# Runbook — cluster-internal hardening (ADR-0040, Phase 6)

Three kubespray runs: etcd encryption at rest, the API audit log, and Cilium
transparent encryption. **Deliberately three runs, not one.**

## 1. Goal

Turn on the control-plane defaults this cluster skipped:

| Run | Change | Reversible? |
|---|---|---|
| **A** | `kube_encrypt_secret_data: true` — Secrets encrypted at rest in etcd | **No**, once Secrets are rewritten |
| **B** | `kubernetes_audit: true` — API audit log, plus an Alloy source to collect it | Yes |
| **C** | `cilium_encryption_enabled` + `wireguard`, and Hubble flow metrics | Yes |

## 2. Prereqs

- **`-e upgrade_cluster_setup=true` on Runs A and B.** Both set apiserver
  flags, and `cluster.yml` alone does **not** reach an already-running
  cluster's kubeadm `ClusterConfiguration` — it completes clean and changes
  nothing. Confirmed on 2026-08-01 (`docs/bootstrap-test-notes.md`). Run C
  does not need it; it touches the CNI, not the apiserver.
- **Ansible version is a hard gate.** kubespray v2.31.0 requires
  `2.18.0 ≤ ansible-core < 2.19.0`. Homebrew's `ansible-playbook` is almost
  certainly newer and fails at kubespray's own assertion. Verified present:
  ```bash
  kubespray-venv/bin/ansible-playbook --version   # core 2.18.18 — OK
  ```
  Recreate if missing:
  `python3.12 -m venv kubespray-venv && kubespray-venv/bin/pip install -r kubespray/requirements.txt`
- **Back up etcd before Run A.** It is the one genuinely one-way step here.
- `ansible_become: true` is already set per-host in `inventory/ukubi/hosts.yaml`,
  so no `-b` on the command line.
- **Each run rolls the control plane or the CNI, and ingress goes down with
  it.** Since ADR-0038, Traefik runs `externalTrafficPolicy: Local` with a
  single replica, so draining its node withdraws the MetalLB VIP entirely —
  a blackhole, not a drain. Schedule accordingly.

Reachability first:

```bash
kubespray-venv/bin/ansible -i inventory/ukubi/hosts.yaml k8s_cluster -m ping
```

## 3. Steps

### Run A — Secrets encrypted at rest

```bash
infisical run --projectId=8a3fa54f-be22-488a-bf51-55158f65c0f2 --env=dev -- \
  kubespray-venv/bin/ansible-playbook \
    -i inventory/ukubi/hosts.yaml \
    -e upgrade_cluster_setup=true \
    --tags control-plane \
    kubespray/cluster.yml
```

Then **rewrite existing Secrets** — encryption is not retroactive, and until
this runs the old plaintext values are still what sits in etcd:

```bash
ssh k9s kubectl get secrets -A -o json | ssh k9s kubectl replace -f -
```

> **After this rewrite there is no way back.** `secrets_encryption.yaml.j2`
> puts the cipher provider first and `identity` last, so plaintext stays
> readable going forward — but once rewritten, removing the flag makes every
> Secret in etcd undecryptable. The key lives at
> `inventory/ukubi/credentials/kube_encrypt_token.creds`, which is gitignored
> (`*.creds`). **Back it up to Infisical.** Losing it is equivalent to losing
> every Secret.

### Run B — API audit log

```bash
infisical run --projectId=8a3fa54f-be22-488a-bf51-55158f65c0f2 --env=dev -- \
  kubespray-venv/bin/ansible-playbook \
    -i inventory/ukubi/hosts.yaml \
    -e upgrade_cluster_setup=true \
    --tags control-plane \
    kubespray/cluster.yml
```

The Alloy side is GitOps, not ansible — it lands when
`gitops/platform/values/alloy/values.yaml` merges. Without it the log is
written, rotated and never read.

### Run C — Cilium WireGuard + Hubble metrics

```bash
infisical run --projectId=8a3fa54f-be22-488a-bf51-55158f65c0f2 --env=dev -- \
  kubespray-venv/bin/ansible-playbook \
    -i inventory/ukubi/hosts.yaml \
    --tags network \
    kubespray/cluster.yml
```

**Then roll every workload.** Enabling encryption makes Cilium recompute pod
MTU downward (~50B VXLAN + ~60B WireGuard), but **already-running pods keep
the veth MTU they were created with**. Until they restart, oversized packets
are dropped inside the tunnel with DF set: handshakes and small requests
succeed while large POSTs, big query results and image pulls hang. It presents
as an intermittent application bug, not a network change.

```bash
for ns in $(ssh k9s kubectl get ns -o name | cut -d/ -f2); do
  ssh k9s kubectl rollout restart deploy,statefulset,daemonset -n "$ns" 2>/dev/null
done
```

## 4. Verification

**Run A** — `kubectl get secret` always shows plaintext (the apiserver
decrypts), so it proves nothing. Read etcd directly, on a control-plane node:

```bash
ETCDCTL_API=3 etcdctl \
  --endpoints=https://127.0.0.1:2379 \
  --cacert=/etc/ssl/etcd/ssl/ca.pem \
  --cert=/etc/ssl/etcd/ssl/member-$(hostname).pem \
  --key=/etc/ssl/etcd/ssl/member-$(hostname)-key.pem \
  get /registry/secrets/default/<a-newly-created-secret>
```

Expect `k8s:enc:secretbox:v1:...` rather than readable YAML. Create a throwaway
Secret first — an old one is still plaintext until the rewrite above.

**Run B** — the file exists and grows on each control-plane node, and reaches
Loki:

```bash
ssh k9s kubectl logs -n monitoring -l app.kubernetes.io/name=alloy --tail=20 | grep -i audit
# then in Grafana: {job="kube-apiserver-audit"}
```

**Run C** — inside the Cilium agent pod. Note the binary is `cilium-dbg`; the
standalone `cilium` CLI is not installed by kubespray:

```bash
ssh k9s kubectl exec -n kube-system ds/cilium -- cilium-dbg status | grep -i encrypt
ssh k9s kubectl exec -n kube-system ds/cilium -- cilium-dbg encrypt status
```

Expect WireGuard enabled with one peer per node. Then transfer something large
between pods to confirm MTU is not silently dropping traffic.

## 5. Rollback

| Run | How |
|---|---|
| **A** | **Only before the Secret rewrite.** Set `kube_encrypt_secret_data: false`, re-run with `upgrade_cluster_setup=true`. After the rewrite, restore etcd from the pre-run backup — there is no flag that recovers it |
| **B** | `kubernetes_audit: false`, re-run. Revert the Alloy values block |
| **C** | `cilium_encryption_enabled: false`, re-run `--tags network`, then roll workloads again so pod MTU returns to the unencrypted value |

Log anything surprising to `docs/bootstrap-test-notes.md`, not to memory.
