---
name: bootstrap
description: Walk the ukubi-cluster bootstrap sequence (PVE post-install, kubespray, ArgoCD, Pigsty) using the checklists already in the repo's READMEs. Use when the user asks what's next in the bootstrap, wants to resume the cluster build, or asks to draft a missing runbook.
user-invocable: true
allowed-tools:
  - Read
  - Write
  - Bash(ansible *)
---

# /bootstrap — bootstrap sequence walker

`docs/runbook-*.md` (the intended step-by-step docs, format defined in
`docs/README.md`) mostly **don't exist yet** — `docs/README.md` lists them
as unchecked TODOs. This skill doesn't pretend they exist; it walks the
live checklists in the READMEs that *do* exist today and treats them as
current state.

## Step 1 — pick the phase

Ask (or infer from what the user said): PVE post-install → kubespray →
ArgoCD bootstrap → Pigsty. If unsure, ask.

## Step 2 — walk the phase's live checklist

- **Kubespray**: read `inventory/ukubi/README.md` "Current status" — it's
  a literal checkbox list (IPs filled in? SSH key deployed? `ansible -m
  ping` passing? `cluster.yml` run?). Report the first unchecked item as
  "next step."
- **ArgoCD**: read `gitops/README.md` "Bootstrap sequence" (Step 1–4:
  install ArgoCD via Helm → `register-repos.sh` → `kubectl apply -f
  gitops/bootstrap/` → watch rollout). Walk in order, checking whether
  each precondition looks met (e.g. don't suggest Step 3 if Step 2's
  secrets aren't confirmed created).
- **Pigsty**: no runbook exists yet and `docs/README.md` only lists it as
  TODO (`runbook-pg-bootstrap.md`, `runbook-migration-pg.md`). Say so
  plainly rather than inventing steps; offer to draft the runbook (Step 4)
  instead.
- **PVE post-install**: same — `ansible/README.md` lists
  `pve-postinstall.yml` as drafted-but-unchecked and the playbook file
  itself doesn't exist yet. Don't reference a playbook path that isn't
  there.

## Step 3 — cross-check against DECISION.md before suggesting a step

Before telling the user to run something, check it doesn't hit a
`DECISION.md` §2/§3 rule — most importantly: **`cluster.yml`, never
`scale.yml`**, on a greenfield bootstrap. If a suggested step would touch
real infra, hand off to the `ansible-ops` skill to build the actual
command rather than executing anything here.

## Step 4 — offer to draft the runbook

If the phase being walked has no `docs/runbook-*.md` yet, offer to write
one now, using `docs/README.md`'s required structure:

1. Goal
2. Prereqs (Infisical auth, IPs assigned, hosts reachable)
3. Steps (exact commands)
4. Verification (sanity checks, expected output)
5. Rollback (how to undo)

Base it on what was just walked — this turns the ad hoc walk into the
permanent doc instead of redoing the same research next time. Don't
overwrite an existing runbook without confirming with the user first.

## What this skill never does

Never runs `ansible-playbook`, `kubespray`, or `pigsty` playbooks itself.
`ansible -m ping` / `--check` dry-runs are fine for verifying reachability;
anything that mutates real infra goes through `ansible-ops` or the user
directly, per `README.md`'s workflow ("you run the actual tool on your
Mac").
