# ADR-0025: Repo credentials via shared HTTPS+PAT, not per-repo SSH deploy key

**Status:** Accepted
**Amends:** [ADR-0004](0004-gitops-pattern-c-registry-applicationset.md) (credential clause only — Pattern C's registry/ApplicationSet structure is unaffected)

## Context

ADR-0004 locked "SSH deploy key per repo, empty passphrase, read-only" as
Pattern C's repo-credential mechanism. Onboarding `editable-blog` found
that routing this credential through Infisical (an `InfisicalSecret` CR,
`argocd-github-apps-creds.yaml`) corrupts the value unpredictably — the
infisical-operator's template rendering was confirmed to mangle both an
SSH private key and a PAT (see `docs/bootstrap-test-notes.md`). A
per-repo SSH deploy key also means minting and rotating a new key for
every app repo.

## Decision

Repo credentials now use one shared ArgoCD repo-creds Secret,
`repo-creds-github-bnei` (HTTPS + a single GitHub PAT scoped to
`MohammadBnei/*`), injected manually via
`ansible/playbooks/register-repos.yml` — same manual-injection mechanism
as the `infra-bootstrap` repo's own SSH key, deliberately **not** an
`InfisicalSecret`, for the same corruption reason above. `registry.yaml`
and `apps.applicationset.yaml` entries use the HTTPS form of `repoURL`
(`https://github.com/...`), not `git@github.com:...`. Full detail lives
in `gitops/README.md`'s "Bootstrap credential chain" section, not
repeated here.

Pattern C's core structure (registry + ApplicationSet `list` generator,
shared `common-app-chart`) is unaffected — only the credential clause of
ADR-0004 is superseded.

## Consequences

- Adding a user app no longer needs a per-repo deploy key — just add the
  repo to `MohammadBnei/*` and it's already covered by the shared PAT
  (see `gitops/README.md`'s "Adding a user app").
- One shared credential is a wider blast radius than per-repo deploy
  keys if it leaks — accepted for a single-operator homelab; revisit if
  that threat model changes.
- `docs/secrets.md` and `gitops/README.md` are the sources of truth for
  this credential's actual fields — not repeated here.
