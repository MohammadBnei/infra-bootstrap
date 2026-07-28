# Runbook — PVE post-install: `.200`/`.161` join the cluster

Stage 2 of the multi-host expansion (see `docs/adr/0020-pve-corosync-cluster.md`
and `ARCHITECTURE.md` §11 Phase 3). Mostly a thin wrapper around
`ansible/playbooks/pve-postinstall.yml` — see that file for the actual
task detail; this runbook is the operator-facing sequencing/verification
around it.

> ⚠️ **Only start this once Stage 1 is done** — `ukubi-cluster` fully up
> and validated on `.165` alone. `.200`/`.161` currently run the *legacy*
> libvirt/KVM cluster; that stays live and untouched until this runbook's
> steps are complete, per the plan's staging note.

## 1. Goal

Reinstall `.200` (server1) and `.161` (ex-laptop) as PVE 9.x, join them
into one corosync cluster with `.165`, give each a dedicated ZFS pool
(ADR-0014), and propagate the golden K8s template (VMID 9001) — leaving
both nodes ready for Terraform to place K8s worker VMs on them (Phase C).

## 2. Prereqs

- PVE 9.2.3 ISO-installed on both `.200` and `.161` (manual/console step,
  out of ansible's scope) — matching `.165`'s version per `ARCHITECTURE.md` §1.
- Root SSH key access to both hosts already in place (same pattern
  `terraform/providers.tf` uses against `.165`).
- `.161`'s sleep/suspend fix (ADR-0013) must land **before** it does
  anything else as a PVE node — this playbook's first play handles it,
  but verify manually if running the plays out of order.
- Confirm and fill in the placeholders in
  `ansible/inventories/proxmox/hosts.yml` before running for real:
  `zfs_pool_device` (via `lsblk`) and `pve_node_name` (via `pvesh get
  /nodes`, only available *after* the corosync join — see step 4 below).
- `ansible.posix` collection installed: `ansible-galaxy collection
  install -r ansible/requirements.yml`.

## 3. Steps

Run against `ansible/inventories/proxmox/hosts.yml`. Never target both new
hosts at once for the corosync join (play 4) — sequential, one at a time,
confirming quorum in between.

Plays are tagged so the corosync join and template propagation can be run
separately from the rest — see the playbook's header comment for the full
command set. In short:

1. **Lid/suspend fix + common host prep + ZFS pools** (plays 1-3, safe to
   run against both hosts together):
   ```bash
   ansible-playbook -i ansible/inventories/proxmox/hosts.yml \
     ansible/playbooks/pve-postinstall.yml --skip-tags corosync,template-propagation
   ```
2. **Corosync join, `.200` first**. Needs `PVE_SSH_PRIVATE_KEY` in the
   environment (the corosync play uses it to pre-trust root@proxmox from the
   new node, so `pvecm add` never blocks on an interactive password prompt):
   ```bash
   infisical run --projectId=<infra-bootstrap-project-id> --env=dev -- \
     ansible-playbook -i ansible/inventories/proxmox/hosts.yml \
     ansible/playbooks/pve-postinstall.yml --tags corosync --limit=server1
   ```
   Confirm on `.165` or `.200`: `pvecm status` shows 2/2 quorum.
3. **Then `.161`**:
   ```bash
   infisical run --projectId=<infra-bootstrap-project-id> --env=dev -- \
     ansible-playbook -i ansible/inventories/proxmox/hosts.yml \
     ansible/playbooks/pve-postinstall.yml --tags corosync --limit=ex-laptop
   ```
   Confirm `pvecm status` shows 3/3 quorum.
4. **Fill in `pve_node_name`** for both hosts in
   `ansible/inventories/proxmox/hosts.yml` from `pvesh get /nodes` output
   (not guaranteed to match the inventory alias — same caveat as
   `terraform/variables.tf`'s `pve_node_name`).
5. **Template propagation**:
   ```bash
   ansible-playbook -i ansible/inventories/proxmox/hosts.yml \
     ansible/playbooks/pve-postinstall.yml --tags template-propagation
   ```

## 4. Verification

```bash
pvecm status        # 3/3 quorum
pvesm status         # both new ZFS pools visible cluster-wide
qm list              # (run per-node, or via `pvesh get /nodes/<node>/qemu`) shows VMID 9001 on each new node
systemctl status sleep.target   # on ex-laptop — masked
```

Before trusting the flow for anything with real data on it, test a
disposable VM: `qm migrate <test-vmid> <target-node> --with-local-disks
--online` should succeed cleanly.

## 5. Rollback

- A misbehaving join: `pvecm delnode <node>` from a healthy majority.
- ZFS pool creation is local and reversible per node (`zpool destroy`,
  `pvesm remove`) if the pool needs redoing.
- Nothing here touches `.165`, `pg01`/`pg02`, or any existing K8s VM —
  blast radius is contained to the two new hosts until Phase C's
  `terraform apply` actually places new VMs on them.

## Previous / Next

- Previous: Stage 1 — bring `ukubi-cluster` up on `.165` alone (`/bootstrap`
  skill, `docs/bootstrap-test-notes.md`).
- Next: Phase C — extend `terraform/variables.tf`'s `k8s_nodes` (via
  `terraform.tfvars`, see `terraform/terraform.tfvars.example`) with
  worker entries on the new nodes, then `scale.yml` to join them to
  `ukubi-cluster`.
