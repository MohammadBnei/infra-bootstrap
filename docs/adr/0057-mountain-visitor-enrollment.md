# ADR-0057: mountain visitors: self-service enrollment into `mountain-visitors`, behind Turnstile

**Status:** Superseded by [ADR-0065](0065-mountain-behind-forwardauth-invited-visitors.md) (2026-10-23):
enrollment is invitation-only (an invitation stage replaces the Turnstile captcha) and mountain.bnei.dev is gated.
Was: Accepted, not live. This PR adds the blueprints; the Turnstile widget
and its two Infisical keys are manual steps (Rollout).
**Date:** 2026-10-15
**Related:** [ADR-0050](0050-public-oidc-client-for-native-apps.md) (Wird's
self-service enrollment, the flow this one is cloned from, and
`core_default_app_access=false`), [ADR-0056](0056-mountain-public-live-cluster-view.md)
(mountain, whose Decision 8 deferred visitor accounts to this ADR),
`docs/runbook-authentik-identity.md`. App side: the private
`MohammadBnei/mountain` repo, `plan/08-auth.md` "W4 hardening".

## Context

mountain.bnei.dev's visitor layer lets signed-in visitors leave marks (cairns,
footprints, a tossed stone) on the shared mountain. Each mark carries the
visitor's handle, and everyone sees it. So this needs public sign-up, which
makes "anyone with an account" mean "anyone on the internet". That raises
four questions: bots, mail abuse, what a visitor may reach, and what a visitor
may say.

authentik already has one public enrollment (Wird, ADR-0050). Two things from
it carry over: every application carries a policy binding, and
`core_default_app_access` is `false`.

## Decision

1. **A second enrollment flow, `mountain-enrollment`, cloned from Wird's**
   (`gitops/bootstrap/authentik-blueprint-mountain-enrollment.yaml`). Its
   stages: captcha, then a prompt (email, handle, password twice), user write
   (inactive), email verification (activates), login. New users are `external`
   and land in **`mountain-visitors` only**. The group is declared locally,
   so the user-write stage gets it with `!KeyOf`; a `!Find` miss would be
   None, and users enrolled during the miss would be created with no group.
   It has no `name` field, because a free-text name would ride along in the
   ID token unmoderated.

