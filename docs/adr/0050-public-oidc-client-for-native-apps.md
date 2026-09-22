# ADR-0050: Public OIDC clients for native and browser apps, with PKCE enforced by policy

**Status:** Accepted — decided 2026-09-22. The authentik behaviour below was
verified against goauthentik 2026.8 **source**, not its documentation; the
blueprint shapes for `expressionpolicy` were not, and carry the same caveat as
[ADR-0039](0039-authentik-identity-layer.md)'s bindings.
**Date:** 2026-09-22
**Related:** [ADR-0039](0039-authentik-identity-layer.md) (the identity layer and
its four tiers — this adds a client *type* to the Native OIDC tier, it does not
add a tier), [ADR-0041](0041-fleet-native-oidc-not-forwardauth.md) (the other
app that does PKCE, client-side, as a confidential client)

## Context

Wird — a Qur'an study app with a Flutter binary for iOS/Android and a website —
needs to authenticate against authentik ([infra-bootstrap#251]). Its Go backend
validates the resulting JWT and mints nothing of its own.

Every OIDC provider on this cluster is `client_type: confidential` with the
secret delivered through Infisical: `authentik-blueprint-grafana.yaml`,
`-argocd`, `-fleet`. That works because all three consumers are servers.

Wird's clients are not. A secret shipped inside an IPA, an APK or a JS bundle is
extractable by anyone who installs the app, so a confidential client here would
be confidential only in name. RFC 8252 §8.5 says native apps must be public
clients and must use authorization code with PKCE.

The alternative considered, and rejected: a **BFF** — Wird's Go backend holds a
confidential client and exchanges tokens on the app's behalf. It would keep
every client on the cluster confidential, at the cost of a session store and a
round trip on login. It was rejected because it does not change the mobile app's
position; it only moves the boundary, and a public client is what the protocol
was designed for. The cluster's convention is worth following, but not past the
point where it stops describing reality.

## Decision

1. **Native and browser clients are public clients.** `client_type: public`,
   no `client_secret` attribute at all. Server-side consumers stay confidential;
   this is an exception with a stated test, not a new default.

2. **Exactly one redirect URI, `https://`, claimed through App Links and
   Universal Links.** No custom scheme (`dev.bnei.wird://`) and no
   `http://localhost` dev entry. Custom schemes are first-come and unclaimable
   on both platforms, so any app can register the same one; domain-verified
   https links cannot be taken without controlling `wird.bnei.dev`. This is the
   control that stops a copycat app — not PKCE, see below. It puts a
   prerequisite on the app side: `wird.bnei.dev` must serve
   `/.well-known/assetlinks.json` and `/.well-known/apple-app-site-association`
   before mobile login completes, and until it does the redirect opens the
   system browser instead of the app.

3. **PKCE is enforced by an authentik expression policy**, not left to the
   client. `OAuth2Provider` has no `pkce_required` field on 2026.8, and
   `token/authorization_code.py` verifies a `code_verifier` only when the
   authorization code already carried a challenge — so a client that simply
   omits `code_challenge` is never checked. Enforcement is possible because
   `views/authorize.py`'s `modify_policy_request()` places
   `oauth_code_challenge` and `oauth_code_challenge_method` into the policy
   request context, which an `expressionpolicy` bound to the application can
   read. The policy requires `S256`; `plain` is rejected, since the OAuth
   default when the method is absent is `plain` and a challenge an attacker can
   read is not a challenge.

   **What it does and does not buy.** PKCE closes code *interception*. It does
   **not** stop a rogue app running the whole flow itself with its own challenge
   and verifier — that request passes the policy cleanly. Decision 2 is what
   addresses that; the two are different problems and were conflated in this
   PR's first draft.

   **The policy must guard on OAuth context.** `modify_policy_request()` runs
   only on the authorize view. `core/api/applications.py`'s
   `_get_allowed_applications()` evaluates the same bindings through a
   `ListPolicyEngine` to decide which tiles a user sees in their library, with
   no OAuth request behind it — so an ungarded expression returns `False` there
   and, under Decision 4's `MODE_ALL`, the application disappears from every
   user's dashboard while login keeps working. The guard tests key *presence*:
   `modify_policy_request()` always assigns `oauth_code_challenge`, setting it
   to `None` when the client sent none, so absent means "not an authorization
   request" and present-but-empty means "an authorization request that skipped
   PKCE".

4. **The application sets `policy_engine_mode: all`.**
   `PolicyBindingModel.policy_engine_mode` defaults to `MODE_ANY` — "any policy
   must pass". With two bindings (group membership and PKCE) at the default,
   passing either one grants access, and the PKCE gate becomes decorative. This
   one field is what makes Decision 2 real.

5. **A public client's blueprint is a plain `ConfigMap`, and its `client_id` is
   committed.** This follows `DECISION.md`'s existing rule rather than bending
   it: the blueprint is an `InfisicalSecret` "when it carries an OAuth2 client
   secret, a plain `ConfigMap` when it does not". There is no secret, and the
   `client_id` ships inside the binary regardless, so there is no
   `WIRD_OIDC_CLIENT_ID` row in Infisical — `docs/secrets.md` says so explicitly
   so the next audit does not read its absence as a gap.

6. **Every public client gets its own access binding.** authentik's
   `AppAccessWithoutBindings` default is `True` — "applications with no policies
   bound can be accessed by any user" — so an unbound application means every
   directory user gets an account on it. Wird binds a new `wird-users` group,
   deliberately **not** `platform-admins`, which means "operator of this
   cluster" and is read by ArgoCD and Grafana.

7. **`refresh_token_threshold` is set explicitly.** It defaults to `seconds=0`,
   which `views/token.py` treats as "always renew": a new refresh token on every
   refresh, with the old one marked `revoked = True`. One lost response on a
   mobile radio, or two screens refreshing at once, and the next refresh is
   `invalid_grant` plus a `SUSPICIOUS_REQUEST` event — a forced re-login, the
   exact thing the requirement forbids. Wird uses `days=3` against a
   `refresh_token_validity` of `days=90` (default `days=30`).

8. **`offline_access` must be bound as a property mapping.** Listing
   `refresh_token` in `grant_types` issues nothing on its own: `views/token.py`
   gates issuance on `SCOPE_OFFLINE_ACCESS` being in the authorization code's
   scope, and the refresh endpoint raises `invalid_scope` without it. No
   existing blueprint here binds it, because no existing app needed a refresh
   token.

9. **`sub_mode` is left at its default (`hashed_user_id`).** Grafana and fleet
   set `user_email` because they key attribution on the address. An app that
   stores per-user rows against `sub` must not: `User.email` is mutable and not
   unique, so a user who changes their address returns as a new, empty account,
   and whoever later takes that address inherits their data.

10. **Membership in that group comes from a self-service enrollment flow, not
    from git.** `gitops/bootstrap/authentik-blueprint-wird-enrollment.yaml`:
    prompt → user write (inactive, into `wird-users`) → email verification →
    login. The group therefore carries **no `users:` list** in any blueprint,
    because that list is replaced rather than merged on every reconcile and
    would delete every enrolled user's access.

    The flow is **open** — anyone who reaches its URL can sign up — and is
    deliberately **not** linked from the brand, since the brand is cluster-wide
    and a "Sign up" link would appear on ArgoCD's and Grafana's login pages too.
    What keeps it from being an open spam surface is email verification, which
    makes **SMTP a hard dependency of this ADR**: `AUTHENTIK_EMAIL__*` is now
    part of `authentik-config`, and without it authentik falls back to
    `localhost:25` and silently drops every message — enrollment, password
    recovery and email MFA alike.

    The relay is SMTP2GO at `mail-eu.smtp2go.com:587`, which `ente-uovi` also
    uses — but **through a different SMTP2GO account**, with its own credential
    and its own From address. The five keys are spelled identically in both
    projects and are not copies of each other: they rotate independently, and
    propagating a change from one to the other would break the other. The shared
    spelling reads like a mirror and is not one; that is worth knowing before
    anyone "fixes the drift" between them.

    They live in the root project rather than `platform-commons-76pb`,
    knowingly against ADR-0049's general rule: that project is readable by any
    app opting into `sharedSecrets.keys` — its own accepted risk — and a relay
    credential that can send mail as `bnei.dev` is not something to hand every
    user app. A password policy (12 characters minimum, plus
    a Have I Been Pwned check with `hibp_allowed_count: 0`) is bound to the
    prompt stage for the same reason.

    **Accepted, not solved: the form has no captcha and no rate limit.** Every
    submission spends SMTP2GO quota and a HIBP range lookup, and the sender
    reputation it burns belongs to a domain that also carries this cluster's
    password recovery. Email verification is what stops a signup becoming an
    *account*, but it is itself the resource being spent, so it is not a rate
    limit. The flow's URL is unlisted, which is obscurity and not a control.
    `authentik_stages_captcha.captchastage` bound ahead of the prompt stage is
    the small fix if abuse appears; it is not built now because it needs another
    external credential pair for an app with no users yet.

    Also accepted: enrollment lets the user pick a username, and
    `user_creation_mode: always_create` surfaces a collision as a uniqueness
    error — a weak account-enumeration oracle against operator usernames.

    Rejected alternatives: **invitation-gated enrollment** (an
    `invitationstage` with `continue_flow_without_invitation: false`) is the
    smaller change and needs no SMTP, but it keeps a human in the loop for every
    signup, which a consumer-facing app cannot carry; **git-committed
    membership** is what this replaces.

11. **Open enrollment forces `argocd` and `grafana` to get access bindings.**
    Both applications had none, and `AppAccessWithoutBindings` defaults to
    `True` — which was safe only while the directory held hand-made operator
    accounts. Decision 10 makes the directory public, so without a binding every
    Wird signup would also receive ArgoCD `role:readonly` (its `policy.default`)
    and Grafana `Viewer` (the fall-through in its `role_attribute_path`): every
    Application and its manifests, every dashboard and Loki log panel. Those
    role mappings decide what an authenticated user may do, never who may
    authenticate. `gitops/bootstrap/authentik-blueprint-platform-apps-policy.yaml`
    binds both to `platform-admins`, and it must be applied together with the
    enrollment blueprint, not after it. `fleet` and `e2e-previews` were already
    bound; these two were the last unbound applications.

12. **`core_default_app_access` is flipped to `false`, so an unbound
    application denies rather than admits.** Decisions 10 and 11 leave the
    cluster one blueprint miss away from an open application, and that failure
    is silent in a way worth spelling out: `!Find` returns `None` rather than
    failing (`blueprints/v1/common.py`), so a miss writes a `policybinding` row
    with `group_id = NULL`; `PolicyEngine.build()` sorts bindings into dynamic
    (`policy_id is not None`) and static (`policy_id is None and (group_id or
    user_id)`), and that row matches neither, so it is skipped entirely;
    `_combine_results` then returns `PolicyResult(empty_result)`. With the flag
    at its default the application is **open**, while
    `SELECT * FROM authentik_policies_policybinding` shows a row — a gate that
    looks present and is not. `!KeyOf` is no safer: it raises, the blueprint
    aborts, and no row means open by the same flag.

    **This one cannot be a blueprint, and there is no env var either.** The
    flag lives on `authentik_tenants.tenant`, and `Tenant` is
    `InternallyManagedMixin, TenantMixin, SerializerModel` — the importer
    refuses any `InternallyManagedMixin` subclass. Nor can configuration reach
    it: `Flag.get()` (`authentik/tenants/flags.py`) reads `tenant.flags` and
    falls back to the hardcoded class default with no `CONFIG.get(...)` on the
    path, and `ensure_default_tenant()` creates the tenant with
    `{"name": "Default", "ready": True}` and no flags. The value exists only as
    a Postgres row, settable only by `ak set_flag`.

    So it is asserted from git the one way left:
    `gitops/bootstrap/authentik-flags-job.yaml`, an ArgoCD **PostSync** hook
    that runs `ak set_flag core_default_app_access false` on every sync of the
    bootstrap Application. `ak set_flag` is
    `tenant.flags[key] = value; tenant.save()` — one key, idempotent, safe to
    run repeatedly. It needs no new credential: `envFrom` the existing
    `authentik-config` Secret. An unrecognised first argument falls through the
    image's `ak` dispatcher to `wait_for_db; python -m manage "$@"`, so the Job
    waits for Postgres by itself.

    **What that still does not cover, and it is the important half:** a Postgres
    restore or a rebuilt tenant triggers no ArgoCD sync, so the flag returns to
    its `True` default and every gate fails open again with no error anywhere.
    That path stays a runbook step. Treat the flag like the cert-expiry alarm in
    `DECISION.md` — load-bearing, and invisible when it goes.

    The cost is the mirror image: an application whose binding blueprint fails
    now denies everyone. ArgoCD and Grafana keep their local admins as
    break-glass per ADR-0039; agent-fleet's `core` does not.

## Consequences

- **Audience validation moves onto the app, and is load-bearing.**
  `signing_key` is the same `authentik Self-signed Certificate` on every
  provider here, and `jwks.py` serves it at every per-app JWKS URL — so a
  Grafana or ArgoCD access token verifies cleanly against Wird's JWKS.
  "Validate the JWT against JWKS" is **not** authentication on this cluster.
  Wird's backend must check `aud == <its client_id>` and
  `iss == https://authentik.bnei.dev/application/o/wird/`. The alternative —
  a per-provider `certificatekeypair` — was not taken: it is real isolation, but
  `aud`/`iss` validation is required by OIDC anyway and costs the app nothing.

- **A stolen authorization code is still useless, but a stolen refresh token is
  not.** PKCE closes interception of the code. Nothing here protects a refresh
  token already on a compromised device; that is what `refresh_token_validity`
  and authentik's session invalidation are for.

- **The `expressionpolicy` shapes are unverified.** Mitigated the way
  ADR-0039's bindings were: the policy lives in its own blueprint file, so if a
  shape is wrong the blueprint logs and carries on and the provider still
  exists. **Decision 12 changes which way that fails.** Before the flag flip a
  missing binding meant login still worked, ungated — silently. After it, the
  same miss stops login for everyone, loudly. The second is the right direction
  for a gate and the wrong one at 3am, which is why the verification steps read
  the database rather than the log, and why the negative test (authorize with
  **no** `code_challenge`) is the one that matters.

- **Known drift this does not fix:** every pre-existing database in
  `pigsty/pigsty.yml` omits `revokeconn`, so PUBLIC keeps CONNECT on them and
  `dbrole_readwrite` — a shared role — can write their tables. `wirddb` sets
  `revokeconn: true` and is the first that does. Fixing the others is its own
  change.

- **`!Find` returns `None` rather than failing**
  (`blueprints/v1/common.py`), which decides where objects are declared. The
  `wird-users` group is declared *identically in two blueprints* — the policy
  file and the enrollment file — because `!KeyOf` resolves only within one
  blueprint and raises when it cannot, while a `!Find` for the enrollment
  stage's `create_users_group` would silently be `None` on any apply where the
  group did not yet exist, creating users with no group and no access,
  permanently, since the stage applies the group only at creation time.

- **Three of this ADR's decisions came out of PR review, not design.** The first
  draft used a custom scheme plus a localhost dev redirect, claimed PKCE stopped
  a rogue app, and left the PKCE expression unguarded. All three were wrong in
  the same direction: treating a public client as the confidential template with
  a field removed. Recorded here because the reasoning is easier to repeat than
  to re-derive.

- **The skill and the runbook had to change with it.**
  `.claude/skills/authentik-oidc/SKILL.md` described the OIDC tier as always an
  `InfisicalSecret`; that is now the confidential case only.

[infra-bootstrap#251]: https://github.com/MohammadBnei/infra-bootstrap/issues/251
