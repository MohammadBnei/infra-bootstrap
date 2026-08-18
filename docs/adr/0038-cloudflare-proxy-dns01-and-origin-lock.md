# ADR-0038: Proxy `bnei.dev` through Cloudflare; move `le` to DNS-01; lock the origin

**Status:** Proposed
**Date:** 2026-08-18
**Amends:** [ADR-0033](0033-dns-to-cloudflare-and-dns01-wildcard.md) (reverses its
§3 "proxying is not adopted" and its §5 "`le` is untouched"),
[ADR-0001](0001-ingress-traefik-ingressroute-over-gateway-api.md) (TLS-ALPN-01 →
DNS-01 for the `le` resolver; the cert-manager rejection is untouched)
**Touches:** [ADR-0030](0030-expose-garage-s3-externally.md) (`s3.bnei.dev` now
transits a third-party proxy)

## Context

Everything this cluster serves to the internet arrives through one path: the
Freebox port-forwards TCP 80 and 443 to Traefik's MetalLB VIP `192.168.1.233`.
In front of that path there is no WAF, no rate limit, no geo filter, no bot
mitigation, no DDoS absorption, and — until this change — **no access log at all**,
so there is no record of who has been knocking.

Because `*.bnei.dev` is a wildcard A record, creating an `IngressRoute` publishes a
hostname to the internet with no DNS step and no review gate. Sixteen hostnames are
currently reachable. Of those, `proxmox.bnei.dev` is a hypervisor root login and
`infisical.bnei.dev` is the secrets store itself; both are protected by nothing but
the application's own login form. Four services share a single `apr1`/MD5 htpasswd
credential whose hash is committed in the legacy `k8s-cluster` repo's git history
and was deliberately not rotated during migration.

ADR-0033 moved the zone to Cloudflare but explicitly declined the proxy: *"All
records stay DNS-only (grey cloud). Cloudflare's proxy terminates TLS at its edge,
which would break Traefik's TLS-ALPN-01 renewal for that host. Proxying is not
adopted by this decision."* That reasoning was correct at the time. It is also the
only thing standing between this cluster and a large, free reduction in exposure —
and ADR-0033 itself built the mechanism that dissolves it, by proving DNS-01 works
against this zone with this token for the `*.e2e.bnei.dev` wildcard.

The blocker is therefore not technical. It is that `le` is still on TLS-ALPN-01,
and a proxied record breaks that renewal **silently, up to 90 days later** — the
failure mode `docs/dns/bnei.dev.zone` warns about in its own header.

### What made this harder than it looked

Three constraints surfaced during review and shape the decision below:

1. **`api.voconsteroid.com` and `dev.api.voconsteroid.com` are a different domain**
   (`docs/runbook-dns-cloudflare-migration.md:76`) served by the same Traefik and
   renewed by the same `le` resolver. The Cloudflare token carries `Zone → DNS →
   Edit` on **bnei.dev only**. Moving `le` to DNS-01 without addressing this would
   silently kill renewal for both hosts — precisely the failure this ADR exists to
   prevent. Worse, leaving them grey-cloud republishes `82.65.231.50`, and one
   grey record voids the WAF for every proxied host: an attacker who learns the
   origin IP connects direct on 443 with any `Host:` header they like.
2. **Cloudflare's Universal SSL covers the apex and first-level subdomains only.**
   `*.ente.bnei.dev` and `*.e2e.bnei.dev` would fail edge TLS unless Total TLS /
   Advanced Certificate Manager is purchased.
3. **Client source IPs are not visible today.** Traefik's Service has no
   `externalTrafficPolicy`, so it defaults to `Cluster` and kube-proxy SNATs every
   request to a node IP. Any IP-based control — an origin allowlist, a rate limit,
   a LAN break-glass route — would be silently inert.

## Decision

1. **Move `voconsteroid.com` to Cloudflare as a prerequisite**, and widen the API
   token to `Zone → DNS → Edit` on both zones. This is a blocking step, not a
   follow-up: the alternative is a permanently grey host that defeats the whole
   perimeter. `docs/runbook-dns-cloudflare-migration.md` is the rehearsed procedure.

2. **`le` moves from `tlsChallenge` to `dnsChallenge` (Cloudflare).** The resolver
   name stays `le` and `storage: /data/acme.json` stays, so no `IngressRoute`
   changes anywhere: `acme.json` is keyed by resolver name and records no challenge
   type, the ACME account and cert list are reused, nothing re-issues at startup,
   and renewal at T-30d simply uses the new challenge. The explicit
   `1.1.1.1`/`8.8.8.8` propagation resolvers carry over from `le-dns` — the pod
   resolver forwards to Pi-hole, which has no business answering for `bnei.dev`.

   **This reverses ADR-0033 §5 ("`le` is untouched"), not merely its §3.**
   `DECISION.md` §3's `⚠️ DNS-01 as the cert engine for le` bullet is rewritten
   rather than appended to. cert-manager remains banned; this is still Traefik's
   own lego, with Cloudflare as a native provider and no plugin to maintain.

