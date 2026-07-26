# ADR-0013: `.161` (ex-laptop) sleep-risk mitigation

**Status:** Accepted

## Context

`.161` (ex-laptop) is confirmed by user intent as the 3rd PVE node, but
as laptop hardware it carries a sleep/suspend risk that could affect
quorum for anything scheduled there.

## Options considered

- A forced-wake timer (prevent the laptop from sleeping on a schedule) — rejected.
- A suspend-disabler systemd unit (block sleep entirely while acting as
  a PVE node) — chosen, see Decision below.

## Decision

Disable suspend entirely, not the forced-wake alternative — belt-and-suspenders
across two layers (`ansible/playbooks/pve-postinstall.yml`, play 1):
`HandleLidSwitch=ignore` (+ docked/external-power variants) in
`/etc/systemd/logind.conf` so a lid close never triggers suspend, plus
masking `sleep.target`/`suspend.target`/`hibernate.target`/
`hybrid-sleep.target` via systemd to cover any other suspend trigger.
Must run before `.161` joins the corosync cluster or runs any VM — see
`docs/runbook-pve-postinstall.md`.

## Consequences

The sleep/suspend risk itself is resolved. `.161` still stays lower-trust
capacity for **scheduling** purposes independent of this fix — see
`ARCHITECTURE.md` §1 Physical Hosts and `inventory/ukubi/README.md`'s
topology notes (best-effort workloads only, no critical-path scheduling,
until it's had a track record in production). Per ADR-0020, `.161`
sleeping does not by itself sink PVE cluster quorum (2-of-3 nodes still
quorate) — this mitigation is about `.161`'s own VM availability, not
cluster-wide quorum.
