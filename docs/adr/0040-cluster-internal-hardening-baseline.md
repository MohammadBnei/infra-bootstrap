# ADR-0040: Cluster-internal hardening baseline

**Status:** Accepted (Decisions 1–4, 7 and 9 built; 5, 6 and 8 are not — see the implementation note)
**Date:** 2026-08-18
**Related:** [ADR-0006](0006-reject-infisical-as-ssh-tls-ca.md) (its Consequences name Cilium
encryption as the sanctioned answer to plaintext pod traffic),
[ADR-0003](0003-cni-cilium-chaining-over-kube-proxy-replacement.md) (chaining mode is preserved),
[ADR-0009](0009-reject-wireguard-tailscale.md) (see Decision 3 — this is not that)

## Context

ADR-0038 and ADR-0039 harden the perimeter and the front door. Neither changes what
happens after something is already inside, and inside is where this cluster is
weakest. An audit of the repo found that every containment mechanism a Kubernetes
cluster would normally use is either off by default and never enabled, or explicitly
deferred:

- **Secrets are plaintext in etcd.** `kube_encrypt_secret_data` is unset in
  `inventory/ukubi/group_vars/`, so it takes kubespray's default of `false`. Every
  Secret — the Cloudflare zone token, the Garage root token, the GitHub PAT, every
  database URL — sits unencrypted on all three control-plane nodes and in every
  etcd snapshot.
- **There is no API audit log.** `kubernetes_audit` is likewise unset and defaults
  to `false`. There is no record of who did what against the API server, which also
  means no detection rule downstream can ever be written.
- **There is one NetworkPolicy in the entire cluster**
  (`gitops/platform/thot/networkpolicy.yaml`) and it is ingress-only for a single
  pod. There is no default-deny anywhere. The LAN is a single flat `192.168.1.0/24`
  with no VLANs, so a compromised application pod can reach Pigsty's Postgres VIP,
  Garage, the Proxmox API, Pi-hole and the registry directly.
- **No namespace carries a PodSecurityAdmission label.** Twelve namespaces are
  created implicitly by ArgoCD's `CreateNamespace=true` with no
  `managedNamespaceMetadata`, so every one of them enforces `privileged`.
- **`common-app-chart` has no `securityContext` field at all**, so no application
  deployed through it can be hardened even deliberately. This is already recorded
  in-repo at `gitops/platform/values/searxng/values.yaml` as a skipped hardening step.
- **No ArgoCD `AppProject` exists.** Every Application uses `project: default`,
  which permits any source repository, any destination namespace, and any
  cluster-scoped resource kind.
- **Pod-to-pod traffic is plaintext.** Cilium is the CNI and supports transparent
  encryption; it is off.
- **Hubble is running and feeding nothing.** `cilium_enable_hubble: true` and
  `cilium_enable_hubble_ui: true` are set, but no metrics are exported and no rule
  or dashboard consumes the flow data the cluster is already paying to produce.

None of this is an oversight of a single change; it is the accumulated default state
of a cluster built for function first. This ADR turns the defaults on.

## Decision

1. **Encrypt Secrets at rest** — `kube_encrypt_secret_data: true`.

2. **Enable the API audit log** — `kubernetes_audit: true`. The audit log is written
   to `/var/log/audit/kube-apiserver-audit.log` on a hostPath, **not** to
   `/var/log/pods`, so `gitops/platform/values/alloy/values.yaml` needs an explicit
   file-tail source or the log is produced and never collected. That Alloy change is
   part of this decision, not a follow-up: an audit log nobody reads is a disk-space
   cost with no security value.

3. **Encrypt pod-to-pod traffic with Cilium's transparent WireGuard** —
   `cilium_encryption_enabled: true` **and** `cilium_encryption_type: wireguard`.
   The second variable is not optional: kubespray v2.31.0 defaults
   `cilium_encryption_type` to `ipsec`.

   **This is not what ADR-0009 rejected.** That ADR rejected a WireGuard/Tailscale
   *VPN mesh for remote cluster access*; this is WireGuard as a datapath transport
   between nodes that already trust each other, with no new remote-access path and
   no new listener reachable from outside the LAN. ADR-0006's Consequences name this
   mechanism explicitly — *"the lazy fix is enabling Cilium's built-in encryption
   (currently off) — not standing up a CA"* — so this ADR is executing an
   instruction already on the books rather than reopening a rejection. `DECISION.md`
   §3's flat "Wireguard/Tailscale ❌" entry is annotated to say so, because the
   apparent contradiction will otherwise be re-litigated by every future reader.

   Cilium continues to chain via `cni.chainingMode: portmap`
   (`cilium_enable_portmap: true`), where Cilium still owns the datapath. This is
   *not* the chain-atop-a-foreign-CNI configuration Cilium documents as unsupported
   for encryption. `cilium_kube_proxy_replacement: false` is untouched, so ADR-0003
   stands unchanged.

