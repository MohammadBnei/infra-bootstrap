# ukubi-cluster bootstrap test — manual steps & findings (2026-07-11)

Notes from the first end-to-end test of kubespray + GitOps bootstrap against
the 2-node test cluster (`k8s-cp-01` 192.168.1.241, `k8s-worker-01`
192.168.1.242). Captures what had to be done by hand so it can be folded into
automation/docs later, plus real bugs found and fixed in the repo.

## One-time machine/tooling setup (not yet automated)

- **SSH host keys**: first connection to fresh VMs needs `ssh-keyscan -H <ip>
  >> ~/.ssh/known_hosts` before `ansible -m ping` will work non-interactively.
- **`kubespray-venv/` had the wrong Python version.** It was Python 3.9.6, but
  kubespray v2.31.0 pins `ansible==11.13.0`, which requires Python >=3.11.
  Also, kubespray requires ansible-core strictly between 2.18.0 and 2.19.0 —
  the Homebrew-installed ansible (2.21.1) on PATH is too new and must not be
  used for kubespray runs. Fixed by recreating the venv with Python 3.12:
  ```bash
  rm -rf kubespray-venv
  /opt/homebrew/bin/python3.12 -m venv kubespray-venv
  kubespray-venv/bin/pip install --upgrade pip
  cd kubespray && ../kubespray-venv/bin/pip install -r requirements.txt
  ```
  Always invoke kubespray via `kubespray-venv/bin/ansible-playbook`, never the
  Homebrew `ansible-playbook` on PATH.
- **Helm is not installed on the VM images.** Installed via the official
  script on `k8s-cp-01` (`curl -fsSL
  https://raw.githubusercontent.com/helm/helm/main/scripts/get-helm-3 | bash`)
  before `helm install argocd` could run. `vm-provision.yml` (once written,
  see `ansible/README.md`) should probably include this, or a dedicated
  `helm-install` role/step.
- **`infra_bootstrap_id_ed25519` SSH deploy key**: generated fresh
  (`ssh-keygen -t ed25519 -N ""`), added as a **read-only Deploy Key** on
  `MohammadBnei/infra-bootstrap` only. Do NOT also grant it access to
  `k8s-cluster` or other private repos — see the submodule note below for why
  that's unnecessary.

## Real bugs found and fixed in the repo (committed as code changes)

- `inventory/ukubi/group_vars/k8s_cluster/k8s-cluster.yml`: `kube_version` had
  a leftover `v` prefix (`v1.35.4`) from the old kubespray v2.23 convention.
  Kubespray v2.31.0's `kubelet_checksums` dict keys are unprefixed
  (`1.35.4`), and the mismatch broke the internal LooseVersion-style
  comparison used by `validate_inventory` (`'<' not supported between
  instances of 'str' and 'int'`). Fixed by dropping the `v`.
- `gitops/bootstrap/platform.applicationset.yaml`: Infisical `chartRevision`
  was pinned to `0.7.8`, which doesn't exist in
  `https://dl.cloudsmith.io/public/infisical/helm-charts/helm/charts/` (real
  available versions top out at `0.4.2` as of this test). Fixed to `0.4.2`.
- `gitops/bootstrap/argocd-application.yaml`: added
  `repoServer.env: ARGOCD_GIT_MODULES_ENABLED=false`. `infra-bootstrap` has a
  private `k8s-cluster` git submodule that ArgoCD's repo-server doesn't need
  (only plain files under `gitops/` are ever referenced as Application
  sources) and has no credentials for by design. ArgoCD does **not**
  propagate a repo's credentials to its submodules — each submodule needs
  its **own** registered repo-credential Secret in ArgoCD, or submodule
  fetching needs to be disabled outright. Disabling it entirely (rather than
  granting the deploy key access to `k8s-cluster` too) keeps the key's scope
  minimal, per MISSION.md's per-repo least-privilege policy.
  - Note: a `submoduleEnabled: false` field on the ArgoCD `Repository` Secret
    was tried first and does **not** work — it's silently ignored. The only
    effective control is the `ARGOCD_GIT_MODULES_ENABLED` env var on the
    `argocd-repo-server` Deployment.
- Initial `helm install argocd` must pin `--version 7.8.1` (matching
  `argocd-application.yaml`'s pinned chart). Installing without a version pin
  grabs the newest chart, which had a broken `copyutil` init-container
  command render against the cached `v2.14.2` image on this test — crash
  looped on `Init:Error`. Always pin the same version for the manual
  bootstrap install as the self-managing Application uses.

## Open issue — not yet resolved

- The `argocd` self-managing Application (`argocd-application.yaml`) fails
  its structured-merge-diff comparison against its own `Deployment`
  resources: `.status.terminatingReplicas: field not declared in schema`.
  This is a genuine version gap: `terminatingReplicas` was added to K8s's
  `DeploymentStatus` in 1.33+, and ArgoCD 2.14.2 (pinned chart 7.8.1)
  predates that. This may block ArgoCD from ever reaching `Synced` on itself,
  which would also block it from picking up config changes (like the
  `ARGOCD_GIT_MODULES_ENABLED` fix above) via normal GitOps self-sync —
  those had to be patched live with `kubectl set env` instead. **Needs a
  decision**: bump the pinned ArgoCD chart version to one that supports K8s
  1.35, or confirm this is cosmetic and doesn't actually block sync (untested
  as of this note).

