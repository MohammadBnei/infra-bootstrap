# ukubi-cluster bootstrap test — manual steps & findings

## 2026-07-12 — terraform module smoke test

Scoped apply of template + `k8s-cp-01`/`k8s-worker-01` on `.165`. Bugs found & fixed:

- `template.tf` downloaded the cloud image to `local-lvm` (LVM-thin, no `import`
  content type). Fixed: added `var.template_download_storage_id` (default
  `"local"`), separate from `template_storage_id` (VM disk storage).
- IP collision: `.201` was already claimed by the `garage-storage` LXC's
  static IP — the new VM lost ARP resolution to it. Not caught by the VMID
  pre-flight check (only covers VMID reuse, not IP reuse). Resolved by
  removing stray LXCs.
- `agent { enabled = true }` made every fresh clone wait up to 15m for
  `qemu-guest-agent` (not preinstalled on stock Ubuntu 24.04). Fixed via
  `cloud-init.tf`'s `qemu_guest_agent_vendor_data` (installs+enables the
  agent, layered on top of the auto-generated cloud-init via
  `vendor_data_file_id`). Requires the target storage to have `snippets`
  content-type enabled by hand once (`pvesm set local --content ...,snippets`).
- Gotcha: `terraform plan`/`apply` refreshes *every* resource in state, not
  just `-target`ed ones — a stuck guest agent elsewhere re-triggers the 15m
  wait regardless. Use `-refresh=false` for iterative same-session work only,
  not a substitute for a real plan.

## One-time machine/tooling setup (still-relevant reference)

- New VMs need `ssh-keyscan -H <ip> >> ~/.ssh/known_hosts` before
  non-interactive ansible works.
- kubespray v2.31.0 needs Python ≥3.11 + ansible-core strictly between
  2.18.0–2.19.0 — use `kubespray-venv` (Python 3.12), never the Homebrew
  ansible on PATH.
- Helm isn't on the VM images — install via the official script before
  `helm install argocd`.
- `infra_bootstrap_id_ed25519` is a read-only Deploy Key scoped to
  `infra-bootstrap` only — do not also grant it access to `k8s-cluster`.

## Repo bugs fixed (2026-07-12, merged)

- `kube_version` had a leftover `v` prefix, breaking kubespray v2.31.0's
  version comparison (`kubelet_checksums` keys are unprefixed).
- ArgoCD `platform.applicationset.yaml`'s Infisical `chartRevision` pinned a
  nonexistent version (`0.7.8` → `0.4.2`).
- `argocd-application.yaml`: submodule fetching disabled
  (`ARGOCD_GIT_MODULES_ENABLED=false`) since `k8s-cluster` is a private
  submodule ArgoCD doesn't need and has no credentials for — ArgoCD does not
  propagate a repo's credentials to its submodules. `submoduleEnabled: false`
  on the Repository Secret does **not** work (silently ignored); only the
  repo-server env var does.
- Initial `helm install argocd` must pin the same chart version as
  `argocd-application.yaml` — unpinned grabs the newest chart, which crash
  looped against the cached image on this test.

**Architectural gotcha (still true)**: `gitops/bootstrap/*.yaml` is NOT
self-syncing — no App-of-Apps watches it, by design. Any edit under
`gitops/bootstrap/` needs a manual `kubectl apply -f` on the live cluster even
after commit+push. Only `gitops/platform/values/*` (a separate `ref: values`
git source) auto-syncs.

**Gateway API → IngressRoute fallout**: Traefik's chart bundles Gateway API
CRDs; kubespray's newer Gateway API CRDs ship a `ValidatingAdmissionPolicy`
that rejects any CRD create/update below v1.5.0 in that group.
`resource.exclusions` doesn't help (the CRD object itself is rejected, not
the custom resources). Fix is `helm.skipCrds: true`, but that's a bool the
ApplicationSet CRD validates strictly, so a per-element Go-template
conditional in the shared list-generator gets rejected before it's ever
rendered — Traefik had to become its own standalone `Application`
(`gitops/bootstrap/traefik-application.yaml`) with a literal
`skipCrds: true`. Traefik's own CRDs (`traefik.io_*`, `hub.traefik.io_*`)
were installed once out-of-band via `helm pull` + `kubectl apply` (excluding
the Gateway bundle file).

