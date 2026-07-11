# infra-bootstrap

Bootstraps the `ukubi-cluster` homelab: 3 Proxmox VMs → kubespray Kubernetes
→ ArgoCD GitOps + Pigsty Postgres. Secrets flow through Infisical at
runtime, never through this repo.

**`MISSION.md` is the canonical source of truth** for every design decision
below. This file is a condensed summary for quick orientation — if the two
disagree, `MISSION.md` wins, and per its own §16, a locked decision changes
there *first*, then here. When in doubt, open `MISSION.md`.

## Tech stack

| Layer | Tool |
|---|---|
| Virtualization | Proxmox VE (3 physical hosts), QEMU VMs, Ubuntu 24.04 cloud-init |
| Kubernetes | kubespray v2.31.0 (`kubespray/` submodule) → K8s v1.35.4 |
| CNI | Cilium, **chaining mode**, kube-proxy retained (IPVS, strict ARP) |
| LB | MetalLB, L2 only, pool `192.168.1.230-250` |
| Ingress | Traefik + Gateway API `HTTPRoute` only — no cert-manager, no Ingress/IngressRoute |
| GitOps | ArgoCD, Pattern C (registry + `list`-generator ApplicationSets) |
| Secrets | Infisical (project `infra-bootstrap`, env `dev`) |
| Database | Pigsty (vendored in `pigsty/`, has its **own** `pigsty/CLAUDE.md` — don't edit it, it's upstream) |

## Directory map

| Path | What |
|---|---|
| `MISSION.md` | Canonical design decisions, forbidden patterns, drift log |
| `docs/` | Secrets schema, infra-desired/actual state, runbooks (**mostly TODO**, see below) |
| `kubespray/` | Submodule, pinned v2.31.0 |
| `inventory/ukubi/` | Active kubespray inventory |
| `inventory/mycluster/` | Legacy, flagged for deletion (MISSION §14) — don't extend it |
| `ansible/` | Only `ansible/README.md` exists; the playbooks it describes are **not written yet** |
| `pigsty/` | Vendored Pigsty deployment (own docs/CLAUDE.md) |
| `gitops/` | ArgoCD source of truth — see `gitops/README.md` |
| `k8s-cluster/` | Submodule, separate repo, the GitOps *runtime target* (not managed from here) |

## Locked decisions (condensed — full detail + rationale in MISSION.md §5–§13)

- Ingress: Traefik + Gateway API `HTTPRoute` only. Cert engine: Traefik
  built-in ACME HTTP-01, `acme.json` on a PVC (never `emptyDir`).
- MetalLB L2 only (Freebox blocks BGP), pool `192.168.1.230-250`, `.230`
  reserved for the Traefik VIP.
- ArgoCD Pattern C: `gitops/apps/registry.yaml` (human source of truth) +
  `gitops/bootstrap/apps.applicationset.yaml` (`list` generator) must stay
  in sync. Always reuse `gitops/platform/common-app-chart` — never a
  per-app Helm chart. No App-of-Apps `root.yaml`.
- Greenfield cluster runs use `cluster.yml`, never `scale.yml`.
- Secrets only via Infisical, fetched at run time — never committed.

## Forbidden patterns (quick check — full list + reasons in MISSION.md §13)

cert-manager · DNS-01/OVH plugin · IngressRoute / Ingress-NGINX / plain
`Ingress` · Cilium Gateway API · per-app Helm chart · App-of-Apps
`root.yaml` · Ceph · Wireguard/Tailscale · Infisical as SSH/TLS CA ·
Vagrant for Proxmox · Flatcar · external managed Postgres · ArgoCD as a
kubespray addon · secrets/keys/tokens committed to this repo.

Don't propose any of these without an explicit user greenlight, even as a
"better alternative" — MISSION.md §13 records why each was rejected.

## Current WIP state

This repo is mid-bootstrap, not finished:

- `ansible/playbooks/*.yml` and `docs/runbook-*.md` are referenced by
  `README.md` but **don't exist yet** — don't assume their contents, check
  `ansible/README.md` / `docs/README.md` for the TODO checklist instead.
- `inventory/mycluster/` is legacy and should eventually be deleted.
- MISSION.md's own §14 "known drift" list can itself go stale — e.g. it
  currently claims `cert_manager_enabled: true` needs fixing, but
  `inventory/ukubi/group_vars/k8s_cluster/addons.yml` already has it
  `false`. Don't trust either doc blindly — run the `mission-drift` skill
  before relying on drift claims.

## Workflow rules

- All changes via feature branch + PR. No direct push to `main`.
- Secrets never committed; always fetched from Infisical at run time.
- **This session is not the autonomous "Hermes" agent** described in
  `README.md`/`MISSION.md` §12. The repo's real workflow has a human run
  `ansible-playbook`/`kubespray`/`pigsty` against real infra personally —
  treat those as the user's action, not something to execute unattended.
  See the `ansible-ops` skill.

## Skills

- `/add-app` — add a user app to `gitops/` (keeps registry.yaml and the
  ApplicationSet in sync).
- `/mission-drift` — audit the working tree against MISSION.md's locked
  decisions and drift log; report-only.
- `/bootstrap` — walk the cluster bootstrap sequence (PVE → kubespray →
  ArgoCD → Pigsty) using the checklists that already exist in the READMEs.
- `/ansible-ops` — build the correct Infisical-wrapped ansible/kubespray/
  pigsty command; never executes destructive runs itself.
