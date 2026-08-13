# ADR-0034: In-cluster OCI registry (Zot, Garage-backed), with builds moved in-house

**Status:** Proposed
**Amends:** [ADR-0022](0022-self-hosted-actions-runner.md) (adds a *second*,
separate build runner — ADR-0022's cluster-touching runner and its RBAC
scope are deliberately left untouched; see "Why a second runner")

## Context

Every image this cluster runs is built by a GitHub-hosted runner, pushed to
`ghcr.io`, and pulled back down a residential uplink by three nodes.
`VISION.md` names an in-cluster registry as the next step and calls it
"nearly pure upside […] losing it costs rebuilt images rather than lost
work", explicitly ahead of self-hosting git.

The user's drivers, stated directly: **ownership, CI, latency,
observability/reaction, and the biology "one organism" framing**. Alongside
them, one hard rule that shapes the whole design: **stateful data and
stateful objects stay out of the Kubernetes cluster** — the rule that
already put Garage in an LXC (ADR-0030) and Postgres on Pigsty VMs
(ADR-0010).

The latency driver does not close on the registry alone. Today's flow is
GitHub runner → build → push to `ghcr.io` → nodes pull *down*. Self-hosting
only the registry makes a GitHub runner push multi-hundred-MB layers *up* an
asymmetric residential link — the slow direction — and CI gets **worse**.
The registry only pays off when the builder shares the LAN with it. So this
decision necessarily covers the builder too, which is what pulls ADR-0022
into scope.

## Decision

1. **Zot as the registry**, deployed via `gitops/platform/common-app-chart`
   as a platform-common app (public image, no per-app repo — Pattern C says
   this belongs in `platform-common-apps.applicationset.yaml`, not
   `apps/registry.yaml`).

2. **Blobs on Garage S3**, one `zot-registry` bucket provisioned through
   `garage-configure.yml`'s existing `garage_buckets` loop (ADR-0030 made
   that config-driven; this is one list entry, not new tasks).

3. **`dedupe: false`, and the local metadata directory on an `emptyDir`, not
   a PVC.** Zot's S3 driver keeps a local boltdb whose main consumer is
   dedupe; with dedupe off it is scratch. Two things follow, both of which
   were the point:
   - the pod is *genuinely* stateless, so "stateful stays out of the
     cluster" holds in substance and not just on paper, and
   - it sidesteps the ReadWriteOnce-PVC + `RollingUpdate` rollout deadlock
     this homelab has already hit on `agent-fleet` workers.

   If the S3 driver turns out to need durable local metadata (verification
   V4), the fallback is a PVC **plus `strategy: {type: Recreate}`** in the
   same values file — never a PVC with the default rolling strategy.

