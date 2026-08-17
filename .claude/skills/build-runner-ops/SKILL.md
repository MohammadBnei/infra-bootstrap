---
name: build-runner-ops
description: Manage the build-runner LXC's GitHub Actions runner instances for ukubi-cluster (192.168.1.111, one instance per build repo). Use when the user asks to add a build repo, inspect runner/build state, debug a queued or failing image build, or asks why builds don't run in-cluster.
user-invocable: true
allowed-tools:
  - Read
  - Bash(ssh -i ~/.ssh/id_build_runner root@192.168.1.111 systemctl status actions-runner-*)
  - Bash(ssh -i ~/.ssh/id_build_runner root@192.168.1.111 systemctl list-units actions-runner-*)
  - Bash(ssh -i ~/.ssh/id_build_runner root@192.168.1.111 systemctl status podman-prune.timer)
  - Bash(ssh -i ~/.ssh/id_build_runner root@192.168.1.111 journalctl -u actions-runner-* --no-pager -n *)
  - Bash(ssh -i ~/.ssh/id_build_runner root@192.168.1.111 buildah images)
  - Bash(ssh -i ~/.ssh/id_build_runner root@192.168.1.111 buildah images --storage-driver vfs)
  - Bash(ssh -i ~/.ssh/id_build_runner root@192.168.1.111 df -h /)
  - Bash(gh api repos/MohammadBnei/*/actions/runners)
  - Bash(gh run list -R MohammadBnei/* *)
  - Bash(gh secret list -R MohammadBnei/*)
  - Bash(curl -s http://registry.bnei.lan:5000/v2/_catalog)
  - Bash(curl -s http://registry.bnei.lan:5000/v2/*/tags/list)
  - Bash(ansible-playbook -i ansible/inventories/build-runner/hosts.yml ansible/playbooks/build-runner-configure.yml --check --diff)
  - Bash(ansible-playbook -i ansible/inventories/build-runner/hosts.yml ansible/playbooks/build-runner-configure.yml --list-tasks)
  - Bash(ansible-playbook -i localhost, ansible/tests/build-runner-expressions.yml)
---

# /build-runner-ops — image build runner operations

Container images for `ukubi-cluster` are built on the **`build-runner` LXC**
(`192.168.1.111`, VMID 103, `terraform/build-runner.tf` +
`ansible/playbooks/build-runner-configure.yml`) and pushed to Zot at
`registry.bnei.lan:5000`. **Never in-cluster** — see ADR-0034.

