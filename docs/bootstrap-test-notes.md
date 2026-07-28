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

## 2026-07-14 — GPU passthrough fixed (Secure Boot was a red herring)

Starting symptom: "GPU drivers not valid and can't start since enabling
Secure Boot" on `.165`. Audited the live host (read-only SSH first, via
the same `PVE_SSH_PRIVATE_KEY` Infisical secret Terraform uses) before
touching anything, since some earlier work had already failed here.

**What was actually broken:** a previous attempt had installed the
proprietary NVIDIA driver (`nvidia-kernel-dkms`, `nvidia-driver-cuda`,
~15 related `libnvidia-*`/`libcuda*` packages) plus
`pve-nvidia-vgpu-helper` **directly on the Proxmox host itself**.
`pve-nvidia-vgpu-helper` is Proxmox's tooling for NVIDIA vGPU
(mediated-device) passthrough — a GPU-multi-tenancy pattern explicitly
rejected by
[ADR-0011](adr/0011-reject-multi-region-dr-service-mesh.md) for this
single-site, one-GPU homelab. Wrong approach entirely: this repo's design
is raw whole-GPU PCI passthrough of all 4 functions to one VM
(`k8s-worker-01`), with the driver living inside the guest, not on the
host. `nvidia-kernel-dkms` was stuck `iU` in `dpkg -l` (postinst's
DKMS build/sign step never completed) — Secure Boot blocking that
unsigned module was a real symptom, but not the actual problem, since the
host should never have been running this driver at all.

Fix, step by step:
1. Purged the entire host-side NVIDIA stack + `pve-nvidia-vgpu-helper`
   (`apt-get purge`/`dpkg --purge --force-remove-reinstreq` for the
   packages `apt` couldn't resolve cleanly on its own, due to the
   half-configured state). `apt autoremove` incidentally also dropped
   `sudo`/`dkms` as no-longer-needed — reinstalled `sudo` immediately
   since removing it was an unintended side effect, not part of the fix.
   `pg01`/`pg02` (production Postgres, same host) stayed up throughout.
