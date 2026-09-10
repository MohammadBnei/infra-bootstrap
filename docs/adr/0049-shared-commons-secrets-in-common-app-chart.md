# ADR-0049: Shared commons secrets via a dedicated `platform-commons` Infisical project

**Status:** Accepted — decided 2026-09-10. Operator behaviour in "Consequences"
verified empirically against `infisical/kubernetes-operator:v0.11.3` on
2026-09-10, not inferred from docs.
**Date:** 2026-09-10
**Related:** [ADR-0004](0004-gitops-pattern-c-registry-applicationset.md) (the
registry + `list`-generator ApplicationSet this deliberately does not touch),
[ADR-0038](0038-cloudflare-proxy-dns01-and-origin-lock.md) (`ingress.baseline`, the
chart-default-on precedent followed here), [ADR-0034](0034-in-cluster-oci-registry-zot-garage-backed.md)
(the CI half of the same problem, addressed separately)

## Context

The **shared Pigsty Redis** (`redis-main` cluster on pg02) is reached by more than
one consumer, and its credential is duplicated to get there. `docs/secrets.md:64`
records `REDIS_MAIN_PASSWORD` in the root project, feeding ArgoCD's
`externalRedis` via `gitops/bootstrap/argocd-redis-secret.yaml`. `docs/secrets.md:108`
then records agent-fleet holding `REDIS_HOST`/`_PORT`/`REDIS_MAIN_PASSWORD` in
`agent-fleet-nygh` — in its own words, *"shared Pigsty Redis, duplicated from the
existing value."*

The reason for the duplication is correct and is the whole problem: an
`InfisicalSecret` syncs a **whole project env**, so pointing agent-fleet at the
root project to pick up one Redis password would have put every root secret in
its namespace. `zot` is the standing example of what that looks like —
`values/zot/values.yaml:73-84` documents all root-path secrets,
`GARAGE_ROOT_TOKEN` included, landing as env vars in the zot pod.

So sharing a value between two consumers currently means duplicating it, and every
duplicate is a rotation that will be missed.

The second value going into this project is the **zot registry push credential**.
No in-cluster app needs it — pull is anonymous — but CI does, and putting it here
means one shared project rather than a separate CI-only one. See "Consequences"
for the risk that carries and why it was accepted.

## Decision

`common-app-chart` grows a `sharedSecrets.keys` list. When non-empty, it renders
a second `InfisicalSecret` that syncs the named keys from a **new, dedicated
`platform-commons-76pb` Infisical project** into `<release>-commons`, mounted onto the
main container via `envFrom`.

Three properties are load-bearing:

**1. The source project is a literal in the template, never a value.**
`projectSlug: "platform-commons-76pb"` and `envSlug: dev` are hardcoded in
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
comes from what `platform-commons-76pb` contains. That is a weaker guarantee here
than it sounds — see "Consequences" — and the `values.yaml` comment must not claim
the key list does the work.

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
- **A separate CI-only project for the zot push credential**, with
  `universal-auth-credentials` deliberately not granted on it, so no in-cluster app
  could ever read it. Recommended during review; **rejected by the operator** in
  favour of one project and one grant. The risk is recorded in Consequences rather
  than designed out.
- **Per-repo zot htpasswd users with repository-scoped policies**, so a leaked push
  credential could only overwrite one repo's images. Not taken — more zot config
  than the blast radius currently justifies.
- **Consolidating the per-app Infisical projects into one with folders.** Not taken;
  `docs/secrets.md` records that folders were tried and dropped.

## Consequences

- **Accepted risk: any app that opts into commons can read the zot push
  credential.** `platform-commons-76pb` holds both `REDIS_URL` and the zot
  push user/password, and `universal-auth-credentials` is granted on the whole
  project. Because the key list is not an access boundary (Decision 2), an app
  repo can name `ZOT_PUSH_PASSWORD` in its own `sharedSecrets.keys` and receive
  it. An app pod that can push to the registry can overwrite `latest` for any
  image, and every node pulls from that registry anonymously with no signature
  verification — so this is an app-pod-to-cluster-wide-code-execution path.
  Raised before the decision and accepted deliberately: single-operator homelab,
  one project and one grant instead of two. Revisit if a third party ever gets
  commit access to an app repo.
- Adding a commons key is one line in an app's `values.yaml` — not zero. Accepted.
- `platform-commons-76pb` needs a manual `universal-auth-credentials` grant in the
  Infisical UI, as every project does. This is a prerequisite, not background work.
- A chart default reaches app repos that are never edited here. Verified: with
  `sharedSecrets.keys: []`, 25 values files across every local app and platform
  chart render **byte-identical** to `main`.
- **A missing key does not fail — it poisons.** Verified empirically against
  operator **v0.11.3** in a throwaway namespace, not assumed. An unguarded
  `{{ .KEY.Value }}` for a key absent from the source renders the **literal string
  `<no value>`**: the managed Secret is created, the container starts, and the app
  receives a real-looking 10-character credential. The CR reports
  `ReadyToSyncSecrets: True` throughout. An earlier draft of this ADR claimed the
  template fails and the pod sits in `CreateContainerConfigError`; that was wrong.
- **Worse, this applies on resync to an already-good Secret.** With a key present
  and synced correctly, making it disappear from the source overwrote the good
  value with `<no value>` within one resync tick. Nothing surfaced an error — the
  only signal was the status message changing to "Last reconcile synced 0 secrets".
  So renaming or deleting a key in `platform-commons` silently poisons every
  consuming app within 60s.
- **Mitigation, also verified:** the template wraps each key in
  `{{ if .KEY }}{{ .KEY.Value }}{{ end }}`, which turns both cases into an **empty
  string** instead of `<no value>`. An SDK treats empty as "no credential
  provided" and fails clearly, rather than sending a bogus one and getting a
  confusing 403. The key cannot be omitted entirely — `template.data` is a flat
  map. Anything renaming a key in `platform-commons` must treat it as a breaking
  change to every consumer.
- `creationPolicy: Owner` is honored by v0.11.3 — verified `ownerReferences` with
  `controller: true` and `blockOwnerDeletion: true` on the managed Secret, so
  deleting the CR garbage-collects it and revocation through git works. Note the
  CRD does **not** constrain this field with an enum (free string, default
  `Orphan`), so a typo here would silently fall back rather than be rejected.
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