4. **`htpasswd` push authentication with anonymous read-only, from day one
   — not deferred.** Without it, anything on the LAN, including any pod in
   this cluster (notably `agent-fleet`'s LLM-driven worker pods), can `PUT`
   over a live tag and the nodes will pull and run it. That is a strictly
   *worse* supply-chain posture than the `ghcr.io` status quo, and no stated
   driver asks for it. Anonymous read keeps the containerd configuration
   credential-free.

5. **LAN-only: no `IngressRoute`, no ACME.** `registry.bnei.lan` is a `.lan`
   name, so Let's Encrypt cannot issue for it and `certResolver: le` would
   fail forever. The registry is a `LoadBalancer` Service on a **pinned**
   MetalLB address (`metallb.universe.tf/loadBalancerIPs`, same convention
   as Traefik's `.233`) — pinned because that address is hard-coded into
   DNS, and `selfHeal`/`prune` make Service recreation routine.

6. **containerd is told to trust it via kubespray**, not a standalone
   playbook: `containerd_registries_mirrors` in
   `inventory/ukubi/group_vars/all/settings.yml`. The role default is a
   *list* containing a `docker.io` entry and Ansible replaces lists rather
   than merging them, so that entry is carried forward explicitly or the
   existing `/etc/containerd/certs.d/docker.io/hosts.toml` is orphaned.

7. **DNS is repo-managed**, not manual: `registry.bnei.lan` goes in
   `pihole_hosts_records` in `pihole-configure.yml`. That playbook applies
   the list wholesale via `pihole-FTL --config dns.hosts` on every run, so a
   hand-added record would be silently wiped on the next run — producing
   cluster-wide `ImagePullBackOff` with no config change to blame it on.
   (ADR-0030's manual DNS step was `s3.bnei.dev`, an *external* record. The
   `bnei.lan` zone is the opposite case.)

8. **A bucket quota is part of this decision, not a deferred nicety.** The
   Garage LXC is 200GB total and already carries `k8s-longhorn-backup`,
   `pg-backup`, `agent-fleet-files` and `ente-photos`. An unbounded registry
   does not merely fill its own space — it starves the backup system, and
   Longhorn PV backups, pgBackRest's target and image pulls fail together.
   Retention *policy* is deferred; the *bound* is not.

### Why a second runner rather than extending ADR-0022's

ADR-0022's runner holds a projected ServiceAccount token with `create jobs`
in `vos`/`vos-dev`. Adding image builds to that pod means arbitrary
`Dockerfile` execution — and every dependency it pulls — inherits
production-namespace job creation. The relevant erosion is **identity
coupling, not RBAC verb count**: "building needs no new verbs" is a true
answer to a question nobody asked.

So builds get their own Deployment (`gitops/platform/build-runner/`) with
**no ServiceAccount binding at all**, and ADR-0022's runner is left exactly
as that ADR describes it.

Two further practical constraints made this unavoidable anyway:

- The existing runner is `RUNNER_SCOPE=repo`, pinned to `vos-monolith`. It
  cannot pick up jobs for `editable-blog`, the intended pilot. Personal
  GitHub accounts cannot register org-level runners, so a second Deployment
  was required regardless.
- Builds use **rootless buildah with the `vfs` driver**, not kaniko —
  `GoogleContainerTools/kaniko` was archived upstream in June 2025. Rootless
  buildah needs `/etc/subuid`/`/etc/subgid` and likely a
  `seccompProfile`/`procMount` relaxation; `common-app-chart` emits no
  `securityContext` today. That pod-security delta is the real cost of this
  clause and is recorded here rather than discovered later.

## Alternatives considered

- **Harbor.** The only candidate offering vulnerability scanning, signing
  and per-project RBAC. Rejected: it brings its own Postgres, Redis and
  ~8 components — a heavier *stateful* footprint than the thing it exists to
  store images for, which contradicts the hard rule above, in exchange for
  features explicitly declined for the initial cut.
- **Forgejo's built-in container registry** (i.e. skip the standalone
  registry and wait for ADR-0035). Rejected: it couples every
  `imagePullPolicy` in the cluster to forge uptime. A forge is a web app
  with a database behind it and a far larger restart/upgrade surface; the
  registry should outlive it. It also inverts VISION's stated ordering.
- **Docker `distribution`** (the reference registry). Viable, mature S3
  driver, and the closest runner-up. Zot chosen for active CNCF maintenance
  and native Prometheus metrics, which serve the observability driver
  through the path this cluster already has (Prometheus → Grafana →
  Alertmanager → Discord). Retained as the **pre-vetted fallback**: the
  values shape is unchanged if Zot's S3 driver disappoints.
- **Blobs on Longhorn instead of Garage.** Would survive the `.165` reboot
  through replicas rather than depending on an LXC that goes away. Rejected
  on the hard rule — it is real stateful data inside the cluster. Revisit
  only if verification V8 fails.
- **Keep `ghcr.io`.** The status quo all five drivers are aimed at.
- **Registry exposed publicly via Traefik + basic auth.** Would remove the
  containerd work entirely and give a real certificate. Rejected for now:
  it puts the registry on the internet, which is a different security
  posture than the one asked for. The path is designed (an `IngressRoute` on
  a `bnei.dev` name, as with `s3.bnei.dev`) but deliberately not enabled —
  same shape as ADR-0030's admin-API carve-out.

## Consequences

- **Garage becomes a hard dependency of app pod starts**, and it is
  correlated with the most frequent normal event in this cluster: Garage's
  LXC lives on `.165`, the host rebooted for gaming, and that reboot drains
  `k8s-cp-01`/`k8s-worker-01` onto **cache-cold** nodes at the same moment
  the registry backend disappears. "Node image caches soften it" is
  therefore backwards for exactly the case that matters. Accepted and
  bounded: the reboot is an explicit verification step, plus a quota and an
  Alertmanager rule. If that test fails, blob placement is reconsidered
  before ADR-0035 starts.
- `common-app-chart/templates/service.yaml` hard-codes `type: ClusterIP`, so
  this needs a one-line, default-preserving change to the **shared** chart
  every app uses. It ships as its own PR ahead of the registry.
- `common-app-chart` has no ServiceMonitor template. Zot's is hand-written
  through the existing `extraManifests` hook — `prometheus/values.yaml` sets
  `serviceMonitorSelectorNilUsesHelmValues: false`, so it is picked up.
- The `infisical:` block wires secrets via `envFrom`, which injects keys
  verbatim and **cannot rename them**. Zot needs `AWS_ACCESS_KEY_ID` /
  `AWS_SECRET_ACCESS_KEY`, so its S3 credentials use `env:` with
  `valueFrom.secretKeyRef` instead. Getting this wrong yields silent 403s
  from Garage, or a hang while the AWS SDK falls through to IMDS.
- **Phase 1 is a two-way door for *losing* the registry, but not for
  *reverting* it.** Undoing the containerd trust requires a second
  human Ansible run across every node, and the image reference being rolled
  back lives in a *different repo*. Reversibility here is sequenced, not
  free — see the plan's rollback section.
- `--tags=containerd` re-runs the whole containerd role, three of whose
  tasks `notify: Restart containerd`, while the two that actually write
  `certs.d/*/hosts.toml` notify nothing (containerd re-reads per request).
  Every restart it causes is therefore collateral, and `cluster.yml` has no
  `serial:` and no drain — so it is run `--check --diff` first, by hand, per
  `CLAUDE.md`.

  **Resolved live 2026-08-13:** for *this* change the collateral restart did
  not occur at all. Both the check and real runs reported `changed=2` on all
  five nodes, only the two non-notifying `certs.d` tasks; zero handlers ran;
  all nodes stayed `Ready` with unchanged uptimes. So it was applied to all
  five at once rather than `--limit` one at a time. The warning above still
  stands for a *different class of change* — a containerd version bump, or a
  `config.toml`/systemd-unit edit, reaches the notifying tasks and restarts
  every targeted node simultaneously. The durable rule is therefore not
  "always `--limit`" but "`--check --diff` first and read *which tasks*
  report changed" — a minute that decides whether the careful path is
  needed. See `docs/bootstrap-test-notes.md`.
- VISION credits an in-cluster registry with removing the Docker Hub rate
  limit. Nothing in this decision delivers that — a pull-through cache
  (`extensions.sync`) changes image resolution for *every* workload in the
  cluster, a far larger blast radius than the registry itself. It is
  deliberately a separate, later change.
- **Both runners share one fine-grained PAT, and it cannot be a bot's.**
  Registering a repo-level runner requires the `admin` role. A repository
  owned by a *personal account* has exactly two permission levels — the
  owner, and collaborators, who get write. Granular roles including admin
  are an **organization** feature, so no setting and no paid plan can grant
  a collaborator what this needs. Using the existing `argocd-ukubi-bot`
  account was attempted and refused with a 403 against
  `actions/runners/registration-token` (`admin:false maintain:false
  push:true`). The only route to a bot identity here is migrating these
  repos into a GitHub organization, which would rewrite every `repoURL` in
  `gitops/` — out of proportion to the problem, and not taken.

  So `actions-runner`'s existing `ACCESS_TOKEN` (the repo owner's
  fine-grained PAT, `Administration: Read and write`) is widened from one
  repo to two and shared. That is narrower than the bot alternative would
  have been anyway: it carries *only* `Administration`, so a compromise of
  the build pod means "can register/deregister runners on two repos" — it
  cannot read code or Actions secrets. What it does not separate is
  revocation: pulling that token also stops `vos-monolith`'s `oneOffJobs`.
  Separating the *pod identities* was this ADR's point, and that still
  holds — the build pod has no ServiceAccount and therefore no cluster
  access.
- Deferred and named so they are not mistaken for oversights: vulnerability
  scanning, image signing, GC/retention policy, public exposure.
