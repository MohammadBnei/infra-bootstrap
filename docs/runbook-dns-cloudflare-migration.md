# Runbook: migrate the `bnei.dev` DNS zone to Cloudflare

**Status:** **run 2026-08-11** — delegation live on
`brady`/`sasha.ns.cloudflare.com`, all wildcards resolving, `le-dns` loaded
in-cluster. Kept for the record and for the next zone move.
**Decision:** [ADR-0033](adr/0033-dns-to-cloudflare-and-dns01-wildcard.md)
**Zone file:** [`docs/dns/bnei.dev.zone`](dns/bnei.dev.zone) — reconciled
against live *after* the move; the mail records no longer match what step 2
below describes (see "What actually happened").

## What actually happened (2026-08-11)

The DNS half went to plan. Mail did not, and every interesting failure was in
that half:

- **Mailgun turned out to be unused.** The MX/SPF/DKIM records this runbook
  carefully preserved were for a provider already replaced by **SMTP2GO** for
  sending. Removing the MX then broke *inbound*, because a forward is still a
  receive — some server must accept the message before relaying it. Resolved by
  enabling **Cloudflare Email Routing** with a catch-all.
- **A `*._domainkey` wildcard publishing `v=DKIM1; p=`** (empty `p` = revoked)
  was live for a while. That revokes every selector not explicitly published,
  including SMTP2GO's. Removed.
- **`aspf=s` was structurally unsatisfiable.** SMTP2GO's Return-Path is the
  subdomain `em726320.bnei.dev`, and strict SPF alignment demands an exact
  match — so DMARC was riding on DKIM alone. Now `aspf=r`.
- **`rua=` pointed at a Gmail address**, which per RFC 7489 §7.1 requires the
  destination domain to publish an authorization record. Gmail does not, so
  aggregate reports would have been silently refused. Now
  `rua=mailto:dmarc@bnei.dev`, which the catch-all forwards to the same inbox.
- **`*.bnei.dev` shadows any hostname an ESP expects to own.** SMTP2GO's
  `em726320`/`link` CNAMEs resolved as A records off the wildcard until created
  explicitly, so verification reported *misconfigured* rather than *missing*.
  Explicit records beat wildcards — just remember to add them.
- **SPF was overwritten three times** mid-work (Mailgun → SMTP2GO → Mailgun →
  Cloudflare-only) before landing correct. Re-check it **last**, after every
  other mail change.

**Lesson for the next zone move:** establish who actually sends and receives
your mail *before* preserving records, rather than copying what the old zone
had. Half the records here were for a provider nobody used.

Moves `bnei.dev` from its current Google Cloud DNS nameservers to Cloudflare,
collapsing 19 flat A records into 3 wildcards, and unlocking ACME DNS-01 so
Traefik can issue the `*.e2e.bnei.dev` wildcard cert that agent-fleet's per-task
preview subdomains need.

This is a **manual, human-run** procedure. Nothing here is ArgoCD-managed —
`bnei.dev` is external DNS, outside the cluster's control.

## Before you start

- **Ordering matters. Do not switch nameservers until step 4 passes.**
- Mail is live on this domain (Mailgun). A missed MX/SPF/DKIM record breaks
  outbound mail *silently* — it shows up as degraded deliverability days later,
  not as an error. Step 7 is not optional.
- Registration is at **Squarespace**; the zone is currently served by
  **`ns-cloud-d{1..4}.googledomains.com`** (Google Cloud DNS, a leftover from
  the Google Domains acquisition). Records are edited in the Squarespace panel;
  nameservers are changed there too.

## Current state (measured 2026-08-11)

