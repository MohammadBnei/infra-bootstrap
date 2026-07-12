# ADR-0009: Reject Wireguard / Tailscale for this cluster

**Status:** Rejected

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