**No StorageClass existed** — added `containeroo/local-path-provisioner` as a
wave-0 platform app (hostPath-backed stopgap, `defaultClass: true`),
swappable later since no app sets `storageClassName` explicitly. (NFS shared
storage is the current stage-2 work replacing this.)

## 2026-07-13 — full smoke test: terraform → kubespray → ArgoCD → apps

- **Registry apps didn't exist as real GitHub repos** (`n8n`/`openweb-ui`/
  `searxng`/`whodb`/`api`/`ukubi-ai` were aspirational entries). Real
  deployments lived in the `k8s-cluster` submodule's kustomize manifests;
  only `n8n`, `openweb-ui`+pipelines, `searxng`, `pgweb` (archived) were
  complete.
- **Decision**: `searxng`/`pgweb` are platform apps (public images, no
  app-specific code) — added `platform-common-apps.applicationset.yaml`
  (chart+values both live in `infra-bootstrap`, no external repo).
  `registry.yaml` stays reserved for apps needing their own repo.
- **`common-app-chart` additions**: `extraVolumes`/`extraVolumeMounts` (raw
  passthrough), `extraManifests` (raw YAML strings, `tpl`'d), and
  `ingress.middlewares` (Traefik Middleware refs) — same idiom as Bitnami's
  `extraDeploy`. Needed a double-templating escape
  (`{{ "{{" }} .KEY {{ "}}" }}`) so Helm's `tpl` doesn't eat
  `InfisicalSecret`'s own Go-template syntax.
- **Garage installer hung** on an interactive whiptail menu over Terraform's
  non-interactive SSH provisioner — deferred, later replaced entirely (see
  2026-07-26). Gotcha: a hung/never-completed `null_resource` still shows as
  applied in state — `terraform state rm` was needed to keep state honest.
- **`InfisicalSecret.spec.hostAPI` bug**: pointed at
  `infisical.infisical.svc.cluster.local`, which never existed — the
  Infisical Helm release name (`platform-infisical`) makes the real backend
  Service `platform-infisical-backend`. Fixed in all 5 `InfisicalSecret`s
  (PR #6).
- **MetalLB pool collision**: pool `.230-250` overlapped `.232` (Pigsty's HA
  floating VIP). Shrunk pool to `.233-250`, moved Traefik's pin to `.233`.
  Live `IPAddressPool` patch alone isn't enough — `metallb-system/controller`
  must be restarted or it keeps re-offering the stale cached pool.
- **2-node topology confirmed**: no separate `k8s-worker-gpu` VM — GPU
  passthrough lives directly on `k8s-worker-01`.

### Root cause (round 2, same week): DNS search-domain poisoning

Every pod's `resolv.conf` carried a bare `dev` search domain (a real public
TLD) alongside the k8s ones — with `ndots:5`, in-cluster FQDNs resolved
against `....cluster.local.dev` (a live Cloudflare-fronted answer) before the
absolute name was tried, silently breaking every ClusterIP-routed Service
call cluster-wide (looked like a routing/masquerade bug at first, wasn't).
Traced to `.165`'s PVE node identity: hostname `bnei`, domain `dev` — the
original Proxmox install FQDN prompt (`bnei.dev` entered as one field) gets
mechanically split into hostname/domain at the first dot, and PVE bakes its
node-level domain into every guest's generated cloud-init DNS search domain.

**Fix**: `bpg/proxmox` provider's `initialization.dns.domain = "localdomain"`
per-VM in `terraform/k8s-vms.tf` (netplan `use-domains: false` did **not**
work — PVE's generated netplan is static, not DHCP-negotiated). User also
fixed the PVE-level default (`pvesh set /nodes/bnei/dns --search bnei.dev`,
safe since they own that zone); the Terraform override is kept anyway as
defense in depth.

## 2026-07-14 — GPU passthrough fixed (Secure Boot was a red herring)

Real cause: an earlier attempt had installed the proprietary NVIDIA driver +
`pve-nvidia-vgpu-helper` (vGPU/mediated-device tooling, rejected per
ADR-0011) directly **on the Proxmox host** — wrong approach entirely, since
this repo's design is whole-GPU PCI passthrough with the driver living in
the guest. Fix:

1. Purged the host-side NVIDIA stack + vgpu-helper.
2. Configured `vfio-pci` to claim the GPU's 4 PCI IDs, blacklisted
   `nouveau`, forced early module load via `/etc/modules-load.d`.
3. **Real root cause**: AMD-Vi (IOMMU) was disabled in BIOS —
   `/sys/kernel/iommu_groups/` was empty despite a misleading "IOMMU:
   Default domain type: Translated" dmesg line. Needed physical console
   access (no IPMI) to enable under AMD CBS → NBIO Common Options.
4. Even with IOMMU on, 2 of the 4 GPU functions got grabbed by
   `xhci_hcd`/`i2c_nvidia_gpu` before `vfio-pci` on boot — fixed with a
   boot-time systemd oneshot (`vfio-pci-bind-gpu.service`) forcing
   `driver_override` on all 4.
5. Created the PCI Resource Mapping by hand
   (`pvesh create /cluster/mapping/pci --id gpu ...` — root-only, out of
   Terraform's API-token reach) and re-enabled `hostpci0` in `k8s-vms.tf`.

End state: host fully passthrough-ready, mapping exists, Terraform
re-enabled, but not yet attached (VM was torn down between sessions). Secure
Boot was never disabled/needed. Passthrough is exclusive — Proxmox refuses a
second VM against an already-claimed PCI mapping (deliberate, not
vGPU-style sharing, per ADR-0011).

## 2026-07-26 — Garage: replaced community-script installer, full smoke test

`terraform/garage.tf`'s community-scripts.org installer (hung on the
whiptail menu, see above) was replaced with a plain `proxmox_download_file` +
`proxmox_virtual_environment_container`, no script. New
`ansible/playbooks/garage-configure.yml` handles install/config/systemd/
cluster-layout/buckets/keys and writes secrets to Infisical. Run for real
against `.165` twice (idempotency confirmed — only the 3 Infisical upserts
showed as changed on the second run).

Bugs found only by actually running it:

1. Garage's config path is `/etc/garage.toml`, not `/etc/garage/garage.toml`.
2. `garage node id` output includes `@addr:port` — `layout assign` wants the
   bare pubkey only.
3. `regex_search` + a Jinja ternary evaluates both branches
   (`'NoneType' object has no attribute 'group'`) — split into two
   `when`-gated `set_fact` tasks instead. Separately, `regex_search` with a
   capture group returns a list — needs `| first`.
4. Layout-apply idempotency must always re-read `garage layout show`'s
   `apply --version N` hint, not just whether `assign` changed anything
   *this run* (breaks on resuming an interrupted run).
5. `garage bucket allow` takes the bucket name positionally, not `--bucket`.

**Incident**: an unscoped `infisical secrets --projectId=... --env=dev` (no
`--plain`, no key name) printed every real secret value into the transcript,
including `SSH_SERVER1_KEY`'s plaintext private key. **`SSH_SERVER1_KEY`
needs rotation** (new keypair + `authorized_keys` + Infisical update) — check
whether this has been done. Lesson: always scope Infisical CLI reads to one
named key with `--plain`, never an unscoped list.

## 2026-07-27 — editable-blog onboarding

First real per-app repo through the multi-source ApplicationSet template.
Chain of issues, in order:

- SSH deploy key path was a dead end: GitHub deploy keys are one-key-per-repo,
  so a shared credential across `MohammadBnei/*` repos needs a machine-user
  *account* key, not a deploy key. Even after creating `argocd-ukubi-bot` and
  generating a fresh key, the operator-materialized K8s Secret kept failing
  `ssh-keygen -y` — the same infisical-operator template-rendering
  corruption bug hit for Longhorn's S3 key (root-caused 2026-07-28, below).
  GitHub's collaborator-permission API (`gh api -X PUT .../collaborators/...
  -f permission=pull`) also silently kept the invite at Write instead of Read
  (`204` but no effective change) — accepted as-is, Write is a superset of
  what ArgoCD needs.
- **Decision**: switched to HTTPS + a GitHub PAT (from the user's own
  account) instead of SSH entirely, sidestepping both the one-key-per-repo
  limit and the operator corruption bug for this credential.
- **Real bug — no CPU passthrough**: `terraform/k8s-vms.tf`'s `cpu` block
  never set `type`, so both K8s VMs ran on QEMU's baseline `qemu64` model (no
  AVX2). editable-blog's Bun-based image hard-requires AVX2, crashed with
  SIGILL. Fixed with `cpu { type = "host" }` (in-place update, no VM
  recreate, but needs a reboot to take effect). **Caveat for Stage 2**:
  `host` CPU type isn't live-migration-safe across different physical
  CPUs — once `.200`/`.161` join, may need a named baseline microarchitecture
  common to all three hosts instead.
- **Sync stuck `Unknown` despite a working PAT**: root cause was
  self-inflicted — `infisical secrets get --plain | kubectl create secret
  --from-file=password=/dev/stdin` captures the trailing newline `--plain`
  always emits, corrupting the secret byte-for-byte. Every manual
  verification during the investigation used `$(cat ...)`, which silently
  strips trailing newlines, so manual checks looked fine while ArgoCD's
  actual raw-bytes read was broken. **Fix**: `tr -d '\n'` before piping into
  `--from-file`; `register-repos.yml` also got a defensive `| trim` Jinja
  filter. **General lesson**: when a client fails against a secret that
  "looks right" in manual checks, re-verify using the exact same raw-bytes
  access path the failing consumer uses.

End state: `editable-blog` `Synced`/`Healthy`, HTTPS+PAT path confirmed fully
working.

## 2026-07-28 — Freebox cutover: real Let's Encrypt certs, three chained bugs

Freebox port-forward repointed from legacy HAProxy to the Traefik VIP
(`.233`). The first true external check surfaced three stacked bugs, each
hidden until the previous one was fixed:

1. **Wrong port**: the Freebox rule kept the legacy HAProxy's ports
   (`8000`/`8443`) instead of `80`/`443` — needed as two separate explicit
   rules.
2. **No working cert, ever**: Traefik had been serving its self-signed
   fallback cert for every hostname since first bring-up (`curl -k` during
   internal testing had masked it). Root cause: the chart runs non-root but
   never set `podSecurityContext.fsGroup`, so the `acme.json` PVC mounted
   `root:root` — ACME permanently disabled per pod lifetime. Fixed with
   `fsGroup: 65532` (PR #19). That uncovered a second layer: k8s' default
   `fsGroupChangePolicy: Always` resets file mode on every pod restart,
   stomping Traefik's own `0600` back to `660` — fixed with
   `fsGroupChangePolicy: OnRootMismatch`.
3. **HTTP-01 challenge silently swallowed outside the cluster**: LE got a
   fast real 404, but Traefik's own challenge-handler log line never
   appeared for genuine attempts (it did for a manually-faked token from
   inside the LAN) — pointing at something intercepting port 80 upstream of
   the cluster (suspected transparent ISP proxy; couldn't inspect further
   with tools on hand). Switched the `le` resolver from `httpChallenge` to
   `tlsChallenge` (TLS-ALPN-01 over 443, already confirmed working) — no
   change to ADR-0001's cert-manager rejection.
4. **Self-inflicted**: the first fix shipped `tlsChallenge: {}` — the
   chart's templating only flattens non-empty maps into CLI args, so an
   empty map produced no ACME challenge config at all. Fix:
   `tlsChallenge: true` (boolean, not a map) — confirmed via `helm template`
   before pushing.

Also: two direct pushes to `main` this session (one accidental — check
`git branch --show-current` before every commit regardless of what was
active minutes earlier; one pre-authorized by the user while away).

End state: `argocd.bnei.dev`/`dreamer.bnei.dev`/`blog.bnei.dev` all serving
real Let's Encrypt certs, confirmed externally.

## 2026-07-28 — root cause: InfisicalSecret templates need `.Value`

The recurring "operator corrupts templated secret values unpredictably"
symptom (Longhorn S3 key, GitHub SSH key, and now Grafana's admin password
rendering as `{TzNiX2gHl4+uvlMaI7zUQP8Q2YfQc3P6ZY25hXwa2hU= /}`) is one bug,
not three: every key inside an `InfisicalSecret`'s
`managedSecretReference.template.data` block is exposed to the Go template
as a struct (`{ Value string, SecretPath string }`), not a bare string —
`{{ .KEY }}` prints the whole struct; the correct form is `{{ .KEY.Value }}`.
Confirmed against upstream Infisical/infisical#3492/#3483.

**Fixed** in the 4 places that had the bare form: `basic-admin-auth-secret.yaml`,
`grafana-admin-secret.yaml`, `longhorn-backup-secret.yaml`,
`searxng/values.yaml` (double-escaped, Helm-`tpl`'d first).
`common-app-chart`'s and `actions-runner`'s own `infisicalsecret.yaml` were
never affected (no `template:` block).

This does **not** explain the separate "operator doesn't detect value
changes for templated fields" caching bug (logs `already up to date,
skipping update`) — that's a distinct upstream diffing bug. Workaround still
stands if hit again: bypass the operator, `kubectl create secret ... |
kubectl apply -f -` directly.

**Caveat**: any app that already read a malformed value at first boot
(Grafana, kube-prometheus-stack) has it baked into its own state — the
template fix doesn't retroactively fix a running instance; reset the
credential in-app (e.g. `grafana-cli admin reset-password`) after confirming
the new template renders clean.

## 2026-07-28 — Stage 2 Phase C: NFS shared storage + first cross-host K8s worker

`server1`/`ex-laptop` finished PVE reinstall + corosync join earlier the same
day; this session did the next step — a K8s worker on `server1`
(`k8s-worker-02`) plus the shared PVE storage (ADR-0026) needed to clone
onto it cleanly. Full plan/design is in ADR-0026; this is what actually broke
during real `terraform plan`/`apply` runs against live infra, none of it
anticipated by the design alone.

- **Cross-node clone 404, root-caused via provider source, not guesswork**:
  `k8s-vms.tf`'s `clone` block never set a source `node_name`. Cluster-unique
  VMIDs make it tempting to assume that doesn't matter — it does. Pulled
  `bpg/terraform-provider-proxmox`'s actual `vmCreateClone`
  (`proxmoxtf/resource/vm/vm.go`): with `clone.node_name` unset, the provider
  calls `CloneVM` against the *target* node's API endpoint
  (`/nodes/{node}/qemu/{vmid}/clone`, node-scoped, not ID-scoped) — a
  `server1`-targeted clone 404s because VM 9001 only physically exists on
  `.165`. Setting `clone.node_name` lets the provider branch correctly: a
  direct clone if the source's disks are on shared storage, or an automatic
  clone-then-migrate (`--with-local-disks`) if not.
- **LXC rejected for the NFS server, before it was ever built**: `nfs-kernel-server`
  needs kernel-level `nfsd`, not reliably namespaced inside a container.
  Checked `terraform providers schema -json` for
  `proxmox_virtual_environment_container` — its `features` block only covers
  what a container may *mount as a client* (`fuse`, `mount`, `nesting`), no
  AppArmor/privilege escape hatch to make an in-container `nfsd` reliable.
  Built `nfs-storage` as a lightweight VM instead (from the cloud image
  directly, not cloned — cloning from a template not yet on shared storage to
  bootstrap the storage meant to fix that would be circular).
- **Near-miss: `clone.node_name` and `vendor_data_file_id` are both
  `ForceNew`.** Setting either unconditionally on the shared `k8s_node`
  resource (used by every `k8s_nodes` entry via `for_each`) marked the
  already-**live** `k8s-cp-01`/`k8s-worker-01` "must be replaced" in a real
  `terraform plan` — i.e. destroy-and-recreate the running control plane.
  Caught before any apply by actually reading the plan output line by line,
  not just the `Plan: N to add/change/destroy` summary. Fixed by making both
  conditional on the entry actually being cross-host (`null` == omitted,
  byte-for-byte unchanged for same-host entries); the vendor-data snippet
  additionally needed a second, separate resource
  (`k8s_vm_vendor_data_shared`) rather than repointing the original, for the
  same ForceNew reason.
- **`nfs-storage` boot hang**: `agent.enabled = true` with no way to install
  `qemu-guest-agent` before first boot (this VM isn't built via the shared
  k8s vendor-data snippet) made `apply` hang waiting for a handshake that
  never arrives — confirmed by actually hitting it, not foreseen in the
  design. Fixed with a small dedicated cloud-init snippet (guest-agent
  install only) applied at create time.
- **Template disk "move" flatly rejected**: `Error: Cannot move
  local-lvm:base-9001-disk-1 to datastore shared-templates ... it is not
  owned by this VM!`. Once a VM is flagged `template = true`, Proxmox renames
  its disk to a `base-<vmid>-disk-N` volume for (potential) linked-clone use,
  and `move_disk` refuses to relocate that kind of volume regardless of who's
  asking — an in-place `datastore_id` change was never going to work for a
  template's disk specifically (works fine for normal VM disks, e.g. the
  later NFS→local-lvm move for `k8s-worker-02` itself). Fixed with
  `terraform apply -replace=... -target=...` instead of a config edit — since
  nothing had ever cloned from the old copy yet (only full clones are used
  here, no linked-clone dependency), destroying and rebuilding the template
  fresh directly on `shared-templates` was safe.
- **`rtk` hook silently mangled a `terraform plan`**: one `terraform plan`
  run through this session's `rtk`-wrapped shell came back showing only an
  unrelated `local_file` diff — no error, just quietly missing every
  Proxmox-backed resource that should have appeared. Re-running the exact
  same command via `rtk proxy <cmd>` (documented escape hatch for "raw
  command, no filtering") produced the real, complete plan. Lesson: don't
  trust a suspiciously-empty/small plan on this machine — re-run through
  `rtk proxy` before concluding infra state is actually clean.
- **`-target` apply quirk (cosmetic, not a bug)**: a `-target`ed apply only
  recomputes outputs that fall within the targeted resource's dependency
  graph — `k8s_node_ips` (a pure `var.k8s_nodes` expression, no resource
  refs) kept printing a stale 2-entry map after `k8s-worker-02` was targeted
  elsewhere. A full untargeted `terraform plan` confirmed the real value was
  correct all along; the printed "Outputs:" after a targeted apply just
  isn't trustworthy for anything outside that target's own graph.
- **`local_file.kubespray_inventory` needs its own apply**: it's a sibling
  resource to the VM (both depend on `var.k8s_nodes`, neither depends on the
  other), so `-target`ing just the new VM does not regenerate
  `inventory/ukubi/hosts.yaml`. Needed a separate
  `apply -target=local_file.kubespray_inventory` before `kubespray`'s
  `scale.yml` could see the new node at all — easy to miss since the VM
  itself comes up fine either way.
- **Infisical CLI**: this instance is self-hosted
  (`https://infisical.bnei.dev`) — `infisical login` needs `--domain=...`
  explicitly, the flag defaults to app.infisical.com's cloud endpoint
  otherwise. The previously-documented `source ~/.hermes/cache/inf-env.sh`
  shortcut was stale this session; a fresh `infisical login --domain=...`
  plus `infisical run --projectId=... --env=dev -- ...` worked once
  re-authenticated.
- **What NFS shared storage actually bought (worth being honest about)**:
  not "free" cross-host provisioning — a full clone still copies bytes
  either way. What it removes is the *cross-host network* copy: without
  shared storage, a cross-node clone means clone-onto-`.165` (copy #1) then
  `qm migrate --with-local-disks` over the LAN to the target (copy #2, plus a
  transient VM briefly existing on `.165`). With shared storage, the clone
  writes once into NFS (reachable identically from any node, so Proxmox just
  repoints the VM's config to the target node — no network copy for that
  step), and since `k8s-worker-02`'s own `datastore_id` is `local-lvm` (fast
  local disk for a real workload VM, not NFS — ADR-0026's explicit scope
  boundary), a second move happens from NFS to local-lvm, but *within*
  `server1` itself, not across hosts.

End state: `k8s-worker-02` cloned directly onto `server1` via
`shared-templates`, joined via `kubespray scale.yml`
(`--limit`/`--tags` not needed — greenfield-safe since `scale.yml` only adds,
never resets, existing members), `Ready` in the live cluster within ~70s,
Cilium/kube-proxy/Longhorn manager+CSI already scheduled onto it via
DaemonSets, all 18 ArgoCD Applications stayed `Synced`/`Healthy` throughout —
no GitOps-side changes needed for a node-level join.

## 2026-07-29 — Loki + Alloy + Grafana log alerting (PRs #54–#57)

First deploy of centralized logging. Two rounds of live-only bugs, neither
catchable from the PR review or from `yq`/YAML-lint alone — both
root-caused and fixed by actually reproducing them (against the live
cluster and, for the Grafana one, a local Docker container) rather than
guessing from documentation. See ADR-0027 for the design rationale (Loki
over ClickHouse, Alloy over Promtail).

**Round 1 (PR #55), found via ArgoCD `ComparisonError`/`Unknown` sync
status right after PR #54 merged:**

- `platform-loki` never deployed. Loki's own `validate.yaml` rejects a
  nonzero `singleBinary.replicas` alongside any nonzero SimpleScalable-mode
  replica — `write`/`read`/`backend` all default to `3`, not `0`. Fixed by
  zeroing all three explicitly.
- `lokiCanary` was nested under `monitoring:` in the values file — wrong
  key location, silent no-op (same failure class as the pre-existing
  Infisical `values.yaml` incident this skill already documented), the
  canary DaemonSet deployed anyway despite looking disabled.
- `platform-grafana` stayed on its pre-PR config, stuck `Unknown` sync (no
  outage, just a blocked rollout) — the chart's `grafana.configData`
  template runs the whole `alerting:` values block through Helm's `tpl`,
  and the alert rule's `{{ $labels.namespace }}` annotation (Grafana's own
  alert-time templating) collided with Helm's chart-time templating.
  Fixed with the `{{`{{`}}...{{`}}`}}` escape idiom so `tpl` emits it as
  literal text.
- All three fixes verified via `helm template` against the real pinned
  chart versions before pushing (`helm pull --untar` + render), not just
  re-reading the error message and guessing.

**Round 2 (PR #56), found immediately after Round 1 merged and rolled
out:**

- `platform-grafana` went into `CrashLoopBackOff` — a real outage this
  time, not a blocked rollout. `Failed to provision alerting ... failed to
  validate integration "discord" ... token must be specified when using
  the Slack chat API`. This is Grafana's own runtime schema validation,
  not a Helm templating error — `helm template` rendered the file cleanly
  and it still crashed on boot.
- Reproduced against a real local `docker run grafana/grafana:11.4.0`
  before touching the live cluster again (having already broken it once
  on an unverified assumption). Tested `secureSettings.url` with
  `$__file{}`, with a bare env var, and with a plain literal string — all
  three failed identically, proving it was a field-placement bug, not an
  interpolation one. `url` under plain `settings` fixed it.
- Verified the fix two ways before shipping: confirmed Grafana still
  redacts the value in `GET /api/v1/provisioning/contact-points` despite
  the placement (no plaintext leak via the API), and confirmed `$__file{}`
  interpolation actually resolves under `settings` — provisioned a real
  always-firing test rule, pointed the secret file at a local network
  listener (a second Docker container running `nc`), and captured the
  actual outbound POST.

**Follow-up (PR #57), App Logs dashboard:**

- Confirmed live that Loki's `detected_level` (auto-computed per log
  line) filters correctly via `| detected_level=~"..."` but is **not**
  in the label index — `GET /loki/api/v1/label/detected_level/values`
  returns empty. Used a static/custom dashboard variable
  (`critical,error,warn,info,debug,trace,unknown`) instead of trying to
  discover values dynamically.
- Confirmed this matters in practice: tested `| json` and `| logfmt`
  against real logs from all 4 running user apps before designing the
  dashboard around `detected_level` specifically — none of them emitted
  JSON at the time (`vos-monolith`'s Gin access logs, `vos-monolith-dev`'s
  zerolog console output with embedded ANSI codes that broke even
  `| logfmt` field extraction, `editable-blog`'s custom HTTP logger,
  `dream-analyst`'s plain Node output). A JSON-only level filter would
  have silently excluded every app until each one's logging was updated.
- Dashboard JSON verified by actually provisioning it into a real local
  Grafana container and fetching it back via the dashboard API to confirm
  every panel and template variable survived intact, not just
  JSON-syntax-checked.

**Standing gap, not yet fixed**: `.github/workflows/lint.yml`'s `gitops`
job only `helm template`s the local `common-app-chart` — it never renders
the third-party charts (`loki`, `alloy`, `grafana`, `prometheus`, ...)
that `platform.applicationset.yaml` actually deploys. That CI step would
have caught the Round 1 bugs automatically, before merge. Not the Round 2
bug (app-level runtime validation, not a Helm templating error) — that
class needs an actual `docker run` against the rendered config, a bigger
CI lift, probably only worth it for charts with non-trivial runtime
config (secrets, notification channels).
