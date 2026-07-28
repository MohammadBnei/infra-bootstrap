# common-app-chart hooks/oneOffJobs + vos-monolith onboarding — errors & fixes (2026-07-28)

Adding ArgoCD PreSync/PostSync hook support, one-time-job support, and
multi-env layered values to `common-app-chart` (ADR-0023), proven by
migrating `vos-monolith` off kustomize onto Pattern C (self-hosted runner:
ADR-0022). Everything below happened *after* the initial PRs (#21, #24)
merged clean — all four bugs only surfaced once real ArgoCD sync was
attempted against the live cluster, not during design/`helm template`
review.

Format per entry: what broke, root cause, what fixed it.

---

## 1. Raw `{{- range }}` broke the whole ApplicationSet

**Real bug, fixed (PR #22, by a separate session; reconciled into this
repo's docs afterward).**

`apps.applicationset.yaml`'s `helm.valueFiles` was changed to
`{{- range .valuesPath }}\n- $values/{{ . }}\n{{- end }}` to support a
variable number of layered values files per app. ArgoCD's UI showed
`Unable to load data: revision HEAD must be resolved`, with the real
condition buried underneath: `could not find expected ':'` — a YAML parse
error.

Root cause: `gitops/bootstrap/` is applied by the self-syncing `bootstrap`
Application (ADR-0021) as a **literal manifest directory source** — no
Helm, no kustomize, no pre-processing. The file must already be valid
plain YAML before it's ever handed to Kubernetes to become an
`ApplicationSet` object. ArgoCD's own `goTemplate: true` engine only runs
*after* that object exists, substituting Go-template syntax found inside
already-typed **string fields** (`'{{.name}}'`-style) — it never
re-interprets the raw file as a Go text template with control-flow blocks
first. A `{{- range }}` sitting where a YAML sequence item was expected is
just invalid YAML, full stop, before ArgoCD's templating ever gets a
chance to run.

Fix: the shared list-generator template can only ever emit exactly one
value file (`$values/{{ index .valuesPath 0 }}`). Apps needing more than
one (today, only `vos-monolith-dev`) get their own **standalone**
Application instead (`vos-monolith-dev-application.yaml`), same pattern
already established for `traefik-application.yaml` (which hit the same
class of limitation for its `skipCrds` bool field).

Lesson: Go-template string substitution into an already-valid YAML
skeleton is safe (same idiom as every other `'{{.field}}'` already in
these files). Anything that changes the YAML *structure* itself
(variable-length lists, conditional blocks around whole keys) is not —
verify with `yq`/a real YAML parser on the raw file, not just a Go
`text/template` sanity check in isolation (that only proves the template
logic is correct *if* it were pre-processed as text first, which isn't
how ArgoCD actually handles this file).

## 2. `targetRevision: HEAD` silently tracked the wrong branch

**Real bug, fixed (PR #23, generalized in PR #26).**

After #22 merged, `vos-monolith` (prod) still wasn't syncing correctly —
no hard error, just silently wrong. Root cause: every values-source
`targetRevision` was hardcoded to `HEAD`, and `vos-monolith`'s GitHub
default branch is `dev`, not `main`. `back_ci.yml`'s prod tag-bump commits
push to `main` — a branch `back/helm/values.yaml` didn't even exist on
yet at the time. `HEAD` was quietly reading `dev`-branch content for what
was meant to be the *prod* Application.

Fix: added an explicit `targetRevision` field to `registry.yaml`
(`main` for `vos-monolith`, `dev` for `vos-monolith-dev`'s standalone
Application). Then generalized further per explicit user request ("not a
fan of the HEAD thing... I want to be sure of the branch's name"): **every**
`targetRevision: HEAD` in `gitops/` — including every infra-bootstrap
self-reference for the chart/values source, not just per-app repos — was
replaced with the literal branch it resolves to (`main` in every case,
confirmed via `gh repo view --json defaultBranchRef` for each repo
involved). Zero functional change at the time, but removes reliance on a
GitHub UI setting nobody's actively watching.

Lesson: `HEAD` is a footgun the moment an app has more than one live
branch. Don't assume a repo's default branch is its production branch —
check (`gh repo view --json defaultBranchRef`), and prefer stating the
branch explicitly everywhere, even where it currently happens to match
HEAD, since "currently happens to match" is exactly the kind of assumption
that silently breaks later.

## 3. InfisicalSecret / PreSync-hook deadlock

**Real bug, fixed (PR #25).**

Once #23 fixed the branch, `vos-monolith-dev`'s sync still wouldn't
complete: `Error: secret "vos-monolith-dev-infisical" not found`.

Root cause: `hooks.migrate` (a **PreSync** hook Job) auto-inherits
`envFrom` from the Infisical-managed secret. But the `InfisicalSecret` CR
that actually creates that secret was a plain **Sync**-phase resource.
ArgoCD's PreSync phase always runs to completion (or hangs) *before* Sync
phase starts — so the hook Job was waiting on a secret that structurally
could not exist yet. A real deadlock, not just a race: PreSync can't
finish (hook never gets its secret) → Sync phase (which would create the
secret) never starts.

This is the exact same class of bug this repo already hit and documented
for Longhorn's `preUpgradeChecker` PreSync hook
(`gitops/platform/values/longhorn/values.yaml`) — a hook depending on a
resource that only exists in a later phase. It just hadn't bitten a
*new* app combining `infisical.enabled` + a real hook until now (existing
apps' secrets already existed from prior syncs, so the race/deadlock
never had a chance to surface for them).

Fix: made `InfisicalSecret` itself a PreSync hook (`sync-wave: -10`, well
before hook Jobs' default wave, and deliberately **no** delete-policy so
it's never cleaned up — it persists like any normal resource, only its
*apply-ordering* changed). Chart-level fix in `templates/infisicalsecret.yaml`
— benefits every app using `infisical.enabled`, not just ones with hooks.

Lesson: any time a hook Job needs something from `infisical.enabled`'s
auto-injected `envFrom`, check whether that something is itself hook-aware.
It wasn't, until this fix. Longhorn's precedent should have prompted a
closer look at this *before* the first hook combining the two shipped, not
after a live deadlock.

## 4. `main`'s ArgoCD Application had nothing to sync

**Real bug, fixed (vos-monolith PR #113).**

Even after #22/#23/#25, `vos-monolith` (prod) was still stuck: no
`back/helm/values.yaml` existed on `main` at all — only on `dev`, where
all the actual chart-migration work had landed. `registry.yaml`'s
`targetRevision: main` was correct; there was just nothing there yet to
read.

Fix: added `back/helm/values.yaml` directly to `main`, but **deliberately
scoped to main's current, unmigrated state** rather than porting dev's
improved setup wholesale — user has in-progress CI work on `dev` not
ready for `main` yet. Concretely: no `hooks:` block (main's existing
`back/k8s/migration/job.yml` is itself non-functional — missing the hook
annotation, wrong secret name, wrong image — porting it over would just
re-ship known-broken behavior under a new format), no `oneOffJobs:`
(db-check/backfill are dev-only so far). `back/k8s/` and main's existing
kustomize-based CI workflows are untouched.

Lesson: "migrate app X onto the new pattern" doesn't mean every branch of
X gets the same target state at the same time — `main` and `dev` had
diverged (65 commits ahead / 9 behind at the time), and blindly copying
`dev`'s values.yaml onto `main` would have silently activated migrate/
one-off wiring `main`'s CI has no matching support for yet. Always check
what a specific branch's *own* current state actually is before writing
its values file, don't assume siblings converge.

## Overall

None of these four were caught by `helm template`/`helm lint` review, or
by a Go `text/template` sanity check run in isolation — all four only
surfaced against the real, live ArgoCD sync (or, for #1, a real
`kubectl apply` of the literal manifest). Chart-level unit checks prove
the chart renders correctly for whatever values you feed it; they don't
prove ArgoCD applies the *surrounding* manifests in an order the chart's
output actually depends on, or that a registry entry actually points at a
branch that has the files it claims to.
