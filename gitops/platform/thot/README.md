# thot

Plain manifests (no Helm chart — cluster-wide `ClusterRole`/`ServiceAccount`
binding isn't something `common-app-chart` supports), applied as a
standalone ArgoCD Application (see
`gitops/bootstrap/thot-application.yaml`), same escape hatch
`actions-runner`/`e2e-provisioner`/`provisioner` already established. See
agent-fleet's own `docs/adr/0035-thot-cluster-agent.md` for the design
decision and this repo's `docs/adr/0032-thot-rbac-and-alerting.md` for the
concrete RBAC/Alertmanager design.

## Contents

- `namespace.yaml` — `thot`'s own namespace (unlike `provisioner`, which
  shares `agent-fleet`'s — `thot` holds a distinct standing credential and
  its own Discord/git identity, so it gets its own).
- `serviceaccount.yaml` — the identity thot's pod authenticates as.
- `rbac.yaml` — the cluster-wide `ClusterRole`, narrow and explicit on the
  mutate side, with hard exclusions (no `rbac.authorization.k8s.io`, no
  `secrets`, no node-mutation). See ADR-0032 for the full table + rationale.
- `deployment.yaml` — single replica, image built by agent-fleet's own CI
  (`thot/Dockerfile`) — floating tag, not auto-bumped by agent-fleet's
  `docker.yml` deploy job (same trade-off ADR-0012 already accepted for
  `e2e-provisioner`/`e2e-runner` — bump the tag here by hand for now).
- `service.yaml` — `ClusterIP`, `grpc` (9090) + `http` (8080, `/healthz`).
- `infisicalsecret.yaml` — sources thot's own credentials from its own
  narrowly-scoped Infisical project (see below).
- `networkpolicy.yaml` — ingress scoped to exactly who's allowed to reach
  thot's `grpc` port.

## One-time human setup (not something this repo/ArgoCD can do)

1. Create a new Infisical project for `thot` (own project, not
   `agent-fleet-nygh` — same "compromised per-app grant stays contained"
   reasoning as every other per-app project). Add it as a new row in
   `docs/secrets.md`'s "Per-app Infisical projects" table once created.
2. Grant the shared `universal-auth-credentials` machine identity
   (namespace `infisical`) access to this new project — same step every
   other per-app project needed.
3. Add `CLAUDE_CODE_OAUTH_TOKEN` (subscription OAuth, not a metered API
   key — same rule `worker/` follows) to the project.
4. Replace `infisicalsecret.yaml`'s `projectSlug: "thot-REPLACE-ME"` with
   the real slug once the project exists.
5. Apply this Application once (or let `gitops/bootstrap/`'s self-sync
   pick it up per ADR-0021 — no manual `kubectl apply` needed beyond the
   one-time bootstrap already documented in `gitops/README.md`).
