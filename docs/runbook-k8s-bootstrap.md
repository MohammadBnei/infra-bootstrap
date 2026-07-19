# Runbook — K8s bootstrap (Terraform → kubespray → ArgoCD)

Full kubespray procedure per `docs/README.md`'s index, extended to cover
the two phases that have to happen before kubespray can run at all
(Proxmox VM provisioning) and the one that has to happen right after it
(ArgoCD/GitOps). This is the human-run, from-scratch walkthrough —
`CLAUDE.md` is explicit that a human runs `ansible-playbook`/`kubespray`/
`terraform` against real infra personally; this is not the autonomous
Hermes agent's job.

Postgres/Pigsty is a **separate** runbook —
[`docs/runbook-pg-bootstrap.md`](runbook-pg-bootstrap.md) — because
`pg01`/`pg02` are currently real, imported, `prevent_destroy` production
resources. Don't run that doc's steps casually; read its warning banner
first.

## 1. Goal

Stand up `ukubi-cluster` — Proxmox VMs, kubespray Kubernetes, ArgoCD
GitOps and the platform apps — from a blank or partially-built PVE host,
or extend an existing cluster (e.g. add a worker node).

## 2. Prereqs

One-time PVE host setup. Each of these is a real prerequisite, not
optional — Terraform's first apply fails without them.

- **Proxmox API token + SSH credential** — create the `terraform@pve`
  API token and a dedicated `root@pam` SSH keypair, store both in
  Infisical. Exact commands: `terraform/README.md` §A–C. Needed Infisical
  secrets: `PVE_API_TOKEN`, `PVE_SSH_PRIVATE_KEY` (see `docs/secrets.md`).
- **`snippets` content type on storage** — the qemu-guest-agent cloud-init
  vendor-data snippet (`terraform/cloud-init.tf`) needs it enabled once by
  hand on whatever `template_download_storage_id` points at (default
  `"local"`):
  ```bash
  pvesm set local --content vztmpl,import,iso,backup,snippets
  ```
  Metadata-only, reversible, doesn't touch existing files on that storage.
