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
****
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

## ArgoCD stuck-sync deadlock chain — real bug, three-layer finalizer/cache issue

After the `preUpgradeChecker.jobEnabled: false` fix was pushed, `platform-longhorn`
stayed stuck recreating the exact same hook Job for ~35 minutes despite the
fix being live on `origin/main` (verified via `git ls-remote` and `git
fetch` — not a push problem). Root cause was a chain of three separate
ArgoCD staleness/deadlock issues, not one:

1. **In-flight operation doesn't re-render on retry.** An `automated`
   sync's `retry.backoff` loop reuses the manifest/revision resolved at
   the *start* of that operation — it does not re-fetch git or re-render
   Helm on each retry. A `kubectl annotate .../refresh=hard` updates
   `.status.sync` (the comparison view) but does **not** interrupt an
   already-running operation's in-memory retry loop.
2. **Job hook-finalizer deadlock.** The stuck Job carries
   `argocd.argoproj.io/hook-finalizer`, normally removed by the
   application-controller once it decides the hook is done — which never
   happens here, since the hook can never succeed (no ServiceAccount).
   `kubectl delete` on the Job hangs; had to strip the finalizer directly
   (`kubectl patch job ... -p '{"metadata":{"finalizers":null}}'
   --type=merge`) to actually remove it.
3. **Application resources-finalizer deadlock, same shape one level up.**
   Once the Job was cleared, clearing `.status.operationState` (via a
   normal, non-subresource `kubectl patch` — this CRD does **not** expose
   a `/status` subresource, `--subresource=status` 404s) and restarting
   `argocd-application-controller` still weren't enough: the *new*
   operation kept resolving the OLD pre-fix git revision
   (`155e93e3`) instead of the pushed fix (`0a1906ca`) — confirmed via
   `.status.operationState.syncResult.revisions`. Restarting
   `argocd-repo-server` (Helm render) and `argocd-redis` (the actual
   manifest-cache backend — a separate component from repo-server, this
   is the one that matters for cache staleness) did not fix it either.
   What finally worked: `kubectl delete application platform-longhorn`
   (which hangs on the Application's own
   `resources-finalizer.argocd.argoproj.io`), then strip *that*
   finalizer too (`kubectl patch application platform-longhorn -p
   '{"metadata":{"finalizers":null}}' --type=merge`). Kubernetes then
   actually deletes the object, and since it's still declared in
   `platform.applicationset.yaml`'s list generator, the ApplicationSet
   controller immediately recreates it from scratch — genuinely fresh,
   with no operation history to resume. That recreation finally resolved
   `0a1906ca` correctly and moved past the hook.

Never fully root-caused *why* the resolved revision stayed pinned to the
pre-fix commit across an application-controller restart with a cleared
`operationState` — possibly a 4th cache layer (repo revision cache inside
the app controller itself, distinct from repo-server/redis) that only a
full Application object recreation bypasses. Worth a documented recovery
runbook entry in the `k8s-ops` skill: **when a values-file fix doesn't
take effect after a push, don't trust `refresh=hard` or component
restarts alone — if the Application has a stuck/retrying operation,
delete-and-let-the-ApplicationSet-recreate is the reliable unstick.**

## Infisical backend CrashLoopBackOff — version mismatch vs production, real finding

`platform-infisical` synced fine but the backend pod crash-looped:
`Boot up migration failed: alter table "certificate_requests" add column
"pendingMessage" text null - must be owner of table certificate_requests`
(migration `20260429021227_add-pending-message-to-certificate-requests.mjs`).

