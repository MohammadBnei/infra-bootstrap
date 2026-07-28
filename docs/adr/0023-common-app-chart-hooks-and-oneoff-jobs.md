# ADR-0023: `hooks:`/`oneOffJobs:` in common-app-chart, layered values for multi-env

**Status:** Accepted

## Context

`common-app-chart` (ADR-0004) had no support for ArgoCD sync hooks,
multi-environment values, or one-off scripts. The only prior art for any
of this was `vos-monolith`, hand-rolling it via kustomize + raw Job YAML
in its own repo, with git history showing three concrete failure modes:

- A hook Job missing the `argocd.argoproj.io/hook` annotation (while still
  carrying a delete-policy) silently degraded into a normal resource —
  since Job pod templates are immutable, it got stuck on a stale image
  forever (commit `466fe4e1`).
- Default `backoffLimit` (6) retried a deterministically-failing migration
  Job pointlessly, masking the failure (commit `fdea7ac3`).
- An expensive one-time backfill, wired as a `PostSync` hook, kept
  silently re-running on **every** future sync (hooks fire every sync
  regardless of content change) until a human noticed and manually
  removed the wiring from the kustomize overlay (commit `0d7bcffd`).

Separately, `vos-monolith` had an ad-hoc, purely manual pattern
(`oneoff-job.tmpl.yml` + `make oneoff-job`, `sed`-templated, applied by
hand) for running one-off `back/cmd/*` scripts — no automation, no
feedback loop.

## Decision

Three additions to `common-app-chart`, all staying inside ADR-0004's
Pattern C (shared chart, `registry.yaml` + `list`-generator, no kustomize,
no per-app chart):

1. **`hooks:` map** (`templates/hooks.yaml`) — for recurring, idempotent,
   every-sync operations. The chart *always* stamps the ArgoCD hook
   annotation, `backoffLimit: 0`, and `restartPolicy: Never` — not
   user-configurable — so the exact bugs above are structurally
   impossible, not just documented. Map-keyed (not a list) so a layered
   env-override file can touch one field (e.g. just `image.tag`) without
   repeating the whole entry — Helm deep-merges maps but replaces lists
   wholesale. An `enabled` flag (read via `hasKey`, not Helm's `default`
   — `default true false` incorrectly returns `true`, since booleans are
   a zero-value to `default`) lets a hook be safely decommissioned
   without deleting the entry.

2. **`registry.yaml`'s `valuesPath` becomes a list** — multi-env apps
   layer a shared base + a per-env override file via ArgoCD/Helm's
   native `helm.valueFiles` merge. **Correction, found live**: the shared
   `apps.applicationset.yaml` list-generator template can only Go-template
   individual *string* fields (`'{{.name}}'`-style), not emit a
   variable-length YAML list — a raw `{{- range .valuesPath }}...{{- end
   }}` block breaks the ApplicationSet outright, since the self-managing
   `bootstrap` Application (ADR-0021) applies this file as a literal
   manifest *before* any Go-template rendering runs. So the shared
   template only ever emits exactly one value file (`index .valuesPath
   0`); an app needing more than one (today, only `vos-monolith-dev`)
   gets its own standalone Application instead, same pattern as
   `traefik-application.yaml` — see
   `gitops/bootstrap/vos-monolith-dev-application.yaml`. One registry
   entry is still always one Application/one environment. No kustomize
   reintroduced.
   Also found live: `targetRevision` must be explicit per app (`registry.yaml`'s
   `targetRevision` field), not assumed to be `HEAD` — `vos-monolith`'s
   GitHub default branch is `dev`, so `HEAD` silently pointed its *prod*
   Application at `dev`-branch content instead of `main`, where its prod
   CI actually pushes tag bumps.

3. **`oneOffJobs:` map** (`templates/oneoff-cronjobs.yaml`) — for
   irregular/one-time scripts. Each entry renders as a suspended
   `CronJob` (`suspend: true`; the schedule field is syntactically
   required but never fires on its own) that doubles as a ledger
   (`lastRunTag`, chart-ignored, CI-only). Triggered via the native
   `kubectl create job --from=cronjob/<release>-<name> <run-id>`
   primitive — no custom trigger machinery. A generic, reusable GitHub
   Actions workflow (`reusable-oneoff-job.yml`, ADR-0022 covers where it
   runs) triggers any entry whose `image.tag` has moved past
   `lastRunTag`, polls for completion, commits the new `lastRunTag` back
   on success, and on failure prints the failed pod's logs directly into
   the CI run's summary and leaves the ledger untouched for retry.

Both `hooks:` and `oneOffJobs:` entries share one container-spec building
block (`common-app-chart.jobContainer` in `_helpers.tpl`) — a hook and a
one-off job are the same "run this image with this command against these
secrets" shape once the ArgoCD-hook-vs-CronJob wrapper is stripped away.

## Alternatives considered

- **Thin `extraManifests` pass-through** (a small helper for hook
  annotations, leave weight/delete-policy/backoffLimit as manual raw
  fields) — rejected: doesn't prevent the exact bugs already hit.
- **Kustomize overlays for multi-env**, mirroring `vos-monolith`'s
  current approach — rejected: cuts against ADR-0004's explicit move
  away from kustomize.
- **Bespoke CI per app/job for one-off triggering** — rejected once a
  single reusable `workflow_call` workflow covers every app the same way.
- **ArgoCD hooks for one-off jobs** — rejected: wrong lifecycle (hooks
  re-run every sync; one-offs need "run once when new/changed," which
  `lastRunTag` comparison captures instead).
- **Automatic one-time-hook completion detection** (a Job self-checking
  DB/marker state) — rejected as the default; the `enabled` flag /
  `lastRunTag` ledger are the simpler, git-tracked equivalent of what
  `vos-monolith` already did by hand.

## Consequences

- `common-app-chart` gains real, permanent surface area that every future
  app inherits — a bug in `hooks.yaml`/`oneoff-cronjobs.yaml` now affects
  every app using them, not just one.
- Any app using `oneOffJobs` needs the self-hosted runner's RBAC extended
  to its namespace (ADR-0022) before the CI-triggered half works; the
  chart/registry/values-file mechanics work independently of that (a
  human can trigger `kubectl create job --from=cronjob/...` by hand in
  the interim).
- `vos-monolith` is the first (and, as of this ADR, only) app using any
  of this — `hooks.migrate` is wired and active; the real
  `backfill-word-search-vector` (~4h run) is deliberately left unwired,
  proven instead via a trivial `oneOffJobs.dbCheck` smoke-test job first.