4. **Export Hubble flow metrics** — `cilium_hubble_metrics: [dns, drop, tcp, flow,
   icmp]`. Note that `cilium_enable_hubble_metrics: true` alone is a **no-op**: the
   chart template renders `hubble.metrics.enabled` from `cilium_hubble_metrics`,
   which defaults to `[]`. `http` is deliberately excluded — L7 visibility means
   Hubble parses application payloads, which is a different privacy and performance
   posture than L3/L4 flow counting and should be its own decision.

5. **Default-deny NetworkPolicy per namespace, with explicit carve-outs.** The
   existing thot policy is `policyTypes: [Ingress]` only and is *not* a template for
   this — a default-deny that omits egress carve-outs breaks CoreDNS resolution,
   Prometheus scrapes into application namespaces, and Traefik reaching its
   backends. The carve-out set is part of the decision, including
   **authentik → `192.168.1.232:5432`**, which is precisely the pod-to-LAN-Postgres
   flow this rule otherwise blocks.

6. **PodSecurityAdmission labels via `managedNamespaceMetadata`** on the
   ApplicationSets, rather than `kube_pod_security_use_default`. The cluster-wide
   variable is blunt and would apply to namespaces nobody has audited; per-namespace
   labels can be raised incrementally. Longhorn, Cilium, `kube-system`, the
   actions-runner and agent-fleet's dynamically-provisioned worker pods need
   `privileged` or `baseline` and are exempted explicitly. This mechanism only
   reaches namespaces ArgoCD creates — `default` (where `authsecret` lives),
   `kube-system` and anything pre-existing are labelled by hand or not at all.

7. **`securityContext` and `podSecurityContext` passthrough in `common-app-chart`**,
   so PSA enforcement is something applications can actually satisfy.

8. **An ArgoCD `AppProject`** replacing `project: default`, restricting source
   repositories, destination namespaces and cluster-scoped kinds to what is actually
   in use.

9. **A certificate-expiry alert** on `traefik_tls_certs_not_after` below 21 days.
   ADR-0038 moves every host's renewal onto a single Cloudflare API token; token
   expiry or revocation becomes a cluster-wide certificate outage with a 90-day
   fuse. This alert is the only control that catches it, and it is cheap.

10. **Every apiserver-flag change requires `-e upgrade_cluster_setup=true`, and the
    three runs are separate.** `docs/bootstrap-test-notes.md` records both halves of
    this from a real run: `cluster.yml` alone "completed clean but changed nothing"
    against an already-running cluster, and the corrected run rewrites static pods
    on all three control-plane nodes simultaneously with a spurious "wait for
    apiserver" fatal. Batching a CNI DaemonSet rollout into the same run as an
    apiserver restart makes any misbehaviour unattributable, so etcd encryption,
    the audit log, and Cilium encryption are three runs, verified independently.

## Consequences

- **Encryption at rest is effectively one-way.** `secrets_encryption.yaml.j2` orders
  providers with the encryption algorithm first and `identity` last, so enabling it
  is safe for existing plaintext Secrets — they stay readable. But it is **not
  retroactive**: existing Secrets remain plaintext in etcd until rewritten
  (`kubectl get secrets -A -o json | kubectl replace -f -`), and once they *are*
  rewritten, removing the flag makes every Secret in etcd undecryptable. Back up
  etcd before the rewrite. This is the one item in this ADR that is not a flag and
  a revert.
- **The encryption key lands in a tracked directory.** `kube_encrypt_token` defaults
  to `lookup('password', credentials_dir + '/kube_encrypt_token.creds ...')` and
  `credentials_dir` is `{{ inventory_dir }}/credentials` — the same directory that
  already contains a committed `kubeadm_certificate_key.creds`. `.gitignore` gains
  `*.creds` **before** this run, not after. (Kubespray does keep the key consistent
  across control-plane nodes: `encrypt-at-rest.yml` slurps an existing
  `secrets_encryption.yaml` and propagates the extracted token via `delegate_facts`,
  and on first enable the lookup resolves once on the Ansible controller. The
  hazard is losing the file, not divergence between nodes.)
- **Enabling WireGuard silently breaks large transfers until every pod restarts.**
  `cilium_tunnel_mode` is at kubespray's default `vxlan` with `cilium_mtu: "0"`
  (auto). Enabling encryption makes Cilium recompute pod MTU downward — roughly 50
  bytes for VXLAN plus 60 for WireGuard — but **already-running pods keep the veth
  MTU they were created with**. Oversized packets are then dropped inside the tunnel
  with DF set: TLS handshakes and small requests succeed, large POSTs, big query
  results and image pulls hang. A full pod rollout after the run is required, or
  `cilium_mtu` is pinned. This presents as an intermittent application bug, not as a
  network change, which is why it is written down here.
