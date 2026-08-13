# ADR-0035: Self-hosted Forgejo as the authoritative forge, GitHub demoted to push-mirror

**Status:** Proposed
**Depends on:** [ADR-0034](0034-in-cluster-oci-registry-zot-garage-backed.md)
(the registry ships and is validated first — `VISION.md`'s ordering)

## Context

`VISION.md` sequences this after the registry ("**Then git, mirrored.**")
and states the trap in the same breath:

> Ownership is not sole custody — the mirror is the restore path, not a
> hedge against owning the stack. Note the bootstrap circularity: ArgoCD
> syncs `infra-bootstrap` from git, so the repos that bootstrap the cluster
> cannot be the ones hosted only inside it.

The drivers are the same five as ADR-0034: ownership, CI, latency,
observability/reaction, and the organism framing. The specific latency this
decision buys is **reaction time**: ArgoCD's 3-minute poll collapses to an
instant LAN webhook, so `push → build → image → sync → running` becomes one
loop entirely inside the organism, every stage of which already emits
metrics this cluster collects.

## Decision

1. **Forgejo, in a Proxmox LXC** — provisioned by Terraform on the pattern
   `garage.tf` / `k9s-dashboard.tf` already establish, configured by a new
   `ansible/playbooks/forgejo-install.yml`. Terraform's job stops at "bare,
   SSH-reachable container", as with Garage.

2. **Not in the cluster.** Two independent reasons, either of which alone
   would decide it: the standing rule that stateful objects stay out of
   Kubernetes, and the bootstrap circularity above — the repo ArgoCD syncs
   *from* cannot live only inside the thing it bootstraps. An LXC satisfies
   both at no extra cost.

3. **Postgres on Pigsty** (VIP `192.168.1.232`), consistent with ADR-0010.
   Git repositories themselves live on the LXC filesystem: Forgejo shells
   out to `git`, and **only** LFS, attachments, packages and avatars can be
   moved to S3. Those go to Garage; the repositories cannot.

4. **Forgejo is authoritative; GitHub becomes a push-mirror.** A pull-mirror
   was considered and fails three of the five drivers outright — it cannot
   fire CI on push (events originate upstream), cannot hold pull requests,
   and cannot webhook ArgoCD. The GitHub copy exists as the restore path
   required by VISION principle 8, because it leaves the failure domain.

5. **CI moves to Forgejo Actions**, runner on the LXC.

6. **The off-domain restore path is a precondition of this entire ADR, not
   of its final step.** VISION orders it *before* "then git". Forgejo's
   repositories sit on one LXC filesystem, and **pull requests, issues and
   CI history do not push-mirror** — they would exist in exactly one place.
   Implementation therefore does not begin until that restore path exists
   and a break-glass restore has been rehearsed once with Forgejo assumed
   dead. `ARCHITECTURE.md` §10's backup matrix gains a `/var/lib/forgejo`
   row in the same change that installs it.

7. **Migration order**, which is not the intuitive one:

   1. **`infra-bootstrap`'s workflows first** — or the reusable workflow is
      vendored into each caller. `.github/workflows/reusable-oneoff-job.yml`
      is `uses:`-called cross-repo, and Forgejo cannot expand a `uses:`
      pointing at a *different instance*. Any repo calling it breaks the
      moment it moves while `infra-bootstrap` is still on GitHub. "App repos
      first" is therefore self-contradictory for exactly the repos that use
      ADR-0023's machinery.
   2. **`agent-fleet` with the infra repos, not the app repos.** It is
      referenced directly by `gitops/bootstrap/provisioner-application.yaml`
      and by `.gitmodules`, which makes it an infra repo from
      `gitops/bootstrap/`'s point of view regardless of how it is developed.
   3. Then `editable-blog`, then `dream-analyst` — plain app repos, and
      genuinely cheap.
   4. Then `vos-monolith` (+`-dev`), gated on the blocker below.
   5. **`infra-bootstrap`'s own ArgoCD sources last.** Eight files under
      `gitops/bootstrap/` hard-code the repo URL, including the self-syncing
      bootstrap Application (ADR-0021), which has to rewrite its own source
      while running.

   Each app move is **two files, not one**: `gitops/apps/registry.yaml` is
   the *human* source of truth, while
   `gitops/bootstrap/apps.applicationset.yaml`'s list elements are what
   ArgoCD actually reads. Editing only the former is a no-op that also
   creates precisely the drift ADR-0004 exists to prevent.

8. **Open blocker, recorded rather than papered over.**
   `reusable-oneoff-job.yml` is `runs-on: [self-hosted, ukubi]` and needs an
   **in-cluster** ServiceAccount, because the Kubernetes API is LAN-only and
   ADR-0009 rejected a VPN. A Forgejo runner on the LXC has LAN reachability
   but no in-cluster identity, and giving it one would mean exporting a
   kubeconfig out of the cluster — the exact thing ADR-0022 refused. Either
   a second Forgejo runner runs **in-cluster** with ADR-0022's RBAC
   re-derived, or `vos-monolith` stays on GitHub. This ADR does not yet
   choose; it refuses to let the choice be made implicitly by a `runs-on:`
   edit.

## Alternatives considered

- **Gitea.** Technically near-identical, same Actions implementation,
  slightly ahead on some enterprise features. Rejected on the axis the user
  named *first*: Gitea is a commercial product (Gitea Ltd), Forgejo is
  community-governed copyleft under Codeberg. A governance difference, not a
  technical one — but ownership is the stated driver.
- **GitLab CE.** Full suite, includes its own registry and CI. Rejected
  twice over: a ~4GB-RAM Rails/Redis/Gitaly/Sidekiq footprint in an LXC,
  *and* every existing workflow rewritten into GitLab CI YAML — to buy
  scanning/RBAC features already declined in ADR-0034.
- **cgit / soft-serve / Gerrit.** Rejected: each drops pull requests and/or
  CI, killing three of the five drivers.
- **GitHub authoritative, Forgejo as a read-only pull-mirror.** Rejected —
  see Decision 4. It would leave nothing owned and a slower cache running.
- **Forgejo in-cluster.** Rejected: violates the stateful rule *and*
  re-creates the bootstrap circularity VISION explicitly warns about.
- **Do nothing / stay on GitHub.** The status quo the drivers target. It
  remains a legitimate stopping point after ADR-0034, which is why these are
  two ADRs and not one: the registry's value does not depend on this.

## Consequences

- Push → CI → image → webhook → running becomes one LAN loop, observable
  end to end through the existing Prometheus/Loki/Grafana path. That is the
  "reaction" driver, delivered.
- A new credential chain, `repo-creds-forgejo`, alongside ADR-0025's shared
  GitHub PAT, injected the same way by `register-repos.yml`. The two coexist
  for the whole migration.
- **"Migrates with roughly a `runs-on:` change" is true in shape and false
  in detail.** Forgejo Actions ignores the `permissions` and
  `continue-on-error` job keys, is missing some `github` context keys,
  defaults to a Debian/Node runner image rather than GitHub's `ubuntu`
  image, and uses `enable-openid-connect` instead of
  `permissions: id-token: write`. It *does* support `workflow_call`.
- `lint.yml`'s `actions/setup-python`, `ansible/ansible-lint` and
  `azure/setup-helm` still resolve from github.com by default under Forgejo
  — a residual external dependency that partly undercuts the ownership
  driver, and one this ADR does not solve.
- The LXC will inherit a documented trap: Proxmox statically injects
  `/etc/resolv.conf` at the LXC level, bypassing DHCP-handed DNS —
  `k9s-dashboard` hit exactly this (`docs/bootstrap-test-notes.md`). Forgejo
  must resolve `postgres.bnei.lan` and `garage.bnei.lan`, so the container's
  nameserver is set explicitly at provisioning time rather than discovered
  to be broken afterwards.
- **Reversibility is asymmetric.** Any single app repo comes back with two
  file edits. The aggregate does not: once pull requests, issues and CI
  history accumulate in Forgejo, none of it is in the GitHub mirror. This is
  the one-way component, and it is the reason for Decision 6.
