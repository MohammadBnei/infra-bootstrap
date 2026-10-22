# ADR-0056: `mountain.bnei.dev` — a public, live 3D view of ukubi, fed by PromQL only

**Status:** Accepted — decided 2026-10-14, approved by M BN. Decisions 2–3
amended by [ADR-0064](0064-mountain-town-roles-and-guest-probes.md) (platform
services and infra guests public by role key; guests probed by blackbox). This PR lands the
groundwork only: `dbuser_mountain`/`mountaindb` in `pigsty/pigsty.yml` and the
`mountain` build-runner instance. **Live 2026-10-14:** runner
`ukubi-build-mountain` online; `dbuser_mountain`/`mountaindb` created against
`.205` (Patroni leader, `ignored=0`), with connlimit, owner, revoked PUBLIC
connect and a VIP login verified. The app registration (`/add-app`) waits for
the first image.
**Date:** 2026-10-14
**Related:** [ADR-0032](0032-thot-rbac-and-alerting.md) (the one broad read
grant, which this deliberately does not repeat),
[ADR-0034](0034-in-cluster-oci-registry-zot-garage-backed.md) (build-runner),
[ADR-0038](0038-cloudflare-proxy-dns01-and-origin-lock.md) (proxying, origin
lock), [ADR-0053](0053-hq-dashboard-public-client-loopback-redirect.md) (the
database shape copied here). The app-side plan lives in the private
`MohammadBnei/mountain` repo under `plan/`.

## Context

`mountain` is a scroll-story landing page, a sibling of pi-lab's, that ends in
a live 3D mountain: real cluster events reshape it while you watch. A deploy
erupts and leaves new land, an alert sags the glacier, traffic lights the
summit. It is **public**, so it publishes facts about the cluster to anyone,
and it needs a way to read those facts.

Two things make that architecturally significant here:

- the obvious way to read cluster events (client-go informers on pods, events,
  nodes, Applications) needs a ClusterRole on an internet-facing pod, declared
  from an app repo this one does not review;
- whatever the page shows, the internet sees.

## Decision

1. **PromQL only, no RBAC.** The relay reads Prometheus
   (`platform-prometheus-kube-p-prometheus.monitoring:9090`) and Alertmanager,
   nothing else in the cluster. kube-state-metrics, the ArgoCD metrics,
   node-exporter, kubelet and blackbox already carry every signal the view
   needs. The relay gets no ServiceAccount token, no Role, and no change to
   `common-app-chart`. Cost: events arrive within about 45 s instead of
   instantly, which a visualization does not mind.

2. **Public data is built by allowlist, never by deletion.** What the public
   socket and `/api/topology` may carry:
   - app names from an explicit allowlist in the relay's config. e2e previews,
     has-journal and admin apps never appear; anything unlisted is an
     anonymous "other";
   - hosts as `h1..h3`, never hostnames; a `platform|user` group, never a
     namespace;
   - bucketed values only;
   - alerts as a salted fingerprint hash, severity and layer, with no text;
   - no versions. The story copy states major versions statically.

   Exact values exist only in a detail mode for `platform-admins` (a later PR).

3. **What has no source is drawn as unmeasured, never invented.** Garage's
   admin port 3903 stays unexposed on purpose, and Pigsty's metrics live in
   its own VictoriaMetrics, so both show as dim and static. Adding a scrape job
   for either is a separate decision.

4. **The page's "river" is public traffic**: the sum of Traefik response
   bytes across allowlisted apps. Node NIC transmit was rejected because it is
   dominated by Longhorn replication.

5. **Database: `dbuser_mountain` and `mountaindb` in hq's shape.** A SCRAM
   verifier is committed and the plaintext is `DBUSER_MOUNTAIN_PASSWORD` in this
   repo's Infisical project. `pgbouncer: false` because the relay is Go/pgx
   dialing 5432 direct. `revokeconn`, no Grafana datasource. `connlimit: 10`,
   because the relay runs one replica with `Recreate`. The relay **must set
   pgxpool `MaxConns` explicitly (≤ 8)**: the default is `max(4, NumCPU)`,
   which on a node with more than 10 CPUs would exceed the ceiling and fail
   with `too many connections for role` (hq's comment in `pigsty.yml`).

6. **Build on the build-runner LXC** as its own instance, per ADR-0034. The
   repo is **private**, so no fork PR can run on the box that holds the zot
   push credential.

7. **`CF-Connecting-IP` is trusted only from Cloudflare ranges.** The origin
   lock (ADR-0038) also admits the LAN and the pod CIDR, where the header
   could be forged. Rate limits fall back to the TCP peer there. Accepted.

8. **Visitor accounts are out of scope.** The page's planned visitor layer
   (shared marks behind authentik self-enrollment) needs its own ADR first. It
   will cover captcha, the shared SMTP2GO sender, moderation and a kill
   switch. Nothing here opens enrollment.

## Consequences

- One new public surface that writes nothing yet: a read-only socket of
  bucketed, allowlisted facts.
- The allowlist and the relay's `namespace → app` map drift from
  `gitops/apps/registry.yaml` unless checked. The relay exports
  `mountain_unmapped_total`, and the app repo's CI diffs against the registry.
- The relay's own staleness alerts run at `severity: info`. Discord only;
  `warning` would wake thot.

## Rollout

1. This PR: the Pigsty user and DB, and the runner entry.
2. M BN: add `mountain` to the `ACCESS_TOKEN` PAT's repo list, run
   `build-runner-configure.yml`, then `pgsql-user.yml` and `pgsql-db.yml`.
3. With the first image: `/add-app` for `mountain.bnei.dev` (baseline
   middleware on, metrics on a separate unrouted port) and the Traefik scrape
   interval lowered to 15 s.
