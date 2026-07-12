# ADR-0011: Reject multi-region / DR / GPU multi-tenancy / service mesh

**Status:** Rejected

## Context

Several "enterprise-scale" patterns were raised as hypothetically nice
to have: multi-region deployment, disaster-recovery failover, GPU
multi-tenancy, and a service mesh (Linkerd/Istio).

## Decision

Rejected, bundled as one scope-ceiling decision. This is a single-site
homelab with one GPU on one node — none of these add value at this
scale, and each carries real operational overhead.

## Consequences

Don't propose any of these without an explicit user greenlight, even as
a "best practice." If the cluster's scale or availability requirements
genuinely change, revisit as a fresh ADR rather than reopening this one.
