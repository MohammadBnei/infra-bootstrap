# ADR-0004: GitOps Pattern C — registry.yaml + ApplicationSet `list` generator

**Status:** Accepted

## Context

ArgoCD needs one consistent way to deploy N apps without N bespoke Helm
charts or N hand-written Applications. Alternatives considered:

- **Per-app Helm chart** — rejected; N charts to maintain in lockstep
  instead of one shared template.
- **Per-app flat ArgoCD `Application` objects that bypass a registry** —
  rejected; no single place to see "what's deployed," drift-prone.
- **App-of-Apps with an explicit `root.yaml`** — rejected; the
  ApplicationSet's `list` generator already gives an explicit,
  reviewable list of expected repos, without the extra indirection layer
  of a root Application managing child Applications.

## Decision

**Pattern C**, no exceptions:

- Cluster repo hosts `platform/common-app-chart/` — one Helm chart
  (templates for Deployment, Service, IngressRoute) reused by every app.
- Cluster repo hosts `apps/registry.yaml` — flat list of apps
  (`name`/`repoURL`/`valuesPath`/`namespace`/`hostname`), the human
  source of truth for "what's deployed."
- Per-app repos hold only a `values.yaml` (~5 fields).
- ArgoCD `Application` is multi-source: `sources: [chart-source, ref:
  app-values]`.
- ApplicationSet generator: `list` (not `git` directory scanning) — the
  registry gives an explicit list of expected repos.
- Sync policy: `automated + prune + selfHeal`, `CreateNamespace: true`,
  `ServerSideApply: true`. Retry: 5 attempts, 5s base, 2x factor, 3 max,
  10 max duration.
- Repo credentials: SSH deploy key per repo, empty passphrase,
  read-only — works across GitHub/Gitea/self-hosted GitLab without
  per-host recoding.
- CRDs are **not** gitops-managed; their lifecycle is outside ArgoCD's
  update path.

## Consequences

- Adding a new app is a two-file change: one row in `apps/registry.yaml`
  plus a `values.yaml` in the app's own repo. See the `add-app` skill.
- Full operational detail (bootstrap sequence, wave ordering, credential
  chain) lives in `gitops/README.md`, not repeated here.
