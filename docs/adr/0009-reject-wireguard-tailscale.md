# ADR-0009: Reject Wireguard / Tailscale for this cluster

**Status:** Rejected — narrowed 2026-10-11 by
[ADR-0054](0054-netbird-control-plane-hosting-only.md): the cluster may
*host* a NetBird control plane for an external mesh it never joins.
**Superseded for SSH access 2026-10-11 by
[ADR-0055](0055-netbird-as-daily-ssh-path.md):** every host joins that mesh
as a NetBird SSH peer. Routes, network resources and exit nodes into the LAN
stay rejected.

## Context

Wireguard and Tailscale were considered for remote access to the
cluster.

## Decision

Rejected for this cluster. The existing remote-access pattern is
unchanged.

## Consequences

No VPN mesh is layered onto `ukubi-cluster`; remote operations continue
via the existing SSH/bastion pattern (see `DECISION.md`'s Identity &
Access notes).
