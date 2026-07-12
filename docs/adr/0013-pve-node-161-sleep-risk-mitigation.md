# ADR-0013: `.161` (ex-laptop) sleep-risk mitigation

**Status:** Proposed

## Context

`.161` (ex-laptop) is confirmed by user intent as the 3rd PVE node, but
as laptop hardware it carries a sleep/suspend risk that could affect
quorum for anything scheduled there.

## Options under consideration

- A forced-wake timer (prevent the laptop from sleeping on a schedule).
- A suspend-disabler systemd unit (block sleep entirely while acting as
  a PVE node).

## Decision

Not yet decided. Must be resolved before the first `kubespray
cluster.yml` run that includes `.161` as a target host.

## Consequences

Until resolved, treat `.161` as lower-trust capacity — see
`ARCHITECTURE.md` §1 Physical Hosts.
