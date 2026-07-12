# ADR-0001: Traefik IngressRoute for app HTTPS routing (over Gateway API)

**Status:** Accepted
**Date:** 2026-07-11 (reverses an earlier Gateway-API-first stance)

## Context

The cluster needs one ingress path for app HTTPS traffic, with automatic
TLS. The initial design used Gateway API (`HTTPRoute`) exclusively.
Traefik's built-in ACME resolver cannot issue certs for Gateway API
listeners at all: the Gateway API spec requires a pre-existing
`certificateRefs` Secret, and Traefik has no built-in bridge from
`acme.json` to a Secret. Only cert-manager (or an equivalent controller)
can produce that Secret — and cert-manager is rejected (see this ADR's
consequences).

Two cert-engine alternatives were also considered and rejected as part
of this same decision:

- **cert-manager** as a secondary cert engine — unnecessary complexity;
  Traefik's native HTTP-01 is sufficient for a single-domain homelab.
- **DNS-01 via the OVH plugin** (for wildcard `*.bnei.dev`) — requires an
  OVH API token plus ongoing plugin maintenance; out of scope for the
  current design.

## Decision

Use Traefik `IngressRoute` for all app HTTPS routing, with Traefik's
built-in ACME HTTP-01 resolver:

- Per-app `IngressRoute`: `entryPoints: [websecure]`, `routes[].match:
  Host(...)`, `tls.certResolver: le`.
- `ports.websecure.tls.certResolver: le` at the Traefik entrypoint level
  so every router on that port gets ACME automatically.
- Middlewares via `middlewares:` on the `IngressRoute` route
  (Traefik-native, not a separate CRD family).
- Cert storage: `certificatesResolvers.le.acme.storage: /data/acme.json`,
  **PVC-backed, mandatory** — never `emptyDir` (concurrent writers
  corrupt the file). PVC must be RWX, or `replicas: 1` — never RWX with
  `replicas > 1`.
- `certificatesResolvers.le.acme.httpChallenge.entryPoint: web`.

## Consequences

- No plain K8s `Ingress`, no Ingress-NGINX, no Cilium Gateway API — one
  ingress controller, one routing API.
- No cert-manager, ever, as a secondary cert engine for this cluster.
- No DNS-01 / OVH plugin as the cert engine.
- Adding HTTPS to a new app means adding an `IngressRoute` via
  `platform/common-app-chart`, not a `Gateway`/`HTTPRoute` pair.
