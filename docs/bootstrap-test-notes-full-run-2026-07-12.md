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
- **Also needed**: `infisical run` requires `--projectId`; docs only ever
  show `<infra-bootstrap-project-id>` as a placeholder with no obvious
  pointer to the real value. Found it in `docs/secrets.md` line 108
  (`8a3fa54f-be22-488a-bf51-55158f65c0f2`) and surfaced it in `CLAUDE.md`'s
  tech-stack table so it's not buried in prose next time. Also needed
  `--domain=https://infisical.bnei.dev` explicitly (not the CLI default).
- **Also needed**: `terraform plan`/`apply` evaluates every declared
  variable regardless of `-target`, including `imported.tf`'s
  intentionally-undefaulted `pg01`/`pg02`/`hermesagent` vars. Added inert
  placeholder values to the gitignored `terraform.tfvars` (same pattern
  already used for `garage_*`) — safe since `-target` excludes those
  resources from the actual plan/apply graph.

## Kubespray invocation gotcha

- **Real bug (my own execution mistake), fixed**: first attempt ran
  `kubespray-venv/bin/ansible-playbook -i inventory/ukubi/hosts.yaml
  kubespray/cluster.yml` from the repo root — failed immediately with
  `ERROR! the role 'dynamic_groups' was not found`. Root cause:
  kubespray's `ansible.cfg` (which sets `roles_path` relative to the
  `kubespray/` directory itself) is only picked up when the working
  directory *is* `kubespray/`; running it from the repo root pointed at
  `kubespray/cluster.yml` bypasses that config entirely, breaking role
  resolution. `inventory/ukubi/README.md`'s documented invocation (`cd
  kubespray && ansible-playbook -i ../inventory/ukubi/hosts.yaml
  cluster.yml`) is correct as written — I just didn't follow it exactly.
  Also worth noting: piping through `tee log | tail -N` silently masked
  the actual ansible-playbook exit code (reported 0 from `tail`, not the
  real 1) — redirecting straight to a file and checking `$?` afterward is
  the safer pattern for catching failures in a background run.

## ArgoCD bootstrap — kubectl SSH proxy for register-repos.sh

`helm install argocd` (chart `10.1.3`, matching `argocd-application.yaml`'s
pin) went clean on the first try, run via SSH on `k8s-cp-01` per the
`k8s-ops` skill's "never materialize the kubeconfig locally" rule.

`gitops/bootstrap/register-repos.sh` assumes a bare `kubectl` on `PATH`
configured against the live cluster — which conflicts with that same
rule. Fixed by writing a thin `kubectl` wrapper script (scratch dir, first
on `PATH` for this invocation only) that SSHs every call to `k8s-cp-01`
**except** `--dry-run=client` invocations, which render YAML from local
flags/files only (no cluster contact) and must run against the real local
`kubectl` binary — the script's `--from-env-file` paths
(`k8s-cluster/infisical/.env.secret`/`.env.client`) are local paths. First
version of the wrapper proxied *everything* over SSH unconditionally,
which broke `--from-env-file` (tried to read the env file on the remote
node, where it doesn't exist) — fixed by special-casing `--dry-run=client`
to stay local. Script is idempotent; re-ran clean after the fix.

## Longhorn sync deadlock — real bug, fixed

`platform-longhorn` stayed `OutOfSync`/`Missing` while every sibling
platform app (including `local-path-provisioner`, same ApplicationSet,
same wave) synced fine. `describe application platform-longhorn` showed
the sync stuck `waiting for completion of hook batch/Job/longhorn-pre-upgrade`;
the Job itself never started a pod:
`FailedCreate ... serviceaccount "longhorn-service-account" not found`.

Root cause: the Longhorn chart's `preUpgradeChecker` Job is a `PreSync`
hook, which ArgoCD runs *before* the chart's normal (non-hook) resources
— including `longhorn-service-account`, which the Job's pod needs. On a
fresh install there's no prior version to check anyway. The chart's own
`values.yaml` documents this exact gotcha: *"Disable this setting when
installing Longhorn using Argo CD or other GitOps solutions."*

Fixed: `gitops/platform/values/longhorn/values.yaml` — added
`preUpgradeChecker: {jobEnabled: false}`. Also updated the file's stale
comment about disk prep (used to say "ansible, not yet automated" — now
correctly says cloud-init handles it, since that's this run's fix).

Note also: `gitops/platform/values/*` auto-syncs from the **pushed**
remote (ArgoCD clones from GitHub, not the local working tree) — this fix
needs a `git push`, not just a local commit, before ArgoCD picks it up.

## Kubespray cluster.yml — clean run

After fixing the invocation gotcha above: `failed=0` on both nodes,
`unreachable=0`, ~10m35s total. `Cilium | Wait for pods to run` retried a
handful of times mid-run (normal — pods still initializing) and resolved
on its own. Post-run checks: both nodes `Ready` at `v1.35.4` (confirms the
earlier `kube_version` prefix fix holds), `helm` CLI present on `k8s-cp-01`
via `helm_enabled: true` (no manual install needed this time), every pod
across all namespaces `Running`.

## Terraform apply — cp01 + worker01

Clean. `terraform plan` (`-refresh=false`, targeted) showed 3 to add (the
renamed vendor-data file + both VMs), 0 to change, 0 to destroy. Apply
completed in ~1m45s per VM (confirms the qemu-guest-agent cloud-init fix
from the earlier test still holds — no 15-minute guest-agent wait).
`ssh-keyscan` + SSH into both `.201`/`.202` confirmed on first try:
- Correct hostnames (`k8s-cp-01`, `k8s-worker-01`)
- `qemu-guest-agent` active
- `/dev/sdb` auto-formatted ext4 and mounted at `/var/lib/longhorn` via the
  new cloud-init `bootcmd` — the Longhorn disk-prep gap is fully closed
  with zero manual/ansible steps.

