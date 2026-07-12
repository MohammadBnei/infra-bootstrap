# ADR-0015: Kubespray inventory ↔ submodule version alignment

**Status:** Accepted

## Context

`inventory/ukubi/` was authored against kubespray **v2.23** variable
names, while the `kubespray/` submodule is pinned at **v2.31.0**. Running
`cluster.yml` risked silently using v2.23 variable names against a
v2.31.0 submodule and applying the wrong default values with no error.

## Decision

Ported the inventory to v2.31.0 variable names. Confirmed by the
2026-07-12 full smoke test (`docs/bootstrap-test-notes-full-run-2026-07-12.md`):
`cluster.yml` ran clean against `cp01`/`worker01` — `failed=0`,
`unreachable=0` on both nodes, correct `v1.35.4` kube version, no
version-mismatch symptoms. The only issue hit during that run was an
unrelated execution mistake (invoking `ansible-playbook` from the repo
root instead of `kubespray/`), not an inventory/submodule alignment
problem.

## Consequences

`cluster.yml` is safe to run against `inventory/ukubi/` as-is.
