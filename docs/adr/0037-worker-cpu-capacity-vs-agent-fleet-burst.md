# ADR-0037: Worker node CPU capacity vs. agent-fleet session bursts

**Status:** Proposed

## Context

`KubeCPUOvercommit` fired (severity: warning): "Cluster has overcommitted
CPU resource requests for Pods by 0.248 CPU shares and cannot tolerate
node failure." This is kube-prometheus-stack's default rule, unmodified
in `gitops/platform/values/prometheus/values.yaml`:

```
sum(namespace_cpu:kube_pod_container_resource_requests:sum)
  - (sum(kube_node_status_allocatable{resource="cpu"}) - max(kube_node_status_allocatable{resource="cpu"}))
  > 0
```

i.e.: total requested CPU exceeds what would remain allocatable if the
single largest node died. It is not a "cluster is full" alert — it is a
"cluster cannot survive losing one node" alert.

Live read at investigation time (2026-08-18):

- 5 schedulable nodes, allocatable CPU: `k8s-cp-01/02/03` 1400m each,
  `k8s-worker-01/02` 5400m each = 15000m total. Matches
  `ARCHITECTURE.md`'s target spec (2vCPU×3 control-plane + 6vCPU×2
  worker) — no Terraform/inventory drift found.
- Only `k8s-worker-01`/`k8s-worker-02` take regular (non-DaemonSet)
  workload; control-plane nodes are tainted and only run
  daemonsets/system pods.
- Total pod CPU **requests** cluster-wide: 10948m (10.948 cores).
- Largest single node (`k8s-worker-01` or `-02`, both 5400m allocatable)
  removed → 9600m remains. Overcommit at read time: 10948 - 9600 =
  **1348m** (higher than the alert's 0.248 snapshot — session count
  fluctuates; see below).
- `agent-fleet` namespace's dynamically-spawned worker pods (one per
  active coding session, `agent-fleet`'s own `k8s/provisioner/`, not
  anything in this repo) each request **1 full CPU** / limit 4. At read
  time 3 were running = 3000m, ~30% of all cluster-wide requests, all
  landed on `k8s-worker-01` (pushing it to 94% requested/allocatable —
  the tightest node in the cluster).
- Baseline (everything except agent-fleet worker pods) = 7948m, which is
  *below* the 9600m single-node-failure threshold on its own. Agent-fleet
  worker pods are what tips the cluster over the threshold, not the sole
  cause of cluster CPU demand generally (Longhorn instance-managers,
  monitoring stack, ArgoCD, Infisical, control-plane/system daemons
  already account for the ~8-core baseline).

## Decision

Not yet decided. Two independent levers, neither of which belongs to
this repo alone:

1. **Right-size `agent-fleet` worker pod CPU requests** — lives in
   `agent-fleet`'s own `k8s/provisioner/`, not `infra-bootstrap`. A 1-CPU
   *request* per session (vs. a smaller request with the same 4-CPU
   *limit* for burst) would remove most of the current margin without
   capping actual usage.
2. **Add worker capacity** (bump `k8s-worker-01`/`-02` vCPU further, or
   add a third worker VM) — a real Terraform/Proxmox change against
   `.165`, requires checking physical host headroom first, and per this
   repo's workflow rules is a human-run `terraform apply`, not something
   a session executes unattended.

No change made to `terraform/`, `inventory/`, or worker sizing as part of
this investigation — both options need an explicit greenlight.

## Re-measured 2026-08-31 — the numbers moved, the problem did not

The 2026-08-18 figures above are a snapshot of a *fluctuating* quantity and
should not be quoted as standing facts. ADR-0043 cited the "94% requested CPU"
line as a reason not to taint `k8s-worker-01`; that figure no longer holds, so
it is corrected here rather than left to propagate further.

Live read, all five nodes, 2026-08-31:

| | 2026-08-18 | 2026-08-31 |
|---|---|---|
| Allocatable, cluster-wide | 15000m | 15000m (1400m x 3 cp, 5400m x 2 worker) |
| Total pod CPU requests | 10948m | **8298m** |
| Single-node-failure threshold | 9600m | 9600m |
| Overcommit (requests - threshold) | **+1348m** | **-1302m — not overcommitted** |
| `k8s-worker-01` requested | 94% | **57%** (3111m) |
| agent-fleet session pods running | 3 | **0** |

**The alert is quiet only because no sessions are running.** That is the same
mechanism this ADR already describes, observed from the other end — it is not
evidence the problem resolved itself. The structural picture is slightly worse:

- Baseline (everything except agent-fleet session pods) grew **7948m ->
  8298m** — roughly 350m of new platform load since August, including the
  NVIDIA device plugin (50m, ADR-0043).
- Each session still requests **1 full CPU**.
- Headroom before `KubeCPUOvercommit` fires: **~1.3 sessions**, down from
  ~1.65.

### Interaction with ADR-0043's GPU work

The GPU-backed workload ADR-0043 was enabling for is planned at
`requests.cpu: 500m` on `k8s-worker-01`. That takes the baseline to ~8798m and
the headroom to **~0.8 sessions** — i.e. a single agent-fleet session would
trip the alert.

This is worth stating plainly rather than burying: the alert means "the cluster
cannot survive losing one node", and if `k8s-worker-01` is the node that dies,
a GPU workload pinned to it is unschedulable anyway. So the STT service does
not make the *failure* worse, only the *signal* noisier — but it does consume
most of the remaining margin, and lever 1 becomes correspondingly more
attractive than it was in August.

The decision below is still open. Nothing here settles it.

## Consequences

Pending. Until one of the two levers above is pulled, `KubeCPUOvercommit`
will keep firing/clearing as agent-fleet session concurrency rises and
falls — it is an accurate signal of a real (if currently low-severity)
node-failure risk, not a false positive to silence.
