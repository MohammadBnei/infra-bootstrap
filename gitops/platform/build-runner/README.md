# Image-building runner

Plain manifests applied as a standalone ArgoCD Application (see
`gitops/bootstrap/build-runner-application.yaml`), same pattern as
`actions-runner/`. See [ADR-0034](../../../docs/adr/0034-in-cluster-oci-registry-zot-garage-backed.md)
for why it exists and why it is separate.

## Why this isn't just a label on `actions-runner`

`actions-runner/` holds a projected ServiceAccount token with `create jobs`
in `vos`/`vos-dev` (ADR-0022). Building an image means running an app repo's
`Dockerfile` and every dependency it pulls in. Putting both in one pod would
hand that identity to arbitrary build content — **identity coupling, not
RBAC verb count**, which is why "building needs no new verbs" isn't the
reassurance it sounds like.

So this Deployment has **no `serviceAccountName` and no RoleBinding
anywhere**, and ADR-0022's runner is left exactly as that ADR describes it.

The two are also labeled differently on purpose — `self-hosted,ukubi-build`
here vs `self-hosted,ukubi` there — so a workflow asking for a builder can't
land on the pod that can reach the Kubernetes API, or the reverse.

## Contents

- `namespace.yaml` — the `build-runner` namespace.
- `deployment.yaml` — one runner pod, registered against `editable-blog`.
- `infisicalsecret.yaml` — the GitHub PAT, from the same `actions-runner`
  Infisical project (the registration token derives from a *user*-scoped
  PAT, so one PAT covers both runners; GitHub can't scope a PAT to
  "register runners on one repo" anyway).

No ServiceAccount, no RBAC. That absence is the design.

## Building images without a privileged pod

`buildah` with `BUILDAH_ISOLATION=chroot` and `STORAGE_DRIVER=vfs`. That
combination is what keeps this an ordinary unprivileged pod:

- **chroot isolation** skips the user-namespace machinery buildah would
  otherwise need — the usual reason "rootless buildah on Kubernetes" turns
  into a `securityContext` project.
- **vfs storage** skips `fuse-overlayfs`, which is what wants `/dev/fuse`.

The cost is real and worth stating: vfs copies layers rather than stacking
them, so it is slower and more disk-hungry than overlay. That is why the pod
has an `ephemeral-storage` limit — an unbounded build cache on node
ephemeral storage evicts unrelated pods on the same node under disk
pressure. Move to `fuse-overlayfs` (which needs `/dev/fuse`) only if build
times actually become the complaint.

`buildah` is **not** in `myoung34/github-runner`, so the calling workflow
installs it:

```yaml
- name: Ensure buildah
  run: command -v buildah || (sudo apt-get update && sudo apt-get install -y buildah)
```

Idempotent, and effectively free after the first run since `EPHEMERAL=false`
keeps the pod alive across jobs. If that ever becomes annoying, bake an
image — it wasn't worth a build pipeline for one `apt-get`.

## Credential prerequisite — satisfied 2026-08-13

`ACCESS_TOKEN` must list **every repo a runner registers against**, with
`Administration: Read and write`. It now covers `vos-monolith` +
`editable-blog`. **Adding a third build repo means editing that PAT's
repository list too** — the pod otherwise starts and then crashloops on
registration, which reads as a broken image rather than a missing grant.

Verify without deploying anything (the endpoint mints a short-lived token
and changes no state):

```
POST /repos/<owner>/<repo>/actions/runners/registration-token
  201 → the runner will come up
  403 → the PAT doesn't cover that repo, or lacks Administration
```

### Why not the `argocd-ukubi-bot` account

It was tried, and it is structurally impossible — not a plan limitation.
Registering a repo-level runner requires the `admin` role, and a repository
owned by a **personal account** has exactly two permission levels: the owner,
and collaborators (who get write). Granular roles, including admin, are an
*organization* feature. So no setting and no paid plan can give a
collaborator what this needs:

```
login: argocd-ukubi-bot
editable-blog permissions: admin:false  maintain:false  push:true
POST .../actions/runners/registration-token → 403
```

The only route to using the bot is moving these repos into a GitHub
organization, which would rewrite every `repoURL` in `gitops/` — far out of
proportion. Revisit only if an org migration happens for other reasons.

Worth being explicit about, because it looks like it should already work:
`editable-blog` being deployed in the cluster does *not* imply this. That
runs on `repo-creds-github-bnei` / `GITHUB_APPS_PAT` — a different,
fine-grained, **read-only** token that lets ArgoCD *clone* the repo
(ADR-0025). Read-to-clone and admin-to-register are separate grants on
separate tokens, so no amount of deployment implies the second.

### What the shared token does and doesn't reach

One `ACCESS_TOKEN` now covers two repos and two runner pods, so it's worth
being precise about the exposure. It is fine-grained with **only**
`Administration: Read and write` — it cannot read code, cannot read Actions
secrets, and cannot touch any repo outside its list. A compromise of this
pod means "can register and deregister runners on two repos", which is the
narrowest thing that can register a runner at all.

Two choices keep it there rather than wider:

- The token arrives via an explicit `secretKeyRef`, not `envFrom`, so this pod gets that one key and nothing else that shares its Infisical project later.
- The InfisicalSecret points at the small `actions-runner` project, never `infra-bootstrap-1-ge1` — so the Secret in this namespace can't contain `PVE_API_TOKEN`, `K8S_BREAK_GLASS_TOKEN` or `GARAGE_ROOT_TOKEN`.

What is *not* separated is the token itself: both runners share it, so
revoking it stops `vos-monolith`'s `oneOffJobs` too. Separating the pod
identities was the point (ADR-0034) — this pod still has no ServiceAccount
and therefore no cluster access, which is the property that actually
mattered.

### Already done, no action needed

- `ZOT_HTPASSWD` (user `ci`, bcrypt cost 12) is in Infisical — see `docs/secrets.md`.
- `REGISTRY_USERNAME`/`REGISTRY_PASSWORD` set as Actions secrets on `editable-blog`. Rotate with `ZOT_HTPASSWD`; two representations of one credential.
- `gitops/bootstrap/` self-syncs per ADR-0021, so no manual `kubectl apply`.
