# ADR-0010: Reject external managed Postgres

**Status:** Rejected

## Context

A managed Postgres offering (cloud provider RDS-equivalent) was
considered as an alternative to self-hosting.

## Decision

Rejected. Postgres is self-hosted only, via Pigsty (see
`ARCHITECTURE.md` §6 Database).

## Consequences

No cloud database dependency; Postgres HA, backups, and observability
are entirely Pigsty's responsibility, run on-prem VMs.
