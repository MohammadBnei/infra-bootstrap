# MISSION

Authoritative mission-and-ruleset for the **ukubi** homelab cluster and the
`infra-bootstrap` bootstrapping for it. This file is the single source of
truth for design decisions. Any doc, code, comment, or memory that
contradicts it is overridden by this file until MISSION.md itself is updated.

## Reading order (for AI agents)

If you are an AI agent opening a task on this repo or on the cluster it
bootstraps:

1. Read `MISSION.md` first. Hard prerequisite.
2. Then `docs/infrastructure-desired.md` and `docs/secrets.md`.
3. Then `inventory/ukubi/README.md` for current cluster layout deltas.
4. Then everything else (group_vars, playbooks, code).

If two docs disagree, this file wins.

---

## 1. Repository & tooling

- **Repo:** `MohammadBnei/infra-bootstrap`. The legacy
  `MohammadBnei/k8s-cluster` repo is the GitOps runtime target — it is
  **not** gitops-managed from this repo.
- **Kubespray:** pinned via `git submodule` (declared in
  `.gitmodules`). Submodule bumps are a PR of their own — never combined
  with inventory edits.
- **Tooling (operator workstation):** Ansible + Infisical CLI + Helm +
  kubectl. Installed via `bin/install-requirements.sh` once. Secrets
  flow through Infisical at runtime — never committed.

## 2. Physical topology (greenfield)

- **3 Proxmox PVE nodes in the target layout:**
  - `192.168.1.165` — proxmox/bnei, existing primary PVE host.
  - `192.168.1.200` — server1, full PC (PVE reinstall pending).
  - `192.168.1.161` — ex-laptop (PVE reinstall pending, sleep-risk acknowledged).
- **DNS helper host:** `192.168.1.55` — Pi 4 (Debian 13).
  Reserved for Pi-hole / local DNS duties only. It is **not** part of the
  Postgres replication topology.
- **Resolved 2026-07-05:** `.165` stays in service as the primary PVE host;
  `.200` and `.161` are added after reinstall.

## 3. Cluster topology (K8s)

- **Cluster name:** `ukubi-cluster`. Kubernetes DNS service domain:
  `cluster.local` (kubespray default; preserves kubelet join
  compatibility).
- **3 nodes, all QEMU VMs on the active PVE node:**

  | Hostname         | IP            | VMID | vCPU | RAM  | Disk | Role                          |
  |------------------|---------------|------|------|------|------|-------------------------------|
  | `k8s-cp-01`      | 192.168.1.201 | 201  | 2    | 4GB  | 40GB | control plane + etcd + worker |
  | `k8s-worker-01`  | 192.168.1.202 | 202  | 4    | 8GB  | 60GB | worker                        |
  | `k8s-worker-gpu` | 192.168.1.203 | 203  | 6    | 15GB | 100GB| worker + RTX 2070 SUPER PT    |

- **Single CP + single etcd, stacked** (`etcd_deployment_type: kubeadm`,
  static pod managed by kubelet). Adding a second etcd/CPlater means
  re-running `cluster.yml` (NOT `scale.yml`).
- **OS:** Ubuntu 24.04 cloud-init. Cloud-init template VMID 9000 with
  user `core` (NOT `ubuntu`). Per-VM SSH key reference:
  `~/.ssh/id_k8s_vms`. Override at run time via
  `K8S_VM_SSH_KEY_FILE` env var.

## 4. Kubernetes core

- **Version:** v1.35.4. Submodule pinned at the version the inventory is
  authored against — inventory yamls are still authored against
  kubespray v2.23 variable names (despite the submodule being v2.31.0,
  the current latest stable release).
  Until the inventory is ported to v2.31.0 vars, **do NOT run
  `cluster.yml`**. See §Q-D.
- **Container runtime:** containerd.
- **CNI:** Cilium in **chaining mode with kube-proxy retained**.
  Specifically:
  - `cilium_kube_proxy_replacement: false`
  - `cilium_enable_portmap: true`
  - `cilium_l2announcements: false` (MetalLB owns L2)
  - `cilium_enable_hubble: true`, `cilium_enable_hubble_ui: true`.
- **kube-proxy mode:** `ipvs` with `kube_proxy_strict_arp: true`
  (required for MetalLB L2 ARP correctness on the Freebox-switched LAN).

## 5. Ingress & TLS — boundary lock

- **Ingress: Traefik in-cluster.** Deployment, Service `LoadBalancer`
  (MetalLB). Installed via Helm + ArgoCD. Single binary. NO cert
  controller beside it.
