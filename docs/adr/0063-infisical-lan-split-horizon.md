# ADR-0063: LAN clients reach Infisical directly (split horizon)

**Status:** Proposed. Takes effect when `pihole-configure.yml` next runs.
**Date:** 2026-10-20
**Related:** [ADR-0038](0038-cloudflare-proxy-dns01-and-origin-lock.md) (proxied records and the
origin lock), [ADR-0039](0039-authentik-identity-layer.md) (the LAN entries in that
lock), [ADR-0044](0044-stt-grpc-service.md) and [ADR-0046](0046-streaming-recognition.md) (the `stt.bnei.dev` split
horizon this copies).

## Context
`infisical.bnei.dev` is Cloudflare-proxied. A LAN client resolves it publicly, so
its request goes home → Cloudflare → home. On 2026-10-20 the home line dropped
connections in both directions. The agent-fleet build runner's "read the
registry password from Infisical" step failed with Cloudflare 522 and 525, and
that failed image builds. From the runner, the same request sent straight to
the Traefik VIP returned 200 in about 16 ms with a valid certificate, 3 out of 3.

`bnei-lan-records.yml` forbids shadowing a proxied host without an ADR, because
LAN clients would skip the WAF and the origin lock might reject them.

## Decision
Pi-hole answers `infisical.bnei.dev` with the Traefik VIP `192.168.1.233`, the
same pattern as `stt.bnei.dev`.

- **The origin lock needs no change.** `cloudflare-origin-lock` already admits
  `192.168.1.0/24` and the pod CIDR `10.233.64.0/18` (ADR-0039 break-glass).
  Traefik runs `externalTrafficPolicy: Local`, so it sees the real LAN peer.
- **TLS is unchanged.** The `le` certificate is issued by DNS-01 and is valid
  for the name on any path.
- **In-cluster secret sync is unaffected.** It uses the in-cluster service URL
  (`hostAPI: http://platform-infisical-backend…`), not this name.

## Consequences
- On the LAN, Infisical no longer depends on Cloudflare reaching home.
- LAN and pod clients skip Cloudflare's WAF, geo and bot rules for this host.
  The origin lock had already accepted that for every LAN client, and
  Infisical's own authentication is unchanged.
- The record only helps clients that ask Pi-hole. The build runner does
  (`nameserver 192.168.1.55`); a VPN'd laptop does not.
- This is no precedent for other proxied hosts: each needs its own ADR.
