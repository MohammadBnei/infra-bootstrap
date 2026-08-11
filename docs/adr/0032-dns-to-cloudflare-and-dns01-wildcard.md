# ADR-0032: Move `bnei.dev` DNS to Cloudflare; DNS-01 wildcard for e2e previews

**Status:** Accepted

## Context

`agent-fleet`'s e2e preview pods are served under one static host with
path-based routing: `https://e2e.bnei.dev/<taskId>/app/`, with a Traefik
`stripPrefix` middleware removing `/<taskId>/app` before the request reaches the
target app's dev server.

The target app is never told what its public base path is — nothing sets a
`--base`/`basePath` in any seeded start command, and nothing consumes the
`X-Forwarded-Prefix` header `stripPrefix` emits. So any app that emits
root-absolute URLs (`/assets/...`, `/api/...`, client-side router links) 404s
under the preview even when the pod is healthy. The app builds links against
`/`, but `/` belongs to no task.

`agent-fleet/docs/adr/0012` chose path routing for a concrete reason, and it was
correct at the time: no wildcard DNS existed, and ADR-0001 rejected DNS-01, so
per-task subdomains would have meant a **new Let's Encrypt cert per session**.
LE's limit is 50 new certs per 7 days **per registered domain, shared globally
across every subdomain**, so at ~7 preview sessions/day that would exhaust
issuance for `grafana`/`argocd`/`fleet`/`s3`.bnei.dev for a week. Per-task
subdomains were genuinely unavailable.

The unlock is a **wildcard cert**. One cert for `*.e2e.bnei.dev` covers
unlimited per-task subdomains and never re-issues, making the rate limit
irrelevant. Only DNS-01 can issue a wildcard — TLS-ALPN-01 and HTTP-01
structurally cannot.

A second, independent motivation: every `bnei.dev` hostname is currently a
hand-created A record and all 19 of them point at the same IP. `ARCHITECTURE.md`
§3 carried the standing instruction to "add each new one by hand as it's
needed", which wildcards eliminate.

### Why this reopens ADR-0001

ADR-0001 rejected DNS-01 on two premises:

> **DNS-01 via the OVH plugin** (for wildcard `*.bnei.dev`) — requires an OVH
> API token plus ongoing plugin maintenance; out of scope for the current design.

- **"plugin maintenance" was mistaken.** Traefik compiles lego in, and Cloudflare
  is a natively supported DNS-01 provider — `dnsChallenge.provider: cloudflare`
  plus a `CF_DNS_API_TOKEN` env var. There is nothing to install or maintain.
- **"an OVH API token"** becomes a Cloudflare API token. The concern is real but
  changes shape — see Consequences.
- **"out of scope for the current design"** is precisely what changed: the e2e
  preview feature now needs per-task hostnames.

This ADR also supersedes the DNS-provider half of **ADR-0030 point 5**, which
recorded that `bnei.dev` is "external DNS at Squarespace, manual per-host A
records, no wildcard". That correction was accurate when written — it fixed an
older doc error that said "Cloudflare". The domain is now genuinely moving to
Cloudflare, which is a new decision, not a revert of that fix.

## Decision

1. **Move the `bnei.dev` zone to Cloudflare.** Registration stays at Squarespace;
   the nameservers change from `ns-cloud-d{1..4}.googledomains.com` (Google Cloud
   DNS — a leftover from the Google Domains acquisition, which the docs
   previously described loosely as "Squarespace DNS") to Cloudflare's.
   Procedure: `docs/runbook-dns-cloudflare-migration.md`. Zone file:
   `docs/dns/bnei.dev.zone`.

2. **Collapse 19 flat A records into 3 wildcards + the apex.** DNS wildcards
   match exactly one label (RFC 4592), so three are required:

   | Record | Covers |
   |---|---|
   | `bnei.dev` | apex |
   | `*.bnei.dev` | argocd, grafana, infisical, alertmanager, pgweb, s3, fleet, proxmox, blog, dreamer, searxng, ente, e2e |
   | `*.ente.bnei.dev` | `api.ente`, `album.ente` |
   | `*.e2e.bnei.dev` | agent-fleet per-task previews |

   Adding a new app hostname no longer requires a DNS change at all.

3. **All records stay DNS-only (grey cloud).** Cloudflare's proxy terminates TLS
   at its edge, which would break Traefik's TLS-ALPN-01 renewal for that host.
   Proxying is not adopted by this decision.