- **Routing API: Traefik `IngressRoute` for app HTTPS traffic.**
  Reversed 2026-07-11 (was Gateway API only) — Traefik's ACME resolver
  cannot issue certs for Gateway API listeners at all: Gateway API's
  spec requires a pre-existing `certificateRefs` Secret, and Traefik has
  no built-in bridge from `acme.json` to a Secret. Only cert-manager (or
  an equivalent controller) can produce that Secret, and cert-manager is
  banned below — so `IngressRoute` is the only way to keep native ACME
  HTTP-01 working. No plain Ingress, no Ingress-NGINX.
  - Per-app `IngressRoute`: `entryPoints: [websecure]`,
    `routes[].match: Host(...)`, `tls.certResolver: le`.
  - `ports.websecure.tls.certResolver: le` at the Traefik entrypoint
    level so every IngressRoute router on that port gets ACME
    automatically.
  - Middlewares via `middlewares:` on the `IngressRoute` route
    (Traefik-native).
- **Cert engine: Traefik built-in ACME, HTTP-01.**
  - `certificatesResolvers.le.acme.email: account@bnei.dev`.
  - `certificatesResolvers.le.acme.storage: /data/acme.json` — **PVC-backed,
    mandatory**.
  - `certificatesResolvers.le.acme.httpChallenge.entryPoint: web`.
- **Cert-manager: NEVER ADD.** Don't propose it. Traefik's HTTP-01 is
  sufficient.
- **DNS-01 / OVH plugin: NEVER ADD.** Wildcard `*.bnei.dev` via DNS-01
  requires OVH API token + plugin maintenance; out of scope.
- **`acme.json` constraint:** PVC must be RWX OR `replicas=1`. Never
  `emptyDir`. Concurrent writers corrupt the file. Don't set RWX with
  `replicas > 1` — pick one.

## 6. MetalLB

- **Mode:** L2 only (Freebox blocks BGP).
- **IP range:** `192.168.1.230-192.168.1.250`.
- **Reserved ingress VIP:** `192.168.1.230`.
- **Speaker:** tolerates `node-role.kubernetes.io/control-plane:NoSchedule`.
- **Controller:** 2 replicas with `podAntiAffinity
  requiredDuringSchedulingIgnoredDuringExecution` keyed on
  `app=metallb,component=controller`, `topologyKey=kubernetes.io/hostname`.

## 7. GitOps (ArgoCD) — Pattern C

- **ArgoCD install:** `helm install argocd argo/argo-cd -n argocd
  --create-namespace` post-Kubespray. **Not** via kubespray
  `argocd_enabled: true` (that path is rejected).
- **Bootstrap:** `kubectl apply -f bootstrap/{argocd-application,
  applicationset}.yaml` once. After that, the cluster is gitops-driven
  and the `argocd` Application updates argocd itself.
- **ApplicationSet shape:** Pattern C — no exceptions.
  - Cluster repo (`infra-bootstrap` or whichever is the chosen runtime
    repo): `platform/common-app-chart/` (Helm chart with templates for
    Deployment, Service, IngressRoute).
  - Cluster repo: `apps/registry.yaml` (flat list of apps with
    `name/repoURL/valuesPath/namespace/hostname`).
  - Per-app repos: only `values.yaml` (~5 fields).
  - Multi-source: `sources: [chart-source, ref: app-values]`.
- **ApplicationSet generator:** `list` (NOT git directory — registry
  gives an explicit list of expected repos).
- **Sync policy:** `automated + prune + selfHeal`, `CreateNamespace:
  true`, `ServerSideApply: true`. Retry: 5 attempts, 5s base, 2 factor,
  3 max, 10 maxDuration.
- **Repo credentials:** SSH Deploy Key per repo. Empty passphrase.
  Read-only. Works across GitHub / Gitea / self-hosted GitLab without
  per-host recoding.
- **CRDs:** NOT gitops-managed. CRD lifecycle is outside argocd's
  update path.

## 8. Secrets (Infisical)

- **Project:** `infra-bootstrap` (env `dev`, type `shared` per secret).
- **Folder schema:** per `docs/secrets.md`. Naming
  `SCREAMING_SNAKE_CASE`. Path style `/<area>/[<sub>]`. Never start a
  path with `agent-secrets`.
- **NEVER commit secrets to this repo.** `credentials/*.creds` is
  gitignored. Storing SSH private keys, kubeconfig, etcd peer
  certs/keys, OVH tokens, or anything else sensitive in this repo is a
  hard violation. Generate at run time via
  `infisical secrets get ... --plain --silent > /tmp/key && chmod 600`.
