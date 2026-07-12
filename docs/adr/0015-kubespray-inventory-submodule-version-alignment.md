# ADR-0015: Kubespray inventory ↔ submodule version alignment

**Status:** Proposed — **hard blocker on running `cluster.yml`**

## Context

`inventory/ukubi/` is authored against kubespray **v2.23** variable
names, while the `kubespray/` submodule is pinned at **v2.31.0** (the
current latest stable release). Running `cluster.yml` today would
silently use v2.23 variable names against a v2.31.0 submodule and may
apply the wrong default values with no error.

## Decision

Not yet decided which direction to resolve in — most likely, port the
inventory to v2.31.0 variable names (submodule bumps are a PR of their
own, never combined with inventory edits, per `DECISION.md`).

## Consequences

**Do NOT run `cluster.yml` until this is resolved.** This is the
highest-priority open item blocking the next real cluster bootstrap
attempt. See `DECISION.md` Known Drift and `inventory/ukubi/README.md`.
