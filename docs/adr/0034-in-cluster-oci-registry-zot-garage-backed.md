# ADR-0034: In-cluster OCI registry (Zot, Garage-backed), with builds moved in-house

**Status:** Accepted
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

### The builder is an LXC, not a pod — corrected after a live failure

This clause originally put the build runner in-cluster as a pod, using
`buildah` with `--isolation chroot --storage-driver vfs`, on the stated
reasoning that this "keeps this an ordinary unprivileged pod — no
`/dev/fuse`, no user namespaces, no seccomp relaxation."

**That was wrong, and it was asserted without being tested.** Those flags
govern buildah's *run* step. Its *storage* step is separate: extracting an
image layer calls `mount --make-rprivate /`, which needs `CAP_SYS_ADMIN`.
In an unprivileged pod it fails with `remount /, flags: 0x44000: permission
denied` (containers/buildah#4920, #5622), which is precisely what the first
real build produced. The genuinely-rootless alternative needs setuid
`newuidmap`/`newgidmap`, which fails under Kubernetes as well (#4049).

That left only a **privileged** container executing an app repo's
`Dockerfile` — a node-level escape risk, and strictly worse than the
identity coupling this ADR splits the runners to avoid. So the builder
moves out of the cluster entirely: `terraform/build-runner.tf` (LXC, VMID
103, `nesting`+`keyctl`) plus
`ansible/playbooks/build-runner-configure.yml`.

Three things fall out, and two of them are improvements rather than
consolations:

- An LXC has real root, so the whole problem class disappears instead of being negotiated around.
- Builds leave the cluster completely — **stronger** isolation than the no-ServiceAccount pod it replaces, since untrusted build content can no longer reach a Kubernetes node at all.
- It is still on the LAN, so nothing about the latency argument changes.

ADR-0035 already commits to an LXC runner for Forgejo, so Phase 2 inherits
this box rather than provisioning a second one.

The reasoning below about *identity* separation is unchanged and is why
this remains a separate runner from ADR-0022's, rather than that one
growing a build capability.

### Why a second runner rather than extending ADR-0022's

ADR-0022's runner holds a projected ServiceAccount token with `create jobs`
in `vos`/`vos-dev`. Adding image builds to that pod means arbitrary
`Dockerfile` execution — and every dependency it pulls — inherits
production-namespace job creation. The relevant erosion is **identity
coupling, not RBAC verb count**: "building needs no new verbs" is a true
answer to a question nobody asked.

So builds get their own runner — now the `build-runner` LXC, per the section
above — with **no Kubernetes identity at all**, and ADR-0022's runner is left
exactly as that ADR describes it. The move out of the cluster strengthened
this rather than weakening it: the original design's "no ServiceAccount
binding" became "no access to the cluster whatsoever."

Two further practical constraints made this unavoidable anyway:

- The existing runner is `RUNNER_SCOPE=repo`, pinned to `vos-monolith`. It
  cannot pick up jobs for `editable-blog`, the intended pilot. Personal
  GitHub accounts cannot register org-level runners, so a second Deployment
  was required regardless.

  **Generalized 2026-08-17, when `agent-fleet` was migrated:** this is not a
  one-off about `vos-monolith`, it is the standing shape. Every build repo
  needs its own runner *instance*, because a repo-scoped runner serves only
  that repo and org-level runners remain unavailable to a personal account.
  Asked directly whether the runner could be shared, the answer is: **the
  box yes, the registration no.** `build-runner-configure.yml` is therefore
  config-driven off a `build_runner_repos` list (the same shape ADR-0030 gave
  `garage-configure.yml`'s `garage_buckets`) — per-instance directory,
  systemd unit and registration; shared user, packages, sudoers and, most
  importantly, shared rootful buildah image store, so `golang:1.26` and
  `oven/bun:1-slim` are pulled once for all repos.

  The cost of that sharing, which is real and worth stating: **one instance
  runs one job at a time.** `agent-fleet` builds six images, so its release
  serializes — and it competes with `editable-blog`'s builds for the box.
  That is the trade for the base-image cache and a 40GB disk that only has to
  hold one copy of each base.
- Builds use **buildah**, not kaniko — `GoogleContainerTools/kaniko` was
  archived upstream in June 2025. On the LXC it runs as real root, so none
  of the `subuid`/`seccomp`/`procMount` machinery an in-cluster attempt
  would have needed applies. (This bullet previously described that
  machinery as "the real cost of this clause, recorded here rather than
  discovered later." It was discovered later anyway — the cost was not a
  relaxation to configure but a capability that cannot be granted without
  making the pod privileged.)

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
  scanning, image signing, ~~GC/retention policy~~, public exposure.

### The storage driver is overlay, not vfs (2026-08-18)

The section above records that the in-cluster attempt used `buildah` with
`--isolation chroot --storage-driver vfs`. When the builder moved to the LXC,
`vfs` came with it — carried into `build-runner-configure.yml` and into both
build workflows without anyone re-asking whether it was still needed. It was
not. `vfs` existed to survive an unprivileged pod; on a real-root LXC it only
costs, because it copies whole layers where `overlay` stacks them.

Measured on the box, cold cache, per component:

| component | vfs | overlay |
|---|---|---|
| worker | 129s | 96s |
| core | 69s | 61s |
| provisioner | 70s | 60s |
| sidecar | 34s | 26s |
| executor | 33s | 27s |
| migration | 5s | 3s |
| **build total** | **340s** | **273s** |

Store size moved the same way: `vfs` held 5.2GB carrying only base images
(per-component images are pruned after each push), `overlay` holds 3.8GB
carrying those base images *plus* all six built ones.

Two things this surfaced that are worth keeping:

- **There was no `/etc/containers/storage.conf` at all.** The driver was
  whatever buildah compiled in, which happened to be `overlay` — so the
  explicit `--storage-driver vfs` in the workflows was the only thing
  selecting the slow path. It is now pinned in that file by the playbook, and
  the flag is gone from every workflow, so builds and the prune timer read one
  setting and cannot drift onto separate stores.
- **`runroot` and `graphroot` are mandatory once that file exists.** buildah
  falls back to built-in defaults only while there is no `storage.conf`;
  creating a driver-only one broke every buildah command instantly with
  `runroot must be set`. Found by verifying rather than by the next release
  failing.

Switching drivers orphans the old store — the prune timer only ever sees the
active driver's tree — so the playbook removes `storage/vfs`, guarded on the
driver not being `vfs`. That reclaimed 5.2GB; the box went from 7.9GB used to
3.9GB of 40GB.

Native overlayfs, not fuse-overlayfs: there is no `/dev/fuse` in this LXC and
the rootfs is ext4. Granting the device would be a Proxmox-host change, and
nothing needs it.

### Retention policy — no longer deferred (2026-08-17)

Decision 8 above kept the *bound* and deferred the *policy*. Migrating
`agent-fleet` is what forced the policy: six images per release, one of them
multi-GB (`worker` carries Claude Code, Playwright deps and a Go toolchain),
against a 40GB quota on a 200GB LXC that also holds `k8s-longhorn-backup`,
`pg-backup`, `agent-fleet-files` and `ente-photos`.

`storage.gc` + `storage.retention` in
`gitops/platform/values/zot/values.yaml`: **last 3 tags per repository plus
`latest`, `deleteUntagged`, `repositories: ["**"]`.**

The count is 3 by explicit choice, tightened from the 5 this section first
carried. It is the user's call on where to sit between disk headroom and
rollback depth, and the trade is stated plainly below rather than treated as a
tunable nobody has thought about: at 3, `agent-fleet` alone burns the whole
window in three releases, so the *only* image guaranteed to be there is the one
currently deployed plus its two predecessors.

Three things about it are decisions rather than defaults:

- **`mostRecentlyPushedCount`, never `mostRecentlyPulledCount` /
  `pulledWithin`.** Those look like better signals — keep what's actually in
  use — and they are actively wrong *given decision 3*. Retention's pull/push
  statistics live in zot's metaDB, a boltdb under `storage.rootDirectory`,
  which decision 3 put on an `emptyDir`. Push order survives, because a
  metaDB rebuild recovers it from the manifests in S3; pull counts exist
  nowhere else. After any restart every tag reads "never pulled", so a
  pull-keyed policy deletes exactly the tags in service. This is the second
  time decision 3's `emptyDir` has reached further than expected — worth
  checking against it before adding anything that keeps registry-side state.
- **`latest` pinned by its own `keepTags` pattern entry** (they are OR'd).
  `gitops/platform/thot/deployment.yaml` and `agent-fleet`'s
  `provisioner/internal/catalog/catalog.go` both float on
  `agent-fleet-executor:latest` deliberately. Losing that tag breaks
  `platform-thot` and every cluster-access session with no version bump to
  point at.
- **Shipped `dryRun: true`, armed 2026-08-18.** This is the one part of the
  registry with a genuinely one-way door: a GC'd blob is gone and the image
  must be rebuilt. Staging it as a dry run is what made the two preconditions
  checkable instead of assumed.

  The first — nothing currently pinned on the would-delete list — was
  confirmed against a real pass: `editable-blog` `0.41.0` keep, `0.39.0` /
  `0.38.0` / `0.37.9` delete, with the live blog running `0.41.0`, so every
  deletion sat below the deployed tag. `agent-fleet` had exactly 3 version
  tags and lost nothing. 3 is tight, but in steady state the deployed tag is
  always the newest, so the exposure is a rollback deeper than 3 releases
  rather than normal operation.

  The second — **that S3 blobs are actually reclaimed** — cannot be answered
  without arming, which is why the baseline was recorded first: 3.3 GB / 144
  objects against the 40 GB quota. zot's docs describe `gc` uniformly across
  storage backends and never exclude remote ones, but that is not evidence,
  and the failure is silent and asymmetric — manifests deleted (rollback depth
  gone) while Garage usage is unchanged (quota still fills). If the bucket
  does not shrink across a GC interval, this reverts to `true`.

Applying it is not automatic: `config.json` is mounted with `subPath`, which
never picks up ConfigMap updates, and nothing notifies the Deployment. An
ArgoCD sync updates the ConfigMap and leaves the pod on the old config — it
takes a deliberate `kubectl -n zot rollout restart deploy/zot`.
