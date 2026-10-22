# ADR-0064: mountain's town shows platform services and infra guests by role; blackbox probes the guests

**Status:** Proposed — decided 2026-10-22 by M BN in mountain's R7/R8 planning (one question at a time, two doubt
cycles). Amends [ADR-0056](0056-mountain-public-live-cluster-view.md) Decisions 2 and 3.
**Date:** 2026-10-22
**Related:** [ADR-0056](0056-mountain-public-live-cluster-view.md) (the public view this widens),
[ADR-0029](0029-postgres-automatic-failover-3-node-etcd-quorum.md) (the Postgres pair and witness probed here),
[ADR-0034](0034-in-cluster-oci-registry-zot-garage-backed.md) (build-runner, Garage). The app-side plan lives in the
private `MohammadBnei/mountain` repo under `plan/`.

## Context

mountain.bnei.dev now draws ukubi as a live town (mountain R7, deployed 2026-10-22):
- three islands, one per Proxmox host;
- every allowlisted app as a building on the host its pods run on.

Two gaps showed up live:
- **h3 (`ex-laptop`) was an empty island.** No allowlisted app runs most of its pods on `k8s-cp-03`.
- **Garage had S3 traffic but no building.** It runs as an LXC outside Kubernetes.

The owner chose to draw the Terraform-level topology too: the k8s VMs (control plane, workers) and the guests outside
Kubernetes. Each guest is shown only once the cluster can measure it ("probes first").

ADR-0056 limited the public data to allowlisted apps (Decision 2). It drew Garage and Pigsty as unmeasured, and called
measuring them "a separate decision" (Decision 3). This ADR is that decision, and it also records R7's platform
services.

## Decision

1. **Platform services are public under role keys, never product names** (mountain R7). The mapping lives in
   mountain's `relay/config.yaml`:

   | Namespace | Public key |
   |---|---|
   | traefik | gate |
   | authentik | guardhouse |
   | argocd | craneyard |
   | monitoring | watchtower |
   | longhorn-system | warehouse |
   | infisical | vault |
   | garage | granary |
   | zot | depot |

   - They are treated like apps: sync and health, churn, bucketed replicas and traffic, storage pools, and the host
     bucket their pods run on.
   - Pod names, node names, IPs and exact pod counts never leave the relay.
   - Storage pools say `replicated` or `local`, never the product.
   - Two mechanism names stay public, on purpose:
     - the event kinds `argo.sync` and `argo.health`;
     - the sign-up link to the identity provider, where a visitor is sent anyway.

2. **The k8s VMs and the infra guests are public under role keys too** (mountain R8):

   | Guest | Host | Public key |
   |---|---|---|
   | k8s-cp-01..03 | h1..h3 | keep-h1..h3 |
   | k8s-worker-01..02 | h1, h2 | hall-h1, hall-h2 |
   | pg02 | h1 | archive-h1 |
   | pg01 | h2 | archive-h2 |
   | pg-etcd-witness | h3 | witness |
   | nfs-storage | h2 | cellar |
   | build-runner | h2 | forge |
   | hermesagent | h3 | mill |
   | garage-storage | h1 | granary (the service key becomes a machine) |

   - **What is published:** the role, the host bucket and, for a probed guest, an up/down state.
   - **Debounce:** a guest's state changes on the page only after it has held for **10 minutes**, both ways, and is
     never published early: after a restart the last published state stands and any difference waits 10 minutes again.
     The page is not a real-time oracle for a single box.
   - **The k8s VMs have no state of their own** (owner, 2026-10-22, mountain R8 deploy B doubt cycle): the keeps and
     halls grey with their island, like every building. Per-node Ready would publish the k8s etcd members' state live
     and split control plane from worker, which today's per-host Ready does not.
   - **Not debounced:** host state (per-host Ready, quorum, host-tagged alerts) stays live as before.
   - **k9s-dashboard is never drawn, probed or named.** It is the cluster-admin break-glass box.
   - **Real hostnames only reach a signed-in `platform-admins` session**, through mountain's `/auth/me`. They never
     reach the public socket, a public replay or the public tables. Carve-out (owner, 2026-10-22): mountain's
     admin-only detail channel (ADR-0056, R2) keeps the raw alert labels, node names and instances included, and its
     30-day private `events.detail` rows. Machine state never goes through it.
   - The owner is making this repository **private**, so its IP ↔ hostname files stop mapping the public role keys
     back to machines. History already cloned elsewhere is out of reach; this is accepted.