3. **All A records go proxied; SSL/TLS mode is Full (strict).** `Flexible` would
   send plaintext to the origin and is never acceptable here. **CNAMEs stay grey** —
   `em726320.bnei.dev` (SMTP2GO return path), `link.bnei.dev` and
   `s726320._domainkey` break bounce handling, click tracking and DKIM verification
   if proxied, and Cloudflare's UI defaults edited CNAMEs to proxied.

4. **Geo filtering happens at Cloudflare's WAF, not in Traefik.** This deliberately
   does not port `k8s-cluster/traefik/middlewares/geoblock.yml` forward: that plugin
   makes a per-request HTTP call to `get.geojs.io`, putting a third-party API on the
   request path with a 150ms timeout. A WAF custom rule costs nothing, runs before
   traffic reaches the house, and absorbs the request instead of forwarding it.
   A skip rule for `argocd.bnei.dev/api/webhook` comes first — GitHub's webhook
   egress is US-based, and a geo rule would otherwise silently degrade GitOps to
   3-minute polling with no alert.

5. **The origin is locked to Cloudflare.** A Traefik `ipAllowList` middleware
   (Cloudflare's published v4+v6 ranges, plus `192.168.1.0/24`, plus the pod CIDR)
   is attached at **entrypoint level** on `websecure`, so it evaluates the raw TCP
   source before any forwarded-header handling. Without this, proxying is
   decoration: the origin IP is discoverable and every WAF rule is one `curl
   --resolve` away from irrelevant.

6. **`externalTrafficPolicy: Local` on Traefik's Service, with a named cost.** It is
   required for (5) and for the LAN break-glass route in ADR-0039. It is not free:
   MetalLB's L2 speaker announces only from a node holding a ready local endpoint,
   and Traefik runs `replicas: 1` with `Recreate` and an RWO `acme.json` PVC. During
   any Traefik rollout there are zero endpoints and **nothing answers ARP for
   `.233`** — a blackhole, not a drain, bounded by Longhorn detach/attach. Adding
   replicas is not available: ADR-0001 mandates a single `acme.json` writer.

7. **Deep wildcards are renamed, not purchased.** `api.ente` → `ente-api`,
   `album.ente` → `ente-album`, `<shortId>.e2e` → `<shortId>-e2e`, and
   `dev.api.voconsteroid.com` → `dev-api.voconsteroid.com` — all first-level and
   therefore covered by Universal SSL for nothing. `*.ente.bnei.dev`,
   `*.e2e.bnei.dev` and `*.api.voconsteroid.com` are deleted.

   The voconsteroid case was confirmed live on 2026-08-18: with
   `*.api.voconsteroid.com` proxied, `dev.api.voconsteroid.com` returned no
   certificate at all and the TLS handshake failed before HTTP — the edge has
   nothing to present for a second-level name. `api.voconsteroid.com`, one level
   deep, served normally from the `CN=voconsteroid.com` Universal SSL cert. That
   is the whole constraint, reproduced. This is preferred over Advanced Certificate
   Manager because it is a one-time change against a recurring fee.

8. **Traefik access logging is enabled** (JSON, matching `logs.general`). Alloy
   already tails `/var/log/pods` on every node, so these reach Loki under
   `{namespace="traefik"}` with no collector change. This is a prerequisite for any
   detection work and closes a gap that predates this ADR.

## Consequences

Named explicitly so they are not later mistaken for oversights:

- **Cloudflare terminates TLS for every host, including `infisical.bnei.dev`.**
  Every secret fetched through that hostname, every ArgoCD session token and every
  Proxmox root credential transits a third party in plaintext at their edge. Under
  an ADR whose stated priority is attack-surface reduction this is a real
  counter-current, and it is accepted knowingly: the exposure it removes (an
  unauthenticated internet path to a hypervisor login and a secrets store) is
  judged larger than the exposure it adds. It is not a free win and should not be
  described as one.
- **Cloudflare becomes an availability dependency for all external access.** The
  break-glass path is physical/LAN via Proxmox, which is unaffected.
- **The API token now spans two zones and sits on the renewal path for every host.**
  ADR-0033 already accepted that a zone-wide token can repoint every production
  hostname; it can now do so in two domains, and token expiry or revocation becomes
  a cluster-wide certificate outage with a 90-day fuse. That fuse is the reason
  ADR-0040 adds a `traefik_tls_certs_not_after` expiry alert.
- **`le` and `le-dns` are now one failure domain.** ADR-0033 §4 gave them separate
  storage files so a DNS-01 failure could not take down the resolver serving every
  other host. With both on DNS-01, the same provider and the same token, that
  separation buys nothing but two files. Kept for now because collapsing them is a
  second migration; the justification is retired, not the resolver.
- **New hostnames get HTTP 526 during their first issuance.** Traefik orders on the
  first TLS handshake for an unknown SNI and serves a self-signed default meanwhile;
  Full (strict) rejects that. The window is DNS-01 propagation — 30–120s — and is
  permanent if the order fails, with Cloudflare's error page hiding the ACME error.
  Previously this presented as a browser cert warning that a retry resolved.
  Mitigated by issuing `*.bnei.dev` through `le-dns` as the default store cert.
- **Every Traefik rollout and every node drain is now an ingress outage** (see
  Decision 6). Traefik values changes stop being routine.
- **Port 80 remains an unfiltered entrypoint.** The origin allowlist is
  `websecure`-only; port 80 serves nothing but a redirect, but it is still open.
- **`s3.bnei.dev` now transits a proxy that normalizes URI paths**, while S3 SigV4
  signs the encoded path. A mismatch surfaces as `SignatureDoesNotMatch`, which
  reads as an auth bug rather than a proxy bug. Every consumer must be retested,
  including `ente-museum`. Cloudflare Free also caps proxied request bodies at
  100MB; current payloads are well under it.
- **Long-lived responses die at 100 seconds (HTTP 524) on the free plan.**
  `fleet.bnei.dev` serves ConnectRPC streaming and needs a sub-100s heartbeat frame
  before it can be proxied.
- **A stale bookmarked Ente or preview URL now returns NXDOMAIN**, not a TLS error —
  a harder failure for an already-configured mobile client.
- **The renames require coordinated changes in `agent-fleet`** (`names.go`'s
  `PreviewHostFor` and `PreviewDomainFor`, `config.go`'s `E2eHost`) plus a
  provisioner image rebuild on the `build-runner` LXC. The `*.bnei.dev` cert must
  exist before previews are renamed, or every preview serves the self-signed default.
- **`ARCHITECTURE.md` §3 and ADR-0033 §2 claim `*.bnei.dev` does not cover deeper
  names, while `docs/dns/bnei.dev.zone` argues the closest-encloser rule.** The
  renames make the disagreement moot, but the docs are reconciled as part of this
  change rather than left contradicting each other.

## Alternatives considered

- **Stay grey-cloud; do everything in Traefik** (geoblock plugin + CrowdSec
  bouncer). This is the status-quo-preserving option and has working prior art in
  the legacy repo. Rejected: the geoblock plugin puts a third-party HTTP call on
  every request path; CrowdSec is a stateful service plus a LAPI plus a bouncer
  plugin to operate; and neither absorbs a volumetric attack nor hides
  `82.65.231.50`. Cloudflare provides all three at the edge for nothing.
- **Advanced Certificate Manager (~$10/mo) to keep the deep wildcards.** Rejected:
  three hostname renames are a one-time cost against a recurring fee, and they also
  simplify the zone from four web records to two.
- **Cloudflare Tunnel (`cloudflared`) instead of the port-forward.** Genuinely
  attractive — it closes 80/443 entirely, removes the need for the origin allowlist,
  removes the need for `externalTrafficPolicy: Local` and therefore removes the
  rollout-outage consequence above. Rejected: it introduces a new always-on daemon
  as a hard dependency for all inbound traffic, with no LAN-independent path if it
  fails, and it is a larger change than the one being made here. Worth revisiting if
  the `Local` outage window proves annoying in practice.
- **Cloudflare Origin CA certificates instead of ACME.** Free, 15-year, wildcard at
  any depth, trusted by Cloudflare in Full (strict) — this would delete both ACME
  resolvers and the whole renewal-failure class. Rejected: it makes the origin
  unreachable by anything except Cloudflare (the cert is not publicly trusted), which
  breaks the LAN break-glass path ADR-0039 depends on, and it trades a 90-day
  renewal risk for a silent 15-year one.
- **Delegate only the deep subdomains to a second zone.** Rejected for the same
  reason ADR-0033 rejected it: it splits the zone across providers for a blast-radius
  gain that the renames achieve more cheaply.
- **Do nothing and rely on per-app authentication.** Rejected: it is the current
  state, and it leaves a hypervisor root login and a secrets store answering
  unauthenticated connections from the entire internet.
