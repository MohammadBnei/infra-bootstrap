# ADR-0063: LAN clients reach Infisical directly (split horizon)

**Status:** Accepted. Takes effect when `pihole-configure.yml` runs.
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
  `192.168.1.0/24` (ADR-0039 break-glass). Traefik runs
  `externalTrafficPolicy: Local`, so it sees the real LAN peer.
- **Pods must not use this name.** CoreDNS forwards to Pi-hole, so a pod now
  gets `192.168.1.233` too. Under kube-proxy IPVS with `Local` and one Traefik
  replica, only pods on Traefik's node can connect to it; from any other node
  the connection is refused (tested from k8s-worker-01, 2026-10-20). An
  in-cluster client uses the backend Service instead, as all InfisicalSecrets
  already do (`hostAPI: http://platform-infisical-backend…`). No pod calls
  `infisical.bnei.dev` today. The same holds for `stt.bnei.dev`.
- **TLS is unchanged.** The `le` certificate is issued by DNS-01 and is valid
  for the name on any path.
- **In-cluster secret sync is unaffected.** It uses the in-cluster service URL
  (`hostAPI: http://platform-infisical-backend…`), not this name.

### Amendment 2026-10-20: dnsmasq, not dns.hosts
A `dns.hosts` record answers A only. Pi-hole forwarded the AAAA query
upstream, and the build runner, which has an IPv6 route, took Cloudflare's
IPv6 address anyway: `curl` went `via 2a06:98c1:3121::2`. The split-horizon
names now live in `bnei_lan_split_horizon` and become dnsmasq lines,
`local=/<name>/` plus `address=/<name>/<ip>`. The Pi answers them itself and
never forwards them, so the AAAA answer is empty (NOERROR). Measured live
after the change: 10 of 10 runner calls went via `192.168.1.233`, status 200.
`stt.bnei.dev` moved with it for consistency; it has no public AAAA, so its
behaviour is unchanged. The playbook restarts
pihole-FTL only when the lines change.

## Consequences
- On the LAN, Infisical no longer depends on Cloudflare reaching home.
- LAN and pod clients skip Cloudflare's WAF, geo and bot rules for this host.
  The origin lock had already accepted that for every LAN client, and
  Infisical's own authentication is unchanged.
- The record only helps clients that ask Pi-hole. The build runner does
  (`nameserver 192.168.1.55`); a VPN'd laptop does not.
- Infisical now sees LAN callers by their LAN address rather than the WAN IP
  (via Cloudflare's XFF). That is what lets the secret-rotation runbook's
  Trusted IPs plan (`docs/runbook-secret-rotation-2026-10-18.md`, T1) admit
  `192.168.1.0/24`. Callers that bypass Pi-hole still arrive with a public IP.
- This is no precedent for other proxied hosts: each needs its own ADR.
