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
- **K8s control plane is 3-CP/etcd (not 1, not 2), deliberately placed:**
  2 members on the stable hosts (server1, ex-laptop), `k8s-cp-01` (`.165`,
  the host that gets rebooted for gaming) as the minority 3rd — see
  `ADR-0017`. Fronted by a kube-vip VIP at `k8s.bnei.lan`/`192.168.1.180`
  — see `ADR-0016`.
- **Secrets policy:** all secrets flow through Infisical, fetched at run
  time, per the schema in `docs/secrets.md`. Never committed to
  this repo.
- **DNS authority:** Pi-hole on Pi 4 (`.55`) is authoritative for
  `bnei.lan`; `bnei.dev` is external, hosted at **Cloudflare** (registration
  stays at Squarespace) with **wildcard A records** — `*.bnei.dev`,
  `*.ente.bnei.dev`, `*.e2e.bnei.dev`, plus the apex. Adding an app hostname
  no longer needs a DNS change. **The apex and `*.bnei.dev` are proxied
  (orange cloud) as of 2026-08-18** — [ADR-0038](docs/adr/0038-cloudflare-proxy-dns01-and-origin-lock.md).
  That became possible only because `le` moved to DNS-01 first; under
  TLS-ALPN-01 a proxied record breaks renewal silently, which is why ADR-0033
  declined proxying. Deliberately still grey: `fleet` (ConnectRPC streaming vs
  Cloudflare's 100s origin timeout), `s3` (SigV4 vs proxy path normalization),
  and `*.ente.bnei.dev` (two labels deep — free Universal SSL covers the apex
  plus one wildcard level only). See [ADR-0033](docs/adr/0033-dns-to-cloudflare-and-dns01-wildcard.md),
  `docs/runbook-dns-cloudflare-migration.md`, and `ARCHITECTURE.md` §3.
  *Supersedes the previous "manual per-host A records at Squarespace DNS, no
  wildcard" — which was itself a correction of an older "Cloudflare" error
  (ADR-0030 point 5); the domain is now genuinely moving there.*
- **Postgres HA: automatic failover via Patroni + etcd is accepted
  behavior, DCS is a 3-node etcd quorum.** Reverses the earlier "no
  automatic failover" stance once a live check (2026-07-30) showed
  Patroni had already auto-promoted the replica for real — the roles in
  every doc were flipped from live reality until then. 2 PG data VMs
  (`.165` + server1) + a 3rd etcd-only witness VM on ex-laptop for real
  DCS quorum, mirroring the k8s 3-CP/etcd placement logic. See
  `ADR-0029`.
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
- **CI runs in-cluster, not on GitHub-hosted runners:** GitHub-hosted
  runners can't reach the cluster's K8s API (LAN-only `.bnei.lan`, no VPN
  per ADR-0009). A self-hosted runner lives in-cluster instead, RBAC-scoped
  to `vos`/`vos-dev` only (no cluster-wide access) — see
  [ADR-0022](docs/adr/0022-self-hosted-actions-runner.md). It drives
  `common-app-chart`'s `hooks:` (guard-railed ArgoCD PreSync/PostSync
  `Job`s) and `oneOffJobs:` (suspended `CronJob`s + a git-committed ledger,
  triggered by a generic reusable workflow) — see
  [ADR-0023](docs/adr/0023-common-app-chart-hooks-and-oneoff-jobs.md).
