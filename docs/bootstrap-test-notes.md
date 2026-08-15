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

## 2026-07-30 — 3-CP/etcd HA rollout, kube-vip, Pi-hole bootstrap

Same session, four separate real-run bugs, none of them foreseeable from
the design alone (ADR-0016/0017's HA plan, `ansible/README.md`'s Pi-hole
section). Also resized `k8s-worker-02` (4→6 vCPU, 8→16GB — server1 had
most of its RAM idle) and added `k8s-cp-02`/`k8s-cp-03` for the 3-CP/etcd
topology (2 members on the stable hosts, `.165` a deliberate minority
voter since it's the host that gets rebooted for gaming).

- **`kubespray-venv` didn't actually exist**, despite being documented
  above as one-time-done reference setup. First `cluster.yml` attempt
  used the Homebrew `ansible-playbook` on `PATH` (ansible-core 2.21.1) and
  failed immediately at kubespray's own version-assertion task ("must be
  between 2.18.0 and 2.19.0"). Recreated fresh:
  `python3.12 -m venv kubespray-venv && pip install -r kubespray/requirements.txt`
  (pins `ansible==11.13.0` → ansible-core 2.18.18). Lesson: this doc
  documented the *requirement*, not a durable artifact — don't assume a
  past session's local tooling setup survived, verify (`ansible-playbook
  --version`) before trusting it.
- **`local_file.kubespray_inventory` needs its own apply — recurrence of
  the 2026-07-28 gotcha, hit again anyway.** The `-target`-scoped apply
  for `k8s-cp-02`/`k8s-cp-03` (deliberately narrow, to avoid touching the
  already-live `k8s-cp-01`/`k8s-worker-01`/`k8s-worker-02`) created the
  VMs but left `inventory/ukubi/hosts.yaml` stale — caught by a
  `terraform plan -target=local_file.kubespray_inventory` showing a
  pending diff before `cluster.yml` ran against a `kube_control_plane`
  group that didn't yet include the new nodes. Same fix as before
  (`apply -target=local_file.kubespray_inventory`), but worth noting this
  is a *repeatable* footgun of the `-target`-for-safety pattern, not a
  one-off — check this every time a `k8s_nodes` entry is added via
  `-target`.
- **CoreDNS/nodelocaldns forward `policy` defaults to random, not
  sequential** — added `upstream_dns_servers: [192.168.1.55, 1.1.1.1]`
  (Pi-hole first, public fallback) so in-cluster pods could resolve
  `bnei.lan` names (the Pigsty VIP, etc). First live test
  (`kubectl run ... nslookup postgres.bnei.lan`) came back `NXDOMAIN` —
  looked like a config or propagation-delay problem at first (tried a
  `kubectl rollout restart daemonset nodelocaldns` on that theory, no
  change). Root cause, found by testing the same query 5x in a row and
  seeing it flip between success and `NXDOMAIN`: CoreDNS's `forward`
  plugin's default policy picks an upstream **at random** per query, and
  `1.1.1.1` gives a perfectly valid (if unhelpful) `NXDOMAIN` for a TLD
  it's never heard of — a real, healthy answer, not a failure, so no
  failover ever triggers. Fixed with kubespray's
  `dns_upstream_forward_extra_opts: {policy: sequential}` (applies to
  both CoreDNS and nodelocaldns, confirmed in
  `roles/kubernetes-apps/ansible/defaults/main.yml`). Verified with 5
  repeated in-cluster lookups post-fix, all correct, plus confirmed
  public-domain resolution (`github.com`) still worked through the same
  path. **General lesson**: a single successful test after a DNS/LB
  config change proves nothing if the failure mode is *probabilistic*
  upstream selection — repeat the test.
- **`nmcli`'s `state: present` only touches the connection profile, not
  the live interface.** Pinning Pi-hole's DHCP-dynamic IP static via
  `community.general.nmcli` showed `changed` and set `ipv4.method:
  manual` correctly, but `ip addr show` still showed the address as
  `dynamic` afterward — would only have actually taken effect on next
  reboot, silently. Added an explicit `nmcli device reapply eth0` step
  (gated on the nmcli task reporting changed) to confirm it live instead
  of trusting "correct on next reboot, unconfirmed until then."
- **`pihole-FTL --config -q <key>` doesn't emit real JSON for array
  values** (`[ 1.1.1.1, 1.0.0.1 ]`, unquoted elements) — a read-then-
  compare idempotency check (`current.stdout | from_json`) for
  `dns.hosts`/`dns.upstreams` worked on the very first run purely by
  luck (empty array parses as valid JSON regardless of the quoting bug)
  and broke on the second run once those lists were populated. Fixed by
  dropping the read-then-compare entirely and setting both
  unconditionally every run — simpler than parsing FTL's bespoke format,
  and re-setting an unchanged value is harmless.
- **Wrong assumption about Pi-hole's SSH key**: guessed
  `~/.ssh/id_ed_pi` would be the dedicated local keypair (matching
  `id_garage`/`id_nfs`'s convention) — wrong key, connection refused.
  Unlike Garage/NFS (Terraform-provisioned, so their key's private half
  naturally exists locally), the Pi is physical hardware set up by hand;
  the actual working credential was Infisical's `SSH_PI4_KEY`. Fixed the
  inventory/README to fetch-from-Infisical rather than assume a local
  file.

End state: `kubectl get nodes` shows all 5 nodes `Ready` (3 control-plane,
2 worker), kube-vip's VIP (`192.168.1.180`) live and bound with both it
and `k8s.bnei.lan` in the API server's cert SANs (confirmed via
`openssl s_client` + `curl -k https://192.168.1.180:6443/version`),
Pi-hole static/authoritative for `bnei.lan` with correct in-cluster
forwarding confirmed by repeated live lookups.

## 2026-07-30 — Pigsty live-check: roles flipped, auto-failover already live (ADR-0029)

Before touching anything, checked `pigsty.yml`'s claims against the
actually-running Patroni cluster (per `pigsty/CLAUDE.md`'s own "trust but
verify" line) — good thing, since the live state contradicted the docs on
two separate points:

- **`patronictl -c /etc/patroni/patroni.yml list` shows the roles
  reversed** from every doc: `192.168.1.207` ("pg02", documented as
  replica) is the current **Leader**; `192.168.1.205` ("pg01", documented
  as primary) is the current **Replica**. No record of when/why this
  flipped — most likely an unattended Patroni-driven failover, given the
  next finding.
- **Automatic failover is live, not a config-file relic.** No pause/
  maintenance mode set; normal `ttl: 30`/`loop_wait: 5`/
  `maximum_lag_on_failover` are all active in `/etc/patroni/patroni.yml`.
  This directly contradicts `DECISION.md` §2's old "no automatic
  failover" line, which §4 had already flagged as unresolved drift
  pending exactly this kind of live check. Resolved by accepting reality
  instead of fighting it — see ADR-0029.
- Also confirmed via `terraform.tfvars`: both PG data VMs are still
  physically on `.165` (the dual-boot host), and DCS is a single etcd
  node (`.207`) — same total-outage-on-`.165`-shutdown risk the k8s
  topology already solved via ADR-0017, still open for Postgres until the
  server1 migration + witness VM (`pg-etcd-witness`, ex-laptop) actually
  land.
- Command used (via Infisical's `SSH_OLDPG_KEY`/`SSH_OLDPG_USER`, which
  — surprisingly — also authenticates against the *new* `pg-proxmox`
  nodes despite the name/docs implying it's scoped to the old, superseded
  `.193` box; see `docs/secrets.md`'s note on that row):
  ```bash
  ssh -i <SSH_OLDPG_KEY file> vagrant@192.168.1.205 \
    "sudo patronictl -c /etc/patroni/patroni.yml list"
  ```
- **General lesson, same shape as the CoreDNS one above**: a doc/config
  file describing a system's intended state is not evidence of its
  actual live state, especially anything with autonomous
  reconciliation (Patroni, Kubernetes, Argo). Check live before designing
  the next change on top of it.

## 2026-07-30 — pg01 replica migration to server1: kernel panic, recovered

Part of ADR-0029's rollout. `.205` (pg01, the replica) was migrated from
`.165` to server1 via a real Proxmox live migration (confirmed via the
PVE task log: `qmigrate OK` on `.165` immediately followed by `qmstart OK`
on server1 — a true live migration, no forced shutdown in between).

- **Post-migration, the guest was completely dark**: no ICMP, no SSH
  (control ping to the still-healthy `.207` from the same machine worked
  fine, ruling out a client-side network issue), and — more telling —
  `patronictl list` on the surviving leader (`.207`) didn't just show it
  as unreachable, it dropped the member from the list entirely. No QEMU
  guest agent is configured on this VM (an old hand-imported production
  disk, never had the agent installed, unlike this repo's cloud-init-built
  VMs), so there was no way to inspect it short of the Proxmox console.
  Root cause once the user checked the console: **kernel panic**.
- Rather than trying to repair the panicked disk, the plan (had it
  persisted) was destroy-and-recreate as a fresh clone + Pigsty
  add-replica, matching how `pg-etcd-witness` was built — reusing an old
  hand-built disk that just kernel-panicked isn't worth the trust. In the
  end, a plain **reboot recovered it cleanly** — `patronictl list`
  afterward showed `Replica`/`streaming`, timeline 23 (matching the
  leader, so no split-brain), lag 0. SSH host key changed after the
  reboot (expected — treated as a one-off `ssh-keygen -R`, not
  investigated further since the box is back to fully healthy).
- **Lesson**: a live migration transplants full running guest state onto
  different physical hardware without ever giving the guest a fresh boot
  to reset anything host-specific — for a VM that was never built through
  this repo's own cloud-init path (i.e., no guest agent, unknown exact
  provenance), that's a real risk, not just a Terraform-level "did the
  disk move" question. A plain reboot is the first thing to try before
  reaching for destroy-and-recreate — cheaper, and worked here.
- End state: `.205` on server1, streaming, lag 0;
  `terraform/imported.tf`'s `pg01.node_name` updated to `"server1"`,
  confirmed zero-diff via `terraform plan -target=`. DCS quorum is still
  single-node (`.207` only) — the witness VM and a 2nd etcd instance on
  server1 are still pending, per ADR-0029.

## 2026-07-30 — Guest agent install + a real, live demonstration of the single-node DCS gap

Installed `qemu-guest-agent` on both `pg01`/`pg02` (user request). Two
sub-findings, then one real incident:

- **Blocked apt on both hosts**: `/etc/apt/sources.list.d/node.list`
  (Pigsty-generated) declares the *same* `archive.ubuntu.com` URI as the
  standard deb822 `ubuntu.sources`, but marks it `[trusted=yes]` — apt
  refuses with "Conflicting values set for option Trusted" and won't read
  *any* source until resolved. Fixed by renaming it to `.disabled`
  (reversible) rather than deleting; it's a pure duplicate of an already-
  trusted mirror, so disabling it costs nothing.
- **A guest-triggered `reboot` does not apply a pending Proxmox hardware
  config change** (here: the new `agent: 1` flag, needed for the
  virtio-serial channel qemu-guest-agent uses). Only a full API-level
  stop + start picks it up — confirmed by testing both: `sudo reboot`
  left `qemu-guest-agent.service` unable to start ("dependency job
  failed", no device present); a cold stop/start immediately after fixed
  it (`agent/ping` returns real data).
- **The incident**: `pg01` (replica) was cold-stopped/started first —
  safe, already-proven-recoverable, no issue. `pg02` (the live Leader)
  was then stopped the same way. Since etcd is *still single-node*,
  co-located on `.207` (not yet resolved — ADR-0029's witness VM /
  2nd etcd member aren't live yet), stopping `.207` took the sole DCS
  node down with the primary. Patroni on `.205` logged continuous
  "No route to host" against `192.168.1.207:2379` for the entire outage
  window — with no DCS reachable at all, Patroni **cannot** promote a
  replica, no matter how healthy it is. The Pigsty VIP (`.232`) stayed
  down the whole time; nothing failed over. This is not a bug, it's
  exactly the single-point-of-failure ADR-0029 already named — now
  reproduced live instead of theoretical.
- **Compounding factor**: `infisical.bnei.dev` started 503ing within
  seconds of `.207` going down and stayed down for the whole outage
  window — strongly suggesting Infisical's own backend runs on this same
  `pg-proxmox` cluster. That's worth confirming properly outside this
  incident: if true, Infisical (the credential source for basically every
  tool used to operate this repo, including the PVE API token needed to
  *restart* `.207`) has a hard dependency on the exact database whose HA
  this session exists to build. During the outage, no PVE API/SSH
  credentials could be fetched at all — a human had to restart `.207`
  directly in the Proxmox console.
- **Resolved**: `.207` restarted, rejoined as Leader (timeline bumped
  23→24, no divergence — `.205` matched at lag 0 immediately after). Both
  VMs now have working guest agents (`agent/ping` returns data on both).
  `terraform/imported.tf`'s `agent` field removed from both `pg01`/`pg02`'s
  `ignore_changes` (now real, matches config, confirmed zero-diff).
- **Lesson**: don't restart the *only* DCS node for *any* reason —
  including maintenance that looks unrelated to Postgres, like enabling a
  guest agent — until the 3-node etcd quorum in ADR-0029 is actually live.
  Until then, the sole etcd node is a single point of failure for the
  entire cluster's ability to do anything, not just for the primary's own
  uptime.

## 2026-07-30 — INCIDENT: CA rotation + first etcd quorum expansion attempt

Executing `docs/runbook-pg-ca-rotation-etcd-quorum.md`. Phases 3.0–3.3
(backup, new CA generated + backed up to Infisical, certs re-issued on
both nodes, `.207`'s etcd restarted onto the new cert) went exactly as
planned and verified clean. Phase 3.4 (`bin/etcd-add 192.168.1.205`) is
where this went wrong — a chain of three separate mistakes, each one
compounding the last, ending in a real quorum-loss incident on the
**live primary's** DCS. Postgres itself was never down at any point.

**Mistake 1 — declared the full target state in `pigsty.yml` too early.**
`.197` (pg-etcd-witness, not yet provisioned) was already listed in the
`etcd:` inventory group from earlier documentation work. `etcd.yml`
bakes *every currently-declared* host into each member's
`initial-cluster` config value at generation time — it doesn't know
"planned" from "live." `.205`'s first bootstrap attempt failed
immediately ("member count is unequal", then a timeout dialing
`.197:2380`, which doesn't exist). Fix: only declare a host in this
group immediately before actually joining it, never ahead of time — now
called out explicitly in `pigsty.yml`'s own comment.

**Mistake 2 — fragmented the retry into separate `-t` tag runs.**
After fixing the inventory, re-running just `-t etcd_config` to
regenerate `.205`'s config (instead of re-running the *same* combined
command as `bin/etcd-add`) silently dropped `-e etcd_init=existing` —
that flag was only ever passed by the wrapper script, not persisted
anywhere. `.205`'s config regenerated with the *default*
`initial-cluster-state: "new"`, so it began bootstrapping its own
standalone cluster instead of joining `.207`'s. Symptom: `cluster ID
mismatch` warnings, `.205` computing its own local cluster ID from a
2-member list, `.207` computing (and keeping, permanently) its real ID
from its original 1-member genesis — these can never match by
definition. **Lesson: re-run the exact same command, don't split a
multi-step Pigsty operation into hand-picked tags once flags are
involved — the wrapper scripts exist for a reason.**

**Mistake 3 (the actual incident) — stopped `.205`'s etcd to relieve
load on `.207`, not realizing `.207`'s own `etcdctl member add
etcd-2 ...` (the earlier successful part of the same failed attempt)
had already durably committed a 2-voter configuration to `.207`'s own
raft log** — trivial to commit at the time (a 1-node cluster has quorum
of 1). With `.205` down, `.207` now believed it needed 2-of-2 votes and
had only itself: real quorum loss on the *live primary's* DCS.
`patronictl`/`etcdctl` calls against `.207` started timing out
(`ReadIndex` requires a quorum round-trip). The VIP stayed up only
because Patroni's existing leader lock hadn't expired yet — this was a
live risk window, not yet a realized outage, but close.

**Wrong recovery attempt**: `etcd --force-new-cluster` on `.207`,
assumed (from memory, not verified) that it discards prior membership
and reforms as a true single-node cluster. It doesn't — it replays the
node's own *committed* raft history, which still included the `.205`
member-add. Same endless pre-vote loop, now against a manually-run
process instead of systemd. Also hit a real footgun retrying the
cleanup: `pkill -f 'force-new-cluster'` matched its own invoking shell's
command line (which contained that literal string) and killed the SSH
session executing it, not just the target process — use a PID-specific
kill, not a `pkill -f` pattern that could match your own command.

**Correct recovery**: `etcdutl snapshot restore` — the actually-documented
tool for "one healthy member, rebuild a clean single-member data
directory from its real data, discarding confused membership history."
Procedure used:
1. Backed up `.207`'s full `/data/etcd` (tarball, kept both remotely and
   downloaded locally) before touching anything.
2. Copied the live backend db file out (`/data/etcd/member/snap/db`),
   ran `etcdutl snapshot restore <db> --data-dir /data/etcd-restored
   --name etcd-1 --initial-cluster 'etcd-1=https://192.168.1.207:2380'
   --initial-cluster-token etcd --initial-advertise-peer-urls
   'https://192.168.1.207:2380' --skip-hash-check` — restored into a
   **separate** directory, not overwriting the live one, so the original
   (with its confused-but-real history) stayed available as a fallback
   the whole time.
3. Verified the restore log explicitly: `"Trimming membership
   information from the backend"` then `"added member ... local-member-id:
   0, added-peer-id: e8387d5fe083034c"` — exactly one member, same
   cluster ID (`f7cc4f0446bbe8b5`) and same member ID `.207` already had,
   meaning Patroni's existing etcd3 config needed zero changes.
4. Only after that verified cleanly: `mv /data/etcd
   /data/etcd-broken-2026-07-30` (kept, not deleted) → `mv
   /data/etcd-restored /data/etcd` → `chown -R etcd:etcd` → normal
   `systemctl start etcd` (no special flags — the config file was
   already correct single-member the whole time, it was the *data*
   that needed fixing, not the config).
5. Verified: `etcdctl member list` (1 member), `etcdctl endpoint health`
   (real committed write succeeded), `patronictl list` (both members
   healthy, **same leader, no re-election, no timeline bump** — the
   actual DCS key data survived the restore intact, only membership
   metadata was reset), VIP responsive throughout the verification.

**General lessons**:
- A `member add` that "succeeds" is not reversible by restarting the new
  member differently — it's already durably committed on the *existing*
  member's side the moment it returns success. If the new member never
  actually comes up healthy, that's a real quorum-math problem on the
  existing cluster, not a cosmetic loose end.
- Don't recall disaster-recovery command semantics from memory under
  time pressure — verify with `--help`/docs against the actual installed
  version before running anything on a live primary's DCS. Got
  `--force-new-cluster`'s behavior wrong once already this incident.
- Postgres itself tolerated a fully-down DCS for several minutes without
  any data-plane impact (direct `psql` queries kept working the entire
  time) — the real risk was Patroni's leader-lock TTL eventually expiring
  mid-incident, not an instant outage. That gave enough headroom to fix
  this properly instead of panicking into a worse action.

### Second occurrence — same failure, plus a genuinely reassuring discovery

Retried `.205`'s join as a single atomic `bin/etcd-add` call (not
fragmented tags this time — `initial-cluster-state` confirmed correctly
`"existing"` beforehand). **Failed the exact same way regardless**:
`.205` computed its own local cluster ID from its 2-member
`initial-cluster` config and rejected all of `.207`'s raft messages as a
"cluster ID mismatch," while `.207`'s side had — again — durably
committed the `member add`. Same quorum-loss consequence on `.207` as
the first occurrence, recovered with the identical `etcdutl snapshot
restore` procedure (backup → restore into a new dir → verify → swap in
→ normal `systemctl start`), second time faster and with more confidence
since the procedure was now proven.

**Conclusion: this is not a one-off mistake, it's a real gap in
understanding how to statically join a new member to an etcd cluster
whose real cluster ID was fixed at a *single-member* genesis long ago.**
`initial-cluster-state: existing` alone does not make a new member defer
to the peer's real ID — in this etcd version, with this static
(non-discovery-URL) join method, the new member still computes its own
candidate ID locally at first boot from its own `initial-cluster` value,
and there's no way for a 2-entry list to hash to the same ID as the
original 1-entry genesis. Needs actual etcd documentation research
before a 3rd attempt, not another guess — this was called out and
paused rather than repeated a third time.

**Reassuring discovery**: Patroni has a built-in **DCS failsafe mode**
for exactly this situation. When it can't reach etcd at all but can
directly reach the other member's Patroni REST API (`.205`'s
`:8008/failsafe` from `.207`'s side), it logs `"continue to run as a
leader because failsafe mode is enabled and all members are
accessible"` and deliberately does **not** self-demote. This is why
Postgres/the VIP were never actually at risk through any of this,
confirmed directly: `pg_is_in_recovery()` returned `false` on `.207`
throughout. The one loose end after each etcd recovery: Patroni's own
DCS client got stuck (`EtcdConnectionFailed('No more machines in the
cluster')`) even after etcd itself was confirmed healthy again — a
plain `systemctl restart patroni` (not postgres) on each node cleanly
reset it. End state: both `pg-proxmox-1`/`-2` healthy, streaming, lag 0,
same timeline (25).

**Cleanup left on `.207`** (not yet removed, kept as a safety net):
`/data/etcd-broken-2026-07-30`, `/data/etcd-broken-2026-07-30-b`,
`/tmp/etcd-datadir-backup*.tgz`, `/tmp/etcd-restore-work*`. Safe to
delete once the cluster's been stable for a while and nobody needs to
diff against the pre-incident state.

**Decision: stopped here for the night.** Cluster is stable (2 real
members, Postgres/VIP fine, DCS healthy). The `.205`/witness join work
resumes next session, after actually reading etcd's join/discovery
documentation properly instead of continuing to trial-and-error the
same failing mechanism on production a third time.

## 2026-07-30 — `.205` etcd join: root cause found, 3rd attempt succeeds

Resumed the paused join. Rather than guessing a 3rd time, checked live
evidence first (all read-only, no risk): `.207`'s `etcdctl member list`
confirmed single-member (`etcd-1`, cluster ID `f7cc4f0446bbe8b5`,
matching ADR-0029's documented "still open" state) — but `.205`'s
`/data/etcd/member/{wal,snap}` was **not empty**, and its last journal
entries showed it booting with `local-member-cluster-id:
c35a5b635c65e63f`, a different, self-generated ID, rejecting every
packet from `.207` as a cluster ID mismatch.

**Root cause, confirmed rather than inferred**: the earlier botched
bootstrap (the one that regenerated with `initial-cluster-state: new`,
described above) had already written a real WAL to `/data/etcd` with
its own self-genesis cluster ID baked in. etcd only performs actual
join/discovery logic against `--initial-cluster`/
`--initial-cluster-state` when the data directory is *empty* — once a
WAL exists, every subsequent restart just resumes that persisted
identity, completely ignoring what the flags/config say. Both prior
retries used correct flags (`initial-cluster-state: existing`) but
neither had wiped the stale data directory first, so both were doomed
regardless — this is a more precise mechanism than ADR-0029's original
"computes its own candidate cluster ID" wording, now corrected there.

**Fix**: `systemctl stop etcd` (already stopped) + `rm -rf
/data/etcd/member` on `.205`, confirmed the directory came back empty,
then re-ran `ANSIBLE_PRIVATE_KEY_FILE=<key> bin/etcd-add
192.168.1.205` unchanged. Joined clean on the first try — no cluster ID
mismatch, no quorum-loss incident, `patronictl list` identical
before/after (same leader, same timeline 25, lag 0 throughout). Ran the
rest of the runbook's 3.4 tail (`etcd_config,etcd_launch` on `.207`,
`pg_conf,patroni_reload`, `pg_vip`) with no issues.

**Two more real gaps found immediately after**, both via the user
noticing Grafana's etcd dashboards showed both hosts `down` despite
`etcdctl endpoint health`/`patronictl list` confirming otherwise:

1. `/etc/pki/infra.crt` — the infra/monitoring node's own mTLS client
   cert for scraping (`roles/infra/tasks/cert.yml`, tag `infra_cert`) —
   was never reissued from the new CA during the CA-rotation runbook
   (which only covered `etcd_cert`/`pg_cert`). Fixed with `./infra.yml
   -l 192.168.1.205 -t infra_cert`. Didn't fully fix it alone — see next.
2. `/etc/pki/ca.crt` — the **node-wide** CA trust bundle
   (`roles/node/tasks/cert.yml`, tag `node_ca`), a separate file from
   `/etc/etcd/ca.crt` — was still the pre-rotation CA on both `.205`/
   `.207`. VictoriaMetrics' scrape client didn't trust etcd's
   now-new-CA-signed server certificate and rejected the TLS handshake
   client-side; etcd's own log showed this as `rejected connection on
   client endpoint ... remote error: tls: bad certificate` (misleading
   at first glance — reads like etcd rejecting *something*, but the
   "remote error" is the client's alert, logged from etcd's side).
   Fixed with `./node.yml -l 192.168.1.205,192.168.1.207 -t node_ca`,
   then `systemctl restart vmetrics vmalert` on `.205` (cert files are
   read once at process start, not hot-reloaded). Confirmed via
   VictoriaMetrics' own `/api/v1/targets` API: both etcd targets `up`
   immediately after, journal quiet.

**Lesson, same shape as the Round 1/2 logging bugs**: a live incident's
own root cause (WAL persistence surviving flag changes) is diagnosable
by directly reading the affected host's actual on-disk state and logs
rather than re-guessing at the Ansible/config layer — the fix here was
one `rm -rf` once the real mechanism was understood, not a config
change at all.

End state: real 2-member etcd quorum (`.205` + `.207`), Postgres/VIP
unaffected throughout, monitoring dashboards accurate again. Still
open: `pg-etcd-witness` (`.197`) provisioning + join — runbook Phase
3.5, next session's priority. 2-member quorum is `floor(2/2)+1` = 2,
still no better than single-node for actual fault tolerance.

## 2026-07-30 — `pg-etcd-witness` provisioned + joined: real 3-node etcd quorum live

Same session, continuing straight to runbook Phase 3.5. Generated a
dedicated keypair (`~/.ssh/id_pg_etcd_witness`), backed up to Infisical
(`SSH_PG_ETCD_WITNESS_HOST/KEY/PORT/USER`, `docs/secrets.md`).
`terraform apply -target=proxmox_virtual_environment_vm.pg_etcd_witness`
succeeded clean (`vm_id=303`, cross-host clone `.165`→`ex-laptop`,
7m14s, plan had shown 1 to add / 0 to change — matched exactly). VM
reachable immediately (`core@192.168.1.197`, cloud-init keys applied).

**Two real bugs hit getting `node.yml` to complete, neither foreseeable
from the design**:

1. `node_monitor`'s ping/vector-registration tasks delegate to the
   `infra` group host (`.205`) — which needs `.205`'s own key
   (`SSH_OLDPG_KEY`, user `vagrant`), not `.197`'s
   (`SSH_PG_ETCD_WITNESS_KEY`, user `core`). A single
   `ANSIBLE_PRIVATE_KEY_FILE` env var can't serve both simultaneously.
   Fixed by running a throwaway `ssh-agent -a <fixed-socket-path>` with
   both keys loaded via `ssh-add`, then invoking ansible with
   `SSH_AUTH_SOCK=<that-socket>` and no `ANSIBLE_PRIVATE_KEY_FILE`
   override — ssh/ansible tries each identity per host automatically.
   Needed a *fixed* socket path (`ssh-agent -a /tmp/....sock`), not
   `eval "$(ssh-agent -s)"`, since shell environment doesn't persist
   between separate tool invocations in this session.
2. `node.yml` failed outright on `node_monitor`'s vector setup:
   `roles/node_monitor/templates/vector.env` doesn't exist in this
   checkout. Root cause: `pigsty/.gitignore`'s blanket `*.env` rule
   swallows this file too, even though it's a static, non-secret asset
   Pigsty ships with upstream (a literal one-liner,
   `VECTOR_OPTS="--config-dir /etc/vector"`, no Jinja variables) — it's
   just never been tracked in this repo's checkout. Never hit before
   because `.205`/`.207` already had it deployed from whenever they
   were first bootstrapped (outside this checkout's history); `.197` is
   the first node ever bootstrapped *through* this exact checkout.
   Fixed by recreating the file locally with the same content already
   live on `.207` (confirmed via `cat /etc/default/vector` there first,
   not guessed) — intentionally left gitignored, same precedent as
   `files/pki/ca/ca.key` being present-locally-but-untracked by design.

With both fixed, `node.yml`, `etcd.yml -t etcd_cert`, and
`bin/etcd-add 192.168.1.197` all completed clean on first retry — no
quorum-loss incident this time (unlike `.205`, `.197` is a brand-new
node with an empty data directory from the start, so none of the
earlier stale-WAL failure mode applies). `etcdctl member list` showed
3 started members immediately; `patronictl list` never changed
(same leader, same timeline 25, lag 0) through the whole sequence.
Ran the remaining runbook tail
(`etcd_config,etcd_launch -f 1` on `.205`/`.207`,
`pg_conf,patroni_reload`, `pg_vip`) with zero issues — `-f 1` kept the
two restarts sequential, never both down at once.

Final verification: `etcdctl endpoint health --cluster` true on all 3
members, VictoriaMetrics `/api/v1/targets` shows all 3 `etcd`+`node`
jobs `up`, CA fingerprint on `.197` matches `.207` exactly (confirms
the fresh node picked up the current post-rotation CA automatically —
the `infra_cert`/`node_ca` gap from the earlier entry only affects
nodes that predated the CA rotation, not new ones), VIP (`.232`)
responsive.

**End state: real 3-node etcd DCS quorum live** (`etcd-1`/`.207`,
`etcd-2`/`.205`, `etcd-3`/`.197`), `floor(3/2)+1` = 2 — tolerates any
single member down, the actual goal of ADR-0029. **Not yet done**: the
real proof — stop `.207` (current Leader) and confirm `.205` promotes
automatically with the VIP following, while DCS quorum survives on the
remaining 2 members. That's the next session's first priority.

## 2026-07-30 — Real `.165` outage test: Postgres/etcd/K8s HA all confirmed live, several real gaps found and fixed

User physically powered down `.165` for a real end-to-end test of
everything built this session. Results, in order of what broke and what
didn't:

**Postgres/etcd: full success.** `.205` auto-promoted to Leader (timeline
25→26, real Patroni failover, no manual intervention), the Pigsty VIP
(`.232`) followed automatically, and etcd quorum survived on `.205`+`.197`
(2 of 3) the whole time. This is the actual proof ADR-0029 set out to get.

**K8s: full success, but a tooling gap looked like a cluster failure.**
`k8s-cp-02`/`k8s-cp-03`/`k8s-worker-02` stayed `Ready`, kube-vip's VIP
(`.180`) kept serving the API throughout. But `kubectl --kubeconfig
/etc/kubernetes/admin.conf` on a surviving CP node failed with "no route
to host" — that file hardcodes `k8s-cp-01`'s own IP (`.201`, on `.165`)
as the `server:` address, not the VIP. `--server=https://192.168.1.180:6443`
override fixed it immediately; the cluster itself was never actually
down. Worth fixing `admin.conf` generation to target the VIP by default
in a future session.

**Real bug found: Infisical's own `REDIS_URL`/`DB_CONNECTION_URI` were
stale, hardcoded IPs — a gap this session's own Redis relocation created
and missed.** When Redis moved off `.207` earlier today, the check for
consumers only looked at `gitops/platform/values/infisical/values.yaml`
(`redis: enabled: false` — the Helm chart's *bundled* subchart toggle)
and concluded Infisical wasn't affected. Wrong: Infisical's actual Redis
connection is a separate env var, sourced from
`ansible/playbooks/register-repos.env` (`REDIS_URL=redis://:Redis.Main@192.168.1.207:6379`)
and rendered into the `infisical-secrets` K8s Secret — never touched
during the relocation. Once `.165` went down, this hardcoded dead IP
made the whole Infisical backend 503 (the exact same "backend runs on
this same cluster" pattern from an earlier incident, but this time
Postgres itself was fully failed-over and fine — this was a
Redis-reference bug, not a repeat of the DCS gap). Also updated
`DB_CONNECTION_URI` to use `postgres.bnei.lan` instead of the raw VIP IP,
and `REDIS_URL` to `redis.bnei.lan`, matching the "DNS name, not a
hardcoded IP" pattern already used elsewhere — both `register-repos.env`
and `k8s-cluster/infisical/.env.secret` updated, and the live
`infisical-secrets` Secret patched + `platform-infisical-backend`
restarted directly (full `register-repos.yml` run wasn't possible: it
targets `k8s-cp-01`, which was down, and needs unrelated prerequisites —
`GITHUB_APPS_USERNAME`/`PAT` — not set in this environment). Confirmed
fixed: `https://infisical.bnei.dev` back to `200`.

**Real gap found: Grafana got stuck `Multi-Attach error for volume ...
already used by pod(s)`.** This is not a bug specific to this cluster —
it's how Kubernetes always behaves when a node with CSI-attached
(Longhorn) storage goes away *ungracefully*. The default node-eviction
timer reschedules pods (confirmed: new pods did get created on
`k8s-worker-02` for everything, including Longhorn's own CSI sidecars,
most of which had been concentrated on the two dead nodes) but never
force-detaches a `ReadWriteOnce` volume from a node it can't confirm is
gone — so Grafana's new pod couldn't attach the same PVC until `.165`
came back. Chose not to force it via the K8s 1.28+ "out-of-service" taint
this time (`.165` was expected back soon); instead built a permanent
fix — see below.

**Real gap found: the Freebox never knew about `bnei.lan` at all.**
`bnei.lan` was only ever resolvable by querying Pi-hole directly or from
inside the K8s cluster (CoreDNS forwards there) — any LAN device using
the Freebox's own DNS (the default) got NXDOMAIN. User fixed this by
pointing the Freebox's DHCP-handed-out DNS server at Pi-hole
(`192.168.1.55`) directly, confirmed working on the operator Mac
afterward (`scutil --dns` showed the new server, `k8s.bnei.lan` resolved
clean). **Still open**: the `k9s-dashboard` LXC (`192.168.1.110`) still
failed to resolve `bnei.lan` even after the Freebox fix — its
`/etc/resolv.conf` is statically injected by Proxmox itself at the LXC
level (`# --- BEGIN PVE ---` marker), completely bypassing DHCP-handed
DNS. No Terraform `dns`/`nameserver` override exists for this container.
Fix (`pct set 102 --nameserver 192.168.1.55 --searchdomain bnei.lan` on
server1) is straightforward but wasn't applied this session — blocked on
SSH access to `server1`'s own PVE host (port 2222 refused, port 22
needed a passphrase not available, and Infisical was down at the exact
moment this was attempted). Revisit next session.

**Permanent fix built: `.165` now drains itself before every graceful
shutdown.** New `ansible/playbooks/drain-165-configure.yml` installs a
systemd oneshot service (`drain-165.service`, ordered `Before=shutdown.target`,
`After=network-online.target`) that runs `kubectl drain k8s-cp-01
k8s-worker-01` on every reboot/shutdown, using a dedicated
least-privilege kubeconfig (`node-drainer` ServiceAccount,
`gitops/bootstrap/node-drainer-rbac.yaml` — cordon + evict only, never
cluster-admin, since this credential lives on a dual-boot gaming host
rather than a dedicated infra host). This should make the *next* `.165`
reboot fully clean — pods evicted and volumes detached before the node
disappears, no Multi-Attach, no manual taint needed. Installed and
verified live (`systemctl status` active/enabled) but not yet proven
through a real reboot cycle — that's the actual test for next time
`.165` goes down.

**General lesson, same shape as several earlier ones this session**: a
"we checked the consumers" pass is only as good as where you looked —
the Infisical Redis-reference bug survived the original relocation
specifically because the check stopped at one config file
(`values.yaml`) without realizing a *different* file
(`register-repos.env`) fed the same logical dependency through a
separate path. When relocating any shared credential/endpoint, grep the
whole repo for the old value, not just the "obvious" values file.

## 2026-07-30 — `.165` drain automation: two real bugs found via actual reboot tests, redesigned around self-drain

The `drain-165.service` design above looked right on paper and passed a
manual `systemctl stop` test, but two *real* `.165` reboot cycles (not
just the manual test) exposed it was broken in two separate ways —
worth recording both, since neither was guessable without actually
watching a real shutdown happen.

**Bug 1 — the systemd ordering was backwards.** `Before=pve-guests.service`
was meant to make the drain run *before* Proxmox stopped the guest VMs.
It did the opposite: systemd stops units in the *reverse* of their start
order, so `Before=X` means "start before X, stop *after* X." Confirmed
directly in `.165`'s journal: `pve-guests.service` fully stopped (all
VMs powered off, timestamped) — *then* `drain-165.service`'s `ExecStop`
finally ran, cordoning two already-dead nodes and failing to evict
anything (kubelet was already gone). First real test: only ~1 of 34
pods got cleanly evicted before the nodes went `NotReady` with no
cordon at all (the unit hadn't even started yet). Second test, after
tightening timeouts alone (not the ordering): cordon happened, but
still against nodes already powered off.

**Bug 2 — the RBAC was missing a permission the whole time.** Once the
ordering bug was understood and the drain script actually got a chance
to run against *live* nodes, it still failed cleanly: `kubectl drain
--ignore-daemonsets` needs `get`/`list` on `daemonsets` just to
recognize and skip DaemonSet-owned pods (Longhorn, Cilium, kube-proxy,
MetalLB's speaker, etc.) — without it, every node failed `"cannot get
resource daemonsets... forbidden"` and drain never completed. This had
been wrong since the RBAC was first written; the ordering bug just
meant it was never actually exercised against live nodes until now.

**Redesign, not a patch**: rather than keep fighting `pve-guests.service`
ordering (a host-level Proxmox service neither this repo nor the user
fully controls), moved the whole mechanism *into* the two K8s guest VMs
themselves. Proxmox's own `qmshutdown` already sends each guest an ACPI
shutdown signal and waits per-VM (confirmed 180s timeout in the
journal) for a graceful shutdown — a far more natural trigger than
racing a hypervisor-level service. `k8s-cp-01`/`k8s-worker-01` now each
run `drain-self.service`/`uncordon-self.service` (new
`ansible/playbooks/self-drain-configure.yml`, superseding
`drain-165-configure.yml`, deleted), draining/uncordoning *themselves*
using the identical `Before=shutdown.target`/`After=network-online.target`
idiom — just inside the guest's own systemd instead of the hypervisor's,
sidestepping the ordering question entirely. `.165` itself was cleaned
up (both old units, scripts, and the kubeconfig removed).

**Also discussed and deliberately declined**: full etcd decommission/
recommission on every `.165` reboot ("cattle not pets" for a routine,
recurring event) — rejected as overkill and actively risky, since it
would mean removing/re-adding `k8s-cp-01`'s etcd membership on every
gaming reboot, exactly the kind of operation this same session's earlier
etcd quorum work (ADR-0029) proved fragile. Drain-and-return (cordon →
evict → reboot → rejoin → uncordon) is the correct pattern for a
routine, recurring reboot; decommission/recommission is for a
deliberate, infrequent rebuild — different problem.

**Also discussed and deliberately declined**: automating this via
Terraform/cloud-init for zero-touch coverage of future/replacement
nodes. Terraform has no mechanism to configure an already-running VM's
guest OS (its only guest-level touchpoint is cloud-init, which runs
once at first boot) — cloud-init *could* bake this in for brand-new
nodes, but can't mint its own live cluster token at first-boot time
without threading a long-lived, pre-minted token through as a
Terraform variable. Deferred as a real but non-urgent follow-up; new
nodes get this via a manual `self-drain-configure.yml` run for now.

**Verified this round**: after the redesign, re-running
`self-drain-configure.yml` correctly (a) applied cleanly on both nodes,
(b) immediately uncordoned both (they were still cordoned-but-Ready
from the earlier failed tests) within ~15s, and (c) the scoped
`node-drainer` credential was confirmed still least-privilege
(`kubectl get secrets` → `Forbidden`) even with the new `daemonsets`
permission added. **Not yet re-proven through a full, real `.165`
reboot cycle** with the corrected design — that's the next real test.

## 2026-07-30 — Third `.165` reboot test: real root cause finally found — Proxmox's own shutdown timeout, not systemd ordering

After the self-drain redesign above, a third real `.165` reboot test
still only evicted 2-3 of 34 pods per node before they went `NotReady`.
This time the journal made the actual cause unambiguous:
`drain-self.service`'s `ExecStop` starts, cordons the node, issues a
handful of evictions — then **the log simply stops mid-stream**, no
completion message, no timeout message, no error, straight to the next
`-- Boot --` marker roughly 5 minutes later.

That silence is the tell: it means the VM itself was killed while the
script was still running, not that the script's own logic gave up.
Cross-referencing the earlier `pve-guests` journal entries
(`"Stopping VM 201 (timeout = 180 seconds)"`) confirmed it — **Proxmox's
own per-VM ACPI shutdown timeout (180s) was shorter than the drain
script's systemd `TimeoutStopSec` (240s)**, so Proxmox always force-killed
the guest before the drain's own timeout could ever fire, let alone
before 34 real pods could finish evicting. Two prior "fixes" (tightening
timeouts, fixing the ordering) never touched this because it's a
third, independent constraint — the *hypervisor's* patience, not
anything inside the guest.

**Fix**: `terraform/k8s-vms.tf`'s shared `k8s_node` resource now sets
`startup { down_delay = 300 }` on every K8s VM — this Proxmox VM option
doubles as the guest's ACPI shutdown timeout when `qmshutdown` is called
without an explicit `--timeout` (which is how a normal `.165` reboot
invokes it), so 300s comfortably exceeds both the drain script's own
180s `kubectl drain --timeout` and its 240s `TimeoutStopSec`. Applied
in-place via `terraform apply -target=...` (0 add/destroy, 5 changed,
no VM restart needed — confirmed via `qm config 201/202 | grep startup`
showing `startup: down=300` immediately). Harmless on nodes that never
use self-drain; it only affects how long a graceful shutdown is allowed
to take.

**Lesson, same shape as the `pve-guests.service` ordering bug**: a
completely silent failure (no error, no timeout message, log just
stops) is itself a strong signal — it means something *external* to
the failing process killed it, not that the process's own logic hit a
dead end. Cross-referencing a *different* service's journal
(`pve-guests`, from an unrelated earlier debugging session) is what
actually cracked this one, not staring harder at `drain-self.service`'s
own output.

**Not yet re-tested with all three fixes in place** (self-drain
redesign + RBAC fix + this timeout fix) — that combination has never
been through a real `.165` reboot cycle yet. Next real test is the
actual proof.

## 2026-08-01/02 — etcd metrics-bind fix (PR #78): `cluster.yml` alone doesn't reach an already-running cluster

`etcd_listen_metrics_urls` was added to
`inventory/ukubi/group_vars/k8s_cluster/k8s-cluster.yml` (mirrors the
existing `kube_proxy_metrics_bind_address` fix) to stop `etcdMembersDown`/
`etcdInsufficientMembers` firing — cp-02/cp-03 had rejoined post-outage with
kubeadm's loopback-only `--listen-metrics-urls` default, unreachable from
Prometheus. Getting the code-correct fix actually live took two rounds of
real, on-cluster trial and error.

**Round 1 — `cluster.yml --tags control-plane,download` completed clean but
changed nothing.** Live check (`ssh` + `grep listen-metrics-urls
/etc/kubernetes/manifests/etcd.yaml` on all 3 CP nodes, plus `kubectl get cm
kubeadm-config -n kube-system -o jsonpath='{.data.ClusterConfiguration}'`)
showed the var never reached the cluster at all — the live
`etcd.local.extraArgs` had no `listen-metrics-urls` entry, cp-02/cp-03 were
still `127.0.0.1:2381`. Root cause: kubespray's day-2 reconciliation of an
already-running cluster's kubeadm config (`kubeadm upgrade apply`/`upgrade
node`, then `kubeadm init phase etcd local` + `control-plane all` to rewrite
the static pod manifests — `roles/kubernetes/control-plane/tasks/
kubeadm-upgrade.yml`) is entirely gated behind `upgrade_cluster_setup`,
which **defaults to `false`**
(`roles/kubernetes/control-plane/defaults/main/main.yml:3`) and is normally
only set `true` by the dedicated `upgrade_cluster.yml` playbook. Plain
`cluster.yml` against an already-initialized cluster
(`kubeadm_already_run.stat.exists == true`) skips nearly all of
`kubeadm-setup.yml`'s init/join logic, and — without this flag — skips the
reconciliation path too. **Any future group_vars change meant to alter an
already-running cluster's kubeadm ClusterConfiguration (etcd/apiserver/
controller-manager/scheduler extraArgs, etc.) needs `-e
upgrade_cluster_setup=true` explicitly on `cluster.yml`, even with no
`kube_version` bump** — kubespray's own upgrade docs mention this flag only
in the context of version bumps, easy to miss for a config-only change.

**Round 2 — added `-e upgrade_cluster_setup=true`, then the play died with a
"wait for the apiserver to be running" fatal on cp-01, 60/60 retries
exhausted.** Looked like a real outage. It wasn't: `upgrade_cluster_setup=true`
rewrites `kube-apiserver.yaml`/`kube-controller-manager.yaml`/
`kube-scheduler.yaml`/`etcd.yaml` on **all three** control-plane nodes in the
same run — every static pod restarts near-simultaneously across the whole
control plane, and ansible's fixed post-upgrade health-check retry budget
(60 attempts) wasn't generous enough for that; cp-01 didn't come back inside
the budget and the play aborted there.

Verified live instead of trusting the ansible exit code or reflexively
re-running/rolling back: `crictl ps -a` on cp-01 showed the new
`kube-apiserver` container already `Running` (previous attempt `Exited`
cleanly, no crash loop), `stat` on all 3 nodes' manifest files showed
identical rewrite timestamps (proving the reconciliation itself had
succeeded everywhere, not just where the wait failed), `curl -sk
https://127.0.0.1:6443/healthz` returned `ok` on all 3 nodes, `etcdctl
member list` showed all 3 members `started`, `kubectl get nodes` showed all
5 nodes `Ready`. Everything had self-healed within the restart window, well
before ansible's own timeout gave up. Confirmed end-to-end via Alertmanager:
`etcdMembersDown`, `etcdInsufficientMembers`, `TargetDown`,
`KubeContainerWaiting`, `KubePodNotReady` all cleared from the active alert
list afterward.

**Lesson, same shape as the CoreDNS/Pigsty "check live state, not the
docs/exit-code" lessons above**: a kubespray play failing on a
"wait for apiserver" step is not the same thing as the cluster being down.
A simultaneous multi-node control-plane manifest rewrite is disruptively
noisy for a short window *by design* — check `crictl ps -a`/`healthz`/
`etcdctl member list`/`kubectl get nodes` directly before assuming an outage
or reaching for a hand-patch. Because the play died mid-run, tasks after the
manifest-rewrite step (CNI reinstall, kubelet-csr-approver helm apps,
resolv.conf reapply) never got a chance to run in that invocation — turned
out low-risk to skip here since live checks showed the cluster fully
healthy and the target alerts cleared, but the safer general habit is to
re-run the same command once cluster health is confirmed (kubespray's
control-plane role is idempotent).

## 2026-08-13 — zot registry (ADR-0034) first live bring-up: four findings, one of them a real (silent) failure

First end-to-end deploy of the in-cluster OCI registry. The Garage bucket,
the Application sync and the build runner all came up without drama; what
follows is only the parts that did *not* behave as written, because those
are the ones worth the words.

### `/metrics` is 401 by default once htpasswd auth is on — repository policies do not cover it

The scrape was silently broken on arrival. `accessControl.repositories`
governs image paths only; enabling `http.auth.htpasswd` locks down
`/metrics` too, and nothing in the startup log says so — zot cheerfully
logs `metrics extension enabled` and `setting up metrics routes` while
every scrape gets a 401. Caught by probing the endpoint directly rather
than by trusting the log:

```
anonymous GET  /v2/                     -> 200
anonymous GET  /v2/_catalog             -> 200
anonymous POST /v2/test/blobs/uploads/  -> 401   # push correctly refused
bad-cred  POST /v2/test/blobs/uploads/  -> 401
anonymous GET  /metrics                 -> 401   # <-- not intended
```

Fix is a sibling of `repositories` under `accessControl`:

```json
"accessControl": {
  "repositories": { "**": { "anonymousPolicy": ["read"], "defaultPolicy": [...] } },
  "metrics": { "anonymousPolicy": ["read"] }
}
```

**The trap inside the trap**: do not "harden" this later by adding a
`basicAuth` stanza to the ServiceMonitor. `isAnonymousMetricsRequest`
(`pkg/api/authn.go` v2.1.20) requires `isAuthorizationHeaderEmpty(request)`
— *sending* credentials makes the request non-anonymous and it fails the
very check that would have let it through. Adding auth to be safe breaks
the scrape rather than securing it. Verified against the v2.1.20 source,
not inferred from behaviour.

### A ConfigMap mounted with `subPath` never updates — and ArgoCD reports Healthy the whole time

Stricter than the CoreDNS/nodelocaldns lesson recorded above. That one is
"eventually, unconfirmed"; this one is **never**. A `subPath` volume mount
is resolved once at container start and receives no subsequent kubelet
sync, ever. Meanwhile ArgoCD is entirely correct that the Application is
`Synced` and `Healthy` — the ConfigMap *object* does match git; only the
running process holds stale content. Green dashboard, stale config, no
signal anywhere.

Confirmed live editing zot's `distSpecVersion`: the ConfigMap updated, the
pod kept the old value until `kubectl rollout restart deploy/zot -n zot`.
Any change to `gitops/platform/values/zot/values.yaml`'s embedded
`config.json` needs that restart, and the same applies to every app using
`extraManifests` + `extraVolumeMounts` + `subPath` in `common-app-chart`.
Added to the `k8s-ops` skill.

### `.lan` names do not resolve from the MacBook — but this does not affect the pipeline

`dig registry.bnei.lan @192.168.1.55` answers `192.168.1.234`; `dig
registry.bnei.lan` (default resolver) answers nothing. `scutil --dns`
shows `nameserver[0] 151.236.14.64` on the primary interface, with Pi-hole
only on a lower-priority one — a VPN resolver winning.

Worth writing down mostly so the *next* person does not debug the registry
when the fault is the laptop: in-cluster consumers are unaffected, since
pods resolve via CoreDNS which forwards to Pi-hole first
(`dns_upstream_forward_extra_opts: {policy: sequential}`). Only manual
testing from the Mac is affected — use `192.168.1.234:5000` directly, or
fix the laptop's resolver order.

### Smaller things

- `distSpecVersion: "1.1.0"` produced `config dist-spec version differs from version actually used` on every start; zot serves 1.1.1 regardless. Cosmetic, but an expected-and-ignored warning is indistinguishable from a real one at 3am. Now `1.1.1` (PR #129).
- `garage-configure.yml --tags bucket_ops` behaved exactly as ADR-0030 promised on a live re-run: the four existing buckets and keys skipped, only `zot-registry` created, `ZOT_S3_ACCESS_KEY`/`_SECRET` written. The new opt-in `max_size` quota applied cleanly (`changed_when: false`, so it reports `ok` not `changed` — expected, since re-setting an identical quota is a no-op in garage itself).
- The S3 storage driver was verified from zot's own startup config dump (`"name":"s3"`, `"regionendpoint":"http://garage.bnei.lan:3900"`, `"Dedupe":false`) rather than from "the pod is Running". ADR-0034 named this the one unproven component; a filesystem fallback would also have shown `Running`.

### containerd trust rollout: the feared collateral restart did not happen

ADR-0034 warned that `--tags=containerd` re-runs the whole containerd role,
three of whose tasks carry `notify: Restart containerd`, and that
`cluster.yml` has no `serial:` and no drain — so the plan was `--check
--diff` first, then `--limit` one node at a time.

The `--check` run answered the question and made the ritual unnecessary.
Both runs, dry and real, reported `changed=2` on all five nodes, and the
only two changed tasks were:

```
container-engine/containerd : Containerd | Create registry directories
container-engine/containerd : Containerd | Write hosts.toml file
```

Neither notifies the restart handler. The three tasks that do (*Unpack
containerd archive*, *Generate systemd service*, *Copy containerd config
file*) were `ok`. Real run: `RUNNING HANDLER` occurrences — **zero**.
Afterwards all five nodes `Ready` with unchanged uptimes (18d/14d/14d/18d/
15d), no pod churn. So it ran across all five at once, not node-by-node.

Also confirmed in the same output: the `docker.io` mirror entry carried
forward into `containerd_registries_mirrors` renders **byte-identical** to
the role default — the loop shows one iteration `ok` (docker.io) and one
`changed` (`registry.bnei.lan:5000`) per host. That carry-forward exists
because Ansible replaces lists rather than merging them; the `ok` is the
evidence it was transcribed correctly rather than approximately.

**The generalisable bit** — the restart warning is about a *class of
change*, not the tag. Adding a `certs.d` entry touches only non-notifying
tasks. A containerd **version bump**, a `config.toml`/systemd-unit change,
or anything else that reaches the three notifying tasks still restarts
containerd on every targeted node simultaneously, and still deserves
`--limit`. Run `--check --diff` and read *which tasks* report changed —
that is the cheap question that decides whether the careful path is needed,
and it costs a minute.

### `infisical.autoReload: true` restarts an app on *any* secret in the project, not just its own

Zot bounced repeatedly on its first afternoon — four Deployment revisions in
~40 minutes, only two of which were deliberate `rollout restart`s.

Cause: the infisical-operator computes a single ETag over the **whole
managed secret** and stamps it on the pod template
(`secrets.infisical.com/managed-secret.<name>`). `common-app-chart`'s
`infisical:` block syncs a project *path*, and `infra-bootstrap-1-ge1`'s
root holds **54 keys** — so the annotation changes when *any* of those 54
change, and the Deployment rolls. There is no per-key granularity.

The recurring trigger is one this repo runs often:
`garage-configure.yml`'s two Infisical write tasks are `changed_when: true`
unconditionally, rewriting `GARAGE_ROOT_TOKEN` plus every bucket's key pair
on every run. So onboarding an unrelated bucket restarts the registry.

Two things made the cost worse than a normal rolling update:

- The registry is on the critical path of every pod start, so its blips are everyone's blips.
- MetalLB is **L2**. A reschedule moves the announcing node (`nodeAssigned … announcing from node "k8s-cp-01"` in the Service's events), so ARP convergence stacks on top of the pod cycle. Surge-then-kill keeps the *pod* transition clean; it does nothing for the L2 announcement.

Set `autoReload: false`. The trade is explicit: after a genuine S3 credential
rotation zot serves errors until restarted — rare and alertable — versus
restarts that were frequent and silent. A deliberate restart is already this
app's operating model, since its `config.json` is mounted with `subPath` and
never picks up ConfigMap updates either (see above).

**Generalisable**: `autoReload: true` is only safe when the app's Infisical
path contains *only that app's* secrets. For anything reading a shared
project root, it is an availability risk disguised as convenience — and it
gets worse as the project grows, since every new secret adds another
unrelated restart trigger. The real fix in both cases is a per-app Infisical
folder (`secretsPath`), which would also stop `envFrom` handing the pod 54
keys it has no business holding.

### buildah cannot build in an unprivileged pod — the builder moved to an LXC

First real run of `editable-blog`'s build pipeline failed, and the failure
invalidated a design claim in ADR-0034 rather than a config value.

Everything up to the build worked, which is worth recording because it
proves the rest of the chain: runner registration, checkout, `buildah`
install, version read, **registry login** (Infisical htpasswd hash → zot,
plaintext → GitHub secret → `buildah login`), and cleanup. Then:

```
Error while applying layer: ApplyLayer exit status 1
  stderr: remount /, flags: 0x44000: permission denied
error creating build container: writing blob: adding layer with blob "sha256:..."
exit code 125
```

`0x44000` is `MS_PRIVATE|MS_REC` — `mount --make-rprivate /`, which needs
`CAP_SYS_ADMIN`.

**The mistaken assumption**: ADR-0034 claimed `--isolation chroot
--storage-driver vfs` "keeps this an ordinary unprivileged pod". Those flags
govern buildah's *run* step. Layer extraction is a *storage* step and does
its own mount work regardless — `chroot` isolation does not reach it.
Known upstream: containers/buildah#4920, #5622, #2554. The rootless path
instead wants setuid `newuidmap`/`newgidmap`, which fails under Kubernetes
too (#4049).

The claim was written confidently and never tested before being encoded in
an ADR. The verification section of that same ADR is what caught it, on the
first real run — which is the argument for having one.

**Resolution**: the builder left the cluster. `terraform/build-runner.tf`
(LXC 103, `nesting`+`keyctl`, 4 cores / 4GB / 40GB) plus
`ansible/playbooks/build-runner-configure.yml`. Real root, so the problem
class disappears rather than being negotiated around. Two side effects are
improvements: builds no longer run on a Kubernetes node at all (stronger
isolation than the no-ServiceAccount pod), and ADR-0035's planned Forgejo
runner now has a box waiting for it.

The rejected alternative was a privileged pod. It would have worked in
minutes and put a container executing arbitrary app-repo `Dockerfile`s at
node-root — strictly worse than the identity coupling ADR-0034 splits the
runners to avoid, and it would have meant arguing against that ADR to ship
it.

**Generalisable**: "unprivileged container image builds" is a genuinely hard
problem, not a flag. Before designing anything around buildah/kaniko/img in
Kubernetes, build one throwaway image on the target platform first. The
distance between "the docs list a rootless mode" and "it builds on this
cluster" is where the whole cost is.

### build-runner LXC bring-up: five failures, each one a wrong assumption

The LXC itself was easy; getting a build through it took five iterations, and
every one was an assumption written into code without being exercised. Listed
because the *pattern* is the lesson, not the individual fixes.

**1. Duplicate vztmpl download.** `build-runner.tf` declared its own
`proxmox_download_file` for the Debian 13 template, copying
`k9s-dashboard.tf`'s "needs its own download" comment. That comment's
reasoning is *per-node* — garage's template on `.165` isn't visible to
`server1` — and build-runner is on `server1`, the same node as
k9s-dashboard. Apply failed:

```
refusing to override existing file
'/var/lib/vz/template/cache/debian-13-standard_13.6-1_amd64.tar.zst'
```

Now references `proxmox_download_file.k9s_dashboard_lxc_template.id`.
Copying a comment is not the same as copying its reasoning.

**2. `keyctl` needs `root@pam`.** The `features` block set
`nesting=1,keyctl=1`; the API token can only set `nesting`:

```
Permission check failed (changing feature flags (except nesting)
is only allowed for root@pam)
```

Already documented in `terraform/README.md` as a bpg hard restriction.
Dropped `keyctl` rather than escalating for a feature that may be
unnecessary — if a build ever fails on a keyring error the fix is
`pct set 103 --features nesting=1,keyctl=1` on server1 as root@pam, which
would then be drift Terraform cannot express.

**3–4. `become_user` on a minimal Debian LXC.** Two missing packages, both
surfacing as the same useless error:

```
Module result deserialization failed: No start of json char found
```

`sudo` (ansible's default `become_method`; the LXC ships without it) and
`acl` (to hand module temp files from root to an unprivileged become user).
The play-level `become: true` masks both, because becoming root when already
root never exercises either. Adding `acl` alone did not fix it — `sudo` was
the load-bearing one.

**5. `config.sh` rejects `--flag=value`.** The runner's configurator wants
space-separated arguments. Given `--url=https://...` it reports
`Unrecognized command-line input arguments` and then
`Invalid configuration provided for url`, which points at the *value* rather
than the syntax that actually broke. `no_log: true` on that task hid all of
it; the diagnosis came from running `config.sh` by hand over SSH.

### And then rootless buildah failed on the LXC too — but recoverably

The first successful-looking run still died:

```
insufficient UIDs or GIDs available in user namespace
(requested 0:42 for /etc/shadow) ... lchown /etc/shadow: invalid argument
```

preceded by `newgidmap: write to gid_map failed: Operation not permitted`
and `Falling back to single mapping`. An unprivileged LXC gives the runner
user exactly one UID, and `node:22-alpine` chowns `/etc/shadow` to gid 42.

**This is the same root cause that killed the in-cluster attempt** — no
usable user namespace — but here it is recoverable, because the box has real
root. That is precisely the property the LXC was chosen for. The runner
*process* still cannot be root (GitHub's `config.sh` refuses to register that
way), so the runner user gets `NOPASSWD` sudo for `/usr/bin/buildah` alone
and every buildah call goes through it.

All four calls had to move together, not just the build: `buildah login`
writes its auth file under `/run/containers/<uid>/`, so a rootless login is
invisible to a rootful push.

**Also caught here**: `node -p` read the version out of `package.json`, but a
build box has no Node runtime. The step did not fail — command substitution
returned empty — and it surfaced three steps later as
`tag registry.bnei.lan:5000/editable-blog:: invalid reference format`.
Switched to `jq` with `set -euo pipefail` and an emptiness check.

### V10 — the number ADR-0034 asked for

First green run, `editable-blog` at `0.37.9`, verified in the registry
(`/v2/_catalog` → `["editable-blog"]`, tags `0.37.9` + `latest`, blobs in
Garage):

| pipeline | wall clock |
|---|---|
| `local-registry.yml` — LAN build → LAN push | **67s** |
| `docker.yml` — GitHub runner → Docker Hub | **113s** |

**Read this honestly: it is not apples-to-apples.** `docker.yml` also runs a
Trivy scan, uses buildx with a registry-backed cache, and triggers a deploy
job; the LAN pipeline does none of those. So the fair claim is "meaningfully
faster, and certainly not slower," not "1.7× faster." A like-for-like number
needs the scan added to the LAN pipeline, or removed from the comparison.

What is unambiguous: the WAN is off the hot path in both directions, and
nodes now pull over gigabit instead of a residential downlink — which was
the actual argument, and which the wall clock above does not even measure.

---

## 2026-08-14 — `nfs` StorageClass (ADR-0036) bring-up: two bugs caught before the destructive step

Adding the second export to `nfs-storage` (`.198`) for the unreplicated
`nfs` StorageClass. Terraform's part went clean on the first try —
`~ update in-place`, `0 to add, 1 to change, 0 to destroy`, no ForceNew
trap despite `nfs.tf`'s history of them. The interesting part is what the
pre-flight checks caught.

### 1. The 200GB default did not fit, and LVM-thin would have hidden that

`terraform.tfvars` was written with `nfs_k8s_disk_size_gb = 200` as a
working assumption, with a "confirm with `pvesm status` first" note. The
confirm found server1's `local-lvm` at **104.2G avail of 374.5G**.

The trap is that this would have *worked*. `local-lvm` is LVM-thin, so a
200GB volume provisions successfully against 104GB of real space and only
bites later — when the export fills, the pool hits 100%, and every VM
sharing it (`k8s-worker-02`, `k8s-cp-02`, `pg01`) locks up simultaneously.
A thin pool converts "I over-committed storage" into "three VMs are down",
with a long delay in between.

Dropped to 50GB — about half the real free space. `variables.tf`'s default
now carries the measured figure and the reason, so the next person doesn't
re-derive it from a guess.

### 2. Kernel device order is not SCSI interface order

The playbook addressed disks as `/dev/sdb` (templates) and `/dev/sdc`
(k8s), assuming `sdX` follows `scsiN`. It does not. After the hot-plug,
`lsblk` showed:

```
sdb   50G                                 <- the NEW disk (scsi2)
sdc  100G ext4 nfsexport /export/templates <- the OLD disk (scsi1)
```

Reversed. Confirmed via `/dev/disk/by-id/`:
`...drive-scsi1 -> ../../sdc`, `...drive-scsi2 -> ../../sdb`.

Running the playbook as written would have `mkfs.ext4 -L nfsexport` on the
*new* empty disk, then left two disks claiming `LABEL=nfsexport` with the
mounts done by label. **The template disk itself was never at risk** — the
`blkid ... | grep -q TYPE=` guard sees the existing ext4 signature and
skips the mkfs, which is precisely the failure this idiom exists to
prevent. Worth noting as evidence that guard earns its keep.

Fixed by addressing disks as
`/dev/disk/by-id/scsi-0QEMU_QEMU_HARDDISK_drive-scsiN`, which matches
`terraform/nfs.tf`'s `interface` value exactly and is stable across
reboots and hotplug ordering. **Generalizable: any future playbook that
formats a Proxmox VM disk should use by-id, not `/dev/sdX`.**

### 3. Two non-bugs worth recording

- **Host key mismatch on `.198`.** SSH refused with
  `REMOTE HOST IDENTIFICATION HAS CHANGED`. Not the terraform run — the
  stale `known_hosts` entry was an **ECDSA** key while the host serves
  **ED25519**, i.e. a leftover from a previous occupant of that IP.
  Verified out-of-band before clearing it, by asking the qemu guest agent
  through the PVE API to print the host key
  (`/nodes/server1/qemu/302/agent/exec` → `ssh-keygen -lf`) and comparing
  fingerprints. They matched, so `ssh-keygen -R` was safe. Cheap trick,
  worth reusing: the PVE API is an independent channel to the guest, so a
  host key can always be confirmed without trusting the SSH connection
  being questioned.
- **The DNS reboot turned out to be unnecessary.** `terraform/nfs.tf` now
  sets `initialization.dns.servers`, and both the runbook and the ADR
  warned that on an already-running VM this only regenerates the
  cloud-init drive, needing a reboot to land. In practice `.198` already
  resolved `k8s-cp-01.bnei.lan` via `192.168.1.55` with no reboot. The
  warning stays in the docs — it costs nothing and is right in the general
  case — but the reboot was skipped here.

### Outcome — clean bring-up, one cosmetic bug found

With both fixes in, the run went through in one pass. `terraform apply`:
`0 added, 1 changed, 0 destroyed`. Playbook: `ok=9 changed=5 failed=0`.
ArgoCD had already synced `platform-csi-driver-nfs` off the merge
(`Synced`/`Healthy`, no manual apply — ADR-0021 working as designed), and
`kubectl get sc` showed `nfs` alongside `longhorn (default)`.

Acceptance test (1Gi RWX PVC, two pods pinned to different nodes via
`requiredDuringScheduling` anti-affinity):

- PVC bound `RWX` on class `nfs`
- pods landed on `k8s-worker-01` / `k8s-worker-02`; each read the other's
  file, so this is genuine cross-node RWX, not a same-node false pass
- directory mode `drwxrwxrwx` — `mountPermissions: "0777"` applied
- data present at `/export/k8s/pvc-<uid>/` on `.198`
- deleting the namespace removed the subdirectory and left 0 `nfs` PVs —
  `reclaimPolicy: Delete` confirmed end to end

### The cosmetic bug: a `changed_when` that cried wolf

The format task reported `changed` for **both** disks — including `scsi1`,
the live 1.8GB template export. Genuinely alarming for a second.

It had not been reformatted. Proof: `tune2fs -l` showed `scsi1`'s
filesystem created `Jul 28 21:09` (original) versus `scsi2`'s `Aug 14
15:18` (today), with `images/` and `snippets/` and their July mtimes
intact.

The cause was the `changed_when`, not the shell logic:

```yaml
shell: blkid {{ item.device }} | grep -q TYPE= || mkfs.ext4 ...
changed_when: "'TYPE=' not in nfs_mkfs.stdout"
```

`grep -q` writes **nothing** to stdout by definition, so `'TYPE=' not in
stdout` is true on every run, formatted or not. The task always claimed
`changed`. This was inherited from the original single-disk playbook where
it was invisible (one item, first run, actually changed); adding a second
disk made it look like a live export was being reformatted on every run.

Fixed by having the mkfs branch echo a marker and testing for that
instead. Worth generalizing: **a `changed_when` that reads stdout from a
`grep -q` guard is always wrong** — the quiet flag is the whole point of
`-q`. Check the exit code, or emit an explicit marker.

Two guards did their job here and are worth keeping: the `blkid` check
(prevented an actual reformat of live data despite the misleading report)
and the by-id device addressing from the previous section (without it the
same run would have targeted the wrong disks entirely).

A second, smaller idempotency bug surfaced from the same re-run: `Create
export directories` pinned `mode: "0755"`, but `csi-driver-nfs` chmods the
share root to `0777` to match its `mountPermissions`. The two fought, so
every re-run reported `changed` on a directory nobody had touched. These
paths are *mountpoints* — after the mount, the visible mode belongs to the
filesystem's own root inode, not to anything the playbook created — so the
`mode:` was dropped rather than argued with. With both fixes the playbook
re-runs at `ok=8 changed=0`.

## 2026-08-15 — `.165` is on a 100Mb link; two measurement traps found first

Chasing a suspected "10Gbit limit" between `.165` and the Freebox. The
limit is real but was the opposite of the framing: **`.165`'s physical NIC
negotiates 100Mb/s**, ~12 MB/s. The host carries `pg02` (PG **leader**,
streaming to `pg01` on `.200`), `etcd-1`, `k8s-cp-01`, `k8s-worker-01`, and
the Garage LXC backing Longhorn backups + Zot's registry blobs. All of it
crosses that link. **Open** — not yet isolated to switch vs. cable.

**Trap 1 — `vmbr0` reports a fake `10000Mb/s`.** A sweep built on
`ethtool $(ip -o route get 1.1.1.1 | awk '{print $5}')` returned
`10000Mb/s` for all three PVE hosts. The default-route interface on a PVE
host is the **bridge**, and a Linux bridge has no PHY, so the driver
reports a synthetic 10G. This is almost certainly where the original
"10Gbit" figure came from. Enumerate real devices instead — bridges,
`veth`, and `tap` have no `device` symlink in sysfs:

```bash
for d in /sys/class/net/*/device; do
  n=$(basename $(dirname $d)); echo -n "$n: "; ethtool $n | grep -E "^\s+Speed"
done
```

**Trap 2 — the flat LAN is not physically uniform.** The corrected sweep
gave `.165` 100Mb, `.200` and `.161` 1000Mb. The inference drawn — "the
switch is fine, so it's `.165`'s cable" — was **wrong**, because it assumed
all three shared the switch. They don't: **only `.165` goes through the
TP-Link; `.200` and `.161` are cabled straight to the Freebox.** Their
1000Mb proves the *Freebox ports* are gigabit and says nothing about the
switch. Two hosts on a different path are not a control group.

`ARCHITECTURE.md` §3 described the LAN as flat and said nothing about
physical uplinks, which is what made the bad assumption easy. Both it and
`docs/infrastructure-actual.md` §3 now carry the per-host path table.

Generalizable: **a logically flat LAN says nothing about physical paths.**
Before comparing link speeds across hosts, confirm they traverse the same
cabling — otherwise the comparison silently changes two variables at once.

**Trap 3 — "the switch" was never one hop.** Photos of the rack settled
two things at once. The switch is a **`TL-SG108E`** — 8-port *Gigabit*
Easy Smart — and its other ports light the `1000M` LED, so the switch is
exonerated outright. But `.165` never reaches it directly: the path runs
through **in-wall structured cabling terminated on a `C5e` patch panel**
(ports labeled per room). Real chain:

```
.165 NIC → patch cable → wall socket → in-wall run
         → C5e patch panel → patch cable → TL-SG108E → Freebox
```

Five segments and four terminations, where the whole investigation had
been reasoning about "the cable" as a single object.

**Trap 4 — there is a second switch, and it makes the panel irrelevant.**
`.165` shares an **unidentified switch in the room** with the Pi 4
(`192.168.1.55`), *before* the wall. Full chain:

```
.165 NIC → patch cable → ROOM SWITCH (unidentified, shared with the Pi)
         → patch cable → wall socket → in-wall run
         → C5e patch panel → patch cable → TL-SG108E → Freebox
```

This retroactively killed the hypothesis recorded above. **Ethernet
negotiates per segment**: `ethtool nic0` reports only the link between
`.165`'s NIC and whatever it is *directly* plugged into — the room switch.
The wall run, the patch panel and the `TL-SG108E` are downstream and
cannot influence that number at all, so no punch-down or split run
explains the 100Mb/s. Kept here rather than deleted, because a
confidently-argued theory about hardware two hops beyond the measurement
is exactly the failure worth remembering.

Narrowed to one segment, four suspects: the room switch is a 10/100 model
(most likely), its port, `.165`'s patch cable, or `nic0` autoneg forced.

Four traps, one shape: **each wrong turn came from treating an
abstraction as the physical thing.** `vmbr0` for a NIC, "flat LAN" for
uniform cabling, "the switch" for a five-segment path, and then the wrong
switch entirely. Link-layer debugging has to be done against the topology
that physically exists — which here meant going and looking at it twice.

**Root cause: the room switch is a 10/100 fast-ethernet unit.** Confirmed
by inspecting it. It cannot do gigabit at all, so `.165` was hard-capped
at ~12 MB/s no matter what any cable did. Fix: replace with any gigabit
switch — unmanaged is fine, VLAN capability already exists at the rack on
the `TL-SG108E`.

The user's opening instinct — "buy a cheap TP-Link gigabit switch" — was
correct from the start. It was aimed at the wrong switch, and the
investigation spent four rounds establishing *which* one. Both of the
early recommendations to buy hardware were wrong: the first because the
target device was already gigabit, the second because the whole purchase
was called off. The winning move was cheap and physical each time — read
the label, look at the LEDs, count the hops.

Still unverified: **per-segment link speed is not end-to-end throughput.**
Once the room switch is gigabit its *uplink* renegotiates against the
in-wall run, which has never been measured. If that punch-down carries
only 2 pairs it comes up at 100Mb and the ceiling simply moves one hop
out — the trap-3 hypothesis would return, correctly this time, as the
*next* bottleneck rather than this one. Confirm with
`iperf3 -c 192.168.1.200` from `.165` (expect ~940 Mbit/s), and check the
`Router salon` uplink LED on the `TL-SG108E` while at it. `ethtool`
describes one segment at a time and will never answer this.

Worth knowing for later: the `TL-SG108E` is the *Easy Smart* model, so it
has a web UI (`192.168.0.100`, off-subnet — reach it via a temporary
`ip addr add 192.168.0.50/24 dev <iface>`) exposing per-port stats and
error counters, plus **802.1Q VLANs, LACP and port mirroring**. Already
owned, never configured — and the only route to segmenting this LAN,
since the Freebox has no VLANs.
