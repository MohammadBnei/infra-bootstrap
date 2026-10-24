# ADR-0067: mountain becomes atlas, for platform-admins only

**Status:** Proposed — decided 2026-10-24 by M BN in mountain's R10 interviews ("This project is now mostly for
internal purpose… consider this project only for admins"). Amends [ADR-0065](0065-mountain-behind-forwardauth-invited-visitors.md)
(the gate admits `platform-admins` only; invited visitors lose access), [ADR-0056](0056-mountain-public-live-cluster-view.md)
and [ADR-0064](0064-mountain-town-roles-and-guest-probes.md) (role keys, scrubbing and bucketing were for a public or
visitor audience; atlas shows real names).
**Date:** 2026-10-24
**Related:** the app-side design lives in the private `MohammadBnei/mountain` repo, `plan/10-understanding.md` (R10,
A2: `cmd/atlas` replaces the relay and the town).

## Context

mountain.bnei.dev was a live town for the public (ADR-0056), then for `platform-admins` and invited
`mountain-visitors` (ADR-0065). In R10 the owner turned it into **atlas**, the surface for understanding the whole
system: realms, their parts, the routes between them, the ADRs that govern each part, live state. It is internal: a
client-facing project comes later as its own thing. Real names are the point of it, so the role-key scrub, the
buckets and the visitor features (marks, plants) are gone with the town.

atlas enforces the audience itself: every route but `/healthz` and `/auth/*` refuses anyone but a signed-in
`platform-admins` member, and its OIDC callback gives a non-admin no session. The gate in front stays, as the first
lock.

## Decision

1. **`mountain-gate` admits `platform-admins` only.** The `mountain-visitors` binding on the forwardAuth application
   is removed (`state: absent` in `authentik-blueprint-mountain-gate-policy.yaml`).
2. **The `mountain` OIDC application admits `platform-admins` only.** Its `mountain-visitors` binding is removed the
   same way (`authentik-blueprint-mountain-policy.yaml`).
3. **No new invitations.** The invitation flow (`authentik-blueprint-mountain-enrollment.yaml`) and the
   `mountain-visitors` group stay declared for now, inert: an account it creates reaches nothing. Removing them is a
   follow-up, because a group deleted under live memberships needs the owner's review first.
4. **What atlas reads stays read-only**: Prometheus and Alertmanager over the cluster network (no ServiceAccount, no
   RBAC, ADR-0056), and the repos through a read-only GitHub token (contents, metadata) until mountain's
   `ukubi-atlas` GitHub App replaces it.

## Consequences

- **Visitors lose access** the moment this syncs: the outpost refuses them before mountain is reached. Nobody but
  the owner is known to use it.
- **The ADR-0064 role keys and the ADR-0065 buckets no longer constrain mountain.** The `guest-<role>` blackbox targets
  stay as they are: atlas maps them to the machines they probe (its `realms.yaml`).
- **Order does not matter** between this change and mountain's A2 deploy: each refuses visitors on its own.
- **Revert** re-adds the bindings; mountain's own check would still refuse visitors until mountain is reverted too.

## Rollout

1. This PR. After the sync, check both bindings are gone and the admin ones stay:
   `psql -d authentik -tAc 'SELECT target_id, group_id, enabled FROM authentik_policies_policybinding'`.
2. mountain A2 (one deploy: atlas replaces the relay).
3. Later, on the owner's word: remove the enrollment flow and the `mountain-visitors` group.