- **`thot` (agent-fleet's standing cluster agent) holds a cluster-wide
  `ClusterRole`** — the broadest standing grant in the cluster after the
  human operator's own break-glass access, deliberately excluding
  `rbac.authorization.k8s.io`, `secrets`, and node-mutation verbs. Design
  decision lives in agent-fleet's own ADR-0035; the concrete RBAC verb
  table and Alertmanager fan-out routing are this repo's own call — see
  [ADR-0032](docs/adr/0032-thot-rbac-and-alerting.md).
- **Centralized logging: Loki (SingleBinary, filesystem storage) + Grafana
  Alloy (DaemonSet)** — over ClickHouse (too heavy for this cluster's log
  volume, no native Grafana integration) and over Promtail (Alloy's OTLP
  support is needed anyway for planned trace/metric instrumentation). Log
  alerting is Grafana-native, not Loki's Ruler and not routed through
  Alertmanager. See [ADR-0027](docs/adr/0027-logging-loki-alloy-over-clickhouse-promtail.md).

- **Three StorageClasses, and `longhorn` is the default.** Anything whose
  loss would be an incident goes on `longhorn` (3 replicas, daily snapshots
  to Garage) — that is unchanged, [ADR-0002](docs/adr/0002-storage-longhorn-over-ceph-nfs.md).
  `nfs` (`nfs-storage.bnei.lan:/export/k8s`, `csi-driver-nfs`) is a second,
  **unreplicated class that is never backed up** (decided 2026-08-14 — not
  a pending gap), for ReadWriteMany and for bulk data that can be
  regenerated; it dies with `server1`, so nothing important goes on it, and
  there is no restore path if something does —
  [ADR-0036](docs/adr/0036-nfs-storage-class-for-k8s.md).
  `local-path` remains a node-pinned RWO fallback, [ADR-0019](docs/adr/0019-longhorn-rollout-specifics.md).
  A PVC that sets no `storageClassName` gets `longhorn`; opting into `nfs`
  is always explicit.

- **Container images come from the in-cluster registry: Zot at
  `registry.bnei.lan:5000`, blobs on Garage S3.** LAN-only and plain HTTP
  — `.lan` is a name Let's Encrypt cannot issue for, so there is no
  `IngressRoute`; containerd trusts it via
  `containerd_registries_mirrors` in `inventory/ukubi/group_vars/all/`.
  Anonymous pull, authenticated push (htpasswd). Stateless by
  construction: `dedupe: false` and an `emptyDir` staging dir, so nothing
  durable lives in the cluster.
  Retention is **last 3 tags per image plus `latest`** with
  `deleteUntagged` — keyed on push order, never pull recency, because the
  metaDB holding pull stats is that same `emptyDir` and resets on restart.
  One documented exception: **`ukubi-stt` keeps 2**, because a CUDA + baked-
  weights image is ~5GB against ~2.5GB for the largest other one. Its policy
  must stay ordered *before* the `**` catch-all — zot applies the first
  matching policy, so a repo rule placed after it is silently inert.
  `latest` is pinned explicitly: thot's executor and `agent-fleet`'s
  `catalog.go` both float on it.
  **Images are built on the `build-runner` LXC, never in the cluster** —
  buildah cannot extract layers without `CAP_SYS_ADMIN`, and the only
  in-cluster way to grant that is a privileged pod running app-repo
  `Dockerfile`s. Adding a build repo means **its own runner instance on
  that same LXC** — an entry in `build_runner_repos` — plus adding it to the
  `ACCESS_TOKEN` PAT's repo list first. The registration cannot be shared
  (repo-scoped runners are repo-only; org-level ones need a GitHub org, and
  personal accounts have none); the box and its buildah image cache are.
  Current build repos: `editable-blog`, `agent-fleet`.
  See [ADR-0034](docs/adr/0034-in-cluster-oci-registry-zot-garage-backed.md).
- **Identity is authentik, and nothing is created by clicking.** Single
  sign-on for everything the cluster fronts, deployed as a platform app at
  `authentik.bnei.dev` on Pigsty Postgres. Every provider, application, group
  and policy is a **blueprint in git** — an `InfisicalSecret` whose template is
  the blueprint when it carries an OAuth2 client secret, a plain `ConfigMap`
  when it does not. Four tiers; Native OIDC (ArgoCD, Grafana, agent-fleet
  `core`) and forwardAuth (e2e previews, `wedding.bnei.dev/admin`) are live, the
  WebAuthn critical tier is not. **One group, `platform-admins`**, read by both
  ArgoCD and Grafana, deliberately not authentik's own `authentik Admins`.
  **The local admins on ArgoCD and Grafana stay** — ArgoCD is what deploys
  authentik, so routing its only login through authentik would make an
  authentik outage recoverable by raw `kubectl` alone. mTLS is structurally
  unavailable (Cloudflare terminates TLS), which is why the critical tier is
  passkeys. `/authentik-oidc` is the procedure. See
  [ADR-0039](docs/adr/0039-authentik-identity-layer.md) and
  [ADR-0041](docs/adr/0041-fleet-native-oidc-not-forwardauth.md).
- **Certificate renewal is one token, so it gets an alarm.** Since ADR-0038
  every host in both zones renews through a single `CF_DNS_API_TOKEN`; its
  revocation or expiry stops renewal everywhere with no error anyone sees, on a
  90-day fuse. The `TraefikCertExpiringSoon` rule on
  `traefik_tls_certs_not_after < 21d`
  (`gitops/platform/values/traefik/values.yaml`) is the only control that
  catches it — treat it as load-bearing, not as monitoring garnish. See
  [ADR-0040](docs/adr/0040-cluster-internal-hardening-baseline.md) Decision 9.

## 3. Do not propose (quick reference — see linked ADR for full reasoning)

Never propose these without an explicit user greenlight, even as a
"better alternative":

- ❌ **cert-manager** as a secondary cert engine — [ADR-0001](docs/adr/0001-ingress-traefik-ingressroute-over-gateway-api.md). Unchanged and absolute.
- ✅ **DNS-01 is now the cert engine for `le`** — reversed by
  [ADR-0038](docs/adr/0038-cloudflare-proxy-dns01-and-origin-lock.md)
  (2026-08-18), which supersedes this entry's former ⚠️ status. Cloudflare's
  proxy terminates TLS at its edge, so TLS-ALPN-01 cannot renew a proxied
  host — DNS-01 is the prerequisite for proxying anything, not a concession.
  Both `le` and `le-dns` are DNS-01 via Cloudflare, and both remain
  Traefik-native lego with no plugin. **cert-manager is still banned**
  ([ADR-0001](docs/adr/0001-ingress-traefik-ingressroute-over-gateway-api.md));
  only the DNS-01 half of that rejection is amended.
- ❌ **Gateway API for app HTTPS routing** — [ADR-0001](docs/adr/0001-ingress-traefik-ingressroute-over-gateway-api.md)
- ❌ **Plain K8s Ingress or Ingress-NGINX** — [ADR-0001](docs/adr/0001-ingress-traefik-ingressroute-over-gateway-api.md)
- ❌ **Ceph** — [ADR-0002](docs/adr/0002-storage-longhorn-over-ceph-nfs.md)
- ❌ **Cilium Gateway API / `cilium_l2announcements: true`** while
  MetalLB owns L2 — [ADR-0003](docs/adr/0003-cni-cilium-chaining-over-kube-proxy-replacement.md)
- ❌ **Per-app Helm chart** — [ADR-0004](docs/adr/0004-gitops-pattern-c-registry-applicationset.md)
- ❌ **Per-app flat ArgoCD Apps that bypass the registry** — [ADR-0004](docs/adr/0004-gitops-pattern-c-registry-applicationset.md)
- ❌ **App-of-Apps spawning per-app Applications one-by-one** (bypassing
  the registry) — [ADR-0004](docs/adr/0004-gitops-pattern-c-registry-applicationset.md).
  A single flat Application self-syncing `gitops/bootstrap/` itself is
  fine and in use — [ADR-0021](docs/adr/0021-self-syncing-bootstrap-directory.md).
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
- ❌ **Kubernetes-native HPA scale-to-zero (alpha, pre-1.37)** — cluster
  is pinned to 1.35.4, the feature is Alpha in 1.36 with no
  request-buffering for HTTP-fronted apps — [ADR-0031](docs/adr/0031-defer-hpa-scale-to-zero.md)

## 4. Known drift vs `inventory/ukubi/` (must be cleaned before next `cluster.yml` run)

These items in working-tree files contradict this decision log. The
agent **must** reconcile them before invoking anything that consumes
them:

- **`inventory/mycluster/`** exists as a separate inventory (legacy).
  Under greenfield it is obsolete — flag for deletion in a later PR.
- **Resolved (2026-07-30):** `pigsty.yml`/`ARCHITECTURE.md`'s PG role
  labels previously didn't match live reality (`.207` is the current
  Leader, `.205` the Replica, opposite of the old static "pg01/pg02"
  naming) — docs corrected to describe live role rather than static
  naming. See `ADR-0029`.
- **Resolved (2026-07-30): real 3-node etcd DCS quorum is live.**
  `pg-etcd-witness` (`.197`, ex-laptop) applied and joined alongside
  `.205`; all 3 members (`.207`/`.205`/`.197`) confirmed healthy,
  `floor(3/2)+1` = 2 tolerance. See `ADR-0029` and
  `docs/bootstrap-test-notes.md`'s 2026-07-30 entries. **Still open**:
  the end-to-end failover proof (stop `.207`, confirm `.205` promotes +
  VIP follows + DCS survives on 2 of 3) hasn't been performed yet.

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

_Last refreshed: 2026-08-04._
_Source of truth: this file (`DECISION.md`) for WHY, `docs/adr/` for
per-decision reasoning, `ARCHITECTURE.md` for WHAT._