| Record | Value |
|---|---|
| `bnei.dev` A | `82.65.231.50` |
| 15× `<host>.bnei.dev` A | `82.65.231.50` — argocd, grafana, infisical, alertmanager, pgweb, s3, fleet, proxmox, blog, dreamer, searxng, ente, e2e |
| `api.ente`, `album.ente` A | `82.65.231.50` — two labels deep |
| `bnei.dev` MX | `10 mxa.mailgun.org`, `10 mxb.mailgun.org` |
| `bnei.dev` TXT | `v=spf1 include:mailgun.org ~all` |
| `smtp._domainkey` TXT | RSA public key (DKIM) |
| CAA | none — Let's Encrypt is not blocked |
| DNSSEC | **not enabled** (no DS, no DNSKEY) |
| TTLs | `14400` (4h) |

`api.voconsteroid.com` / `dev.api.voconsteroid.com` are a **different domain**
and are not touched by this migration.

Re-measure before starting, in case something changed:

```bash
for h in bnei.dev argocd grafana infisical alertmanager pgweb s3 fleet \
         proxmox blog dreamer searxng ente api.ente album.ente e2e; do
  n=$([ "$h" = "bnei.dev" ] && echo "bnei.dev" || echo "$h.bnei.dev")
  printf "%-24s %s\n" "$n" "$(dig +short A "$n" | tr '\n' ' ')"
done
dig +short MX  bnei.dev
dig +short TXT bnei.dev
dig +short TXT smtp._domainkey.bnei.dev
dig +short DS  bnei.dev          # must stay empty — see step 3
```

## Steps

### 1. Lower TTLs on the current zone (≥4h before cutover)

In the Squarespace panel, set every record's TTL to `300`. Existing TTLs are
14400, so without this a mistake takes 4 hours to roll back instead of 5 minutes.

Wait out the old 4h TTL before proceeding.

### 2. Create the Cloudflare zone and import records

Add `bnei.dev` as a zone in Cloudflare, then
**DNS → Records → Import and Export → Import DNS records** using
[`docs/dns/bnei.dev.zone`](dns/bnei.dev.zone).

Three things to get right here:

- **Cloudflare's zone-add scan is a head start, not a source of truth.** DNS
  cannot be enumerated without AXFR, so the scan guesses common names and will
  miss things — `smtp._domainkey` is exactly the kind of record it misses.
  Verify the three mail records by hand against the table above regardless of
  what the scan produced.
- **Delete any flat per-host A records** the scan created (argocd, grafana,
  fleet, …). `*.bnei.dev` supersedes all of them; leaving them behind means
  every future host change has two places to get wrong. Keep only the 8 records
  in the zone file.
- **Every A record must be DNS-only (grey cloud).** The importer defaults
  proxiable records to *Proxied*. A proxied record terminates TLS at
  Cloudflare's edge, which breaks Traefik's TLS-ALPN-01 renewal for that host —
  silently, up to 90 days later. This is the single highest-risk click in the
  migration.

### 3. Do not enable DNSSEC

It is off today. Turning it on requires publishing a DS record at the registrar
and is a separate, independently-rollback-able change. Enabling it mid-migration
turns a DNS mistake into a total resolution outage.

### 4. Verify against Cloudflare's nameservers *before* delegating

This is the safety net — the zone is not yet authoritative, so this is free to
get wrong.

```bash
CF_NS=<your-assigned>.ns.cloudflare.com

for n in bnei.dev grafana.bnei.dev api.ente.bnei.dev foo.e2e.bnei.dev; do
  printf "%-24s %s\n" "$n" "$(dig +short A "$n" @"$CF_NS")"
done                                              # all -> 82.65.231.50

dig +short MX  bnei.dev                    @"$CF_NS"
dig +short TXT bnei.dev                    @"$CF_NS"
dig +short TXT smtp._domainkey.bnei.dev    @"$CF_NS"
```

Compare the DKIM value **byte-for-byte** against the live one from step 0. The
key contains a literal space that is part of the record, not a formatting
artifact — see the note in the zone file.

Do not continue until every line matches.

### 5. Switch nameservers

At Squarespace, replace the four `ns-cloud-d*.googledomains.com` entries with
Cloudflare's assigned pair.

### 6. Verify propagation, then restore TTLs