3. **blackbox-exporter probes the guests** (supersedes the "separate decision" in ADR-0056 Decision 3):
   - **Target naming:** one ServiceMonitor target per guest in
     `gitops/platform/values/blackbox-exporter/values.yaml`, named `guest-<role>` (the public key, not the hostname)
     at a literal IP.
   - **Each probe proves the service, not just the box:**

     | Guest | Probe |
     |---|---|
     | Postgres pair | Patroni `:8008/health`, module `patroni_health` (HTTP/1.0 or 1.1, 200 only). Never `/primary` or `/leader`, so the page cannot tell primary from replica |
     | etcd witness | `:2379` over TLS, module `etcd_tls` |
     | Garage | S3 `:3900` |
     | NFS | `:2049` |
     | build-runner | `:22` |
     | hermesagent | its dashboard `:9119` (its nftables rule admits the k8s node IPs) |

   - **No alert rule.** The existing probe rules are scoped to `target=~"pve-.*"` and `target="netbird"`, so a guest
     never pages as a dead hypervisor.
   - **The relay's query:** mountain reads `max by (target)(probe_success{target=~"guest-.*"})`. `instance` (the IP)
     never enters the relay.
   - Garage's admin port 3903 stays unexposed, and Pigsty's own metrics stay in Pigsty. A probe answers "is it
     serving"; nothing scrapes their internals.

## Consequences

- **What an observer learns:** the cluster's service roles and infra roles, their host bucket, and their up/down
  state, about 10 minutes late for the guests. For example, "the witness on h3 has been down for a while".
  - The Postgres pair plus the witness, read together, give a delayed view of the etcd DCS quorum. The owner accepts
    this with the debounce.
  - Primary vs replica is not revealed: both answer `/health`.
- **Live traffic can show an outage before the debounce:** granary keeps its live S3 traffic (walkers, error puffs), so
  a dead garage-storage shows within a poll, and an archive or cellar outage can show as other apps' errors. The owner
  accepts this (2026-10-22); the debounce covers the machine's own state, not every signal it touches.
- **More probe traffic:** seven more targets at 30 s each. Two side effects:
  - sshd on build-runner logs a pre-auth disconnect per probe. Accepted; no `PerSourcePenalty` exemption for the node
    IPs, which would let any pod brute-force without penalty.
  - hermesagent's `.72` has no DHCP reservation (ADR-0051). If the lease moves, the probe tests the wrong box.
- **Keeping the list in sync:** the guest list in `values.yaml` is mirrored by hand in mountain's `relay/config.yaml`.
  - mountain counts an unmapped `guest-*` target, or a configured probe with no series, in `mountain_unmapped_total`,
    which raises its existing `MountainUnmapped` notice.
  - A new Terraform guest with no probe is caught by the `mission-drift` skill's checklist.
- **Correcting ADR-0056:** its Consequences say the app repo's CI diffs against the registry. No such step exists;
  `mountain_unmapped_total` is the only guard.

## Rollout

1. This PR: the probes, the two modules, this ADR, and ADR-0056's status line. Plus the lines that said blackbox
   probes only the PVE hosts: the values header, `CLAUDE.md`, `ARCHITECTURE.md` §9 and the ApplicationSet comment.
2. **Before merging**, check the two non-trivial probes by hand from a node:
   - `curl -sv http://192.168.1.205:8008/health` should answer HTTP/1.0 or 1.1 with status 200;
   - `openssl s_client -connect 192.168.1.197:2379` should complete a handshake without a client certificate.

   If either fails, adjust its module before merging.
3. After the sync: `max by (target)(probe_success{target=~"guest-.*"})` returns 7 series, all 1.
4. mountain R8 deploy B (the machines) ships about 24 h later. Its relay draws a guest only after its first probe
   answer.
