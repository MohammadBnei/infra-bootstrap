# DECISION

Settled-decisions log for the `ukubi` homelab cluster and the
`infra-bootstrap` bootstrapping for it. This is the WHY: rationale for
choices that were never really in question, plus a quick-reference list
of things not to propose. It is **not** a spec doc — target topology and
specs live in [`ARCHITECTURE.md`](ARCHITECTURE.md). Full alternative-weighing
for anything that had real competing options, was reversed, was
rejected, or is still open lives in [`docs/adr/`](docs/adr/README.md),
one file per proposition, each independently trackable by status.

Any doc, code, comment, or memory that contradicts this file or an
`Accepted` ADR is overridden by them until the file/ADR itself is
updated.

## Reading order (for AI agents)

1. This file (`DECISION.md`) — hard prerequisite.
2. [`ARCHITECTURE.md`](ARCHITECTURE.md) for target topology/specs.
3. [`docs/adr/`](docs/adr/README.md) for the reasoning behind any
   specific decision, and for anything still `Proposed`.
4. [`docs/infrastructure-actual.md`](docs/infrastructure-actual.md) for
   current live state, and [`docs/secrets.md`](docs/secrets.md).
5. [`inventory/ukubi/README.md`](inventory/ukubi/README.md) for current
   cluster layout deltas.
6. Then everything else (group_vars, playbooks, code).

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

## 2. Locked decisions (no dedicated ADR — never really in question)

- **Physical topology resolved 2026-07-05:** `.165` stays in service as
  the primary PVE host; `.200` and `.161` are added after reinstall. See
  `ARCHITECTURE.md` §1 for the host table.
- **MetalLB is L2-only** — the Freebox blocks BGP, so there was never a
  real BGP option to weigh. See `ARCHITECTURE.md` §3 for the pool/VIP.
- **Secrets policy:** all secrets flow through Infisical, fetched at run
  time, per the schema in `docs/secrets.md`. Never committed to
  this repo.
- **DNS authority:** Pi-hole on Pi 4 (`.55`) is authoritative for
  `bnei.lan`; `bnei.dev` is external via Cloudflare. See
  `ARCHITECTURE.md` §3 for target records.
- **Postgres has no witness node and no automatic failover** in the
  current design — 2 data VMs in primary/replica mode only, no 3-node
  Patroni quorum. Simplicity over full HA at this scale.
- **K8s nodes are always QEMU VMs, never LXC** — kernel isolation, GPU
  passthrough, CNI compatibility, and debuggability all need a real
  kernel per node.