Why not a pod, since it gets asked every time: buildah cannot extract image
layers in an unprivileged container. `mount --make-rprivate /` needs
`CAP_SYS_ADMIN` and fails with `remount /, flags: 0x44000: permission
denied` (containers/buildah#4920, #5622) — confirmed live, after the ADR
originally claimed otherwise. The only in-cluster alternative was a
**privileged** pod running app-repo Dockerfiles, a node-level escape risk.
An LXC has real root, so the problem class disappears instead of being
negotiated around, and builds leave the cluster entirely — *stronger*
isolation than the no-ServiceAccount pod it replaced.

## Runner topology — one instance per repo, one box

`build_runner_repos` in the playbook's `vars:` is the source of truth. Each
entry gets its own directory, its own `actions-runner-<name>.service`, and
its own GitHub registration. Everything else on the box is shared.

**The registration cannot be shared, and this is not a configuration
choice.** A runner registered at repo scope only picks up jobs for that
repo. Sharing one across repos needs an **org-level** runner, and personal
GitHub accounts cannot register those. ADR-0034 considered migrating the
repos into a GitHub organization and rejected it — it would rewrite every
`repoURL` in `gitops/`.

What *is* shared, and where the value actually is: this box and its rootful
buildah image store. `golang:1.26` and `oven/bun:1-slim` are pulled once and
reused by every repo. So "share the box, not the registration."

Consequence to keep in mind when diagnosing slow builds: **one instance runs
one job at a time.** A repo whose workflow fans out across a matrix
serializes on its own runner, and a release competing with another repo's
build waits.

## Adding a build repo

Always through the playbook's vars list, never by hand over SSH — the
playbook is idempotent and this keeps the box reproducible.

1. **Widen the PAT first.** The repo must be added to `ACCESS_TOKEN`'s
   repository list (Infisical project `actions-runner-x-qbo`, env `prod`;
   fine-grained, `Administration: Read and write`, owner's own token).
   **This is a GitHub UI action — `gh` cannot edit PAT scopes.** Skipping it
   makes "Mint a runner registration token" fail with a 403 that looks like a
   bad PAT rather than a missing repo.
2. Add an entry:
   ```yaml
   build_runner_repos:
     - name: some-repo
       url: https://github.com/MohammadBnei/some-repo
       # home: optional, defaults to /opt/actions-runner-<name>
   ```
3. Set the registry push credentials on that repo:
   ```bash
   gh secret set REGISTRY_USERNAME -R MohammadBnei/some-repo
   gh secret set REGISTRY_PASSWORD -R MohammadBnei/some-repo
   ```
4. Re-run the playbook:
   ```bash
   ansible-playbook -i ansible/inventories/build-runner/hosts.yml \
     ansible/playbooks/build-runner-configure.yml
   ```
   This is a **mutating run against real infra** — build/explain the command,
   but only run it yourself if the user explicitly says to run it now in this
   session (same rule as `ansible-ops`). `--check --diff` is always safe to
   run directly to preview.

Already-registered instances are skipped (the playbook stats each
instance's `.runner`), so a re-run only touches the new one. Confirm that in
`--check --diff` before the real run: an existing instance reporting
`changed` on its registration tasks means something is off.

## Writing the workflow

`runs-on: [self-hosted, ukubi-build]`. Two constraints that are not
negotiable and have both already cost a debugging session:

- **`ukubi-build`, never `ukubi`.** The `ukubi` label belongs to the
  *in-cluster* runner holding a projected ServiceAccount token with `create
  jobs` in `vos`/`vos-dev` (ADR-0022). Builds must not land there — that's
  the identity coupling ADR-0034 split the runners to avoid — and cluster
  jobs must not land here.
- **`sudo apt-get` does not work.** `/etc/sudoers.d/runner-buildah` grants
  `/usr/bin/buildah` and nothing else, so a step that installs a tool at job
  time hangs on a password prompt. Bake tooling into the playbook instead.
  This is why builds here use plain GitHub Actions secrets rather than the
  Infisical-CLI-at-job-time pattern other repos' workflows use: that
  bootstrap is `curl | sudo -E bash` + `sudo apt-get install`.

Every buildah call goes through `sudo` — login included. Rootless buildah in
this LXC gets a single UID mapping (`newuidmap` is not permitted) and dies on
any image chowning to a second UID. Mixing rootless and rootful also splits
the auth file: `buildah login` writes `/run/containers/<uid>/auth.json`, so a
rootless login is invisible to a rootful push. And `--tls-verify=false` on
login and push — the registry is plain HTTP, since Let's Encrypt cannot issue
for `.lan`.

Read the version from `package.json` with `jq` under `set -euo pipefail`, not
`node -p` — there is no Node runtime on this box, and `node -p` did not fail
the step: the command substitution returned empty and the failure surfaced
downstream as `...:` → `invalid reference format`.

## Read-only inspection (safe to run directly)

```bash
ssh -i ~/.ssh/id_build_runner root@192.168.1.111 systemctl status 'actions-runner-*'
ssh -i ~/.ssh/id_build_runner root@192.168.1.111 buildah images --storage-driver vfs
ssh -i ~/.ssh/id_build_runner root@192.168.1.111 df -h /
gh api repos/MohammadBnei/<repo>/actions/runners --jq '.runners[] | {name, status, labels: [.labels[].name]}'
curl -s http://registry.bnei.lan:5000/v2/_catalog            # anonymous read
curl -s http://registry.bnei.lan:5000/v2/<image>/tags/list
```

`buildah images` needs no `sudo` over SSH — the inventory's `ansible_user` is
`root`, so an interactive session is already root and reads the same rootful
store the builds write. **Pass `--storage-driver vfs`**: builds specify it
explicitly, each driver keeps its own tree under the graph root, and a query
against the default driver simply will not see the build images.

## Disk is the thing that fills

40GB, shared by every build repo, with `--storage-driver vfs` — which copies
whole layers rather than stacking them. The failure mode is a build dying on
ENOSPC, which names nothing useful.

- A weekly timer (`podman-prune.timer`, name kept for continuity) runs
  `buildah rmi --prune --force --storage-driver vfs` as **root**. Both the
  user and the driver flag are load-bearing: it previously ran as the runner
  user against the default driver, which pruned a store no build has ever
  written to — reporting success weekly and reclaiming nothing.
- **Never `buildah rmi --all`** on this box. The shared base-image cache is
  the entire point of putting multiple repos on one machine; `--all` evicts
  the other repo's bases too. Workflows should prune per-component after
  pushing, not wholesale at the end.
- The registry side has its own bound: `zot-registry` is quota'd at 40GB with
  a 5-tag retention policy (`gitops/platform/values/zot/values.yaml`). That
  is a *separate* budget from this disk — use `/garage-ops` for it.

## Related skills

- `/ansible-ops` — construct the Infisical-wrapped playbook invocation.
- `/terraform-ops` — the LXC itself (`terraform/build-runner.tf`).
- `/garage-ops` — the `zot-registry` bucket, its quota and its S3 key.
- `/k8s-ops` — whether the cluster can actually pull what was pushed.
