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

## One-time human setup

Exactly one step, and it genuinely cannot be automated from here:

**Widen the existing PAT's repo scope to include `editable-blog`.** The
`ACCESS_TOKEN` in the `actions-runner` Infisical project is a fine-grained
PAT with `Administration: Read and write`, currently scoped to
`vos-monolith` only (see `../actions-runner/README.md`). **Expected failure
mode if skipped:** the pod starts, then crashloops on registration.

Worth being explicit about, because it looks like it should already work:
`editable-blog` being deployed in the cluster does *not* imply this. That
deployment runs on `repo-creds-github-bnei` / `GITHUB_APPS_PAT` — a
different, fine-grained, **read-only** token that lets ArgoCD *clone* the
repo (ADR-0025). Registering a self-hosted runner calls GitHub's
`actions/runners/registration-token` API, which needs `Administration:
write` on that specific repo. Read access to clone and admin access to
register are separate grants on separate tokens.

### Already done, no action needed

- `ZOT_HTPASSWD` (user `ci`, bcrypt cost 12) is in Infisical — see `docs/secrets.md`.
- `REGISTRY_USERNAME`/`REGISTRY_PASSWORD` are set as GitHub Actions secrets on `editable-blog`. Rotate them together with `ZOT_HTPASSWD`; they are two representations of one credential.
- `gitops/bootstrap/` self-syncs per ADR-0021, so no manual `kubectl apply`.
