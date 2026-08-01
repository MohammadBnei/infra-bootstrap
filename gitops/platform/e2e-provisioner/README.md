# e2e-provisioner

Plain manifests (no Helm chart — RBAC/ServiceAccount binding isn't
something `common-app-chart` supports, and this needs its own tightly
scoped Role), applied as a standalone ArgoCD Application (see
`gitops/bootstrap/e2e-provisioner-application.yaml`), same pattern as
`gitops/platform/actions-runner/` for things that don't fit the
registry/`common-app-chart` mold. See `docs/adr/0012` in the
[`agent-fleet`](https://github.com/MohammadBnei/agent-fleet) repo for why
this exists and the design it implements.

Deploys into the existing `agent-fleet` namespace (already created by that
repo's own registry Applications) — no `namespace.yaml` needed here, unlike
`actions-runner` which needed a new one.

## Contents

- `serviceaccount.yaml` — the identity the provisioner pod authenticates as.
- `role.yaml` — a namespaced `Role`+`RoleBinding` (never a `ClusterRole`),
  granting `create`/`get`/`list`/`watch`/`delete` on `Pod`/`Service` and
  `traefik.io` `IngressRoute`/`Middleware` in the `agent-fleet` namespace
  only. This is the **only** RBAC surface in the whole agent-fleet that can
  create/delete cluster resources — the worker pods themselves never get
  any of it, by design (see `docs/adr/0012`).
- `deployment.yaml` — a single provisioner pod (`agent-fleet-e2e-provisioner`,
  built by agent-fleet's own CI). Floating `:latest` tag for v1 — its
  Deployment lives here, outside agent-fleet's CI auto-bump, same accepted
  trade-off as `actions-runner`'s `myoung34/github-runner:latest`.
- `service.yaml` — ClusterIP; worker pods reach it at
  `http://e2e-provisioner.agent-fleet.svc.cluster.local:8080/mcp/:taskId`.
- `infisicalsecret.yaml` — sources `AGENTFLEET_DB_*` from the same
  `agent-fleet-nygh` Infisical project worker/bot already use.
- `networkpolicy.yaml` — the first `NetworkPolicy` anywhere in this cluster.
  Scopes e2e-runner pods' inbound traffic: Traefik → app + code-server
  ports (human preview, gated by the `basic-admin-auth` Middleware at L7);
  worker pods → app port only, never code-server (code-server is a
  human-review-only IDE/terminal); the provisioner itself → the Playwright
  MCP port only.

## One-time human setup (not something this repo/ArgoCD can do)

1. Point a DNS record for `e2e.bnei.dev` at the cluster's Traefik ingress —
   no wildcard DNS exists anywhere in this cluster (see
   `docs/adr/0001-ingress-traefik-ingressroute-over-gateway-api.md`), so
   this is one static hostname with path-based routing per task
   (`e2e.bnei.dev/<taskId>/app/`, `/<taskId>/code/`), not a per-task
   subdomain.
2. Apply this Application once (or let `gitops/bootstrap/`'s self-sync pick
   it up per ADR-0021 — no manual `kubectl apply` needed beyond the
   one-time bootstrap already documented in `gitops/README.md`).
