# infra-bootstrap

Bootstraps the `ukubi-cluster` homelab: 3 Proxmox VMs → kubespray Kubernetes
→ ArgoCD GitOps + Pigsty Postgres. Secrets flow through Infisical at
runtime, never through this repo.

**`ARCHITECTURE.md` is canonical for target specs/topology; `DECISION.md` +
`docs/adr/` are canonical for decisions/rationale.** This file is a
condensed summary for quick orientation — if they disagree, ARCHITECTURE.md
wins for specs, DECISION.md/docs/adr/ win for decisions, and per
`DECISION.md`'s own §5, a locked decision or spec changes there *first*,
then here. When in doubt, open those files.

## Tech stack

| Layer | Tool |
|---|---|
| Virtualization | Proxmox VE (3 physical hosts), QEMU VMs, Ubuntu 24.04 cloud-init |
| IaC (Proxmox) | Terraform, `bpg/proxmox` provider, local state — see `terraform/README.md`, scoped to `.165` only |
| Kubernetes | kubespray v2.31.0 (`kubespray/` submodule) → K8s v1.35.4 |
| CNI | Cilium, **chaining mode**, kube-proxy retained (IPVS, strict ARP) |
| LB | MetalLB, L2 only, pool `192.168.1.230-250` |
| Ingress | Traefik + `IngressRoute` only — no cert-manager, no Gateway API, no plain Ingress |
| GitOps | ArgoCD, Pattern C (registry + `list`-generator ApplicationSets) |
| Secrets | Infisical (project `infra-bootstrap`, env `dev`) |
| Database | Pigsty (vendored in `pigsty/`, has its **own** `pigsty/CLAUDE.md` — don't edit it, it's upstream) |

## Directory map

| Path | What |
|---|---|
| `ARCHITECTURE.md` | Canonical target topology/specs (the WHAT) |
| `DECISION.md` | Canonical settled decisions, forbidden patterns, drift log (the WHY, short form) |
| `docs/adr/` | One Architecture Decision Record per proposition (Proposed/Accepted/Rejected/Superseded) |
| `docs/` | Secrets schema, actual state, ADRs, runbooks (**mostly TODO**, see below) |
| `kubespray/` | Submodule, pinned v2.31.0 |
| `inventory/ukubi/` | Active kubespray inventory |
| `inventory/mycluster/` | Legacy, flagged for deletion (MISSION §14) — don't extend it |
| `ansible/` | Only `ansible/README.md` exists; the playbooks it describes are **not written yet** |
| `pigsty/` | Vendored Pigsty deployment (own docs/CLAUDE.md) |
| `gitops/` | ArgoCD source of truth — see `gitops/README.md` |
| `k8s-cluster/` | Submodule, separate repo, the GitOps *runtime target* (not managed from here) |
| `terraform/` | Terraform for Proxmox VM/LXC provisioning on `.165` — see `terraform/README.md` |

## Locked decisions (condensed — full detail + rationale in `DECISION.md` and `docs/adr/`)

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

## Forbidden patterns (quick check — full list + reasons in `DECISION.md` §3 and `docs/adr/`)

cert-manager · DNS-01/OVH plugin · Gateway API / Ingress-NGINX / plain
`Ingress` · Cilium Gateway API · per-app Helm chart · App-of-Apps
`root.yaml` · Ceph · Wireguard/Tailscale · Infisical as SSH/TLS CA ·
Vagrant for Proxmox · Flatcar · external managed Postgres · ArgoCD as a
kubespray addon · GitOps-managed Proxmox · secrets/keys/tokens committed
to this repo.

Don't propose any of these without an explicit user greenlight, even as a
"better alternative" — each has a `docs/adr/*.md` recording why it was
rejected, linked from `DECISION.md` §3.

## Current WIP state

This repo is mid-bootstrap, not finished:

- `ansible/playbooks/*.yml` and `docs/runbook-*.md` are referenced by
  `README.md` but **don't exist yet** — don't assume their contents, check
  `ansible/README.md` / `docs/README.md` for the TODO checklist instead.
- `inventory/mycluster/` is legacy and should eventually be deleted.
- `DECISION.md`'s own §4 "known drift" list can itself go stale — don't
  trust it blindly — run the `mission-drift` skill before relying on
  drift claims.

## Workflow rules

- All changes via feature branch + PR. No direct push to `main`.
- Secrets never committed; always fetched from Infisical at run time.
- **This session is not the autonomous "Hermes" agent** described in
  `README.md`/`DECISION.md` §2. The repo's real workflow has a human run
  `ansible-playbook`/`kubespray`/`pigsty` against real infra personally —
  treat those as the user's action, not something to execute unattended.
  See the `ansible-ops` skill.

## Skills

- `/add-app` — add a user app to `gitops/` (keeps registry.yaml and the
  ApplicationSet in sync).
- `/mission-drift` — audit the working tree against `DECISION.md`'s
  locked decisions, `docs/adr/` statuses, and drift log; report-only.
- `/bootstrap` — walk the cluster bootstrap sequence (PVE → kubespray →
  ArgoCD → Pigsty) using the checklists that already exist in the READMEs.
- `/ansible-ops` — build the correct Infisical-wrapped ansible/kubespray/
  pigsty command; never executes destructive runs itself.
- `/terraform-ops` — build the correct Infisical-wrapped terraform command
  for `terraform/` (Proxmox VM/LXC provisioning on `.165`); never executes
  apply/import/destroy itself.
- `/k8s-ops` — operate the live ukubi-cluster (kubectl/helm/ArgoCD) over
  SSH once execution is authorized for the session; encodes the real
  gotchas hit during the first end-to-end bootstrap test (see
  `docs/bootstrap-test-notes.md`).