- **`cni.enableRouteMTUForCNIChaining` is not available.** It does not exist as a
  kubespray variable in v2.31.0 — setting it in `group_vars` is inert — and it would
  have to go through `cilium_extra_values` as a raw Helm value. It is also the wrong
  knob for portmap chaining, where Cilium sets the MTU itself. Recorded so it is not
  proposed again as the mitigation for the previous bullet.
- **Default-deny is the highest-risk item operationally.** It is the change most
  likely to break something subtle and slowly. It lands last, one namespace at a
  time, with the carve-outs verified before the deny rule is applied.
- **PSA will reject workloads that currently run.** The exemption list in Decision 6
  is a starting point, not a proof; anything missed surfaces as a pod that will not
  schedule.
- **Every `cluster.yml` run is now an ingress outage.** ADR-0038's
  `externalTrafficPolicy: Local` means draining the node holding Traefik withdraws
  the MetalLB VIP entirely. The three runs in Decision 10 are three such windows.
- **`auto_renew_certificates` stays `false` for now.** Control-plane certificates
  expiring silently at one year is a real gap, but flipping it adds a systemd timer
  that restarts control-plane components on a schedule — a different kind of risk
  that deserves its own change rather than riding along with three others.

## Alternatives considered

- **`kube_pod_security_use_default: true`** instead of per-namespace labels.
  Simpler and cluster-wide in one variable. Rejected: it applies a policy to
  namespaces nobody has audited, including `kube-system` and Longhorn, and the
  failure mode is workloads that stop scheduling with no incremental path.
- **A service mesh for pod-to-pod mTLS** (Istio, Linkerd). Rejected by ADR-0011 and
  unchanged here: Cilium's transparent encryption achieves the confidentiality goal
  with a flag, no sidecars, no certificate rotation and no application changes.
- **A non-Infisical internal CA** to issue pod certificates. `ARCHITECTURE.md` §8
  explicitly leaves this open rather than closed. Rejected for this purpose: it
  solves the same problem as Decision 3 at far greater operational cost, and
  ADR-0006 already named Cilium encryption as the preferred answer. A CA may still
  be justified later for something else; it is not justified by this.
- **IPsec instead of WireGuard** for Cilium encryption — it is kubespray's default
  for `cilium_encryption_type` and would avoid the ADR-0009 naming confusion
  entirely. Rejected: Cilium's own guidance favours WireGuard, and choosing a
  weaker-supported mode to dodge a documentation ambiguity is the wrong trade. The
  ambiguity is resolved with a sentence instead.
- **Batch all kubespray changes into one run** to minimise ingress outages.
  Rejected on the evidence in `docs/bootstrap-test-notes.md`: this repo has already
  been burned once by a `cluster.yml` run whose effect could not be attributed, and
  three short windows are cheaper than one unattributable failure.
- **Do nothing internally and rely on the perimeter.** Rejected: a perimeter with
  nothing behind it means the first compromised application pod reaches Postgres,
  Proxmox and the registry, and nothing records that it happened.

## Implementation note — what was actually built (2026-08-24)

Appended, not merged into the sections above, per `DECISION.md` §5.

Decisions 1–4 were executed on **2026-08-18** as the two kubespray runs in
[`docs/runbook-cluster-hardening-adr-0040.md`](../runbook-cluster-hardening-adr-0040.md)
(Decision 10's "three runs" became two — `--tags control-plane` cannot separate
the two apiserver flags, so they went together). Decision 7 shipped earlier, in
PR #157. Decision 9 shipped in this change. Decisions 5, 6 and 8 have no
implementation at all and are the remaining work.