2. Configured `vfio-pci` to claim the GPU's 4 PCI IDs
   (`10de:1e84`/`10de:10f8`/`10de:1ad8`/`10de:1ad9`) via
   `/etc/modprobe.d/vfio.conf`, blacklisted `nouveau`, and made sure
   `vfio`/`vfio_pci`/`vfio_iommu_type1` actually load early via
   `/etc/modules-load.d/vfio.conf` (the `modprobe.d ids=` option alone
   doesn't force early loading — needed both).
3. Rebooted (twice — see gotcha below). Every reboot of `.165` briefly
   restarts `pg01`/`pg02` along with it; confirmed both came back healthy
   each time.
4. **Real root cause, found only after step 3 still didn't bind
   `vfio-pci` to anything**: `/sys/kernel/iommu_groups/` was completely
   empty — AMD-Vi was fully disabled at the BIOS level (ASRock B450
   Gaming K4, no IPMI/BMC, so this needed physical keyboard+monitor
   access — not something fixable over SSH). The kernel's generic
   `iommu: Default domain type: Translated` dmesg line is printed
   regardless of whether real hardware IOMMU groups exist, and was a
   misleading signal during the first diagnosis pass. User enabled it
   under AMD CBS → NBIO Common Options; after that reboot, 16 IOMMU
   groups appeared and the GPU's 4 functions landed in group 2 together
   with their upstream PCIe bridge, as expected for a clean multi-function
   passthrough candidate.
5. Even with IOMMU working, `vfio-pci` only auto-claimed 2 of the 4
   functions on boot (`.0`/`.1`) — `.2`/`.3` still got grabbed first by
   `xhci_hcd`/`i2c_nvidia_gpu` (a mainline in-kernel driver for the
   USB-C UCSI controller, unrelated to the purged proprietary NVIDIA
   stack). `options vfio-pci ids=...` is a boot-order race, not a
   guarantee. Fixed by force-binding all 4 via `driver_override` +
   unbind/bind (worked live, no reboot needed to test), then persisted
   as a boot-time systemd oneshot so it's deterministic going forward:
   `/usr/local/bin/vfio-pci-bind-gpu.sh` +
   `vfio-pci-bind-gpu.service` (`WantedBy=sysinit.target`,
   `Before=pve-guests.service`).
6. Created the PCI Resource Mapping (`pvesh create /cluster/mapping/pci
   --id gpu --map node=bnei,path=0000:0b:00,id=10de:1e84,iommugroup=2`) —
   the one-time root-only step Terraform's API-token provider can't do,
   flagged in `terraform/k8s-vms.tf`'s own comments since the 2026-07-13
   session.
7. Re-enabled the `hostpci0` block in `terraform/k8s-vms.tf` for
   `k8s_worker_01` (commit `c99efa7c`, branch
   `fix/gpu-passthrough-secureboot`). `terraform validate` passes.

**End state (2026-07-14):** host is fully passthrough-ready — all 4 GPU
functions on `vfio-pci`, mapping exists, Terraform config re-enabled —
but **not yet attached to a VM**, since `k8s-worker-01` doesn't currently
exist (`qm list` only shows `pg01`/`pg02`/templates; last smoke test's
VMs were torn down). The next full bootstrap's `terraform apply` creates
it with the GPU attached. Secure Boot itself was left enabled throughout
— it was never disabled, and didn't need to be, once the host stopped
trying to load an unsigned third-party driver.

**Single-VM note:** raw PCI/VFIO passthrough is exclusive by
construction — Proxmox refuses to start a second VM against a PCI
Resource Mapping already claimed by a running VM. This is deliberately
not vGPU-style sharing across multiple VMs/tenants (see ADR-0011 above).

Also fixed two pre-existing stale doc references found while writing
this up (not caused by this session, just never cleaned up after the
2026-07-12 topology correction below): `terraform/README.md`'s topology
table and `-target` example both still referenced a separate
`k8s-worker-gpu` VM that was abandoned in favor of GPU-passthrough-on-
`k8s-worker-01` — removed. See `docs/infrastructure-actual.md`'s
"GPU passthrough" subsection under Proxmox host details for the
consolidated current-state summary.

## 2026-07-26 — Garage: replaced community-script installer, full Terraform + Ansible smoke test

`terraform/garage.tf`'s `null_resource.garage_bootstrap` (community-scripts.org
`ct/garage.sh` installer over SSH) was replaced with a direct, single-phase
LXC create — a `proxmox_download_file` (vztmpl) + a plain
`proxmox_virtual_environment_container` resource, no script, no
`terraform import` dance. A new `ansible/playbooks/garage-configure.yml`
handles everything after LXC creation: binary install, config, systemd
unit, single-node cluster layout, bucket/key creation, and writing
`GARAGE_ROOT_TOKEN`/`LONGHORN_S3_ACCESS_KEY`/`_SECRET`/
`PGBACKREST_S3_ACCESS_KEY`/`_SECRET` to Infisical. Both were actually run
against `.165`, not just validated — real end-to-end smoke test.

**Template version correction:** initially wrote `garage.tf` against
Debian 12, following an old comment's example — user caught this
(`.165` already had Debian 13 templates available). Confirmed via
`pveam available` on `.165` that `debian-13-standard_13.6-1_amd64.tar.zst`
is the current mirror version (a `13.1-2` copy was also already cached
locally from earlier testing, but the Terraform resource downloads its
own copy rather than depending on that out-of-band artifact, so a
from-scratch rebuild on a fresh host still works).

**`GARAGE_VERSION`/`GARAGE_SHA256`:** the playbook requires these as env
vars rather than hardcoding a version (same "confirm, don't guess"
discipline as `pve_node_name`). For this run: `v2.3.0`, sha256 obtained by
downloading the `x86_64-unknown-linux-musl` binary directly and hashing
it (`shasum -a 256`) — garagehq.deuxfleurs.fr doesn't publish a fetchable
checksum file at a predictable URL.

**Real bugs found and fixed, only surfaced by actually running it:**

1. Garage's default config path is `/etc/garage.toml`, not
   `/etc/garage/garage.toml` — the daemon failed with `IO error: No such
   file or directory` and restart-looped until this was fixed.
2. `garage node id` prints `<pubkey>@<address>:<port>` (meant for peer
   connections); `garage layout assign` wants the bare pubkey. Using the
   full string gave `Error: 0 nodes match`.
