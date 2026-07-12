# ADR-0006: Reject Infisical as SSH CA / TLS CA

**Status:** Rejected
**Date:** 2026-07-11

## Context

Infisical already holds secrets for this cluster. It was proposed as a
certificate authority too — issuing SSH certs for VM access and/or TLS
certs for intra-cluster encryption.

## Decision

Rejected.

- This is a single-operator homelab with no multi-admin credential churn
  to justify running a CA.
- Infisical would become a circular dependency: it runs *inside* the
  cluster it would be gating SSH access to.
- No concrete TLS need was named at decision time.

## Consequences

Infisical stays a secrets store only. If plaintext pod-to-pod traffic
ever becomes an actual, named concern, the lazy fix is enabling Cilium's
built-in encryption (currently off) — not standing up a CA.
