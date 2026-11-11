# ADR-0071: Target platform: four servers, Talos first, one registry entry per app

**Status:** Proposed. Sets the direction only. Each step below lands as its
own PR, and every ADR it supersedes is amended in that step's PR, not here.
**Date:** 2026-11-11
**Related:**
- [ADR-0070](0070-talos-pilot.md) and
  [`docs/plan-talos-pilot-esprimo.md`](../plan-talos-pilot-esprimo.md): the
  pilot that decides the OS and Postgres legs;
- [`docs/evaluation-drop-proxmox-talos.md`](../evaluation-drop-proxmox-talos.md);
- [ADR-0035](0035-self-hosted-forgejo-authoritative-github-mirror.md)
  (Forgejo), [ADR-0034](0034-in-cluster-oci-registry-zot-garage-backed.md)
  (builds), [ADR-0029](0029-postgres-automatic-failover-3-node-etcd-quorum.md)
  (Patroni), [ADR-0004](0004-gitops-pattern-c-registry-applicationset.md)
  (Pattern C), `VISION.md` principle 8 (restore path).

## Context

Two Esprimo G558s arrived (32 GB, 1 TB SSD each). With server1 and `.165`
that makes four capable servers, plus ex-laptop and the Pi. The owner chose
to design the target layout instead of bolting the Esprimos on (#376).

The pains the owner named:
1. **Postgres:** the 2026-08-15 timeline divergence needed a hand reinit
   (ADR-0029), and day-to-day Postgres work means SSH keys, Ansible runs,
   LAN access and a separate observability stack (Pigsty's vector +
   VictoriaMetrics).
2. **New apps:** shipping one app takes about twelve steps over five repos
   and tools, and no file lists them all. The registry also has to be
   mirrored by hand into `bootstrap/apps.applicationset.yaml`
   (`gitops/apps/registry.yaml:3-4`).
3. **Ownership:** git is on GitHub; the owner wants self-hosted git first.

The plan went through a four-angle doubt cycle (architecture, solo
operator, failure/security, facts and capacity): 10 blockers and 27 majors,
folded in below.

## Decision

### Hardware roles
1. **`.165` becomes a dedicated always-on server.** Windows gaming on it
   ends, so its reboots stop costing quorum and data.
2. **Cluster = server1, `.165`, esprimo-1, esprimo-2.** Three of them carry
   the control plane.
3. **ex-laptop leaves the cluster** and becomes the backup host: restic of
   Garage, the pgBackRest repo, Longhorn's backup target. No etcd, no k8s.
   Its USB NIC stops being a quorum risk.
4. **The Pi stays** DNS and jump host, outside the cluster.

### Data
5. **HA stays** for the control plane (3 nodes) and Postgres.
6. **Garage: 3 zones, `replication_factor` 3, on `.165`, esprimo-1 and
   esprimo-2.** Not server1: its single 476 GB NVMe can't hold a full copy
   (rf 3 puts one on every zone, about 550-650 GB). Image pulls and S3 keep
   working with one host down.
7. **Backups go to ex-laptop's disk**, never to the host whose data they
   copy.
8. **Off-site: an offline USB disk kept at family, copied monthly**, for
   what can't be rebuilt: ente-photos, database dumps, an Infisical export,
   the git repositories. Up to a month stale; accepted by the owner. This
   meets `VISION.md` principle 8 for a fire or theft, at a month's lag.
9. **A tested restore comes before any wipe.**

### Delivery
10. **Forgejo is primary, GitHub a push mirror** (ADR-0035's direction).
    CI is Forgejo Actions; ArgoCD syncs from Forgejo on a webhook.
    agent-fleet stays on GitHub until it is ported.
11. **Builds run in-cluster, rootless BuildKit, isolated:** a dedicated
    namespace, nodes tainted for builds, no access to app secrets, network
    policy to Forgejo and zot only. Conditional on the pilot proving it on
    Talos (user namespaces, seccomp/AppArmor); otherwise a build VM.
    Supersedes ADR-0034's build clause when it lands.

### One registry entry per app
12. **One file per app in one central folder**,
    `gitops/apps/registry/<app>.yaml`, read by an ApplicationSet git-files
    generator. This replaces the hand mirror. A JSON schema is checked in
    CI; the template fails on a missing key (`missingkey=error`, today
    `missingkey=zero`).
13. **Fenced:** generated apps run in an `apps` AppProject with a namespace
    and repo allowlist, not `project: default`
    (`apps.applicationset.yaml:211`). Approval is Forgejo branch protection
    plus a required review. The agent fleet edits the registry only through
    PRs that pass the same gate.
14. **A registry edit never deletes data.** `preserveResourcesOnDeletion`
    on the ApplicationSet; `Retain` on volumes, databases and buckets;
    generated secrets never regenerate. Each entry has a fixed `id` apart
    from its name, and removal is two steps: mark retired, then an
    explicit delete PR.
15. **One entry can declare:** image build and deploy (zot by digest,
    `common-app-chart` v2); Postgres database, roles with `connlimit`,
    extensions; a Garage bucket and its key; volumes; secrets; authentik
    SSO; hostname and route; dashboard, alerts, log stream and SLO;
    opt-in previews.
16. **Secrets:** the platform generates the ones it owns (database
    password, S3 keys, OIDC client secret) into Infisical. External keys
    are listed by name; the owner pastes them into Infisical and the app
    reports "blocked: X missing" until they exist. No value ever in git.
17. **Previews** are opt-in per PR by a command in the PR body or a label,
    short-lived, at most two at a time.

### Reconciler
18. **`common-app-chart` v2 emits existing operators' resources:** the CNPG
    `Database` (if CNPG wins the pilot), `IngressRoute`, `PrometheusRule`,
    `InfisicalSecret`.
19. **A small Go controller covers only what no maintained operator
    covers:** per-app CNPG roles and `connlimit` (they live in the shared
    `Cluster`'s `managed.roles`, which a per-app chart can't own), the
    per-app authentik OIDC client and policy (blueprints are a fixed list
    in `values/authentik/values.yaml:57-81`), and a Garage bucket with a
    scoped key. Generated secrets go to the Infisical operator first; Go
    only if it can't. The controller's credentials are scoped per kind,
    and it grants keys only for buckets declared in the registry. It needs
    a name other than "provisioner", which agent-fleet already uses.
20. **Ordering uses ArgoCD sync waves and Lua health checks** for the CNPG,
    InfisicalSecret and controller resources. The Argo app tree is the one
    place to look when a deploy breaks. There is no `UkubiApp` CRD.
21. **Status is aggregated by atlas, not by a platform object.** The
    registry is atlas's `declared` column, operator status its `applied`
    column, discovery its `discovered` column. atlas never writes.

### Observability
22. **One Prometheus, Loki and Grafana** for everything, with node-exporter
    and smartctl-exporter on every server and ex-laptop. Postgres metrics
    and logs join the same stack.
23. **A heartbeat outside the cluster:** the Watchdog alert goes to an
    external dead-man service (today it routes to `null`,
    `gitops/platform/values/prometheus/values.yaml:25-35`).
24. **WAL-archive and backup-age alerts**, so a dead backup disk pages
    instead of silently filling Postgres.

### Order of work
The owner chose **Talos first, then the platform**:

| Step | What |
| --- | --- |
| M0 | Backup host with a tested restore, the first offline-disk copy, outside heartbeat, WAL-archive alerts, Patroni timeline alerts on today's stack |
| M1 | Pilot (ADR-0070) with the added tests T24-T28 |
| M2 | Go/no-go. On go: host-by-host Talos rebuild, each host its own window with a written degraded-HA plan |
| M3 | Forgejo, mirrored with GitHub; ArgoCD's source flips |
| M4 | Garage rf 3 filled by an rclone copy |
| M5 | Postgres per the pilot (CNPG one database at a time, or Pigsty kept); the first CNPG write is the point of no return |
| M6 | Registry v2, `common-app-chart` v2, the controller, one app at a time |
| M7 | Builds in-cluster; the build-runner LXC retires |
| M8 | Previews |

A no-go keeps Proxmox; M3-M8 still apply on top of it.

## Alternatives considered

- **Esprimos as two Proxmox hosts with k8s VMs (#376).** Quick capacity,
  but it grows corosync to five members and changes none of the pains.
- **Keep Proxmox through the migration, Talos later per host.** The
  operator review's choice: no long degraded-HA window. The owner chose
  Talos first; the per-host windows and the M0 restore are the guard.
- **One `UkubiApp` CRD with a full controller.** One status object, but the
  owner would own every integration, and atlas already aggregates status.
- **Declarations in each app's repo.** Rejected by the owner: one central
  registry is easier to fence, review and read.
- **Garage single instance + backups.** Cheaper on disk, but a host loss
  stops image pulls.
- **Cloud off-site copy.** Fresher (nightly) for a few euros a month; the
  owner chose the offline disk.

## Consequences

- **Supersedes or amends, each in its step's PR:** ADR-0002 (backup
  target), 0004 (list generator), 0017 (control-plane placement), 0022 (CI
  runner), 0029 (witness on ex-laptop), 0030 (Garage in one LXC), 0034
  (build clause, stateful-out-of-k8s), 0035 (D1-D3, D5-D7), 0042
  (pgBackRest repo), and `DECISION.md` §2. On a Talos or CNPG go, also
  0003/0018, 0016, 0020, 0036, 0043 and "nodes are always VMs".
- **More owner-built parts:** chart v2 and the controller. Everything else
  is upstream.
- **Capacity:** peak about 71 GB RAM and 21.5 CPU requested against 126 GB
  and 30 threads. With `.165` down, CPU doesn't fit at peak (about 16
  allocatable). So the agent-fleet session cap must follow allocatable CPU,
  not a fixed number, and previews stay at two.
- **The Esprimos share one switch:** one failure takes two hosts. Noted
  wherever two control planes or two Garage zones sit behind it.
- **The bootstrap tier** (Forgejo, Infisical's database, the backup
  target) needs a home under either pilot outcome before M3. Open.

## The bet

Existing operators, sync waves and a small Go controller can deliver every
part of an entry, with atlas as the only place status is aggregated. If
one-file deploys need ordering that waves and health checks can't express,
the controller grows toward a `UkubiApp` CRD, and this ADR is revisited.

## Not doing

- A cloud off-site copy, or a Garage replica outside the house.
- Per-app declaration files in app repos.
- Previews for every PR.
- Any prod change from this ADR alone.
