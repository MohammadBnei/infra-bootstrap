# ADR-0017: Second control-plane / etcd member

**Status:** Proposed

## Context

Current design is single control-plane + single etcd, stacked
(`etcd_deployment_type: kubeadm`, static pod managed by kubelet). Adding
a 2nd CP/etcd member is a real option once more hosts (`.200`/`.161`)
are online.

## Decision

Not yet decided when to add a 2nd CP. Adding one means **re-running
`cluster.yml` against the same inventory — not `scale.yml`**, since
`scale.yml` doesn't include the control-plane join role.

## Consequences

Pending — single-CP remains the accepted design (see
`ARCHITECTURE.md` §2 Kubernetes Cluster) until this is decided.