## Critical blocker discovered

**None of this session's `gitops/` rework is pushed to GitHub.** ArgoCD
clones `git@github.com:MohammadBnei/infra-bootstrap.git` from the remote —
it cannot see local working-tree changes. `gitops/platform/values/`,
`gitops/bootstrap/*.applicationset.yaml`, `gitops/README.md`, and every fix
above only exist locally (`git status` shows them untracked/modified, and
even commit `47aed35` isn't pushed to `origin/main`). Every platform app
sync failure back to `platform-infisical`'s "no such file or directory" for
its values path traces back to this. **Nothing past kubespray verification
can be meaningfully tested until this is committed and pushed.**

## 2026-07-12 — continued

- **`gitops/bootstrap/*.yaml` is NOT self-syncing from git.** This tripped
  us up twice: `argocd-application.yaml` and `platform.applicationset.yaml`
  are only ever `kubectl apply -f`'d once, at bootstrap time. There's no
  App-of-Apps watching that directory (intentionally — MISSION.md forbids
  one), so any later edit to a file under `gitops/bootstrap/` needs a manual
  `kubectl apply -f <file>` re-run on the live cluster before it takes
  effect, even after the edit is committed and pushed. Only
  `gitops/platform/values/*` (referenced as a separate git `ref: values`
  source by the Applications/ApplicationSet) auto-syncs normally.
- **ArgoCD self-app fixed**: bumped to chart `10.1.3`/app `v3.4.5` (see
  `MISSION.md` / `argocd-application.yaml` history). Confirmed `Synced` +
  `Healthy` after the bump — the `terminatingReplicas` issue above is fully
  resolved, not just cosmetic.
- **Gateway API → IngressRoute reversal fallout**: after moving all app
  routing to Traefik `IngressRoute` (MISSION.md §5, dated 2026-07-11),
  `platform-traefik` couldn't sync at all. Root cause chain:
  1. Traefik's chart bundles a full Gateway API CRD set
     (`crds/gateway-standard-install.yaml`, bundle-version `v1.2.1`).
  2. kubespray had already installed newer Gateway API CRDs, which ship
     their own `ValidatingAdmissionPolicy`
     (`safe-upgrades.gateway.networking.k8s.io`) that unconditionally
     rejects installing/reinstalling *any* CRD in that group below
     `v1.5.0` — this is not just a downgrade check, it blocks fresh
     `CREATE`s too, regardless of whether an existing CRD is present.
  3. Deleting the old (now-unused, confirmed no live `Gateway`/`HTTPRoute`
     objects anywhere) Gateway API CRDs — done with explicit user
     authorization — did **not** fix it: ArgoCD's own sync attempt to
     recreate them from the chart hit the same policy on `CREATE`.
  4. `resource.exclusions` in `argocd-cm` was tried first and doesn't work
     for this: the rejected objects are `CustomResourceDefinition`
     (group `apiextensions.k8s.io`), not objects in the
     `gateway.networking.k8s.io` group itself.
  5. `helm.skipCrds: true` is the actual fix, but it's a `bool` field the
     ApplicationSet CRD validates strictly — a per-element Go-template
     conditional (`{{ if eq .name "traefik" }}true{{ else }}false{{ end }}`)
     in the shared list-generator template gets rejected by the API server
     before the ApplicationSet controller ever renders it. Traefik had to
     be pulled out into its own standalone `Application`
     (`gitops/bootstrap/traefik-application.yaml`) with a literal
     `skipCrds: true`.
  6. Traefik's own needed CRDs (`traefik.io_*`, `hub.traefik.io_*` — NOT
     the Gateway API bundle) were installed once, out-of-band, by
     `helm pull`ing the chart locally and `kubectl apply`ing just those
     files (excluding `gateway-standard-install.yaml`) directly on the
     control-plane node.
- **No StorageClass existed anywhere** — every PVC (Traefik's `acme.json`,
  every future `common-app-chart` PVC) was stuck `Pending` with "no
  persistent volumes available... and no storage class is set". NFS/
  Proxmox-backed shared storage is still deferred; added
  `containeroo/local-path-provisioner` (chart `0.0.37`) as a wave-0
  platform app (`gitops/platform/values/local-path-provisioner/values.yaml`,
  `defaultClass: true`) as a hostPath-backed stopgap default StorageClass.
  Swappable later without touching any app's PVC template, since none of
  them set `storageClassName` explicitly.
