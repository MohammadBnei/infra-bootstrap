# ukubi-cluster bootstrap test — manual steps & findings (2026-07-11)

## 2026-07-12 — terraform module smoke test (k8s-cp-01 + k8s-worker-01)

Scoped `-target` apply of `proxmox_download_file.ubuntu_2404_cloudimg` +
`proxmox_virtual_environment_vm.ubuntu_2404_template` (test VMID, not the
real 9000) + `k8s_cp_01` + `k8s_worker_01` on `.165`. `pg01`/`pg02`/
`hermesagent`/garage untouched. Two real bugs found and fixed, one
non-fatal gotcha to keep in mind for the real bootstrap:

- **Real bug, fixed**: `template.tf`'s `proxmox_download_file` reused
  `var.template_storage_id` (`local-lvm`, LVM-thin) for the cloud-image
  download. LVM-thin only supports content types `images`/`rootdir`, not
  `import` — the download failed with `HTTP 500 ... can't upload to
  storage type 'lvmthin', not a file based storage!`. Fixed by adding
  `var.template_download_storage_id` (default `"local"`, a dir storage —
  confirmed via `pvesh get /storage` on `.165` that `local` supports
  `import,backup,vztmpl,iso`) and pointing the download resource at it,
  separate from `template_storage_id` (where the VM disk itself lands).
- **Environmental, not a module bug**: `192.168.1.201` was already
  claimed by the `garage-storage` LXC's static IP, so the new `k8s-cp-01`
  VM lost ARP resolution to it (SSH landed on the wrong host, gave
  `Permission denied` even though cloud-init had succeeded). Not caught by
  `k8s-vms.tf`'s own VMID pre-flight warning since that only covers VMID
  reuse, not IP reuse — worth a similar warning for IP collisions if this
  keeps happening. Resolved by removing the stray `garage`/`wireguard`
  LXCs (the latter is also a forbidden pattern per `DECISION.md` §3).
- **Fixed**: both VMs' `agent { enabled = true }` block made the provider
  wait (up to `agent.timeout`, 15m default) for `qemu-guest-agent` to
  respond and publish network interfaces on first apply — Ubuntu's stock
  24.04 cloud image doesn't ship the agent pre-installed/started, so every
  fresh clone hit the full 15-minute wait before finishing with a
  non-fatal `Warning: error waiting for network interfaces from QEMU
  agent`. Fixed by adding `cloud-init.tf`
  (`proxmox_virtual_environment_file.qemu_guest_agent_vendor_data`, a
  `#cloud-config` snippet with `packages: [qemu-guest-agent]` +
  `runcmd: [systemctl enable --now qemu-guest-agent]`) referenced via each
  VM's `initialization.vendor_data_file_id` in `k8s-vms.tf`.
  `vendor_data_file_id` layers on top of the auto-generated
  `user_account`/`ip_config` cloud-init rather than replacing it (unlike
  `user_data_file_id`, which would). Confirmed fix: re-created
  `k8s-cp-01`/`k8s-worker-01` (destroy+recreate was required —
  `vendor_data_file_id` forces replacement, and cloud-init wouldn't
  re-run on an in-place change anyway due to instance-id caching) —
  create time dropped from 15m+ to ~1m20s, `qm agent <vmid> ping` returns
  clean on both, `systemctl is-active qemu-guest-agent` reports `active`.
  Prerequisite: the target storage (`template_download_storage_id`,
  default `"local"`) needs `snippets` added to its content-type list —
  confirmed `.165`'s `local` didn't have it by default
  (`vztmpl,import,iso,backup`); enabled via `pvesm set local --content
  vztmpl,import,iso,backup,snippets`. Same one-time-by-hand-prereq pattern
  as `gpu_mapping_name`, documented in `cloud-init.tf`'s header comment.
- **Gotcha to expect again (unrelated to the above)**: `terraform plan`/
  `apply` refreshes *every* resource in state by default, not just
  `-target`ed ones. If any existing VM in state has a stuck/non-running
  guest agent, that refresh alone re-triggers the same 15-minute wait —
  independent of whatever you're actually planning to change. Use
  `-refresh=false` to skip it when you know nothing changed outside
  Terraform (safe for iterative work in a single session; not a
  substitute for a real `terraform plan` before trusting the result).

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

