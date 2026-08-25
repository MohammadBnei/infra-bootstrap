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
| Registry | Zot at `registry.bnei.lan:5000` (MetalLB `.234`), blobs on Garage S3, LAN-only plain HTTP — no `IngressRoute`, since Let's Encrypt can't issue for `.lan`. Anonymous pull, htpasswd push. 3-tag retention + GC, `latest` pinned. Images are built on the **`build-runner` LXC**, never in-cluster, **one runner instance per build repo** (`editable-blog`, `agent-fleet`) — see ADR-0034 and the `build-runner-ops` skill |
| Secrets | Infisical (project `infra-bootstrap-1-ge1`, id `8a3fa54f-be22-488a-bf51-55158f65c0f2`, domain `https://infisical.bnei.dev`, env `dev` — see `docs/secrets.md`) |
| Database | Pigsty (vendored in `pigsty/`, has its **own** `pigsty/CLAUDE.md` — don't edit it, it's upstream) |
| Identity/SSO | authentik at `authentik.bnei.dev`, platform app on Pigsty Postgres. Four tiers; Native OIDC (ArgoCD, Grafana, agent-fleet `core`) and forwardAuth (e2e previews, `wedding.bnei.dev/admin`) are live. Everything declared as **blueprints in git** — nothing clicked in the UI. One group, `platform-admins`, read by both ArgoCD and Grafana; local admins deliberately kept as break-glass — see ADR-0039/0041 and the `/authentik-oidc` skill |
| Observability | Prometheus + Grafana (metrics/dashboards), Loki + Grafana Alloy (logs, SingleBinary/filesystem + DaemonSet — see ADR-0027), Alertmanager (routes to Discord). Grafana alerting is native (LogQL rules against Loki), not Loki's Ruler. `common-app-chart`'s `logAlerts:` block lets a user app declare its own log alert rules from its own repo. Metric alerts go the other way — real `PrometheusRule`s through Alertmanager, e.g. Traefik's cert-expiry rule (ADR-0040 Decision 9); Prometheus adopts rules from any chart via `ruleSelectorNilUsesHelmValues: false`. `blackbox-exporter` probes the three **PVE hosts** themselves (`pveproxy:8006`, TCP) — the hypervisors were unmonitored until 2026-08-25. Its companion is the `monitoring-blind` Grafana rule: Prometheus is a StatefulSet and does not reschedule off a dead node, so a host failure can take the evaluator with it — that rule is evaluated by Grafana (a Deployment) instead. Note `ds-prometheus` is **Pigsty's VictoriaMetrics**; the cluster's own Prometheus is `ds-platform-prometheus` |

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
| `docs/bootstrap-test-notes.md` | Real-run incident log — what actually broke and why, distilled into the `k8s-ops`/`ansible-ops` skills. Read before repeating an operation that has been done once |

## Locked decisions (condensed — full detail + rationale in `DECISION.md` and `docs/adr/`)

- Ingress: Traefik + `IngressRoute` only (Gateway API rejected — see
  ADR-0001). Cert engine: Traefik built-in ACME **DNS-01 via Cloudflare**
  (resolver `le`) since ADR-0038 — it was TLS-ALPN-01 until 2026-08-18, and
  had to change before any record could be proxied. `acme.json` on a PVC
  (never `emptyDir`). `le-dns` is a second DNS-01 resolver with its own
  storage file; both now share a provider and a token, so the blast-radius
  split ADR-0033 gave them no longer buys anything. cert-manager stays banned.
- DNS: `bnei.dev` is at Cloudflare with **wildcard A records**. The apex and
  `*.bnei.dev` are **proxied** (ADR-0038, 2026-08-18) — possible only because
  `le` moved to DNS-01 first; under TLS-ALPN-01 a proxied record breaks renewal
  silently. Still grey on purpose: `fleet` (streaming vs CF's 100s timeout),
  `s3` (SigV4 vs path normalization), `*.ente.bnei.dev` (two labels deep — free
  Universal SSL covers apex + one wildcard level only). Adding an app hostname
  needs no DNS change. ADR-0033, ADR-0038.
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
- Container images come from `registry.bnei.lan:5000` (Zot, blobs on
  Garage). LAN-only plain HTTP, no `IngressRoute` — Let's Encrypt cannot
  issue for `.lan`. **Builds run on the `build-runner` LXC, never
  in-cluster** (buildah needs `CAP_SYS_ADMIN` to extract layers; the only
  in-cluster way to grant that is a privileged pod running app-repo
  Dockerfiles). A new build repo needs its own runner *instance* on that
  same LXC — repo-scoped runners are repo-only and personal accounts can't
  register org-level ones, so the box and its buildah image cache are
  shared but the registration never is — *and* adding to the `ACCESS_TOKEN`
  PAT's repo list first. Add it to `build_runner_repos` in
  `ansible/playbooks/build-runner-configure.yml` and re-run — ADR-0034,
  `build-runner-ops` skill.
- Registry retention: **last 3 tags per image plus `latest`**, with
  `deleteUntagged`. `latest` is pinned explicitly because thot's executor
  and agent-fleet's `catalog.go` both float on it. Deliberately **not**
  keyed on pull recency — zot's metaDB is an `emptyDir`, so pull stats
  reset on every restart. Armed (`dryRun: false`) 2026-08-18 after a real
  dry-run pass confirmed nothing deployed was on the delete list; a GC'd blob
  is gone and the image must be rebuilt.
- Storage: `longhorn` is the **default** StorageClass and the only one with
  replication + backups (ADR-0002/0019). `nfs`
  (`nfs-storage.bnei.lan:/export/k8s` via `csi-driver-nfs`, ADR-0036) is a
  non-default class that is **unreplicated and never backed up** (a settled
  decision, not a pending gap) — use it for RWX and regenerable bulk data
  only, never for anything whose loss matters. There is no restore path.
  `local-path` is a node-pinned RWO fallback. Opting out of `longhorn` is
  always an explicit `storageClassName`.
- Greenfield cluster runs use `cluster.yml`, never `scale.yml`.
- Secrets only via Infisical, fetched at run time — never committed.

## Forbidden patterns (quick check — full list + reasons in `DECISION.md` §3 and `docs/adr/`)

cert-manager (still banned — ADR-0038 amended only the DNS-01 half of
ADR-0001's rejection, not this) · Gateway API / Ingress-NGINX / plain
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

- `ansible/playbooks/register-repos.yml`, `pve-postinstall.yml`,
  `garage-configure.yml`, `pihole-configure.yml` and
  `build-runner-configure.yml` are done, committed, and have been run for real
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
- `/authentik-oidc` — connect an app to authentik as an OIDC client
  (ADR-0039): declarative blueprint delivered as a Secret, credentials via
  Infisical, nothing clicked in the UI. Carries the model names and field
  shapes verified against the running instance — notably that `redirect_uris`
  is a list of objects, not strings.
- `/build-runner-ops` — the `build-runner` LXC's GitHub Actions runner
  instances (one per build repo, ADR-0034): add a build repo, inspect
  runner/build/disk state, debug a queued or failing image build.
