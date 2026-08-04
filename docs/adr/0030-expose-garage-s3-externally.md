# ADR-0030: Expose Garage's S3 API externally at `s3.bnei.dev`

**Status:** Accepted

## Context

Garage (S3-compatible object storage, off-cluster LXC `garage-storage`,
`192.168.1.199`) has been LAN-only since it replaced MinIO: its S3 API
(port 3900) is reachable at `http://garage.bnei.lan:3900` for in-cluster
consumers (Longhorn backup target, and soon pgBackRest), but nothing
outside the LAN can reach it. `ARCHITECTURE.md` §7 already named
`s3.bnei.dev` via Traefik as the intended target; `garage-configure.yml`'s
own closing message flagged it as "a separate follow-up." The user asked
to actually expose a bucket externally with an API-key system.

Garage already has its own key system (`garage key create` +
`garage bucket allow`, scoped per bucket, SigV4-signed requests) — that
*is* the API-key system, nothing new needed there. What was missing was
(a) a network path from the internet to Garage's S3 port, and (b) bucket
and key provisioning being config-driven enough to add a new bucket
without copy-pasting a block of Ansible tasks each time.

A stale sketch already existed at `k8s-cluster/garage/service.yml`
(legacy submodule, not wired to ArgoCD) showing the right shape — a
headless Service + Endpoints bridging Traefik to an off-cluster IP — but
it pointed at the wrong IP (`.210` instead of `.199`) and used a
`cert-manager` `Certificate` resource, which is a forbidden pattern in
this repo (`DECISION.md` §3) — Traefik's built-in ACME (`certResolver:
le`) is the only cert engine used here (ADR-0001).

## Decision

1. **Expose Garage's S3 API at `https://s3.bnei.dev`** via a new
   `gitops/redirectors/garage-s3.yaml`: headless `Service` + `Endpoints`
   pointing at `192.168.1.199:3900`, plus an `IngressRoute` with
   `tls.certResolver: le` — same pattern as every other app's
   IngressRoute, no `cert-manager`.
2. **Authenticated S3 API only.** No anonymous/public bucket reads are
   enabled. Every request must be SigV4-signed with a Garage-issued key
   scoped to the specific bucket it's reading/writing. Garage's
   website/public-access feature is explicitly not enabled by this
   decision — if a future need calls for public unauthenticated reads,
   that's a separate decision with a different security posture, not a
   silent extension of this one.
3. **Garage's admin API (port 3903) stays out of scope.** It remains
   bound to `127.0.0.1` on the LXC (already the case) and gets no
   Service/route. Nothing external, and nothing in-cluster, consumes it.
4. **Bucket/key provisioning becomes config-driven**, not hardcoded per
   bucket: `garage-configure.yml`'s two previously-duplicated per-bucket
   task blocks (Longhorn, pgBackRest) collapse into one `garage_buckets`
   list, looped over for bucket creation, key creation, per-bucket
   `garage bucket allow --read --write`, and the matching Infisical
   write (`<prefix>_S3_ACCESS_KEY`/`_SECRET`). Adding a bucket — internal
   or external-facing — is now one list entry; there's no separate
   "internal vs external" bucket flag, since exposure is decided
   entirely at the Traefik layer (one shared S3 endpoint, same as AWS
   S3), not per-bucket. See the new `garage-ops` skill for the
   operational workflow.
5. **`s3.bnei.dev`'s DNS record is a manual step**, not something ArgoCD
   or this repo can create: `bnei.dev` is external DNS at Squarespace,
   manual per-host A records, no wildcard (see the DNS-provider
   correction bundled into this same change — `ARCHITECTURE.md`,
   `DECISION.md`, and `docs/infrastructure-actual.md` previously said
   "Cloudflare"/implied a wildcard, which was wrong).

## Consequences

- Longhorn and pgBackRest are unaffected — they keep using
  `garage.bnei.lan:3900`, no config change on their side.
- A second, public network path to Garage now exists. The security
  boundary is entirely Garage's own per-key bucket ACLs plus TLS —
  there's no additional network-layer restriction (no IP allowlist, no
  rate limiting) in this first cut. Rate limiting / per-key quotas are a
  deliberate non-goal for v1: Garage's own auth is the control; a
  Traefik `RateLimit` middleware can be added later if abuse is observed
  — nothing to build speculatively now.
- `k8s-cluster/garage/service.yml` (the stale, wrong-IP, cert-manager
  sketch in the legacy submodule) is now doubly superseded. Cleaning it
  up is a separate change in that submodule's own repo, not covered
  here — flagged so it doesn't get mistaken for the live config.
- Any future bucket, internal or external, goes through the same
  `garage_buckets` list — no more hand-rolled per-bucket Ansible blocks.
