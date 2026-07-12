# ukubi-cluster full smoke test — errors & fixes (2026-07-12, full run)

Full end-to-end repeat of terraform → kubespray → GitOps on the 2-node
test cluster (`k8s-cp-01` 192.168.1.241, `k8s-worker-01` 192.168.1.242),
done in one continuous pass. Kept separate from `docs/bootstrap-test-notes.md`
(the earlier partial-test log from the same day) per user request.

Goal: prove the pipeline is repeatable and boring before attempting the
real migration (cp01 + worker01 + worker-gpu + pg01/pg02/hermesagent).
This run also validates Longhorn (not just local-path-provisioner) and
folds the manual `helm` CLI install into kubespray.

Format per entry: what broke, root cause, what fixed it.

---

## Pre-flight changes (before first apply)

- **Planned, not a bug**: `inventory/ukubi/group_vars/k8s_cluster/addons.yml`
  `helm_enabled: false` → `true`, so kubespray installs the `helm` CLI on
  `k8s-cp-01` instead of the manual `get-helm-3` curl step from the prior
  test. Confirmed this doesn't conflict with ADR-0005 (`argocd_enabled` is
  the forbidden flag; `helm_enabled` only installs the binary).
- **Planned, not a bug**: `terraform/cloud-init.tf`'s vendor-data snippet
  (renamed `qemu_guest_agent_vendor_data` → `k8s_vm_vendor_data`) extended
  with a `bootcmd` stanza to format/mount the `scsi1` disk at
  `/var/lib/longhorn` on boot, so Longhorn's wave-0 GitOps sync has a disk
  without a separate ansible playbook. `terraform/k8s-vms.tf`'s 3
  `vendor_data_file_id` references updated to match.
- **Real bug, fixed**: `inventory/ukubi/hosts.yaml` had `k8s-cp-01`/
  `k8s-worker-01` pointed at `192.168.1.241`/`.242` — leftover scratch IPs
  from an earlier ad hoc test. `terraform/k8s-vms.tf`'s actual
  `ip_config` for these resources is `.201`/`.202` (the real target
  topology per `inventory/ukubi/README.md`). Applying terraform as-is
  would have created VMs kubespray could never reach. Confirmed `.201`/
  `.202` are currently free (no ARP response) — the earlier garage-storage
  LXC conflict at `.201` was already resolved in the prior test. Fixed by
  updating `hosts.yaml` to `.201`/`.202` to match terraform's real output.
  Note: `~/.ssh/known_hosts` entries from the prior test are for
  `.241`/`.242` and are now irrelevant — needs a fresh `ssh-keyscan` for
  `.201`/`.202` once the VMs exist.