- **Generation policy:** agent-generate-random (32 bytes, base64) for
  all DB passwords and tokens; user-generate-manual for things that
  can't be rotated from a fresh install (K8s vault password, PVE API
  token, Garage root token, ArgoCD-Infisical client id/secret);
  tool-generate-and-capture for things kubespray/pigsty/Garage
  generate during install (etcd peer certs/keys, etc).

## 9. PostgreSQL (Pigsty)

- **2 data VM in primary/replica mode.** No Pi 4 etcd witness. No 3-node
  Patroni quorum in the current design.
- **Source PG 16.4 at `.193`** was the migration source. Cutover is
  complete and the source VM is decommissioned.
- **Cutover:** bootstrap Pigsty with source as initial primary, then
  add replicas. Brief `<5 min` read-only window.
- **Backups:** pgBackRest, local on each VM + off-host 149GB HDD on
  server1. 7 daily / 4 weekly / 3 monthly. PITR 7 days.
- **Observability built-in:** pg_exporter, Grafana dashboard, PgBouncer,
  HAProxy stats.
- **Current state (2026-07-05):** `pg01` (`192.168.1.205`, VMID 205)
  and `pg02` (`192.168.1.207`, VMID 207) both run on `.165` as QEMU VMs
  with primary/replica replication. Automatic failover is **not** part of
  the current design. Redis is currently co-located on `pg02`.

## 10. Storage

- **NFS for K8s app PVs only** (`ReadWriteMany` workloads).
- **Postgres NOT on NFS.** Pigsty data on local PVE host storage.
- **NFS server:** server1 (`.200`) once it has PVE reinstalled; export
  `/home/mohammad/.local/share/k8s-nfs` (legacy path kept).
- **Backup target:** 149GB HDD on server1 (replaces dead Ceph OSD).

## 11. DNS

- **Pi-hole on Pi 4 (`.55`)**, authoritative for `bnei.lan`.
- **Freebox DHCP:** primary DNS = Pi-hole (`192.168.1.55`).
- **External zone:** `bnei.dev` via Cloudflare registrar; wildcard A
  `*.bnei.dev` → public IP / router port-forward.
- **Local K8s record plan (target):**
  - `k8s.bnei.lan` → reserved API VIP `.180` (currently unused;
    re-evaluate when SANs are rotated onto it).
  - `k8s-proxmox-gpu.bnei.lan` → `.201` (current test-build isolation
    name; see §Q-E).

## 12. Workflow discipline

- **All changes via feature branch + PR.** Branch from `main`. Do not
  push to `main` directly.
- **Greenfield runs use `cluster.yml` (NOT `scale.yml`).** `scale.yml`
  doesn't include the control-plane join role.
- **Secrets flow through Infisical**, fetched at run time per
  `docs/secrets.md`.
- **Post-cluster-up hooks:** write infra-real state into
  `docs/infrastructure-actual.md`. Capture generated kubespray/pigsty
  outputs into Infisical per `docs/secrets.md`.