- **Workflow discipline:**
  - All changes via feature branch + PR. No direct push to `main`.
  - Greenfield cluster runs use `cluster.yml`, **never** `scale.yml`
    (`scale.yml` doesn't include the control-plane join role).
  - Post-cluster-up hooks write real infra state into
    `docs/infrastructure-actual.md`; captured kubespray/pigsty outputs
    go into Infisical per `docs/secrets.md`.
  - Single cutover event for the current migration — downtime is
    accepted; cleaner than a rolling migration for a single-operator
    homelab.
  - Operations live on Hermes (hermesagent LXC) — no operator-workstation
    action required from the user when an agent can do it via API + SSH.

## 3. Do not propose (quick reference — see linked ADR for full reasoning)

Never propose these without an explicit user greenlight, even as a
"better alternative":

- ❌ **cert-manager** as a secondary cert engine — [ADR-0001](docs/adr/0001-ingress-traefik-ingressroute-over-gateway-api.md)
- ❌ **DNS-01 / OVH plugin** as the cert engine — [ADR-0001](docs/adr/0001-ingress-traefik-ingressroute-over-gateway-api.md)
- ❌ **Gateway API for app HTTPS routing** — [ADR-0001](docs/adr/0001-ingress-traefik-ingressroute-over-gateway-api.md)
- ❌ **Plain K8s Ingress or Ingress-NGINX** — [ADR-0001](docs/adr/0001-ingress-traefik-ingressroute-over-gateway-api.md)
- ❌ **Ceph** — [ADR-0002](docs/adr/0002-storage-longhorn-over-ceph-nfs.md)
- ❌ **Cilium Gateway API / `cilium_l2announcements: true`** while
  MetalLB owns L2 — [ADR-0003](docs/adr/0003-cni-cilium-chaining-over-kube-proxy-replacement.md)
- ❌ **Per-app Helm chart** — [ADR-0004](docs/adr/0004-gitops-pattern-c-registry-applicationset.md)
- ❌ **Per-app flat ArgoCD Apps that bypass the registry** — [ADR-0004](docs/adr/0004-gitops-pattern-c-registry-applicationset.md)
- ❌ **App-of-Apps with an explicit `root.yaml`** — [ADR-0004](docs/adr/0004-gitops-pattern-c-registry-applicationset.md)
- ❌ **ArgoCD as a kubespray addon** — [ADR-0005](docs/adr/0005-argocd-install-helm-not-kubespray-addon.md)
- ❌ **Infisical as SSH CA / TLS CA** — [ADR-0006](docs/adr/0006-reject-infisical-as-ssh-tls-ca.md)
- ❌ **Vagrant for Proxmox provisioning** — [ADR-0007](docs/adr/0007-reject-vagrant-for-proxmox.md)
- ❌ **Flatcar as VM OS** — [ADR-0008](docs/adr/0008-reject-flatcar-vm-os.md)
- ❌ **Wireguard / Tailscale** — [ADR-0009](docs/adr/0009-reject-wireguard-tailscale.md)
- ❌ **External managed Postgres** — [ADR-0010](docs/adr/0010-reject-external-managed-postgres.md)
- ❌ **Multi-region / DR / GPU multi-tenancy / service mesh** — [ADR-0011](docs/adr/0011-reject-multi-region-dr-service-mesh.md)
- ❌ **GitOps-managed Proxmox** — [ADR-0012](docs/adr/0012-reject-gitops-for-proxmox.md)
- ❌ **`acme.json` on `emptyDir`** — PVC mandatory (see ADR-0001).
- ❌ **Storing SSH keys, kubeconfig, etcd certs, OVH tokens, or anything
  sensitive in this repo.** Use Infisical.
- ❌ **Proxmox API tokens committed to this repo.** Fetch from Infisical
  at run time.

## 4. Known drift vs `inventory/ukubi/` (must be cleaned before next `cluster.yml` run)

These items in working-tree files contradict this decision log. The
agent **must** reconcile them before invoking anything that consumes
them:

- **`inventory/ukubi/README.md`** still references the "libvirt ukubi
  cluster on `server1`" as a coexisting cluster. Under greenfield that
  cluster is gone.
- **`inventory/mycluster/`** exists as a separate inventory (legacy).
  Under greenfield it is obsolete — flag for deletion in a later PR.

## 5. Maintenance

- **New architecturally-significant proposal** (real alternatives, a
  reversal, or genuinely open) → write an ADR first, `Status: Proposed`,
  in `docs/adr/`.
- **When an ADR resolves** → flip its status (`Accepted` / `Rejected` /
  `Superseded by ADR-000N`), update `docs/adr/README.md`'s index, and if
  accepted, add a linking bullet to §2 or §3 above.
- **Simple conventions that were never really in question** go straight
  into §2 of this file without an ADR — don't manufacture ceremony for
  non-decisions.
- When a previously accepted decision is reversed, the old ADR gets
  `Superseded by ADR-000N` (new ADR number) — never silently delete or
  edit history out of an ADR.

---

_Last refreshed: 2026-07-12._
_Source of truth: this file (`DECISION.md`) for WHY, `docs/adr/` for
per-decision reasoning, `ARCHITECTURE.md` for WHAT._