Diagnosed **without touching the live cluster or production DB** — purely
by comparing local config: `k8s-cluster/infisical/values.yml` (the actual
manifests deployed on the legacy production cluster at `.181`, per
`docs/infrastructure-actual.md` §3) pins `image.tag: "v0.159.28"`, while
`gitops/platform/values/infisical/values.yaml` (this test's config) had
`v0.162.3`. Both point at the **same shared production Postgres**
(`pg01`, `.205`) via the same `.env.secret`-derived `DB_CONNECTION_URI` —
this test's newer Infisical version was the first ever to attempt a
migration production has never run, and it hit a pre-existing
table-ownership inconsistency on that one table (likely from some earlier
out-of-band `psql` session, unrelated to this repo). This is a real,
latent production issue — production will hit the exact same failure
whenever it's eventually upgraded past v0.159.28.

Did **not** touch production Postgres to fix the ownership (out of this
smoke test's `cp01`/`worker01` scope — would need explicit user
authorization + a `REASSIGN OWNED BY` on live infra). Fixed for this
smoke test by pinning `gitops/platform/values/infisical/values.yaml`'s
`backend.image.tag` back to `v0.159.28` to match the proven-working
production version, sidestepping the untested migration. Follow-up (not
done here): fix the `certificate_requests` ownership on `pg01` before
production is ever upgraded past v0.159.28.

## Final verification summary

**Fully healthy**: `argocd` self-app, `platform-longhorn` (health-wise;
`.status.sync` stays OutOfSync on 7 of its own CRDs — cosmetic, no
functional impact observed), `platform-traefik` (LB IP `.231` confirmed),
`platform-local-path-provisioner`, `platform-metrics-server`,
`platform-infisical` (after the version pin).

**Expected/documented limitations, not bugs**:
- Longhorn volumes report `degraded` robustness (Traefik's, Grafana's) —
  `defaultReplicaCount: 3` vs. only 2 schedulable nodes in this smoke
  test; matches the values.yaml's own documented ADR-0002 limitation.
- Prometheus's PVC (20Gi) volume is `faulted`
  (`insufficient storage;precheck new replica failed`) — `terraform.tfvars`
  sets `longhorn_disk_size_gb = 20` for this smoke test only (explicitly
  commented "test sizing, not the real production value"); a 20Gi request
  doesn't fit a 20GB disk once Longhorn's reserved-capacity overhead and
  the other PVCs are accounted for. Not a config bug — production sizing
  would use a much larger disk.

**Real, separate gap found (pre-existing, not caused by this session)**:
the **Infisical Kubernetes Operator** (provides the `InfisicalSecret`
CRD — a different component from the Infisical *server* fixed above, with
its own independent versioning, `docs/bootstrap-test-notes.md` already
noted "requires Infisical operator ≥ 0.6.0") is not registered anywhere
in `gitops/` at all. Confirmed via `grep -rl InfisicalSecret gitops/` —
only `argocd-github-apps-creds.yaml` (a CRD *instance*) and
`grafana/values.yaml` (references a secret name) exist; nothing installs
the CRD itself. Consequences, all downstream of this one gap:
- `gitops/bootstrap/argocd-github-apps-creds.yaml` can't apply →
  `repo-creds-github-bnei` never gets created → every wave-10 user app
  (`n8n`, `whodb`, `openweb-ui`, `openweb-ui-pipelines`, `searxng`, `api`,
  `ukubi-ai`) stays stuck `Unknown` sync status forever, confirmed via
  repo-server logs: `failed to list refs: error creating SSH agent: SSH
  agent requested but SSH_AUTH_SOCK not-specified`.
- Grafana's `admin.existingSecret: grafana-admin` (meant to come "via
  ExternalSecret → Infisical" per its values.yaml comment) never
  materializes → `CreateContainerConfigError: secret "grafana-admin" not
  found`.

Did not add the operator during this smoke test — registering a new
platform component is a real feature addition beyond this run's declared
scope (terraform → kubespray → GitOps validation for cp01/worker01), not
a bug fix. Flagging for a follow-up PR.

## Teardown

`terraform destroy -target=k8s_cp_01 -target=k8s_worker_01` — clean,
2 destroyed. Also cleaned up an orphaned state entry:
`proxmox_virtual_environment_file.qemu_guest_agent_vendor_data` (the
pre-rename resource address) stayed in state after being renamed to
`k8s_vm_vendor_data` in `cloud-init.tf` — the scoped `-target` apply
earlier only created the new address, it never implicitly removed the
old one. Destroyed it separately. Final state: only
`proxmox_download_file.ubuntu_2404_cloudimg`,
`proxmox_virtual_environment_file.k8s_vm_vendor_data`, and
`proxmox_virtual_environment_vm.ubuntu_2404_template` remain, matching
the intended "leave template/cloud-init resources, destroy the VMs"
pattern.

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

