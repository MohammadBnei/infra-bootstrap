# ADR-0049: Shared commons secrets via a dedicated `platform-commons` Infisical project

**Status:** Accepted — decided 2026-09-10.
**Date:** 2026-09-10
**Related:** [ADR-0004](0004-gitops-pattern-c-registry-applicationset.md) (the
registry + `list`-generator ApplicationSet this deliberately does not touch),
[ADR-0038](0038-cloudflare-proxy-dns01-and-origin-lock.md) (`ingress.baseline`, the
chart-default-on precedent followed here), [ADR-0034](0034-in-cluster-oci-registry-zot-garage-backed.md)
(the CI half of the same problem, addressed separately)

## Context

`docs/secrets.md` records two secrets that were copied by hand between Infisical
projects rather than shared:

- `STT_TOKEN_FLEET` — lives in `ukubi-stt-bhr-m`, duplicated into `agent-fleet-nygh`.
- `WEDDING_WALL_S3_*` — lives in the root project, duplicated into `wedding-2026-ih1x`.

The reason recorded for the duplication is correct and is the whole problem: an
`InfisicalSecret` syncs a **whole project env**, so pointing agent-fleet at the
STT project would have put `REGISTRY_PASSWORD` in its namespace. `zot` is the
standing example of what that looks like — `values/zot/values.yaml:73-84`
documents all root-path secrets, `GARAGE_ROOT_TOKEN` included, landing as env
vars in the zot pod.

So sharing a value between two apps currently means duplicating it, and every
duplicate is a rotation that will be missed.

## Decision

`common-app-chart` grows a `sharedSecrets.keys` list. When non-empty, it renders
a second `InfisicalSecret` that syncs the named keys from a **new, dedicated
`platform-commons` Infisical project** into `<release>-commons`, mounted onto the
main container via `envFrom`.

Three properties are load-bearing:

**1. The source project is a literal in the template, never a value.**
`projectSlug: "platform-commons"` and `envSlug: dev` are hardcoded in
`templates/shared-infisicalsecret.yaml`. An earlier draft of this design put them
in `values.yaml`. That was wrong: app `values.yaml` files live in **seven repos
that `infra-bootstrap` does not review**, auto-synced with `prune: true,
selfHeal: true`. A values-driven `projectSlug` would let anyone with commit access
to any app repo point the CR at `infra-bootstrap-1-ge1` and read
`PG_SUPERUSER_PASSWORD` or `CA_PIGSTY_KEY` into a pod with **zero PRs here**.

**2. The key list is env hygiene, not an access boundary.** `template.data`
filters the *output* of a request made with `universal-auth-credentials`, which
holds a root-project read grant. `docs/secrets.md` already says this outright: *"a
`secretsScope` narrows the sync but not the identity's read grant."* Containment
comes from `platform-commons` containing only app-safe keys. The `values.yaml`
comment must not claim otherwise.

**3. Not a PreSync hook.** `templates/infisicalsecret.yaml` is a PreSync hook to
break a deadlock with PreSync hook Jobs. The commons CR deliberately is not, because
**ArgoCD never prunes hook resources** — a hook here would keep syncing into the
namespace forever after `sharedSecrets.keys` is cleared, making revocation through
git impossible. Git is the only control surface this repo has. With
`creationPolicy: Owner` (not `Orphan`) and a plain `sync-wave: "-10"`, clearing the
list removes both the CR and the managed Secret.

The cost of (3) is that PreSync hook Jobs cannot see commons keys — PreSync
completes before the Sync phase begins. `_helpers.tpl`'s `jobContainer` therefore
does **not** inherit this secret; `hooks:` and `oneOffJobs:` keep using the app's
own Infisical project. `agent-fleet` uses `hooks:` today, so this is a real
constraint, not a hypothetical one.

`envFrom` precedence, lowest to highest: **commons → `envFrom` → the app's own
Infisical secret → an explicit `env:` entry.** Commons is the weakest layer, so
anything app-specific shadows it.

## Alternatives considered

- **Whole-bundle `envFrom` from a commons path, zero per-app config.** Rejected —
  reproduces the zot situation across every app namespace. Every app would hold
  every shared credential.
- **Named keys against the existing root project `infra-bootstrap-1-ge1`.**
  Rejected — this was the first draft, and adversarial review killed it. See
  Decision (1) and (2): `template.data` is not access control, and the key list is
  attacker-controlled from repos this one does not review. It was rejected on the
  grounds that a dedicated project "buys a manual grant for nothing"; it buys the
  entire security property.
- **A secret replicator (reflector / kubed / emberstack).** Rejected — a new
  cluster dependency for something the Infisical operator already does natively
  cross-namespace.
- **Status quo: keep duplicating per project.** Rejected — it is the problem.
- **Consolidating the per-app Infisical projects into one with folders.** Not taken;
  `docs/secrets.md` records that folders were tried and dropped.

## Consequences

- Adding a commons key is one line in an app's `values.yaml` — not zero. Accepted.
- `platform-commons` needs a manual `universal-auth-credentials` grant in the
  Infisical UI, as every project does. This is a prerequisite, not background work.
- A chart default reaches app repos that are never edited here. Verified: with
  `sharedSecrets.keys: []`, 25 values files across every local app and platform
  chart render **byte-identical** to `main`.
- A key requested but absent from `platform-commons` fails the operator's template,
  so no managed Secret is created and the container sits in
  `CreateContainerConfigError`. The signal path is poor — `InfisicalSecret` has no
  ArgoCD health check and the real error is in the `infisical-operator` logs in
  another namespace.
- During migration a stale per-app copy silently **wins** over commons, because the
  app's own secret has higher precedence. Verify by *value*, not by presence,
  before deleting the old copy.

## Out of scope

Chart defaults for repeated non-secret constants (investigated and dropped — the
boilerplate was illusory: `logAlerts.datasourceUid` already defaults to `ds-loki`,
a default `resources` duplicates `limitRange.defaultRequest` and would OOMKill
zot per its own `values.yaml:33-37`, and an `image.registry` prefix would fire on
no current app while silently breaking a bare `redis`). Generating
`apps.applicationset.yaml` (dropped — ADR-0004's checker is 21 lines, its output
would auto-apply via ADR-0021, and a dropped element cascade-deletes PVCs through
`resources-finalizer` + `prune: true`). The CI-side credential problem, which is
its own ADR.