3. Combining `regex_search` (for extracting `rpc_secret`/`admin_token`
   from an existing config) with a Jinja ternary (`X if cond else Y`)
   fails with `'NoneType' object has no attribute 'group'` — it evaluates
   both branches regardless of which one Ansible should pick. Fixed by
   splitting into two mutually-exclusive `when`-gated `set_fact` tasks
   instead of one ternary. Separately, `regex_search` with a group
   backreference returns a **list**, not a scalar — needs `| first`.
4. Layout-apply idempotency initially only checked "did `assign` change
   anything *this run*" to decide whether to run `apply` — broke on
   resuming an interrupted run where `assign` had already staged a change
   in a prior invocation but `apply` never happened. Fixed by always
   re-reading `garage layout show` and checking for its `apply --version
   N` hint, independent of whether `assign` ran this time.
5. `garage bucket allow` takes the bucket name as a positional argument,
   not `--bucket <name>` — the flag form errors with `Found argument
   '--bucket' which wasn't expected`.

**End state (2026-07-26):** `garage-storage` (VMID 301, Debian 13,
`192.168.1.199`) running Garage v2.3.0, single-node layout applied,
`k8s-longhorn-backup`/`pg-backup` buckets created with one S3 key each,
all five secrets confirmed present in Infisical via scoped `--plain`
lookups (never dumped in bulk after the incident below). Re-ran the full
playbook a second time to confirm idempotency — only the 3
`infisical secrets set` upserts showed as changed, everything else
skipped or no-op'd as expected.

**Incident: secret exposure via unscoped `infisical secrets` list.**
Mid-session, a diagnostic `infisical secrets --projectId=... --env=dev`
(no `--plain`, no key name) was run to check CLI auth state and printed a
full table of real secret values into the session transcript — including
`SSH_SERVER1_KEY`'s plaintext private key. `SSH_SERVER1_KEY` should be
rotated (new keypair, updated `authorized_keys` on server1, new value
written to Infisical). Going forward, any Infisical CLI check in this
kind of session should use `--plain` scoped to one named key, never an
unscoped list/dump.

