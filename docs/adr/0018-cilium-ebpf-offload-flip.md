# ADR-0018: Cilium eBPF offload flip (kube-proxy-replacement)

**Status:** Proposed

## Context

ADR-0003 locks Cilium into chaining mode with kube-proxy retained,
because not all PVE hosts have confirmed eBPF hardware support. If
`.200` (server1) turns out to have eBPF-capable hardware, chaining mode
would still be *safe* there but unnecessary — however `.161` (the
laptop) may still lack eBPF, so the cluster would need mixed-mode
handling to flip only where it's supported.

## Decision

Not yet decided. Keeping chaining mode cluster-wide for now specifically
because of `.161`'s uncertain hardware. **No flip without an explicit
greenlight**, even if `.200`'s eBPF support is confirmed.

## Consequences

Pending — no change to ADR-0003's decision until this resolves.