- **Operations live on Hermes (hermesagent LXC).** No operator
  workstation actions required from the user when an agent can do them
  via API + SSH (per the user's "agent does it yourself" expectation).

## 13. Forbidden patterns (NEVER propose without explicit user greenlight)

- ❌ **cert-manager** as a secondary cert engine for this cluster.
- ❌ **DNS-01 / OVH plugin** as the cert engine.
- ❌ **Gateway API for app HTTPS routing** (reversed 2026-07-11 — Traefik's
  ACME resolver can't serve certs to Gateway API listeners without
  cert-manager as a Secret bridge; `IngressRoute` is the lock now).
- ❌ **Plain K8s Ingress or Ingress-NGINX** (Traefik-only).
- ❌ **Cilium Gateway API** (Freebox blocks BGP; Traefik is the lock).
- ❌ **`cilium_l2announcements: true` while MetalLB owns L2** (race over
  the same address pool).
- ❌ **Per-app Helm chart.** Always reuse `platform/common-app-chart`.
- ❌ **Per-app flat ArgoCD Apps that bypass the registry.** All apps go
  through `apps/registry.yaml` + ApplicationSet.
- ❌ **App-of-Apps with explicit `root.yaml`.** ApplicationSet's
  generator is the lock.
- ❌ **Ceph.** NFS is sufficient for homelab.
- ❌ **Wireguard / Tailscale** for this cluster (existing remote-access
  pattern unchanged).
- ❌ **Multi-region / DR / multi-tenancy GPU / service mesh.**
- ❌ **Infisical as SSH CA for VM access / as TLS CA for intra-cluster
  encryption.** [REJECTED 2026-07-11: single-operator homelab has no
  multi-admin credential churn to justify a CA; Infisical would become
  a circular dependency (it runs inside the cluster it'd gate SSH
  access to); no concrete TLS need was named — Cilium's built-in
  encryption (currently off) is the lazy fix if plaintext pod traffic
  is the actual concern.]
- ❌ **Vagrant for Proxmox provisioning.** Manual `qm importdisk` +
  `qm clone` + `qm set --ipconfig0 --sshkeys`.
- ❌ **Flatcar as VM OS.** Debian/Ubuntu + GitOps gives adequate
  immutability with less Day-2 friction.
- ❌ **External managed Postgres.** Self-hosted only.
- ❌ **ArgoCD as a kubespray addon.** Always Helm + `kubectl apply -f
  bootstrap/`.
- ❌ **`acme.json` on `emptyDir`.** PVC mandatory.
- ❌ **Storing SSH keys, kubeconfig, etcd certs, OVH tokens, or anything
  sensitive in this repo.** Use Infisical.
- ❌ **`scale.yml` on a greenfield bootstrap.** Use `cluster.yml`.
- ❌ **Proxmox API tokens committed to this repo.** Fetch from
  Infisical at run time.

## 14. Known drift vs `inventory/ukubi/` (must be cleaned before next cluster.yml run)

These items in working-tree files contradict MISSION.md. The agent
**must** reconcile them before invoking anything that consumes them:

- **`inventory/ukubi/group_vars/k8s_cluster/addons.yml` line
  `cert_manager_enabled: true`** → flip to `false`. Traefik ACME is
  the cert engine.
- **`inventory/ukubi/README.md` "Open questions / risks" mentions
  `v2.31.0 submodule bump`** — pending. Until inventory is ported to
  v2.31.0 vars, running `cluster.yml` will silently use v2.23 vars on a
  v2.31.0 submodule and may apply the wrong default values. Pin a
  consistent pair.
- **`inventory/ukubi/README.md`** still references the "libvirt ukubi
  cluster on `server1`" as a coexisting cluster. Under greenfield that
  cluster is gone.
- **`inventory/mycluster/`** exists as a separate inventory (legacy).
  Under greenfield it is obsolete — flag for deletion in a later PR.

## 15. Open questions (under decision; do not commit without explicit greenlight)

- **Q-B. `.161` laptop as a PVE node** — confirmed by user intent, but
  laptop-sleep risk on quorum is open. Mitigations: forced-wake timer,
  suspend-disabler systemd unit. Decide before first `kubespray
  cluster.yml`.
- **Q-C. Storage layout on PVE nodes** — ZFS pool (snapshots, simple
  cloning) vs `local-zfs` directory (simpler initial; harder to
  snapshot/clone VM disks). Affects VM provisioning.
- **Q-D. Kubespray inventory ↔ submodule version alignment** —
  inventory is on v2.23 var names; submodule is v2.31.0. Pick a
  consistent pair before running cluster.yml.
- **Q-E. Endpoint naming** — `k8s-proxmox-gpu.bnei.lan` (current) vs
  `k8s.bnei.lan` (legacy/libvirt). Decide when promoting from test
  build to production.
- **Q-F. Second control plane + etcd member** — adding a 2nd CP means
  re-running `cluster.yml` against the same inventory (NOT
  `scale.yml`). Decide when.
- **Q-G. CPU offloading on `.200`** — if `.200` has HW eBPF, Cilium
  chaining mode is still safe but unnecessary; we keep chaining mode
  anyway because `.161` laptop may lack eBPF. No flip without
  greenlight.

## 16. Maintenance

- When a locked decision moves, this file is updated FIRST. Reference
  the conversation/diff reason inline.
- When a new decision is locked, add a sub-section in §X or insert a
  new numbered section, tagged with date.
- When a previously locked decision is rejected, leave the section
  with a `[REJECTED YYYY-MM-DD: reason]` tag — don't silently delete
  history.

---

_Last refreshed: 2026-07-05._
_Source of truth: this conversation's decision locks +
`inventory/ukubi/` working tree + `docs/infrastructure-desired.md` +
`docs/secrets.md`._
_Drift flags: see §14._
_Open questions: see §15._
