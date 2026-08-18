# Runbook — cluster-internal hardening (ADR-0040, Phase 6)

Three kubespray runs: etcd encryption at rest, the API audit log, and Cilium
transparent encryption. **Deliberately three runs, not one.**

## 1. Goal

Turn on the control-plane defaults this cluster skipped:

| Run | Change | Reversible? |
|---|---|---|
| **A** | `kube_encrypt_secret_data` + `kubernetes_audit` — both apiserver flags | Encryption: **no**, once Secrets are rewritten. Audit: yes |
| **B** | `cilium_encryption_enabled` + `wireguard`, and Hubble flow metrics | Yes |

**Why two runs and not three.** An earlier draft of this runbook listed etcd
encryption and the audit log as separate runs — but both are apiserver flags
applied by the same role, so `--tags control-plane` applies *both* and the
identical command cannot separate them. Splitting them would need a second PR
staging the vars, or an `-e kubernetes_audit=false` override on the first pass,
and neither buys anything: they are one kubeadm `ClusterConfiguration` rewrite
and one apiserver restart either way.

The separation that *does* matter is **apiserver vs CNI**. Rolling the CNI
DaemonSet in the same pass as an apiserver restart is what makes a failure
unattributable, and this repo has been burned by exactly that before.

## 2. Prereqs

- **`-e upgrade_cluster_setup=true` on Run A.** It sets apiserver flags, and
  `cluster.yml` alone does **not** reach an already-running cluster's kubeadm
  `ClusterConfiguration` — it completes clean and changes nothing. Confirmed
  on 2026-08-01 (`docs/bootstrap-test-notes.md`). Run B does not need it; it
  touches the CNI, not the apiserver.
- **Ansible version is a hard gate.** kubespray v2.31.0 requires
  `2.18.0 ≤ ansible-core < 2.19.0`. Homebrew's `ansible-playbook` is almost
  certainly newer and fails at kubespray's own assertion. Verified present:
  ```bash
  kubespray-venv/bin/ansible-playbook --version   # core 2.18.18 — OK
  ```
  Recreate if missing:
  `python3.12 -m venv kubespray-venv && kubespray-venv/bin/pip install -r kubespray/requirements.txt`
- **Back up etcd before Run A.** It is the one genuinely one-way step here.
  ```bash
  ssh k9s kubectl exec -n kube-system etcd-k8s-cp-01 -- etcdctl \
    --endpoints=https://127.0.0.1:2379 \
    --cacert=/etc/kubernetes/ssl/etcd/ca.crt \
    --cert=/etc/kubernetes/ssl/etcd/server.crt \
    --key=/etc/kubernetes/ssl/etcd/server.key \
    snapshot save /var/lib/etcd/pre-adr0040.db
  ```
  That writes inside the etcd pod's `/var/lib/etcd`, which is a hostPath on
  the node — so the file survives the pod. Copy it off the node afterwards;
  a backup that only exists on the machine it protects is not a backup.
- `ansible_become: true` is already set per-host in `inventory/ukubi/hosts.yaml`,
  so no `-b` on the command line.
- **Each run rolls the control plane or the CNI, and ingress goes down with
  it.** Since ADR-0038, Traefik runs `externalTrafficPolicy: Local` with a
  single replica, so draining its node withdraws the MetalLB VIP entirely —
  a blackhole, not a drain. Schedule accordingly.

- **Run from inside `kubespray/`, with relative paths.** Ansible looks for
  `ansible.cfg` in the CURRENT DIRECTORY, not beside the playbook, so invoking
  `kubespray/cluster.yml` from the repo root never loads `kubespray/ansible.cfg`
  and its `roles_path = roles:...` never applies. The run then dies immediately
  with `the role 'dynamic_groups' was not found`, having searched
  `kubespray/playbooks/roles` instead of `kubespray/roles`. This is the same
  invocation `docs/runbook-k8s-bootstrap.md` already uses.

Reachability, and a read-only check that roles resolve at all:

```bash
kubespray-venv/bin/ansible -i inventory/ukubi/hosts.yaml k8s_cluster -m ping

cd kubespray && ../kubespray-venv/bin/ansible-playbook \
  -i ../inventory/ukubi/hosts.yaml --list-tags cluster.yml >/dev/null && echo OK
```

## 3. Steps

### Run A — Secrets encrypted at rest AND the API audit log

One run, both flags — see the note in §1.

```bash
cd kubespray
infisical run --projectId=8a3fa54f-be22-488a-bf51-55158f65c0f2 --env=dev -- \
  ../kubespray-venv/bin/ansible-playbook \
    -i ../inventory/ukubi/hosts.yaml \
    -e upgrade_cluster_setup=true \
    --tags control-plane \
    --become --diff \
    cluster.yml
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

The Alloy side of the audit log is GitOps, not ansible — it lands when
`gitops/platform/values/alloy/values.yaml` merges. Without it the log is
written, rotated and never read.

### Run B — Cilium WireGuard + Hubble metrics

```bash
cd kubespray
infisical run --projectId=8a3fa54f-be22-488a-bf51-55158f65c0f2 --env=dev -- \
  ../kubespray-venv/bin/ansible-playbook \
    -i ../inventory/ukubi/hosts.yaml \
    --tags network \
    --become --diff \
    cluster.yml
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
decrypts), so it proves nothing. Read etcd directly.

Two details verified live on 2026-08-18, both of which an earlier draft of this
runbook got wrong:

- etcd here is a **kubeadm-managed static pod**, so its certs are at
  `/etc/kubernetes/ssl/etcd/{ca.crt,server.crt,server.key}` — NOT the
  `/etc/ssl/etcd/ssl/member-*.pem` layout kubespray uses for external etcd.
- the etcd image is **distroless**: there is no shell, so
  `kubectl exec ... -- sh -c '...'` fails with
  `exec: "sh": executable file not found`. Call `etcdctl` directly.

```bash
# create a throwaway Secret first — pre-existing ones stay plaintext until the
# rewrite above, so an old Secret proves nothing either
ssh k9s kubectl create secret generic enc-probe -n default --from-literal=k=v

ssh k9s kubectl exec -n kube-system etcd-k8s-cp-01 -- etcdctl \
  --endpoints=https://127.0.0.1:2379 \
  --cacert=/etc/kubernetes/ssl/etcd/ca.crt \
  --cert=/etc/kubernetes/ssl/etcd/server.crt \
  --key=/etc/kubernetes/ssl/etcd/server.key \
  get /registry/secrets/default/enc-probe

ssh k9s kubectl delete secret enc-probe -n default
```

Expect the value to begin `k8s:enc:secretbox:v1:...`. Before Run A the same
command returns readable YAML — worth running once beforehand so the
difference is visible rather than assumed.

**Audit log** — the file exists and grows on each control-plane node, and reaches
Loki:

```bash
ssh k9s kubectl logs -n monitoring -l app.kubernetes.io/name=alloy --tail=20 | grep -i audit
# then in Grafana: {job="kube-apiserver-audit"}
```

**Run B** — inside the Cilium agent pod. Note the binary is `cilium-dbg`; the
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
| **A** (encryption) | **Only before the Secret rewrite.** Set `kube_encrypt_secret_data: false`, re-run with `upgrade_cluster_setup=true`. After the rewrite, restore etcd from the pre-run backup — there is no flag that recovers it |
| **A** (audit) | `kubernetes_audit: false`, re-run. Revert the Alloy values block |
| **B** | `cilium_encryption_enabled: false`, re-run `--tags network`, then roll workloads again so pod MTU returns to the unencrypted value |

Log anything surprising to `docs/bootstrap-test-notes.md`, not to memory.
