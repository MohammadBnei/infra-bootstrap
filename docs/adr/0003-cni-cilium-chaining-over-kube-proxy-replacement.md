# ADR-0003: Cilium in chaining mode with kube-proxy retained

**Status:** Accepted
**Date:** 2026-07-05 (approximate — carried over from the original lock, formerly in MISSION.md)

## Context

Only the primary PVE host (`.165`, AMD Ryzen) has confirmed eBPF
hardware support. `server1` (`.200`)'s CPU lacks it, and the ex-laptop
(`.161`) may lack it too. Kubernetes v1.35.4, containerd runtime.

Alternatives considered:

- **Cilium with `kube-proxy-replacement: true`** — rejected, needs eBPF
  support on every node; not guaranteed across all 3 PVE hosts.
- **Flannel** — rejected, no L7 policy, no Hubble observability.
- **Calico** — rejected, doesn't need eBPF but Cilium was already the
  CNI in the repo; no reason to switch.
- **Cilium's own Gateway API / L2 announcements** — rejected; the
  Freebox blocks BGP so MetalLB owns L2 exclusively, and Traefik
  `IngressRoute` is the routing-API lock (ADR-0001). Running
  `cilium_l2announcements: true` while MetalLB also owns L2 would race
  over the same address pool.

## Decision

Cilium in **chaining mode with kube-proxy retained**:

- `cilium_kube_proxy_replacement: false`
- `cilium_enable_portmap: true`
- `cilium_l2announcements: false` (MetalLB owns L2 — see ADR for MetalLB
  in `DECISION.md`)
- `cilium_enable_hubble: true`, `cilium_enable_hubble_ui: true`
- kube-proxy mode: `ipvs` with `kube_proxy_strict_arp: true` (required
  for MetalLB L2 ARP correctness on the Freebox-switched LAN)

## Consequences

- Keeps the cluster portable across mixed eBPF/non-eBPF hardware without
  per-node CNI config branching.
- Whether to flip modes later if all hosts turn out to have eBPF is
  tracked separately as a proposed, not yet decided, item — see
  ADR-0018.
