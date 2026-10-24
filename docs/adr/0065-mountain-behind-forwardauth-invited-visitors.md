# ADR-0065: mountain goes private: an authentik forwardAuth gate, invited visitors only, and the town shows every host an app runs on

**Status:** Proposed — decided 2026-10-22/23 by M BN in mountain's R8 deploy C planning (one question at a time, two
doubt cycles). Amends [ADR-0056](0056-mountain-public-live-cluster-view.md) (the view is no longer public) and
[ADR-0064](0064-mountain-town-roles-and-guest-probes.md) (an app's other hosts, coarser replica counts). Supersedes
[ADR-0057](0057-mountain-visitor-enrollment.md)'s open enrollment. Records an exception to
[ADR-0039](0039-authentik-identity-layer.md) Decision 3. **Amended by [ADR-0067](0067-mountain-atlas-platform-admins-only.md)**:
the gate admits `platform-admins` only; invited visitors lost access in R10.
**Date:** 2026-10-23
**Related:** [ADR-0059](0059-drop-file-sharing.md) (drop: the forwardAuth shape copied here),
[ADR-0051](0051-expose-hermes-dashboard.md) (hermes: a gate in front of an app with its own login),
`docs/runbook-authentik-identity.md`. The app-side plan lives in the private `MohammadBnei/mountain` repo under
`plan/`.

## Context

mountain.bnei.dev draws ukubi as a live town (ADR-0056, ADR-0064): an island per Proxmox host, one building per app on
the host running most of its pods, the infra guests as machines. Anyone could watch it; signing in only unlocked the
admin detail channel and, through a Turnstile-guarded self-enrollment (ADR-0057), visitor plants.

The next step (mountain R8 deploy C) draws an app's **minority pods**: a small tent beside the app on each other host it
also runs on. The doubt cycle showed what that publishes:
- **an HA map**: which apps are spread across hosts, and which ones a single host failure takes down;
- **exact pod counts per host** once read with the public replica bucket (exact for 0..4): 3 replicas and one tent
  is 2 + 1;
- **timing**: tents leaving and arriving show failovers and drains.

ADR-0064 published one host per app. The owner chose to show the tents for every app, and to stop publishing the town
instead of trimming it.

## Decision

1. **The whole of mountain.bnei.dev sits behind an authentik forwardAuth gate.** A dedicated proxy provider
   `mountain-gate` (`forward_single`, external host `https://mountain.bnei.dev`) on the embedded outpost, its
   application `mountain-gate`, `Middleware/mountain-forwardauth` in `default`, and the callback route
   `mountain-outpost-route.yaml`: drop's shape (ADR-0059). The relay keeps its own OIDC application `mountain` for
   its roles (admin detail, plants); behind the gate the page signs in to it automatically (implicit consent, no
   click). The Middleware is referenced from mountain's own `helm/values.yaml`, so the gate goes live with that
   mountain change, not with this repo's.
2. **Who passes: `platform-admins` and `mountain-visitors`** (`authentik-blueprint-mountain-gate-policy.yaml`).
3. **Visitors are invited.** The enrollment flow `mountain-enrollment` keeps its handle moderation, password policy
   and email verification, but its first stage is now an invitation stage that refuses to continue without a valid
   invitation; the Turnstile captcha is deleted. The owner creates invitations in authentik (single use, a few days'
   expiry). An invitation, like the membership it creates, is runtime state: the owner chose this over a membership
   list in git (the netbird-users pattern).
4. **The town shows every host an app runs on** (mountain's annexes): a tent per other host with at least one running
   non-Job pod, held 5 minutes both ways before it appears or leaves, never a count.
5. **Replica counts are coarsened** to buckets 0, 1, 2–4, 5–7, 8–15, 16+, and mountain's stored history is rewritten
   to them (mountain migration 006), so tents plus the bucket no longer give small exact counts.
6. **mountain's versioned assets are `Cache-Control: private`**, so Cloudflare no longer edge-caches them for anyone
   who knows a URL.

### The ADR-0039 exception

ADR-0039 Decision 3 keeps forwardAuth for applications that cannot federate. mountain federates (the relay is an OIDC
client), yet it gets both: the gate decides who reaches the town at all, including the static page, the socket and
the assets, which the relay serves before anyone signs in; the relay's own sign-in still carries its roles. hermes
(ADR-0051) is the precedent: a gate in front of an app with its own login.

## Consequences

- **The town is private.** What ADR-0056 and ADR-0064 describe as public is now shown to `platform-admins` and invited
  `mountain-visitors` only. The role-key naming, product scrub, bucketing, the alert-fingerprint salt and admin-only
  real names all stay, as defence in depth against an invited visitor.
- **Existing visitors keep their access** until removed: everyone who self-enrolled under ADR-0057 is in
  `mountain-visitors`. The owner reviews the group before mountain's gate change merges.
- **Residual inference, accepted:** buckets 0 and 1 are exact by nature, and an app's tents tell how many hosts it
  spans.
- **The forwardAuth session can lapse under an open tab.** mountain's page probes `/auth/me` without following
  redirects after failed reconnects and reloads once onto the login wall.
- **Agents can no longer check the live site** from outside: live checks after the gate are the owner's.
- **The Turnstile keys are unused.** `MOUNTAIN_TURNSTILE_*` leave the authentik secret template now; the owner deletes
  them from Infisical once the gate has held (reverting this ADR's PR needs them back).
- **Revert order is mountain first**: the annexes, then the Middleware ref, then this repo's change. Reverting this
  repo first deletes a Middleware the route still names, and the site answers 404.

## Rollout

1. This PR: the provider, application, outpost entry, binding, Middleware, callback route, the invitation flow, the
   template without the Turnstile keys, these docs. After the sync, restart the authentik worker once the new
   ConfigMaps are mounted (runbook-authentik-identity §9.1). Check, before anything references the Middleware:
   - `curl -sI -H 'X-Forwarded-Host: mountain.bnei.dev' -H 'X-Forwarded-Proto: https' -H 'X-Forwarded-Uri: /'
     https://authentik.bnei.dev/outpost.goauthentik.io/auth/traefik` answers a redirect whose Location carries
     `redirect_uri=https://mountain.bnei.dev/outpost.goauthentik.io/callback`, not the previews provider's;
   - the server log has `loaded application` for host `mountain.bnei.dev` (§8);
   - `curl -s https://authentik.bnei.dev/api/v3/flows/executor/mountain-enrollment/` refuses without an invitation;
   - both policy bindings exist (`SELECT target_id, group_id, enabled FROM authentik_policies_policybinding`).
2. The owner reviews `mountain-visitors`.
3. mountain: the Middleware ref, automatic sign-in, the expiry probe, private assets, replica buckets and migration
   006. Then, anonymously, `curl -sI https://mountain.bnei.dev/` answers 302 to authentik.
4. mountain: the annexes.