```bash
dig +short NS bnei.dev              # -> *.ns.cloudflare.com
dig +short A  foo.e2e.bnei.dev      # -> 82.65.231.50 (wildcard live)
dig +short A  grafana.bnei.dev      # -> 82.65.231.50 (unchanged)
```

Once stable, raise TTLs from 300 to something sane (3600+) in Cloudflare.

### 7. Confirm mail still flows

**Do not skip this, and do not substitute `dig` for it.** Send a test message
through Mailgun and inspect the received headers for:

```
dkim=pass
spf=pass
```

A `dig` that returns the right-looking TXT record does not prove the key still
verifies.

### 8. Create the Cloudflare API token

`My Profile → API Tokens → Create Token`, permissions `Zone → DNS → Edit`,
resources limited to the `bnei.dev` zone.

Store it in Infisical (project `infra-bootstrap-1-ge1`, env `dev`, path `/`) as
**`CF_ACCOUNT_TOKEN`**. See `docs/secrets.md`.

**Verify the token actually carries `Zone → DNS → Edit`.** lego does exactly one
thing with it — create and delete `_acme-challenge` TXT records — and fails with
an opaque authentication error if the permission is missing. A token minted for
some other Cloudflare purpose will not work, and the name does not tell you.
Check it before wondering why issuance hangs:

```bash
curl -s -H "Authorization: Bearer $CF_ACCOUNT_TOKEN" \
  https://api.cloudflare.com/client/v4/user/tokens/verify | jq .
```

Prefer a token scoped to the `bnei.dev` zone alone over an account-wide one —
ADR-0033 already records that a zone-wide token can repoint every production
hostname, and an account-wide token is broader still.

`gitops/bootstrap/traefik-cloudflare-secret.yaml` materialises it into the
`traefik` namespace as the `traefik-cloudflare-dns` Secret, which
`gitops/platform/values/traefik/values.yaml` reads as `CF_DNS_API_TOKEN` (that
env var name is fixed by lego, hence the rename).

`CF_ACCOUNT_ID` also exists in the Infisical project but is **not used** —
lego's DNS-01 provider resolves the zone from the challenge FQDN and never takes
an account ID.

### 9. Verify the `le-dns` resolver came up

```bash
kubectl -n traefik get secret traefik-cloudflare-dns
kubectl -n traefik logs deploy/traefik | grep -i 'le-dns\|acme\|challenge'
kubectl -n traefik exec deploy/traefik -- ls -l /data/   # acme-dns.json, 0600
```

Confirm the pre-existing `le` resolver still loads and `acme.json`'s mtime is
**unchanged** — nothing existing should re-issue.

## Rollback

For steps 1-5: switch nameservers back to the four
`ns-cloud-d*.googledomains.com`. The old zone is left fully intact throughout —
that is deliberate, and it is why nothing is deleted there until the migration
is confirmed good.

For steps 8-9: the `le-dns` resolver is purely additive. Removing it from
`gitops/platform/values/traefik/values.yaml` leaves `le` and every existing
cert untouched.

## Known failure modes

| Symptom | Cause |
|---|---|
| A host's cert stops renewing ~90 days later, no error at cutover | That record was left *proxied* (orange cloud); Cloudflare's edge answers the TLS-ALPN-01 challenge instead of Traefik |
| Mail lands in spam, no bounce | DKIM value was "cleaned up" — the literal space inside `p=` was stripped or re-chunked wrong |
| `api.ente.bnei.dev` stops resolving | Someone deleted `*.ente.bnei.dev` assuming `*.bnei.dev` covers it. Wildcards match exactly one label (RFC 4592) |
| Total resolution failure after NS switch | DNSSEC was enabled somewhere in the process, breaking the chain of trust |
| `le-dns` never issues, ACME logs show propagation timeouts | lego is checking propagation through the pod resolver (Pi-hole) instead of `1.1.1.1`/`8.8.8.8` — check `dnsChallenge.resolvers` |
