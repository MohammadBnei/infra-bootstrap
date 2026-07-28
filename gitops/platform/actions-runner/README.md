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
  with from Infisical (`RUNNER_TOKEN` project, see below).

## One-time human setup (not something this repo/ArgoCD can do)

1. Create a GitHub PAT scoped to `repo` (classic) or fine-grained
   `Administration: write` on `infra-bootstrap` and `vos-monolith` — the
   minimum scope GitHub requires to register a self-hosted runner.
2. Store it in Infisical under a new project/path this manifest's
   `infisical.projectSlug`/`secretsPath` points at, as `ACCESS_TOKEN`.
3. Apply this Application once (or let `gitops/bootstrap/`'s self-sync
   pick it up per ADR-0021 — no manual `kubectl apply` needed beyond the
   one-time bootstrap already documented in `gitops/README.md`).