## 2026-07-13 — full smoke test: terraform → kubespray → ArgoCD → platform-common-apps

Repeat of the chain end to end, this time also trying to get real apps
syncing at wave 10 — the previous test (above) never got past platform
apps. Scope: 2-node Terraform apply (no GPU worker), Garage included in
scope but ultimately deferred (see below), fresh kubespray run, ArgoCD
bootstrap, and migrating `searxng` + `pgweb` off the `k8s-cluster`
submodule's old kustomize manifests. Two real, previously-undiscovered
bugs found and fixed (both merged: PR #5, PR #6); one open networking bug
found and *not* resolved this session.

### Pre-work: two architecture findings before touching infra

- **The registry's app repos don't exist on GitHub.** None of `n8n`,
  `openweb-ui`, `searxng`, `whodb`, `api`, `ukubi-ai` exist under
  `MohammadBnei/*` — confirmed via `gh repo list` (154 repos, no matches).
  `gitops/apps/registry.yaml` had been carrying aspirational entries.
- **The real deployments live inside the `k8s-cluster` submodule** as
  kustomize manifests (`k8s-cluster/n8n/`, `k8s-cluster/searxng/`,
  `k8s-cluster/archive/pgweb/`, etc.), not as standalone repos. Of those,
  only `n8n`, `openweb-ui`(+pipelines), `searxng`, and `pgweb` (in
  `archive/`, not one of the 6 "active" dirs) have real, complete
  configs — `api/` is cert-only, `ukubi-ai/` is just Grafana dashboard
  ConfigMaps, neither is an actual app.
- **Decision: `searxng`/`pgweb` are platform apps, not user apps.**
  Both are public-image tools with no app-specific code, so a private
  per-app repo + deploy key is unnecessary ceremony. Added
  `gitops/bootstrap/platform-common-apps.applicationset.yaml`: a third
  ApplicationSet where `common-app-chart` and the values file both live
  in `infra-bootstrap` itself (single Application source, no external
  repo). `gitops/apps/registry.yaml` stays reserved for apps that
  genuinely need their own repo (currently empty — `n8n`,
  `openweb-ui`(+pipelines), `whodb`, `api`, `ukubi-ai` deferred).
- **Reused real secret values instead of inventing new ones.** searxng's
  `SEARXNG_SECRET_KEY` and the shared `basic-admin-auth` htpasswd
  credential (used by `pgweb`/`jaeger`/`prometheus` in the old cluster,
  from `k8s-cluster/traefik/middlewares/basicauth.yml`) were copied from
  their existing real values into Infisical rather than rotated —
  `docs/secrets.md` documents both, plus the two new small per-app
  Infisical projects (`pgweb-p9-hy`, `searxng-l-dwt`) this pattern uses.

### `common-app-chart` additions (needed for the migration)

Added four generic, additive fields — same idiom as Bitnami's
`extraDeploy`, not per-app special-casing: `extraVolumes` /
`extraVolumeMounts` (raw passthrough into the pod/container spec — needed
for searxng's Secret-mounted `settings.yml`), `extraManifests` (list of
raw YAML strings, `tpl`'d and rendered as separate objects — needed for
searxng's `limiter.toml` ConfigMap and pgweb's `InfisicalSecret`), and
`ingress.middlewares` (Traefik Middleware refs on the IngressRoute —
needed for pgweb's BasicAuth gate). All four verified via `helm
lint`/`helm template` before touching the cluster, including the
double-templating escape trick (`{{ "{{" }} .KEY {{ "}}" }}`) needed so
Helm's own `tpl` doesn't eat the `InfisicalSecret` operator's Go-template
syntax inside a `template:` block.

### Terraform: 2-node + Garage

`k8s-cp-01`/`k8s-worker-01` applied cleanly and fast (~a few minutes,
guest-agent fix from the last test still holds) — zero drift on a
follow-up `-target` plan.

- **Real bug, unresolved**: `null_resource.garage_bootstrap`'s
  community-scripts.org installer script dropped into an **interactive
  `whiptail` menu** ("1 Default Install / 2 Advanced Install / ...")
  instead of running non-interactively, over Terraform's non-interactive
  SSH provisioner — it hangs forever, not just "runs long". The `var_*`
  env vars `garage.tf` sets are supposed to make community-scripts'
  `build.func` skip that menu; something in how the provisioner invokes
  the script isn't triggering that. Confirmed via SSH onto `.165`: the
  script and a `whiptail` process were still alive and blocked after 37+
  minutes. Killed cleanly (nothing was actually created — `pct list`
  never showed a new LXC) and **deferred Garage from this run's scope**.
- **State hygiene gotcha**: even though the provisioner never completed,
  `terraform state list` showed `null_resource.garage_bootstrap` as a
  normal (non-tainted) resource — a future `plan` would've treated it as
  "already applied" and hidden that Garage was never actually installed.
  `terraform state rm null_resource.garage_bootstrap` was needed to make
  state honestly reflect reality before moving on.
- `garage_ip` (`terraform.tfvars`) had only ever been a placeholder
  (`192.168.1.199`, marked "untouched by this test" in a comment) —
  verified free via ping before treating it as real for this run.

### Kubespray

Clean run, `cluster.yml`, both nodes `ok`, `failed=0`, `unreachable=0`,
9m06s total. Inventory (`inventory/ukubi/hosts.yaml`) was already correct
from the last test (`.201`/`.202`, matching Terraform's real topology),
`kube_version` fix already in place, Python 3.12 venv already built — no
prep needed this time, unlike the first test.

### ArgoCD bootstrap: credential handling without touching VM disk

Per user preference, the three `register-repos.sh` bootstrap Secrets
(`repo-infra-bootstrap`, `infisical-secrets`, `universal-auth-credentials`)
were created **without copying any credential files onto the VM or
printing them anywhere** — built locally with `kubectl create secret
--dry-run=client -o yaml` (reads local files directly, renders YAML
in-process) and piped straight into `ssh ... kubectl apply -f -`. Only
`kubectl`'s own confirmation output ("secret/X created") ever left the
pipe. Same technique used later to patch `infisical-secrets` twice
(captcha/telemetry fix, below) and to test the login endpoint safely
(extracting only a `jq`-filtered `.message`/`.error` field, or checking
response byte-size before ever printing a body, to guarantee no live
token could leak into the transcript).

`gitops/bootstrap/` and `traefik-crds/` were `tar`'d and copied to the VM
for `kubectl apply -f` (no secrets in those files, so a plain copy is
fine) — macOS's `tar` adds `._*` AppleDouble sidecar files that `kubectl
apply -f <dir>/` chokes on (`yaml: control characters are not allowed`);
harmless, just `find ... -name '._*' -delete` before applying.

### Real bugs found and fixed (both merged)

- **`InfisicalSecret.spec.hostAPI` pointed at a Service that never
  existed.** Every `InfisicalSecret` in the repo (`grafana-admin-secret`,
  `argocd-github-apps-creds`, plus the new `basic-admin-auth-secret`,
  `pgweb`, `searxng`) and the operator's own safety-net default used
  `http://infisical.infisical.svc.cluster.local:8080/api`. Confirmed via
  `nslookup` inside the cluster: `infisical.infisical.svc.cluster.local`
  is NXDOMAIN — the Infisical Helm chart names its backend Service
  `<release-name>-backend`, and ArgoCD's release name for the platform
  Infisical Application is `platform-infisical`, so the real Service is
  `platform-infisical-backend`. All 5 `InfisicalSecret`s were failing
  universal-auth login identically. This is the **first time any of
  these were exercised end-to-end** since being written — fixed in PR #6.
- **Infisical's captcha/telemetry defaults**: the running pod had
  `CAPTCHA_SITE_KEY=captcha-site-key` (an obvious non-functional
  placeholder) and `TELEMETRY_ENABLED=true` with a real `POSTHOG_API_KEY`
  — neither came from our Helm values or `.env.secret` (confirmed via
  `kubectl get secret -o json | jq keys`, and grepping the pulled chart
  source for "captcha" found nothing), so both are baked into the
  `infisical/infisical` Docker image itself as defaults. Overrode both to
  disabled (`CAPTCHA_SITE_KEY=`, `TELEMETRY_ENABLED=false`) by appending
  to the local `k8s-cluster/infisical/.env.secret` — good hygiene for a
  private homelab regardless, but **did not fix the actual login
  failure** (see below); this was a red herring investigated in parallel.

### Open issue — not yet resolved: ClusterIP Service routing broken cluster-wide

After the `hostAPI` fix, every `InfisicalSecret` still failed
universal-auth login with a real (not DNS-failure) `409` whose body was a
literal Cloudflare DNS-resolution error page (`error code: 1001`, 16
bytes) — clearly not an Infisical application error. Isolated with a few
basic checks:

- Direct pod-IP access (`curl http://<pod-ip>:8080/api/status`) returns a
  clean `200` with real JSON, every time.
- The exact same request through the ClusterIP Service
  (`platform-infisical-backend.infisical.svc.cluster.local`) returns the
  bogus `409` — for **every** endpoint tried, including the trivially
  simple `/api/status` health check.
- **Not specific to Infisical**: `argocd-server.argocd.svc.cluster.local`
  (a completely unrelated Service) returns the identical `409` +
  Cloudflare page. This is a **systemic ClusterIP-routing bug**, not
  anything in this repo's gitops config.
- `sudo ipvsadm -Ln` on `k8s-cp-01` shows the IPVS virtual server rule is
  programmed correctly (`10.233.53.71:8080 -> 10.233.64.109:8080 Masq`,
  pointing at the right pod). `kube-proxy` logs are clean (IPVS proxier
  running, no errors beyond the standard "ipvs is deprecated, consider
  nftables" notice).

**Not resolved**: the IPVS rule being correct but Service-routed traffic
still failing points at something lower in the datapath — masquerade/SNAT
handling, or an interaction with Cilium running in chaining mode
(kube-proxy retained per `ARCHITECTURE.md`) — that needs packet-capture-
level debugging (iptables NAT table dump, `cilium monitor`, or similar) to
actually pin down. Next session should start here before anything else;
until this is fixed, **no ClusterIP-routed traffic works on this
cluster**, which blocks not just `InfisicalSecret` sync but likely
Traefik→backend routing for every app once real traffic starts flowing
(IngressRoutes route to Services, same broken path).

### Status at end of session

Terraform (2-node), kubespray, and the whole ArgoCD platform stack
(Longhorn, Infisical, infisical-operator, Traefik, Prometheus, Grafana,
metrics-server) are up and `Healthy`. `platform-common-apps` (searxng,
pgweb) synced and pods started, proving the new ApplicationSet mechanism
itself works — but neither app can finish going `Healthy` until the
ClusterIP routing bug above is fixed, since both depend on
`InfisicalSecret` (in turn blocked on Service-routed calls to the
Infisical backend).

## 2026-07-13 — round 2: root cause found, fixed, full re-bootstrap

Picking up exactly where the session above left off. The "systemic
ClusterIP-routing bug" hypothesis (masquerade/SNAT, Cilium chaining vs.
kube-proxy) turned out to be a red herring on a **different** axis — a
live `curl` from a debug pod straight to
`platform-infisical-backend.infisical.svc.cluster.local:8080` showed the
hostname itself resolving to public Cloudflare IPs
(`172.67.128.160`/`104.21.1.56`), not a routing failure at all.

### Actual root cause: DNS search-domain poisoning, not routing

- Every pod's `/etc/resolv.conf` carried a bare `dev` search domain
  alongside the normal Kubernetes ones. With `ndots:5`, any in-cluster FQDN
  (4 dots) tries appending search suffixes — including `dev` — before the
  absolute name. `.dev` is a real public TLD, so
  `...cluster.local.dev` gets a live (non-NXDOMAIN) answer from a
  Cloudflare-fronted address, and resolution stops there. Confirmed
  identically for `argocd-server` — never Infisical-specific.
- Traced to the source with direct root SSH to the Proxmox host itself
  (`192.168.1.165`): `pvesh get /nodes/bnei/dns` showed `search: "dev"`.
  The PVE node's own hostname is `bnei` with domain `bnei.dev` — during
  the original Proxmox installer FQDN prompt, entering `bnei.dev` as a
  single field gets mechanically split into hostname=`bnei` +
  domain=`dev` (everything before the first dot vs. everything after). A
  3+ label FQDN (e.g. `pve.bnei.dev`) wouldn't have hit this. PVE's
  cloud-init generator uses that node-level domain as the default DNS
  search domain baked into every guest's netplan — this is why it hit
  every VM on the host, not just the k8s ones.
- First fix attempt (netplan `dhcp4-overrides: use-domains: false` in the
  shared cloud-init vendor-data) **did not work** — `netplan get` showed
  the "dev" search domain is statically written into PVE's own generated
  `50-cloud-init.yaml`, not DHCP-negotiated, so DHCP-domain suppression
  was the wrong lever entirely.
- Real fix: the `bpg/proxmox` Terraform provider's
  `initialization.dns.domain` attribute overrides PVE's cloud-init DNS
  domain generation directly, per-VM. Set to `"localdomain"` (not a real
  TLD, so a failed lookup correctly NXDOMAINs and falls through) on both
  `k8s_cp_01` and `k8s_worker_01` in `terraform/k8s-vms.tf`. Verified live
  post-recreate: `resolvectl status` on both nodes shows `DNS Domain:
  localdomain`.
- User also fixed the PVE-level default afterward
  (`pvesh set /nodes/bnei/dns --search bnei.dev`) — since `bnei.dev` is a
  zone they actually own, this is safe unlike bare `dev`. The Terraform
  per-VM override is kept anyway as defense in depth, independent of
  whatever the shared host defaults to.

### Topology correction (discovered mid-fix)

`k8s-worker-gpu` was never actually deployed (only `k8s-cp-01` +
`k8s-worker-01` exist, matching `inventory/ukubi/hosts.yaml`) — the
intended final topology is 2 VMs, not 3: the worker carries GPU
passthrough directly. `terraform/k8s-vms.tf` and `ARCHITECTURE.md` updated
accordingly. First apply attempt with `hostpci` on `k8s_worker_01` failed:
`PCI device mapping not found for 'gpu'` — the PVE PCI Resource Mapping
was never created by hand on `.165` (root-only, out of reach of the
API-token Terraform provider). `hostpci` block temporarily commented out
to unblock this smoke test; re-enable once the mapping exists.

### MetalLB pool collision (discovered mid-verification)

Traefik's pinned LoadBalancer IP (`192.168.1.231`) and the MetalLB pool
(`192.168.1.230-250`) overlapped with `192.168.1.232`, which the user
already uses as Pigsty's HA floating VIP (vip-manager). Pool shrunk to
`192.168.1.233-250`; Traefik's pin moved to `192.168.1.233`.
`inventory/ukubi/group_vars/k8s_cluster/addons.yml`,
`gitops/platform/values/traefik/values.yaml`, `ARCHITECTURE.md`, and
`CLAUDE.md` updated. Live `IPAddressPool` patched directly and the
`metallb-system/controller` deployment restarted (it had cached the old
pool and kept re-offering `.231` even after the CR was patched and the
Service recreated — a live `kubectl patch` on the pool isn't enough by
itself, the controller needs a restart to stop re-issuing stale
addresses). The Traefik values-file fix landed on a still-open PR
(`fix/dhcp-dns-search-domain`, #8) — since ArgoCD tracks `HEAD` on the
default branch, the live Service annotation didn't update until merge, so
`platform-traefik`'s Service sat `<pending>` (rejecting `.231`, no valid
IP to fall back to) until the PR merged.

### Full re-bootstrap results (terraform + kubespray + ArgoCD)

- **kubespray `cluster.yml`**: clean run, `failed=0 unreachable=0` both
  nodes, ~11 minutes (vs. a much longer original bootstrap) — image/module
  caching from the first run made this pass much faster, as expected.
  Gotcha re-hit and re-fixed in the same session: invoking
  `ansible-playbook -i inventory/ukubi/hosts.yaml kubespray/cluster.yml`
  from the repo root (not `cd kubespray && ansible-playbook -i
  ../inventory/ukubi/hosts.yaml cluster.yml`) breaks kubespray's own
  `ansible.cfg` roles_path resolution (`role 'dynamic_groups' was not
  found`) — this exact mistake and its fix were already documented in
  `docs/bootstrap-test-notes.md` §"gotchas" from the 07-12 run; worth
  re-emphasizing since it's easy to make again reflexively.
- **ArgoCD bootstrap**: Helm install, `register-repos.sh`'s three secrets
  (recreated manually via `kubectl create secret --dry-run=client -o yaml`
  piped over SSH, per this repo's "never materialize credentials locally"
  convention), `gitops/bootstrap/traefik-crds/` + `gitops/bootstrap/`
  applied. The 3 `InfisicalSecret` CRs in `gitops/bootstrap/` failed on
  first apply (`no matches for kind "InfisicalSecret"` — expected
  chicken-and-egg, since the CRD only exists once `infisical-operator`
  itself has synced) and were cleanly re-applied once wave 1 finished.
- **Infisical**: `platform-infisical` + `platform-infisical-operator`
  `Healthy`. `pgweb-infisical` and `searxng-settings` `InfisicalSecret`s
  resolved immediately — **this is the direct end-to-end proof the DNS
  fix works**, since these are exactly the universal-auth calls that were
  failing before.
- **Separate, unrelated finding**: `argocd-github-apps-creds`,
  `grafana-admin-secret`, `basic-admin-auth-secret` initially failed with
  `403 Forbidden` (`"You are not a member of this project"` for
  `infra-bootstrap-1-ge1`) — the universal-auth machine identity had only
  ever been granted access to the dedicated `pgweb-p9-hy`/`searxng-l-dwt`
  projects, not the main one. Fixed by the user granting project access
  in the Infisical UI; all 3 resolved cleanly afterward, unblocking
  Grafana (`Healthy`) and the ArgoCD repo credentials.
- **searxng**: alive — `1/1 Running`, serving on 8080, only non-fatal
  plugin warnings (a couple of search engines fail to register, a tracker
  pattern list fetch fails — cosmetic).
- **pgweb**: still not alive. Crash-loops on `Error: authentication
  failed` against Postgres. Confirmed this is a credential/DB-state issue,
  not networking — `PGWEB_DATABASE_URL`'s host (`192.168.1.232:5432`,
  Pigsty's HA VIP) accepts the TCP connection and responds; it just
  rejects the current credentials. Not investigated further this session
  (out of scope — touches live Postgres/Pigsty auth state, needs the
  user's call per this repo's own Pigsty guardrails). Worth checking
  whether the `pgweb-p9-hy` project's `DATABASE_URL` secret is stale.
- **platform-prometheus**: `Degraded` — its Longhorn volume
  (`pvc-...-db-prometheus-...-0`) ended up `detached`/`faulted`, likely
  from the same early race as the `CSINode ... does not contain driver
  drin.longhorn.io` event (PVC tried to attach before Longhorn's CSI
  plugin had registered on the node). Not remediated — the VMs are being
  torn down at the end of this session anyway, so the volume goes with
  them; if this cluster becomes longer-lived, revisit Longhorn's startup
  ordering relative to PVC creation.
- **platform-longhorn**: `Healthy` but `OutOfSync` — not investigated
  further, likely a benign Helm-hook/drift artifact.

### Status at end of session

Root cause of the previous session's blocker is fixed and proven live:
Infisical, ArgoCD, and Grafana all resolve `InfisicalSecret`s through
ClusterIP DNS names now. searxng is fully healthy. pgweb and Prometheus
have their own separate, unrelated issues (Postgres credentials; a faulted
Longhorn volume) that are explicitly out of scope for this DNS fix. PR #8
carries all of this session's fixes (Terraform `dns.domain` override,
2-node topology correction, MetalLB pool move) and needs merging before
`platform-traefik`'s Service can get a valid IP. VMs are being torn down
at the end of this session (ephemeral test infra, no data worth
protecting) — the next bootstrap should be materially faster and cleaner
than either of the last two, now that all three real bugs found across
both sessions are fixed in the repo itself.