| Decision | State |
|---|---|
| 1 — `kube_encrypt_secret_data` | **Built.** `inventory/ukubi/group_vars/k8s_cluster/k8s-cluster.yml`. Verified live: etcd holds a `k8s:enc:secretbox:v1` envelope |
| 2 — API audit log + the Alloy file-tail source | **Built.** Same file, plus `gitops/platform/values/alloy/values.yaml`. Verified live: audit streams in Loki. The Alloy half needed a correction — tail the log at its **host** path, not the path in the apiserver's flag (PR #170) |
| 3 — Cilium WireGuard | **Built.** `inventory/ukubi/group_vars/k8s_cluster/k8s-net-cilium.yml`, both variables. Verified live: `cilium_wg0` with 4 peers |
| 4 — Hubble flow metrics | **Built**, `[dns, drop, tcp, flow, icmp]`, `http` still excluded |
| 5 — default-deny NetworkPolicy per namespace | **Not built, and the mechanism it names is wrong for this cluster** — see below. A narrower egress-only pilot is in flight on `searxng` (PR #199) |
| 6 — PSA labels via `managedNamespaceMetadata` | **Not built.** No occurrences in `gitops/` |
| 7 — `securityContext` passthrough in `common-app-chart` | **Built** (PR #157), `gitops/platform/common-app-chart/values.yaml` |
| 8 — ArgoCD `AppProject` | **Not built.** Every Application and ApplicationSet is still `project: default` |
| 9 — cert-expiry alert | **Built.** In `gitops/platform/values/traefik/values.yaml`, via the chart's own `metrics.prometheus.prometheusRule.rules` passthrough — see below |
| 10 — separate kubespray runs with `upgrade_cluster_setup` | **Followed**, as two runs rather than three |

### Decision 5 needs a different mechanism than it specifies

Decision 5 says "default-deny **NetworkPolicy** per namespace". A pilot on one
namespace (`searxng`, PR #199) found that plain `NetworkPolicy` **cannot express
the carve-out this cluster needs**, and that writing it anyway takes the
namespace offline.

`nodelocaldns` runs hostNetwork on the link-local `169.254.25.10`, and every
pod's resolver is that address rather than a Service IP. Since Cilium 1.17 —
this cluster runs **1.19.3** — link-local addresses carry the `host` identity,
and Cilium's [L3 policy
docs](https://docs.cilium.io/en/stable/security/policy/layer3/) state that "CIDR
rules do not apply to traffic where both sides of the connection are either
managed by Cilium or use an IP belonging to a node in the cluster (including
host networking pods)". So the obvious `ipBlock: 169.254.25.10/32` DNS carve-out
matches nothing, egress goes default-deny as soon as any rule exists, and DNS
dies for the whole namespace — with no fallback, since
`enable_nodelocaldns_secondary: false`. `toEntities: [host]` is the only way to
say it, and that is a `CiliumNetworkPolicy` field.

Two corrections to the decision's framing follow from the same property:

- **An `except:` on a CIDR rule does not block the node IPs.** CIDR rules do not
  select node identities at all; `policy-cidr-match-mode` is unset, which is its
  default. Node traffic is blocked by the *absence* of a `remote-node` rule.
  Same outcome, different mechanism — and the difference bites whoever later
  adds `remote-node` back for a kubelet scrape.
- **The carve-out list in Decision 5 is incomplete.** It names authentik →
  `192.168.1.232:5432`. The full inventory is larger and includes several flows
  that look internal but are not: ArgoCD, Grafana and agent-fleet `core` all
  reach authentik over `*.bnei.dev`, which leaves the cluster and returns
  through Cloudflare (both origin-lock allowlists carry the pod CIDR
  `10.233.64.0/18` precisely because of this). Longhorn's cross-node
  instance-manager replica sync on `:10000-10250` is nowhere in the ADR and is
  the one flow whose failure is data risk rather than downtime.

The pilot also narrows the ambition. Decision 5's own rationale is that "the
first compromised application pod reaches Postgres, Proxmox and the registry" —
an **egress** problem against the LAN management plane, which is a handful of
rules rather than a per-namespace ingress regime maintained forever. The pilot
implements that narrower shape. Whether the full default-deny is still wanted
afterwards is a question to reopen with a week of Hubble data, not now.

### Decision 9 cost more than the ADR assumed

The ADR calls the alert "cheap", which was true of the rule and false of the
prerequisite: **Traefik was exporting no metrics to Prometheus at all.** The
chart enables the prometheus endpoint by default but leaves
`metrics.prometheus.service` and `.serviceMonitor` off, so the `/metrics`
endpoint existed on :9100 and no scrape target ever pointed at it. Writing the
rule alone would have produced an alert over a metric nobody collected — a
control that reports healthy because it can never fire.

Two further details worth keeping:

- The rule lives in the Traefik chart's `metrics.prometheus.prometheusRule.rules`
  passthrough rather than as a Grafana-managed rule. That keeps the alert next to
  the thing it watches and routes it through the Alertmanager receivers that
  already exist. It also means the alert body is written in a **values file**,
  which Helm does not template — so `{{ $labels.cn }}` passes through intact,
  unlike the Grafana `alerting:` block, which `tpl` re-processes and which has to
  escape its braces.
- Prometheus needed `ruleSelectorNilUsesHelmValues: false`
  (`gitops/platform/values/prometheus/values.yaml`) to adopt a rule authored by
  another chart. Without it the `PrometheusRule` is created, syncs green in
  ArgoCD, and evaluates nothing — the same shape of silent no-op as Decision 4's
  `cilium_enable_hubble_metrics`.