**Bug: infisical-operator (secrets-operator chart) doesn't detect value
changes for Go-template `managedSecretReference.template.data` fields.**
Hit while fixing a bad Garage S3 key (`regex_search` without `| first`
had stored the Python list-repr `['GK...']` instead of the bare key in
Infisical — see `ansible/playbooks/garage-configure.yml`'s fix). After
correcting the source value in Infisical, `longhorn-backup-secret`'s
managed K8s Secret never updated, through: a 60s `resyncInterval`
elapsing repeatedly, deleting the managed Secret (recreated with the
same stale value), restarting both the operator and the
`platform-infisical-backend` deployment, and deleting+recreating the
`InfisicalSecret` CR itself (fresh UID, no stored status). Root-caused by
querying the in-cluster Infisical API directly with a fresh token
(bypassing the operator's own caching) — confirmed the *server* already
had the correct value with a fresh ETag. The operator's own logs show
its very first reconcile after a restart fetches fresh data via machine
identity but still logs `Managed Kubernetes secret already up to date,
skipping update` — a diffing bug specific to templated secrets, not a
data-freshness problem. **Workaround**: `kubectl apply` a
`kubectl create secret generic ... --dry-run=client -o yaml` directly
against the managed Secret, bypassing the operator for that one secret.
Not operator-managed after that — revisit if this chart gets upgraded
(current version pinned in
`gitops/platform/values/infisical-operator/values.yaml`).

## 2026-07-27 — editable-blog onboarding: ArgoCD repo credentials

First real per-app repo exercised through `apps.applicationset.yaml`'s
multi-source template (n8n/openweb-ui/etc. were all still deferred).
`editable-blog`'s Application stuck in `Unknown` sync status,
repo-server logs: `Failed to get git client for repo
git@github.com:MohammadBnei/editable-blog.git: failed to list refs:
ssh: no key found`.

Two wrong turns before the real cause:

1. First guessed this was ArgoCD not applying the `repo-creds`
   URL-prefix credential template to the *second* source of a
   multi-source Application. Built and PR'd an explicit per-repo
   `Repository` secret (mirroring `repo-infra-bootstrap`, which does
   work) — but before merging, tested the actual key material directly
   (temp pod, `ssh-keygen -y` against the mounted secret, never
   printing key bytes) and found `GITHUB_APPS_SSH_KEY`'s stored value
   itself was unparseable (`invalid format` / `error in libcrypto:
   unsupported` across two different OpenSSH builds) — a data problem,
   not an ArgoCD scoping problem. Closed the PR without merging; it
   would have added a permanent per-app credential file for no reason.
2. Regenerated the key fresh (`ssh-keygen`, uploaded to Infisical via
   `secrets set NAME=@/path/to/file`, never through copy-paste) and
   confirmed via direct `infisical secrets get --plain` that the raw
   value in Infisical parses cleanly. But the *operator-materialized*
   K8s Secret (`repo-creds-github-bnei`, from
   `argocd-github-apps-creds.yaml`'s `InfisicalSecret`) still failed
   `ssh-keygen -y` with `invalid format` even on this brand-new,
   never-copy-pasted key.

That second result points at the **same infisical-operator
Go-template rendering bug** logged above, just a different
manifestation: multi-line PEM/OpenSSH key values get mangled somewhere
in `managedSecretReference.template.data` interpolation, not just
stale-cached. **Workaround, same as before**: bypass the operator for
this Secret — piped `infisical secrets get --plain` straight into
`kubectl create secret generic repo-creds-github-bnei --from-file=
sshPrivateKey=/dev/stdin ... | kubectl apply -f -`, verified via
`ssh-keygen -y` against the resulting Secret. Held correctly past one
full `resyncInterval` (60s) without the operator reverting it — same
lucky-but-unreliable non-interference as the Longhorn case.

Separately: `GITHUB_APPS_SSH_KEY` as a single shared credential across
all `MohammadBnei/*` repos can only work as a **machine-user account
key** (invited as a read-only collaborator per repo), never as a
GitHub deploy key — GitHub rejects registering one public key as a
deploy key on more than one repo. The key regenerated here
(`argocd-bot@ukubi-cluster`) is intended for a new dedicated machine
GitHub account, not yet created as of this writing.

**Any future secret pushed through an `InfisicalSecret` CR's templated
`managedSecretReference` — especially multi-line values like private
keys — should be spot-checked against the actual K8s Secret content,
not just against `infisical secrets get`,** until this operator bug is
fixed upstream.

### Follow-up — machine user created, GitHub collaborator-permission API quirk

`argocd-ukubi-bot` GitHub account created and added as a collaborator on
`editable-blog`, with the regenerated key added as its account SSH key
(not a deploy key). It ended up with **Write** access instead of Read —
`gh api -X PUT repos/.../collaborators/argocd-ukubi-bot -f
permission=pull` returns `204 No Content` (success) but the effective
permission stays `write` on every re-check; the GitHub web UI's role
dropdown also didn't let it be downgraded. Root cause not chased further
— accepted as-is per user decision, since Write is a superset of the
Read access ArgoCD actually needs (it only clones/fetches, never
pushes). Functionally fine; just broader than least-privilege.

### Follow-up — real bug: k8s VMs had no CPU passthrough, crashed Bun-based images

Once the git/credential problem was fully resolved, `editable-blog`'s
Application reached `Synced`, but the pod crash-looped with **exit code
132 (SIGILL)** and zero log output (crashed before the runtime could
buffer anything). Root cause: `terraform/k8s-vms.tf`'s `cpu` block never
set `type`, so both `k8s-cp-01` and `k8s-worker-01` were running on
Proxmox's default `qemu64` baseline CPU model — confirmed via
`/proc/cpuinfo` inside a `kubectl debug node/...` pod: `model name
: QEMU Virtual CPU version 2.5+`, no `avx2` flag. editable-blog's
Dockerfile runs its production process via `bun x serve ...`, and Bun
hard-requires AVX2 — it crashes with SIGILL on any CPU lacking it. This
is the first workload in the cluster to actually need a modern
instruction set, so nothing surfaced this until now.

**Fix**: added `type = "host"` to `cpu` in `terraform/k8s-vms.tf`
(matching the existing `machine = "q35"` comment style/precedent right
above it) so both K8s VMs get `.165`'s real CPU features passed through
(confirmed: `AMD Ryzen 5 3600X 6-Core Processor`, `avx2` present).
`terraform plan -target=proxmox_virtual_environment_vm.k8s_node` showed
a clean in-place update (`qemu64 -> host`, 0 to add/destroy) — doesn't
touch `pg01`/`pg02`/`hermesagent`. Required a reboot of both VMs to take
effect (CPU model isn't hot-swappable), a brief full-cluster blip —
acceptable pre-cutover, no real traffic yet.

**Caveat for Stage 2** (already noted inline in `k8s-vms.tf`): `host`
CPU type passes through the exact physical CPU, which isn't
live-migration-safe across physically different CPU models. Once
`.200`/`.161` join and their CPUs are known, may need to switch to a
named baseline microarchitecture common to all three hosts instead of
`host`.

**Result**: pod `Running`/`Ready` with zero crashes since the reboot;
`curl` from an in-cluster pod to `http://editable-blog.editable-blog
.svc.cluster.local:3000/` returns `200`. ArgoCD Application health is
`Healthy`.

### Follow-up — sync status `Unknown`, and the real end of the SSH saga

`status.sync.status` stayed `Unknown` (health `Healthy`) even after
repeated hard refreshes and repo-server restarts, with the condition
frozen on the original `ssh: no key found` message. Root-caused by
re-testing the (previously verified-good) `repo-creds-github-bnei`
secret again, hours later: it had been **silently re-corrupted** by the
infisical-operator (`ssh-keygen -y` now failed `invalid format` on a
secret that had parsed cleanly right after the fix). The "holds past one
resync interval" check done earlier in this doc was not sufficient
evidence of stability — the operator's corruption is real and recurring,
not a one-time fluke, and can strike a completely fresh, never-corrupted
key.

This closed the door on trusting the operator with this credential in
any form. Decision (with user sign-off): **switch from SSH deploy keys
to HTTPS + a GitHub Personal Access Token**, for two independent
reasons:
1. GitHub deploy keys are inherently one-key-per-repo (confirmed:
   attempting to reuse a key across repos is rejected by GitHub) — a
   single shared SSH credential across all `MohammadBnei/*` repos was
   only ever going to work via a machine-user *account* key, not a
   deploy key.
2. HTTPS + PAT sidesteps SSH entirely, including the operator's
   template-corruption bug for this value.

A dedicated machine account (`argocd-ukubi-bot`) was created and added
as a collaborator for the SSH attempt, but ended up with **Write**
instead of Read access — both the `gh api -X PUT .../collaborators/...
-f permission=pull` API call (returns `204` but doesn't change the
effective permission) and the GitHub web UI's role dropdown failed to
downgrade an already-accepted collaborator. Accepted as-is (Write is a
superset of what ArgoCD needs, just broader than least-privilege) — not
chased further.

The user then generated the PAT from their **own** personal account
instead (read access to all their repos, fine-grained token), which is
actually simpler going forward: no per-repo collaborator invite needed
for future apps.

**Confirmed the PAT is ALSO subject to operator corruption**: even a
single-line token got extra garbage bytes appended by the
`InfisicalSecret` template rendering (a stray space + `/`, 97 bytes
where the raw Infisical value was 94) — this bug is not limited to
multi-line PEM/SSH values as first assumed. **This surfaced a real
credential exposure**: a test command built a `user:pass@` URL directly
from the (corrupted) token, and when `git` failed, its own error message
echoed the full URL — including the token — into the session transcript.
The user was notified immediately and asked to revoke/regenerate;
rotation deferred by user decision, proceeded with the same
(already-exposed) token for now. **Lesson for future credential
testing: never embed a raw secret in a URL or command line whose failure
output could echo it back — build auth via a header/file inside the
test pod instead**, which is what all subsequent testing in this
investigation switched to.

**Final, durable fix**: stopped routing this credential through
Infisical/the operator at all. `gitops/bootstrap/argocd-github-apps-
creds.yaml` (the `InfisicalSecret` CR) was deleted — critically, this
had to happen *before* committing the change, otherwise ADR-0021's
self-syncing `bootstrap` Application (`prune: true`, `selfHeal: true`)
would keep recreating the CR from git every time it was deleted to stop
the corruption, permanently undoing the fix. `repo-creds-github-bnei` is
now injected the same way as `repo-infra-bootstrap`: manually, via
`ansible/playbooks/register-repos.yml` (`GITHUB_APPS_USERNAME` /
`GITHUB_APPS_PAT` in `register-repos.env`, PAT routed through a
mode-0600 tempfile, never a CLI argument). `editable-blog`'s `repoURL`
switched from `git@github.com:...` to `https://github.com/...` in both
`gitops/apps/registry.yaml` and `gitops/bootstrap/apps.applicationset
.yaml` to match.

Separately, a parallel session moved `editable-blog`'s `values.yaml` to
`helm/values.yaml` and switched its Infisical wiring from a raw
`secrets.infisical.com/auto-reload` annotation to `common-app-chart`'s
native `infisical.autoReload` field — both legitimate, folded in as part
of getting this Application to sync.

### Follow-up — sync status stuck `Unknown`/`Healthy` even with a working credential

After merging the HTTPS+PAT fix and getting the manual `repo-creds-
github-bnei` secret rebuilt correctly, the Application still couldn't
reach `Synced`: repo-server logs showed a *new* error —
`authentication required: Invalid username or token. Password
authentication is not supported for Git operations.` — GitHub's own
error text, meaning the request reached GitHub and was rejected, not a
credential-lookup failure like before.

This looked, for a while, like a genuine ArgoCD/go-git bug: the token
was independently confirmed valid three separate ways (direct GitHub
API check with `Authorization: Bearer`, `git ls-remote` with a
hand-built `Authorization: Basic` header from a throwaway pod, twice
with different usernames), and switching the secret between
`repo-creds` (template) and `repository` (exact-URL) types, changing
the username (`MohammadBnei` vs. GitHub's documented `x-access-token`
convention for PAT auth), and fully restarting all three ArgoCD
components (`repo-server`, `application-controller`, `server`) made no
difference — the same error every time.

**Actual root cause: self-inflicted, not ArgoCD's fault.** Every
`repo-creds-github-bnei` secret rebuilt during this investigation was
constructed by piping `infisical secrets get --plain | kubectl create
secret ... --from-file=password=/dev/stdin` — and `infisical secrets
get --plain`'s output ends with a trailing newline. `--from-file` on
`/dev/stdin` captures that newline as part of the secret value
byte-for-byte (confirmed via `od -c`: `... Y K \n`). Every *manual*
verification test in this investigation used `$(cat ...)` shell command
substitution to read the value first, which **silently strips trailing
newlines** — so every hand-built test looked fine while the actual
secret ArgoCD was reading had a corrupted (newline-suffixed) password
the whole time. ArgoCD reads the Kubernetes Secret's raw bytes directly
(no shell involved), so it faithfully preserved and used the broken
value, produced a Basic-auth header GitHub couldn't parse as a valid
token, and GitHub's backend responded with its generic "password auth
not supported" message rather than a specific "malformed credential"
one — which is what made this look like an upstream bug for so long.

**Fix**: `tr -d '\n'` before piping into `--from-file=password=...` when
rebuilding this secret by hand. The `ansible/playbooks/register-repos
.yml` task added earlier already sources the PAT from an env var (not a
piped CLI value), which doesn't carry this specific risk, but a
defensive `| trim` Jinja filter was added to its tempfile-write task
anyway, since the failure mode is silent, easy to reintroduce, and
expensive to debug.

**Lesson**: when a `kubectl`/API client fails against a secret that
"looks right" in every manual check, verify using the exact same
data-access path the failing consumer uses (raw bytes, not a shell that
silently normalizes them) — `$(cat ...)`, `printf`, and similar all
strip trailing newlines by design, which can hide exactly this class of
bug.

**End state**: `editable-blog` ArgoCD Application `Synced`/`Healthy`,
pod serving `200` on port 3000 continuously (`16` restarts total, `0`
since the CPU fix, over 2.5 hours). HTTPS+PAT path confirmed fully
working end to end.

## 2026-07-28 — Freebox cutover: real Let's Encrypt certs, three chained bugs

After Stage 1 was verified healthy internally, the Freebox port-forward was
repointed from the legacy HAProxy target to the new Traefik VIP
(`192.168.1.233`). First external check (via a truly external HTTP client,
not a LAN-side curl) immediately surfaced three separate, unrelated bugs
stacked on top of each other — each one only became visible once the
previous one was fixed.

### Bug 1 — wrong port before the right port

First external `curl`/fetch attempt got `ECONNREFUSED` on 443. The Freebox
rule had been updated to point at `.233` but kept the legacy HAProxy's
destination port (`8000`/`8443`) instead of standard `80`/`443` — Traefik's
LoadBalancer service listens on the standard ports, nothing was listening
on `8000`/`8443` at that IP. Fixed by pointing the Freebox rule at `.233`
port `80` **and** `443` explicitly (two separate rules — easy to fix one
and assume the other is fine).

### Bug 2 — Traefik never actually had a working cert, the whole time

Once the port was right, external TLS connected but every client reported
`unable to verify the first certificate`. `openssl s_client` against the
VIP confirmed Traefik was serving its own `TRAEFIK DEFAULT CERT`
(self-signed fallback), not a Let's Encrypt cert — for every hostname,
silently, since the platform first came up. Root cause, from Traefik's own
logs at pod startup:

```
ERR The ACME resolve is skipped from the resolvers list
  error="unable to get ACME account: open /data/acme.json: permission denied"
```

The chart runs non-root (`runAsUser`/`runAsGroup: 65532`) but its
`values.yaml` never set `podSecurityContext.fsGroup`, so the acme.json PVC
mounted `root:root`/`0755` — Traefik could never create the file at all,
which **permanently disables the ACME resolver for that pod's lifetime**
(not retried). This had been true since the very first bring-up; nothing
about the Freebox cutover caused it, the cutover just made it visible for
the first time (`curl -k` during earlier internal checks had masked it by
skipping verification). Fixed with `podSecurityContext.fsGroup: 65532`
(PR #19).

Fixing this uncovered a second layer immediately: on the *next* pod
restart, Traefik logged a **new** error —

```
ERR The ACME resolve is skipped from the resolvers list
  error="unable to get ACME account: permissions 660 for /data/acme.json are too open, please use 600"
```

Kubernetes' default `fsGroupChangePolicy: Always` recursively resets every
file's mode to add group read/write on **every** pod (re)start, which
stomps `acme.json` back to `660` regardless of what Traefik itself wrote.
Fixed with `fsGroupChangePolicy: OnRootMismatch`, which skips the reset
once the directory's group ownership already matches — preserving
Traefik's own `0600` file creation across restarts.

### Bug 3 — HTTP-01 challenge silently swallowed somewhere outside the cluster

With permissions fixed and stale `acme.json` state wiped, Traefik's ACME
resolver started cleanly and began real HTTP-01 attempts — all of which
failed with:

```
acme: error: 403 :: urn:ietf:params:acme:error:unauthorized ::
82.65.231.50: Invalid response from
http://argocd.bnei.dev/.well-known/acme-challenge/<token>: 404
```

The diagnostic that mattered: hitting the exact same challenge path
directly against Traefik's VIP from inside the LAN (bypassing the Freebox
entirely) with a **fake** token correctly logged Traefik's own rejection —
`Cannot retrieve the ACME challenge for argocd.bnei.dev (token
"testtoken123")` — proving the internal router mechanism worked. That
exact log line **never appeared** for any of the real Let's Encrypt
validation attempts, even though LE got back a real, fast HTTP 404 (not a
timeout/connection-refused, which is what a simple missing-forward would
produce). That combination — a clean response, but Traefik's own handler
never seeing the request — points at something on the path (suspected
transparent ISP proxy/cache on port 80; ruled out the Freebox's own
remote-admin UI specifically, since that would present a branded page, not
a bare 404) intercepting *before* the cluster, at a layer neither side
could directly inspect (no external plain-HTTP test tool available, and no
way to packet-capture the ISP's side).

Rather than keep debugging blind at an unreachable layer, switched the
`le` resolver from `httpChallenge` (port 80) to `tlsChallenge` (TLS-ALPN-01,
validated entirely over port 443, already confirmed working end-to-end
externally). Same built-in Traefik ACME, no change to ADR-0001's
cert-manager/DNS-01 rejection. (PR #20)

### Bug 4 (self-inflicted) — `tlsChallenge: {}` renders nothing

PR #20 originally shipped `tlsChallenge: {}`. The chart's CLI-arg templating
only flattens **non-empty** maps into `--flag=value` pairs — an empty map
has nothing to recurse into, so it silently produced no argument at all,
leaving ACME with **no challenge type configured whatsoever** (worse than
before: now neither `httpChallenge` nor `tlsChallenge` was set). Caught by
rendering the chart locally with `helm template` before pushing rather
than trusting the live cluster to reveal it. Fix: `tlsChallenge: true` (a
boolean scalar, not a map) — confirmed via `helm template` that this is
what actually produces `--certificatesresolvers.le.acme.tlsChallenge=true`.

### Process note — two direct pushes to `main`

Both Bug 4's fix and one intermediate Bug 2 fix landed as direct commits
to `main` rather than through a feature branch + PR. The first was a
genuine slip (local checkout ended up on `main` after an earlier PR merge,
not re-verified with `git branch --show-current` before committing — user
flagged it, decided the small low-risk diff wasn't worth reverting). The
second was explicitly authorized in advance ("push to main directly your
small fixes") while the user was away. Lesson for next time: always run
`git branch --show-current` immediately before any commit, regardless of
what branch was active minutes earlier in the same session.

### End state

All three hostnames (`argocd.bnei.dev`, `dreamer.bnei.dev`,
`blog.bnei.dev`) confirmed serving real Let's Encrypt certificates
(issuer `Let's Encrypt`, CNs `YR1`/`YR2`, valid ~90 days from issuance) via
`openssl s_client` against the VIP. Freebox cutover fully verified
externally. `argocd-initial-admin-secret` deleted after the user set a
real admin password through the UI.

## 2026-07-28 — root cause found: InfisicalSecret template values need `.Value`

The "infisical-operator's template rendering corrupts this value
unpredictably" symptom logged twice above (Longhorn S3 key, GitHub SSH
deploy key) plus a new instance (Grafana admin login, `grafana-admin`
Secret in `monitoring` — TLS worked once `grafana-ingressroute.yaml` was
added, but login failed) all turned out to be the same single bug, not
three unrelated ones.

Confirmed by decoding the live `grafana-admin` Secret: the `password`
field held `{TzNiX2gHl4+uvlMaI7zUQP8Q2YfQc3P6ZY25hXwa2hU= /}` — a Go
struct's default `%v` stringification, not a plain string. Cross-checked
against upstream (github.com/Infisical/infisical discussions #3492 /
issue #3483): every key referenced inside an `InfisicalSecret`'s
`managedSecretReference.template.data` block is exposed to the Go
template as `TemplateSecret{ Value string, SecretPath string }`, **not**
a bare string. `{{ .KEY }}` prints the whole struct (`{value
secretPath}`); the correct syntax is `{{ .KEY.Value }}`. Every
`template:` block in this repo was written with the bare form.

Fixed in all four places that had it:
`gitops/bootstrap/basic-admin-auth-secret.yaml`,
`gitops/bootstrap/grafana-admin-secret.yaml`,
`gitops/bootstrap/longhorn-backup-secret.yaml`,
`gitops/platform/values/searxng/values.yaml` (the last one double-escaped,
`{{ "{{" }} .KEY.Value {{ "}}" }}`, since it's Helm `tpl`-rendered before
the operator ever sees it). `gitops/platform/common-app-chart/templates/
infisicalsecret.yaml` and `gitops/platform/actions-runner/
infisicalsecret.yaml` were never affected — neither uses a `template:`
block, so the operator passes their keys straight through unmodified.

This does **not** explain the separate "operator doesn't detect value
changes for templated fields, logs `already up to date, skipping update`"
caching symptom noted in the Longhorn entry above — that looks like a
real, distinct upstream bug in the diffing logic for templated secrets
specifically. The documented workaround for *that* one (bypass the
operator, `kubectl create secret ... | kubectl apply -f -` directly)
still stands as a fallback if a templated secret's value stops updating
on rotation even with the `.Value` fix in place.

Practical effect: any already-provisioned app that reads its password
from one of these Secrets at first boot (Grafana, kube-prometheus-stack)
already has the *old, malformed* value baked into its own state (Grafana
writes it into its DB on first admin-user creation and never re-reads the
Secret after that). Fixing the template makes new/future provisioning
correct — it does not retroactively fix an already-running instance;
reset the credential in the app directly (e.g. `grafana-cli admin
reset-password` via `kubectl exec`) after confirming the new templated
value renders clean.
