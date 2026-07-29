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
| LB | MetalLB, L2 only, pool `192.168.1.233-250` |
| Ingress | Traefik + `IngressRoute` only — no cert-manager, no Gateway API, no plain Ingress |
| GitOps | ArgoCD, Pattern C (registry + `list`-generator ApplicationSets) |
| CI/CD | Self-hosted GitHub Actions runner, in-cluster (`gitops/platform/actions-runner/`), RBAC-scoped to `vos`/`vos-dev` only — see ADR-0022. Drives `common-app-chart`'s `hooks:`/`oneOffJobs:` (ArgoCD sync hooks + a ledger-driven reusable workflow for one-time scripts) — see ADR-0023 |
| Secrets | Infisical (project `infra-bootstrap-1-ge1`, id `8a3fa54f-be22-488a-bf51-55158f65c0f2`, domain `https://infisical.bnei.dev`, env `dev` — see `docs/secrets.md`) |
| Database | Pigsty (vendored in `pigsty/`, has its **own** `pigsty/CLAUDE.md` — don't edit it, it's upstream) |
| Observability | Prometheus + Grafana (metrics/dashboards), Loki + Grafana Alloy (logs, SingleBinary/filesystem + DaemonSet — see ADR-0027), Alertmanager (routes to Discord). Grafana alerting is native (LogQL rules against Loki), not Loki's Ruler. `common-app-chart`'s `logAlerts:` block lets a user app declare its own log alert rules from its own repo |

## Directory map

| Path | What |
|---|---|
| `ARCHITECTURE.md` | Canonical target topology/specs (the WHAT) |
| `DECISION.md` | Canonical settled decisions, forbidden patterns, drift log (the WHY, short form) |
| `docs/adr/` | One Architecture Decision Record per proposition (Proposed/Accepted/Rejected/Superseded) |
| `docs/` | Secrets schema, actual state, ADRs, runbooks — most runbooks now exist, see `docs/README.md` status table |
| `kubespray/` | Submodule, pinned v2.31.0 |
| `inventory/ukubi/` | Active kubespray inventory |
| `inventory/mycluster/` | Legacy, flagged for deletion (MISSION §14) — don't extend it |
| `ansible/` | `register-repos.yml`/`pve-postinstall.yml`/`garage-configure.yml` done and run; `vm-provision.yml`/`k8s-node-prereqs.yml` still pending — see `ansible/README.md` status table |
| `pigsty/` | Vendored Pigsty deployment (own docs/CLAUDE.md) |
| `gitops/` | ArgoCD source of truth — see `gitops/README.md` |
| `k8s-cluster/` | Submodule, separate repo, the GitOps *runtime target* (not managed from here) |
| `terraform/` | Terraform for Proxmox VM/LXC provisioning on `.165` — see `terraform/README.md` |

## Locked decisions (condensed — full detail + rationale in `DECISION.md` and `docs/adr/`)

- Ingress: Traefik + `IngressRoute` only (Gateway API rejected — see
  ADR-0001). Cert engine: Traefik built-in ACME HTTP-01, `acme.json` on a
  PVC (never `emptyDir`).
- MetalLB L2 only (Freebox blocks BGP), pool `192.168.1.233-250`, `.233`
  reserved for the Traefik VIP — `.232` is Pigsty's HA floating VIP,
  `.230`/`.231` excluded alongside it.
- ArgoCD Pattern C: `gitops/apps/registry.yaml` (human source of truth) +
  `gitops/bootstrap/apps.applicationset.yaml` (`list` generator) must stay
  in sync. Always reuse `gitops/platform/common-app-chart` — never a
  per-app Helm chart. No App-of-Apps spawning per-app Applications
  one-by-one (bypassing the registry) — but `gitops/bootstrap/` itself is
  self-syncing via one flat `bootstrap` Application (ADR-0021); editing
  that directory and merging to `main` is enough, no manual `kubectl
  apply` needed after the one-time setup.
- Greenfield cluster runs use `cluster.yml`, never `scale.yml`.
- Secrets only via Infisical, fetched at run time — never committed.

## Forbidden patterns (quick check — full list + reasons in `DECISION.md` §3 and `docs/adr/`)

cert-manager · DNS-01/OVH plugin · Gateway API / Ingress-NGINX / plain
`Ingress` · Cilium Gateway API · per-app Helm chart · per-app Applications
spawned one-by-one bypassing the registry · Ceph · Wireguard/Tailscale ·
Infisical as SSH/TLS CA · Vagrant for Proxmox · Flatcar · external managed
Postgres · ArgoCD as a kubespray addon · GitOps-managed Proxmox ·
secrets/keys/tokens committed to this repo.

Don't propose any of these without an explicit user greenlight, even as a
"better alternative" — each has a `docs/adr/*.md` recording why it was
rejected, linked from `DECISION.md` §3.

## Current WIP state

This repo is mid-bootstrap, not finished:

- `ansible/playbooks/register-repos.yml`, `pve-postinstall.yml`, and
  `garage-configure.yml` are done, committed, and have been run for real
  (server1/ex-laptop reinstalled to PVE and joined the corosync cluster,
  see ADR-0020/ADR-0024); `vm-provision.yml`/`k8s-node-prereqs.yml` and
  their runbooks are still TODO — check `ansible/README.md` /
  `docs/README.md` for the current checklist rather than assuming.
- `inventory/mycluster/` is legacy and should eventually be deleted.
- `DECISION.md`'s own §4 "known drift" list can itself go stale — don't
  trust it blindly — run the `mission-drift` skill before relying on
  drift claims.

## Workflow rules

- All changes via feature branch + PR. No direct push to `main`.
- Secrets never committed; always fetched from Infisical at run time.
- Any commit, PR, or other artifact that credits an AI co-author must use
  `Co-Authored-By: ukubi-claude-macbook <noreply@bnei.dev>` — never
  `Claude`/`Claude Code`/`Claude Sonnet 5` etc.
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
