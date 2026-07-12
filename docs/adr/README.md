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
| [0004](0004-gitops-pattern-c-registry-applicationset.md) | GitOps Pattern C (registry + ApplicationSet) | Accepted |
| [0005](0005-argocd-install-helm-not-kubespray-addon.md) | ArgoCD via Helm, not kubespray addon | Accepted |
| [0006](0006-reject-infisical-as-ssh-tls-ca.md) | Infisical as SSH/TLS CA | Rejected |
| [0007](0007-reject-vagrant-for-proxmox.md) | Vagrant for Proxmox provisioning | Rejected |
| [0008](0008-reject-flatcar-vm-os.md) | Flatcar as VM OS | Rejected |
| [0009](0009-reject-wireguard-tailscale.md) | Wireguard / Tailscale | Rejected |
| [0010](0010-reject-external-managed-postgres.md) | External managed Postgres | Rejected |
| [0011](0011-reject-multi-region-dr-service-mesh.md) | Multi-region / DR / GPU multi-tenancy / service mesh | Rejected |
| [0012](0012-reject-gitops-for-proxmox.md) | GitOps-managed Proxmox | Rejected |
| [0013](0013-pve-node-161-sleep-risk-mitigation.md) | `.161` sleep-risk mitigation | Proposed |
| [0014](0014-pve-storage-layout-zfs-vs-local-zfs.md) | PVE storage layout: ZFS pool vs `local-zfs` | Proposed |
| [0015](0015-kubespray-inventory-submodule-version-alignment.md) | Kubespray inventory ↔ submodule version alignment | Proposed — blocks `cluster.yml` |
| [0016](0016-k8s-endpoint-naming.md) | K8s API endpoint naming | Proposed |
| [0017](0017-second-control-plane-member.md) | Second control-plane / etcd member | Proposed |
| [0018](0018-cilium-ebpf-offload-flip.md) | Cilium eBPF offload flip | Proposed |
| [0019](0019-longhorn-rollout-specifics.md) | Longhorn rollout specifics | Proposed |
