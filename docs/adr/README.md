# Architecture Decision Records

One file per proposition — Nygard-style ADRs (Title / Status / Context /
Decision / Consequences). For the condensed, non-contentious decisions
that never needed this ceremony, see `../../DECISION.md`. For target
topology and specs, see `../../ARCHITECTURE.md`.

**Status values:** `Proposed` (open, under discussion) · `Accepted`
(locked) · `Rejected` (considered and declined) · `Superseded by
ADR-000N` (replaced by a later decision).

| ID | Title | Status |
|----|-------|--------|
| [0001](0001-ingress-traefik-ingressroute-over-gateway-api.md) | Traefik IngressRoute over Gateway API | Accepted |
| [0002](0002-storage-longhorn-over-ceph-nfs.md) | Longhorn over Ceph / NFS-server plan | Accepted |
| [0003](0003-cni-cilium-chaining-over-kube-proxy-replacement.md) | Cilium chaining mode, kube-proxy retained | Accepted |
| [0004](0004-gitops-pattern-c-registry-applicationset.md) | GitOps Pattern C (registry + ApplicationSet) | Accepted (credential clause amended by 0025) |
| [0005](0005-argocd-install-helm-not-kubespray-addon.md) | ArgoCD via Helm, not kubespray addon | Accepted |
| [0006](0006-reject-infisical-as-ssh-tls-ca.md) | Infisical as SSH/TLS CA | Rejected |
| [0007](0007-reject-vagrant-for-proxmox.md) | Vagrant for Proxmox provisioning | Rejected |
| [0008](0008-reject-flatcar-vm-os.md) | Flatcar as VM OS | Rejected |
| [0009](0009-reject-wireguard-tailscale.md) | Wireguard / Tailscale | Rejected |
| [0010](0010-reject-external-managed-postgres.md) | External managed Postgres | Rejected |
| [0011](0011-reject-multi-region-dr-service-mesh.md) | Multi-region / DR / GPU multi-tenancy / service mesh | Rejected |
| [0012](0012-reject-gitops-for-proxmox.md) | GitOps-managed Proxmox | Rejected |
| [0013](0013-pve-node-161-sleep-risk-mitigation.md) | `.161` sleep-risk mitigation | Accepted |
| [0014](0014-pve-storage-layout-zfs-vs-local-zfs.md) | PVE storage layout: ZFS pool vs `local-zfs` | Accepted (both host portions since amended — server1 by 0024, ex-laptop by 0028) |
| [0015](0015-kubespray-inventory-submodule-version-alignment.md) | Kubespray inventory ↔ submodule version alignment | Accepted |
| [0016](0016-k8s-endpoint-naming.md) | K8s API endpoint naming | Accepted |
| [0017](0017-second-control-plane-member.md) | Second **and third** control-plane / etcd member | Accepted |
| [0018](0018-cilium-ebpf-offload-flip.md) | Cilium eBPF offload flip | Proposed |
| [0019](0019-longhorn-rollout-specifics.md) | Longhorn rollout specifics | Accepted |
| [0020](0020-pve-corosync-cluster.md) | PVE corosync cluster (not 3 independent standalone hosts) | Accepted |
| [0021](0021-self-syncing-bootstrap-directory.md) | Self-syncing `gitops/bootstrap/` directory (scoped App-of-Apps) | Accepted |
| [0022](0022-self-hosted-actions-runner.md) | Self-hosted GitHub Actions runner in-cluster | Accepted (amended by 0034 — image builds run on a separate LXC, outside the cluster; this runner's scope is unchanged) |
| [0023](0023-common-app-chart-hooks-and-oneoff-jobs.md) | `hooks:`/`oneOffJobs:` in common-app-chart, layered values for multi-env | Accepted |
| [0024](0024-server1-single-disk-ext4-no-dedicated-zfs.md) | `server1` reinstalled single-disk, ext4 root, no dedicated ZFS pool | Accepted |
| [0025](0025-repo-credential-shared-pat-not-ssh-deploy-key.md) | Repo credentials via shared HTTPS+PAT, not per-repo SSH deploy key | Accepted |
| [0026](0026-nfs-shared-pve-storage-cross-host-clone.md) | NFS-backed shared PVE storage for cross-host VM template cloning | Accepted |
| [0027](0027-logging-loki-alloy-over-clickhouse-promtail.md) | Centralized logging: Loki + Grafana Alloy over ClickHouse / Promtail | Accepted |
| [0028](0028-ex-laptop-no-dedicated-zfs-pool.md) | `ex-laptop` also has no dedicated ZFS pool | Accepted |
| [0029](0029-postgres-automatic-failover-3-node-etcd-quorum.md) | Postgres automatic failover accepted; 3-node etcd DCS quorum | Accepted |
| [0030](0030-expose-garage-s3-externally.md) | Expose Garage's S3 API externally at `s3.bnei.dev` | Accepted |
| [0031](0031-defer-hpa-scale-to-zero.md) | Defer Kubernetes-native HPA scale-to-zero for user apps | Rejected |
| [0032](0032-thot-rbac-and-alerting.md) | `thot`'s cluster-wide RBAC scope and Alertmanager routing | Accepted |
| [0033](0033-dns-to-cloudflare-and-dns01-wildcard.md) | `bnei.dev` DNS to Cloudflare; DNS-01 wildcard for e2e previews | Accepted |
| [0034](0034-in-cluster-oci-registry-zot-garage-backed.md) | In-cluster OCI registry (Zot, Garage-backed), builds moved in-house | Accepted (builder is an LXC, not a pod — corrected in-ADR after a live failure) |
| [0035](0035-self-hosted-forgejo-authoritative-github-mirror.md) | Self-hosted Forgejo authoritative, GitHub demoted to push-mirror | Proposed |
| [0036](0036-nfs-storage-class-for-k8s.md) | Second, unreplicated `nfs` StorageClass on the existing `nfs-storage` VM | Accepted |
| [0038](0038-cloudflare-proxy-dns01-and-origin-lock.md) | Proxy `bnei.dev` through Cloudflare; `le` moves to DNS-01; origin locked to Cloudflare | Accepted (implemented 2026-08-18 — proxied wildcard used instead of the Decision 7 renames; Decisions 3 and 5 also revised. See the in-ADR implementation note) |
| [0039](0039-authentik-identity-layer.md) | authentik as the cluster's identity layer (forwardAuth + OIDC + passkeys) | Accepted (Native OIDC tier built; forwardAuth/passkeys pending — see its implementation notes) |
| [0040](0040-cluster-internal-hardening-baseline.md) | Cluster-internal hardening baseline (etcd encryption, audit log, Cilium encryption, PSA, default-deny) | Proposed |
