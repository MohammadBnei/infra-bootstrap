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

## Consequences

Pending. Until one of the two levers above is pulled, `KubeCPUOvercommit`
will keep firing/clearing as agent-fleet session concurrency rises and
falls — it is an accurate signal of a real (if currently low-severity)
node-failure risk, not a false positive to silence.