2. **Turnstile captcha, first stage, managed mode.** This uses authentik
   2026.8's captcha stage with the Turnstile preset's URLs. The field names
   were checked against upstream `authentik/stages/captcha/models.py` and
   `web/src/admin/stages/captcha/shared.ts` at `version/2026.8.0`. Turnstile
   runs before anything else, so a bot never reaches a handle lookup or a mail
   send. The keys come from Infisical via `authentik-config` and reach the
   blueprint as `!Env MOUNTAIN_TURNSTILE_SITE_KEY` /
   `!Env MOUNTAIN_TURNSTILE_SECRET_KEY`. If a key is missing, `!Env` resolves
   to None and both key fields are required, so the whole blueprint fails and
   **no mountain enrollment exists without a captcha**.
   *Cost:* rotating a key changes the env, not the blueprint file. Discovery
   re-applies a blueprint only when the file's hash changes, so after a
   rotation it must be re-applied by hand (see the file's header).

3. **The handle is the username, moderated at the door.** An expression
   policy on the prompt stage (`mountain-handle`) requires 3–20 characters
   of `[a-z0-9_-]` and rejects a short static denylist, matched as exact words
   and as substrings. Lowercase only also makes authentik's case-sensitive
   uniqueness check behave case-insensitively. The relay shows
   `preferred_username` and nothing else. What the denylist misses goes to
   moderation after the fact: an admin `mark.delete` (mountain detail mode),
   then deactivating the user.

4. **Binding: `mountain-visitors` → `mountain` only**
   (`authentik-blueprint-mountain-policy.yaml`, order 1, beside
   `platform-admins` at order 0; mode `any`). That file now begins with two
   `metaapplyblueprint` entries (`platform-groups`, `mountain-oidc`,
   `required: true`). They close the apply-order race that made its first
   apply fail on 2026-10-15. Its `!Find`s can no longer run against a missing
   application (NULL target, an error) or a missing `platform-admins` (NULL
   group, silently ignored by the policy engine).

5. **A visitor is denied everywhere else, by construction.** Every other
   application is bound only to groups a visitor never joins. Checked in git
   and on the live instance on 2026-10-15:

   | Application | Bound to | Blueprint |
   |---|---|---|
   | `argocd`, `grafana` | `platform-admins` | `authentik-blueprint-platform-apps-policy.yaml` |
   | `hq` | `platform-admins` + PKCE (mode `all`) | `authentik-blueprint-hq-policy.yaml` |
   | `hermes` | `platform-admins` + PKCE (mode `all`) | `authentik-blueprint-hermes-policy.yaml` |
   | `wird` | `wird-users` + PKCE (mode `all`) | `authentik-blueprint-wird-policy.yaml` |
   | `fleet` | `platform-admins` | `authentik-blueprint-fleet-policy.yaml` |
   | `netbird` | `netbird-users`, user `netbird-agent` | `authentik-blueprint-netbird-policy.yaml`, `authentik-blueprint-netbird.yaml` |
   | `wird-admin`, `e2e-previews` | `platform-admins` | `authentik-blueprint-wird-admin-policy.yaml`, `authentik-blueprint-previews-policy.yaml` |

   Membership in `mountain-visitors` is written only by this flow. No group
   above is ever granted by enrollment. With `core_default_app_access=false`,
   an application that lost its binding would deny visitors too. The binding
   gate (W4 hardening item 2) keeps that list honest. Defence in depth: Grafana
   becomes role-strict (item 3). ArgoCD still has `policy.default:
   role:readonly` behind the authentik binding; that is a follow-up, not this
   ADR.

6. **Shared SMTP2GO sender, accepted risk.** Verification mail goes out
   through authentik's one SMTP2GO account, the same one that carries Wird's
   enrollment and every password recovery. A flood of sign-ups could use up
   its quota and block recovery mail for operators. Mitigations: Turnstile in
   front of the send (Decision 2), and a **quota watch**: a weekly check of the
   SMTP2GO dashboard's monthly usage against the plan limit. Turning it into
   an alert (SMTP2GO's API exposes usage) is a follow-up if sign-ups are
   real. A separate sender per app was rejected for now: a second account and
   a second domain verification, for a risk the captcha already narrows.

7. **Not linked from the login page.** The brand's `enrollment_flow` stays
   unset, as for Wird: the brand is cluster-wide, so a "Sign up" link there
   would also appear on ArgoCD's login screen. mountain's "Sign in to play"
   links straight to `https://authentik.bnei.dev/if/flow/mountain-enrollment/`.
   authentik's `?next=` accepts relative URLs only, so after enrollment a
   visitor lands on their authentik library, where the Mountain tile is
   their way back.

## What the relay sees

A visitor's ID token (scopes `openid profile`, the managed profile mapping):
`groups: ["mountain-visitors"]`, `preferred_username` (and `nickname`) = the
handle, `sub` = hashed user id (marks key on it), `name` empty. The relay maps
`platform-admins` → admin, `mountain-visitors` → visitor, anything else → view.

## Rollout

1. **Manual (the one step that cannot be in git):** the Infisical Cloudflare
   token is DNS-only, so create the Turnstile widget by hand. Cloudflare
   dashboard → Turnstile → Add widget: name `mountain-enrollment`, hostname
   `authentik.bnei.dev`, mode **Managed**, no pre-clearance.
2. Store its keys in Infisical (`infra-bootstrap-1-ge1`, `dev`, `/`) as
   `MOUNTAIN_TURNSTILE_SITE_KEY` and `MOUNTAIN_TURNSTILE_SECRET_KEY`,
   **before** merging. `authentik-secret.yaml` references them, and its
   template will not render without them.
3. Merge. Then the propagation chain (`/authentik-oidc`): restart
   infisical-operator (the CR template changed), confirm the new file is
   mounted in the worker, then restart the authentik **worker** (it applies
   blueprints and reads `!Env`; the server only serves what is in the
   database). Restart it again if the flow has not appeared.
4. Verify: the flow exists; a sign-up without solving the widget is refused; a
   real sign-up ends in `mountain-visitors` only; that user is refused at
   ArgoCD, Grafana, hq and hermes; `SELECT target_id, group_id FROM
   authentik_policies_policybinding` shows no NULL group for `mountain`.
