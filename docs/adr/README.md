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
| [0009](0009-reject-wireguard-tailscale.md) | Wireguard / Tailscale | Rejected — superseded for SSH by ADR-0055 |
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
| [0037](0037-worker-cpu-capacity-vs-agent-fleet-burst.md) | Worker node CPU capacity vs. agent-fleet session bursts | Proposed |
| [0038](0038-cloudflare-proxy-dns01-and-origin-lock.md) | Proxy `bnei.dev` through Cloudflare; `le` moves to DNS-01; origin locked to Cloudflare | Accepted (implemented 2026-08-18 — proxied wildcard used instead of the Decision 7 renames; Decisions 3 and 5 also revised. See the in-ADR implementation note) |
| [0039](0039-authentik-identity-layer.md) | authentik as the cluster's identity layer (forwardAuth + OIDC + passkeys) | Accepted (Native OIDC tier built; forwardAuth/passkeys pending — see its implementation notes) |
| [0040](0040-cluster-internal-hardening-baseline.md) | Cluster-internal hardening baseline (etcd encryption, audit log, Cilium encryption, PSA, default-deny) | Accepted (Decisions 1–4/7/9 built and verified live; 5 default-deny, 6 PSA labels and 8 AppProject are not — see the in-ADR implementation note) |
| [0041](0041-fleet-native-oidc-not-forwardauth.md) | `fleet.bnei.dev` moves to the Native OIDC tier (amends ADR-0039 Decision 3); previews stay on forwardAuth | Accepted (implemented 2026-08-21; Decision 3 reversed same-day — basic-admin-auth dropped from the console, see the in-ADR amendment) |
| [0042](0042-pgbackrest-shared-repo-and-restore-command.md) | pgBackRest repo moves to Garage S3; replicas gain a `restore_command` | Accepted (rolled out 2026-08-26; `restore_command` had to go via Patroni's DCS, not `pg_parameters` — see the rollout note) |
| [0043](0043-gpu-node-enablement.md) | GPU node enablement: driver + toolkit via ansible, non-default containerd runtime, `RuntimeClass` per-pod, device plugin as a GitOps platform app | Accepted (rolled out 2026-08-31; needed three post-merge fixes — a YAML bool that rendered as a TOML string, a chart affinity the nodeSelector did not override, and a driver metapackage that was a shim. `.165` reboot re-test outstanding) |
| [0044](0044-stt-grpc-service.md) | `ukubi-stt`: GPU speech-to-text gRPC service — parakeet-rs behind a CUDA gate, gRPC-Web at the edge, shared bearer token, grey-cloud hostname | Proposed (Decision 1's gate **passed** 2026-08-31 — engine confirmed; Decisions 2–6 unbuilt) |
| [0045](0045-model-weights-out-of-the-image.md) | Model weights on a node-local `local-path` PVC; CUDA libraries stay in the image as the ABI pin | Accepted |
| [0046](0046-streaming-recognition.md) | Realtime streaming: Nemotron 3.5 as a lazily-loaded second model, per-session state, still chunked unary rather than WebSocket | Accepted |
| [0047](0047-persian-speech-to-text.md) | Persian speech-to-text — a third model, on the CPU, and Arabic that was already working | Accepted |
| [0048](0048-chunk-boundary-word-splitting.md) | A word split across a chunk boundary was a client join bug, not the model — and the correction model we did not build | Accepted |
| [0049](0049-shared-commons-secrets-in-common-app-chart.md) | Shared commons secrets via a dedicated `platform-commons` Infisical project | Accepted |
| [0050](0050-public-oidc-client-for-native-apps.md) | Public OIDC clients for native/browser apps, with PKCE enforced by an authentik policy (Wird) | Accepted |
| [0051](0051-expose-hermes-dashboard.md) | `hermes.bnei.dev`: the Hermes Agent dashboard behind **two** authentik gates (native OIDC + forwardAuth), public client as an upstream gap, break-glass via the hypervisor console | Accepted, **rolled out 2026-10-02** (three authentik worker restarts needed, not two — the policy file rolls back until the application exists; Cloudflare BIC turned out not to affect the plugin, which uses httpx. Outstanding: the Freebox reservation for .72 and a first interactive login) |
| [0052](0052-wird-adminweb-forwardauth.md) | `wird-admin.bnei.dev`: the forwardAuth tier's second provider (`forward_single`), and the HS256-with-client_secret token a proxy provider actually forwards | Accepted (manifests on PR #268, held for a wird image tag; **the `wird_admin` role and its grants are live 2026-10-03** via Pigsty's own playbooks, negatives verified; the `wird-agent` service account is outstanding. Review caught that a proxy provider's `client_id`/`client_secret` cannot be declared — see Decision 3) |
| [0053](0053-hq-dashboard-public-client-loopback-redirect.md) | `hq.bnei.dev`: one public OIDC client for an SPA and MCP clients, a fixed-port loopback redirect as an exception to ADR-0050 Decision 2, a dedicated always-require consent flow as its compensating control | Accepted (client and DB live; app PR pending) |
| [0054](0054-netbird-control-plane-hosting-only.md) | Host a NetBird control plane (server + dashboard, STUN on `.235`) for an external laptops→Pi mesh; no cluster host joins it — a hosting-only carve-out from ADR-0009 | Accepted, live 2026-10-11 (PR 3, Traefik timeouts, open); host-peer rule amended by ADR-0055 |
| [0055](0055-netbird-as-daily-ssh-path.md) | NetBird as the daily SSH path: every host a peer, `platform-admins` via authentik, light runs over the mesh and heavy runs from the hub over the LAN, `:49222` kept as break-glass only — supersedes ADR-0009 for SSH | Accepted (not live; gated on a spike) |
| [0056](0056-mountain-public-live-cluster-view.md) | `mountain.bnei.dev`: a public live 3D view of ukubi, fed by PromQL only (no RBAC), public data by allowlist, unmeasured shown as unmeasured | Accepted (Pigsty user/DB and build runner live 2026-10-14; app registered 2026-10-14, first sync waits for mountain's first image) |
| [0058](0058-shared-notes-silverbullet.md) | Shared notes of M BN and N MG: a git repo of markdown edited through SilverBullet at `notes.bnei.dev`, native OIDC with a verified-email mapping, `shared-notes` group, fenced egress; users/OIDC/git remote held on the PVC as an accepted deviation | Accepted (not live: SilverBullet's own setup is manual) |
| [0057](0057-mountain-visitor-enrollment.md) | mountain visitors: self-service enrollment into `mountain-visitors` only, Turnstile first (keys by `!Env`), a moderated handle, bound to the `mountain` application alone, shared SMTP2GO sender as an accepted risk | Accepted (not live: the Turnstile widget and its Infisical keys are manual) |