- **GPU passthrough prereqs, if any node in `k8s_nodes` has `gpu = true`**
  — this is a **check**, not a rebuild: confirm the host is already
  passthrough-ready rather than redoing the original diagnostic work
  (full history in `docs/bootstrap-test-notes.md`'s 2026-07-14 entry).
  ```bash
  pvesh get /cluster/mapping/pci        # confirm the "gpu" mapping exists
  lspci -k -s 0b:00                     # confirm vfio-pci is the bound driver, not nouveau/nvidia
  ```
  If either check fails, IOMMU (AMD-Vi) needs enabling in BIOS and
  `vfio-pci` needs binding to all 4 GPU functions before Terraform can
  attach the device — see the bootstrap-test-notes entry for the full
  procedure (this only needs doing once per physical host).
- **PVE DNS search-domain sanity check** — `k8s-vms.tf` hardcodes each
  VM's cloud-init `dns.domain = "localdomain"` specifically to defend
  against PVE defaulting the search domain to a real public TLD (root
  cause of a systemic ClusterIP-DNS failure documented in
  `docs/bootstrap-test-notes.md`'s 2026-07-13 "round 2" entry). Confirm
  your PVE install's own default doesn't need a matching override:
  ```bash
  pvesh get /nodes/<node>/dns
  ```

## 3. Steps

### 3.1 Terraform phase

`terraform/variables.tf`'s `k8s_nodes` map is the **one** place to change
VM CPU/memory/disk, add/remove a node, or flip its control-plane/etcd/
worker/gpu role. `terraform/k8s-vms.tf` and the generated kubespray
inventory (`terraform/hosts-inventory.tf`) both derive from it — nothing
else needs hand-editing when topology changes.

Example: adding a third node, a plain worker with no GPU:

```hcl
"k8s-worker-02" = {
  vm_id                 = 203
  ip                    = "192.168.1.203"
  cpu_cores             = 4
  memory_dedicated_mb   = 8192
  os_disk_size_gb       = 60
  longhorn_disk_size_gb = null   # falls back to var.longhorn_disk_size_gb
  control_plane         = false
  etcd                  = false
  worker                = true
  gpu                   = false
}
```

After `terraform apply`, `inventory/ukubi/hosts.yaml` is regenerated
automatically with `k8s-worker-02` under `kube_node` — no manual inventory
edit. (Don't hand-edit `hosts.yaml` directly; it's overwritten on the next
apply.)

Invocation (Infisical-wrapped, per `terraform/README.md`):

```bash
infisical run --projectId=<infra-bootstrap-project-id> --env=dev -- \
  bash -c 'PROXMOX_VE_API_TOKEN="$PVE_API_TOKEN" \
           PROXMOX_VE_SSH_PRIVATE_KEY="$PVE_SSH_PRIVATE_KEY" \
           TF_VAR_pve_ssh_private_key="$PVE_SSH_PRIVATE_KEY" \
           terraform -chdir=terraform "$@"' _ plan
```

First-run order (full detail in `terraform/README.md` "First-run order" —
summarized here):

1. `terraform init` / `validate` — no credentials needed.
2. `terraform plan` — expect "will create" for template/K8s VMs/garage,
   and either "will create" or a conflict for pg01/pg02/hermesagent.
3. **Import pg01/pg02/hermesagent** — see the safety procedure at the top
   of `imported.tf`. Don't skip the live-config capture step; those
   variables have no defaults on purpose so a guess can't silently apply.
   `plan -target=<resource>` must show zero changes before moving to the
   next import.
4. **Garage bootstrap** — `garage.tf`'s `null_resource.garage_bootstrap`
   runs the community-scripts.org installer over SSH. **Known-flaky**:
   this installer can drop into an interactive `whiptail` menu instead of
   running non-interactively, and hang indefinitely under Terraform's
   non-interactive SSH provisioner (seen and had to be killed by hand in
   the 2026-07-13 smoke test). Run this one `-target` apply
   interactively and watch it — don't background it or assume it
   completed just because the process is still running.
5. **First real `terraform apply` must use `-target`**, scoped to
   genuinely-new resources (template, `k8s_node` for each node in
   `k8s_nodes`, garage) — see the exact command in `terraform/README.md`
   step 5. This keeps pg01/pg02/hermesagent out of reach of an early,
   broad apply even by accident.
6. Steady-state check: a full `terraform plan` (no `-target`) should show
   `No changes.` on the imported resources and garage every time after.
7. GPU PCI Resource Mapping — see Prereqs above; already done as of
   2026-07-14 on `.165` (`gpu` → `0000:0b:00`, iommu group 2).
8. `snippets` content type — see Prereqs above.
9. Once VMs boot: `ssh -i ~/.ssh/id_k8s_vms core@<node-ip>` to confirm
   cloud-init actually worked before handing off to kubespray.

### 3.2 Kubespray phase

**venv setup** (known gotcha — kubespray v2.31.0 pins `ansible==11.13.0`,
which needs Python ≥3.11 and ansible-core strictly between 2.18.0 and
2.19.0; a Homebrew `ansible` on PATH is too new and must not be used for
kubespray runs — full story in `docs/bootstrap-test-notes.md`'s
2026-07-11 entry):

```bash
/opt/homebrew/bin/python3.12 -m venv kubespray-venv
kubespray-venv/bin/pip install --upgrade pip
cd kubespray && ../kubespray-venv/bin/pip install -r requirements.txt
```

**Inventory** is now auto-generated by Terraform (§3.1 above) — confirm
`inventory/ukubi/hosts.yaml` reflects the topology you expect, but don't
hand-edit it.

**Invocation** — run from *inside* the `kubespray/` submodule directory,
against the relative inventory path, not from the repo root against
`kubespray/cluster.yml`. Running from repo root breaks kubespray's own
`ansible.cfg` `roles_path` resolution (`role 'dynamic_groups' was not
found`) — confirmed twice in `docs/bootstrap-test-notes.md` (2026-07-12
and 2026-07-13 sessions hit this identically):

```bash
cd kubespray
../kubespray-venv/bin/ansible-playbook -i ../inventory/ukubi/hosts.yaml cluster.yml --become --diff
```

Greenfield runs always use `cluster.yml`, never `scale.yml`
(`DECISION.md` §2 — `scale.yml` skips the control-plane join role).

**Verification**:

```bash
kubespray-venv/bin/ansible -i ../inventory/ukubi/hosts.yaml all -m ping
```

### 3.3 ArgoCD / GitOps bootstrap phase

Don't re-derive — the full sequence lives in
[`gitops/README.md`](../gitops/README.md#bootstrap-sequence). Summary as
a table of contents:

1. **Install ArgoCD** — pinned Helm chart version, `server.insecure=true`.
2. **Create bootstrap secrets** — `ansible/playbooks/register-repos.yml`,
   fed by `ansible/playbooks/register-repos.env` (see
   `ansible/README.md`). These three secrets deliberately stay local
   instead of coming from Infisical — Infisical itself isn't up yet at
   this point in a from-scratch rebuild.
3. **Apply bootstrap manifests** —
   `kubectl apply -f gitops/bootstrap/traefik-crds/` then
   `kubectl apply -f gitops/bootstrap/`.
4. **Watch it come up** — `kubectl -n argocd rollout status deploy/argocd-server`.

Known convention worth repeating here: secrets are rendered locally with
`kubectl create secret --dry-run=client -o yaml` and piped straight into
`kubectl apply -f -` over the existing SSH connection to `k8s-cp-01` —
never write a kubeconfig or credential file onto the operator's machine
or the VM disk (see `ansible/README.md`'s "Execution model" and the
`k8s-ops` skill).

## 4. Verification

- `kubectl get nodes -o wide` — all nodes `Ready`.
- `kubectl -n argocd get applications` — all `Synced`/`Healthy` (Traefik
  is a standalone Application outside the shared ApplicationSet — see
  `gitops/README.md`'s note on `skipCrds`).
- MetalLB ingress VIP `192.168.1.233` reachable; `open https://argocd.bnei.dev`
  resolves through Traefik.

## 5. Rollback

- **Terraform layer** — for a node added via `k8s_nodes`:
  `terraform apply -target='proxmox_virtual_environment_vm.k8s_node["<name>"]' -destroy`
  (or remove the map entry and `apply`). pg01/pg02/hermesagent already
  carry `prevent_destroy` — this is a documented safety net, not new
  behavior introduced here.
- **Kubespray layer** — for a homelab of this size, the practical
  "rollback" is destroying and recreating the affected VM(s) via
  Terraform and re-running `cluster.yml`, rather than kubespray's own
  `reset.yml` against a partially-joined node.
- **ArgoCD/GitOps layer** — `kubectl delete -f gitops/bootstrap/` reverses
  Step 3 of §3.3 (reverse order of what was applied). Longhorn-backed PVCs
  may need manual cleanup — deleting the Application doesn't delete the
  underlying volume by default.

## Next

Postgres/Pigsty bootstrap: [`docs/runbook-pg-bootstrap.md`](runbook-pg-bootstrap.md).
