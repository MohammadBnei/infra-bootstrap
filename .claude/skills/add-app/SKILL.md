---
name: add-app
description: Add or audit a user app in gitops/ (registry.yaml + apps.applicationset.yaml). Use when the user asks to add a new app to the cluster, expose a new service via ArgoCD, or check that the app registry is in sync.
user-invocable: true
allowed-tools:
  - Read
  - Edit
  - Bash(git diff *)
  - Bash(git status *)
---

# /add-app — add a user app to gitops

Encodes `gitops/README.md`'s "Adding a user app" section. Two files are the
source of truth and **must stay in sync**:
- `gitops/apps/registry.yaml` — human-readable list
- `gitops/bootstrap/apps.applicationset.yaml` — `spec.generators[0].list.elements`,
  mirrors the same entries for ArgoCD to consume

## Step 0 — sync check (always run first, even with no app name given)

Read both files and compare every `name`/`namespace`/`syncWave`/`repoURL`/
`valuesPath`/`hostname` entry. If they've drifted apart, report the
mismatch and ask whether to fix that before adding anything new — don't
silently add a new entry on top of an already-inconsistent registry.

## Adding a new app

Ask for (or infer from context): app name, private repo URL, container
image repository, image tag, service port, external hostname (or none for
an internal-only sidecar like `openweb-ui-pipelines`), and whether it
needs a PVC or health probes.

1. **Per-app repo `values.yaml`** — this lives in the app's own private
   repo, not here. If the user wants a starting point, offer this shape
   (from `gitops/README.md`):
   ```yaml
   image:
     repository: ghcr.io/owner/app
     tag: "0.1.0"
   service:
     port: 8080
   # optional:
   livenessProbe:
     enabled: true
     type: http      # or tcp
     path: /healthz
     initialDelaySeconds: 30
   readinessProbe:
     enabled: true
     type: http
     path: /healthz
     initialDelaySeconds: 15
   ```
2. **Deploy key** — remind the user a read-only SSH deploy key is needed on
   the new repo, with the private key stored in Infisical under
   `GITHUB_APPS_SSH_KEY`. Never generate or write key material into this
   repo.
3. **Per-repo ArgoCD credential** — add an explicit `Repository` secret
   for the new repo: copy `gitops/bootstrap/argocd-repo-editable-blog.yaml`,
   rename it, change the `url`. Required even though
   `argocd-github-apps-creds.yaml`'s `repo-creds` template exists —
   ArgoCD doesn't reliably apply URL-prefix repo-creds templates to the
   *second* source of a multi-source Application (this ApplicationSet's
   per-app values repo is source 2 of 2), confirmed via repo-server logs
   (`ssh: no key found`) onboarding editable-blog. Skipping this step is
   the most likely reason a new app's Application will fail to sync.
4. **`gitops/apps/registry.yaml`** — append an entry:
   ```yaml
   - name: <app>
     namespace: <app>
     syncWave: "10"
     repoURL: git@github.com:MohammadBnei/<app>.git
     valuesPath: values.yaml
     hostname: <app>.bnei.dev
   ```
5. **`gitops/bootstrap/apps.applicationset.yaml`** — mirror the exact same
   entry into `spec.generators[0].list.elements`, keeping the existing
   entries' formatting/ordering style.
6. All user apps sync at wave 10, after Infisical (wave 1) and Traefik
   (wave 2) — no per-app wave override needed.
7. Show the diff and stop. Don't commit or push — the repo's branch
   workflow (feature branch + PR, human merges) is the user's call, not
   this skill's. Once merged, `gitops/bootstrap/` self-syncs (ADR-0021) —
   no manual `kubectl apply` needed.

## What this skill does not do

- Doesn't touch `gitops/platform/common-app-chart` — that chart is shared
  across all apps; a per-app Helm chart is a forbidden pattern
  ([ADR-0004](../../../docs/adr/0004-gitops-pattern-c-registry-applicationset.md)).
- Doesn't create the app's private repo or push secrets — Infisical and
  GitHub repo creation are out of scope.