4. **Add a second Traefik cert resolver, `le-dns`**, using ACME DNS-01 via
   Cloudflare, with its own storage file (`/data/acme-dns.json`) on the existing
   PVC. It exists solely to issue `*.e2e.bnei.dev`.

5. **`le` is untouched.** Every existing `*.bnei.dev` host keeps renewing through
   the original TLS-ALPN-01 resolver. No existing certificate is re-issued by
   this change.

6. **cert-manager remains banned.** `DECISION.md` §3 previously bundled
   "cert-manager · DNS-01/OVH plugin" into a single forbidden entry; they are
   separable and only the DNS-01 half is amended. This is Traefik's own built-in
   ACME resolver, not a second cert engine.

7. **DNSSEC stays off.** It is not enabled today. Turning it on requires
   publishing a DS record at the registrar and is a separate change — enabling it
   during a nameserver migration turns a mistake into a total resolution outage.

## Consequences

- **The Cloudflare API token can edit every `bnei.dev` record.** Cloudflare API
  tokens cannot be scoped to a subset of records within a zone, and keeping one
  zone means there is no subzone to scope to. A leak lets an attacker repoint
  `grafana`/`argocd`/`fleet`/`s3`. This is strictly worse than the alternative
  considered below, and is the accepted cost of a single zone. The token needs
  `Zone → DNS → Edit` and should be scoped to the `bnei.dev` zone alone; it is
  held in Infisical as `CF_ACCOUNT_TOKEN`, exposed to Traefik as
  `CF_DNS_API_TOKEN` (the env var name lego fixes), and read by nothing else in
  the cluster. `CF_ACCOUNT_ID` exists in the same project but is unused — lego's
  DNS-01 provider resolves the zone from the challenge FQDN.
- **A record accidentally set to proxied breaks that host's cert renewal
  silently**, surfacing up to 90 days later rather than at cutover. Recorded as a
  known failure mode in the runbook.
- **Mail is the highest-consequence part of the migration.** `bnei.dev` carries
  live Mailgun MX + SPF + a DKIM key at `smtp._domainkey`. A mis-copied DKIM
  record degrades deliverability without producing an error anywhere, which is
  why the runbook requires an end-to-end `dkim=pass`/`spf=pass` check rather than
  a `dig` comparison.
- **`*.bnei.dev` does not cover two-label hosts.** `api.ente.bnei.dev` needs
  `*.ente.bnei.dev`. Easy to trip over when adding a future nested hostname.
- **agent-fleet can now use per-task preview subdomains**, serving apps at `/`
  with no path rewriting. That is a follow-up change in that repo
  (`agent-fleet/docs/adr/0038`), gated on this one having landed and synced.
- Adding a new app hostname is now purely an `IngressRoute`/registry change —
  the manual-DNS-record step in `ARCHITECTURE.md` §3 and the `gitops/README.md`
  add-an-app flow is gone.

## Alternatives considered

- **Delegate only `e2e.bnei.dev` to Cloudflare as a subzone**, leaving
  `bnei.dev` where it was. Strictly better on blast radius — the API token could
  not touch any production hostname. Rejected because it leaves the zone split
  across two providers with an `NS` delegation to maintain, and keeps the
  manual-A-record toil for every non-e2e host. The single-zone move buys the
  wildcard cleanup as well as the wildcard cert.
- **A fixed pool of preview hostnames** (`e2e1..e2eN.bnei.dev`), pre-issued via
  the existing TLS-ALPN-01 resolver. No DNS-01 and no new credential at all, at
  the cost of slot-allocation bookkeeping in the provisioner and a hard ceiling
  of N concurrent previews. Rejected once the zone move made wildcards free.
- **Cookie-scoped routing on the single existing host** — a claim URL setting a
  cookie, with a `HeaderRegexp` router matching it. Zero DNS and zero cert
  change, but limits a browser to one active preview at a time and is a fragile
  matcher. Rejected for the same reason.
- **Per-task certs without a wildcard.** Rejected on the LE rate limit: 50 per
  registered domain per week, shared with every other `bnei.dev` host.
- **cert-manager with the Cloudflare issuer.** Rejected — unchanged from
  ADR-0001. Traefik's native resolver does this without a second cert engine.
