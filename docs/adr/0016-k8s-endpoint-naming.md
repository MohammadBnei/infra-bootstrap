# ADR-0016: K8s API endpoint naming

**Status:** Proposed

## Context

Two candidate DNS names exist for the K8s API endpoint:

- `k8s-proxmox-gpu.bnei.lan` — current test-build isolation name,
  pointing at `.201`.
- `k8s.bnei.lan` — the legacy/libvirt-era name, mapped to a reserved API
  VIP `.180` that's currently unused.

## Decision

Not yet decided. Resolve when promoting from test build to production.

## Consequences

Until decided, `.180`'s reservation stays provisional and SANs aren't
rotated onto it — see `ARCHITECTURE.md` §3 Networking.
