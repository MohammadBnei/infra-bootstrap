# Self-hosted GitHub Actions runner

Plain manifests (no Helm chart — RBAC/ServiceAccount binding isn't
something `common-app-chart` supports, and this isn't a web app: no
ingress, no typical envFrom-secret shape), applied as a standalone ArgoCD
Application (see `gitops/bootstrap/actions-runner-application.yaml`), same
pattern as `traefik-application.yaml` for things that don't fit the
registry/`common-app-chart` mold. See ADR-0022 for why this exists.

## Contents

- `namespace.yaml` — `actions-runner` namespace, where the runner pod lives.
- `serviceaccount.yaml` — the identity the runner pod authenticates as.
- `rbac-vos.yaml` / `rbac-vos-dev.yaml` — one `Role`+`RoleBinding` pair per
  namespace that has `oneOffJobs` wired up, granting only `create`/`get`/
  `list`/`watch` on `jobs` and `get` on `pods`/`pods/log`. **Extend this
  list (new file, new namespace) any time another app's `oneOffJobs` gets
  wired into `reusable-oneoff-job.yml`** — the runner's access is
  intentionally not cluster-wide.
- `deployment.yaml` — a single runner pod (`myoung34/github-runner`, a
  well-established self-hosted-runner image that handles registration/
  deregistration from `ACCESS_TOKEN`+`REPO_URL`/`ORG_NAME` env vars —
  chosen over the full `actions-runner-controller` operator since a single
  static runner is all this needs; no autoscaling requirement). Labeled
  `ukubi` so `runs-on: [self-hosted, ukubi]` targets it.
- `infisicalsecret.yaml` — sources the GitHub PAT the runner registers
  with from Infisical (`actions-runner` project, see below).

## One-time human setup (not something this repo/ArgoCD can do)

1. ~~Create a GitHub PAT~~ — done. Fine-grained PAT, `Administration: Read
   and write`, scoped to `vos-monolith` only (the only repo
   `deployment.yaml`'s `REPO_URL` registers against today — widen scope +
   add a second `REPO_URL`/Deployment if a second repo ever adopts
   `oneOffJobs`, don't pre-provision for it).
2. ~~Store it in Infisical~~ — done, project `actions-runner` (slug
   `actions-runner-x-qbo`), secret `ACCESS_TOKEN`. See `docs/secrets.md`'s
   "Per-app Infisical projects" table.
3. Apply this Application once (or let `gitops/bootstrap/`'s self-sync
   pick it up per ADR-0021 — no manual `kubectl apply` needed beyond the
   one-time bootstrap already documented in `gitops/README.md`).
