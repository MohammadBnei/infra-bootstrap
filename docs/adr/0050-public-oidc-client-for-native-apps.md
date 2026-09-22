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

2. **PKCE is enforced by an authentik expression policy**, not left to the
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

3. **The application sets `policy_engine_mode: all`.**
   `PolicyBindingModel.policy_engine_mode` defaults to `MODE_ANY` — "any policy
   must pass". With two bindings (group membership and PKCE) at the default,
   passing either one grants access, and the PKCE gate becomes decorative. This
   one field is what makes Decision 2 real.

4. **A public client's blueprint is a plain `ConfigMap`, and its `client_id` is
   committed.** This follows `DECISION.md`'s existing rule rather than bending
   it: the blueprint is an `InfisicalSecret` "when it carries an OAuth2 client
   secret, a plain `ConfigMap` when it does not". There is no secret, and the
   `client_id` ships inside the binary regardless, so there is no
   `WIRD_OIDC_CLIENT_ID` row in Infisical — `docs/secrets.md` says so explicitly
   so the next audit does not read its absence as a gap.

5. **Every public client gets its own access binding.** authentik's
   `AppAccessWithoutBindings` default is `True` — "applications with no policies
   bound can be accessed by any user" — so an unbound application means every
   directory user gets an account on it. Wird binds a new `wird-users` group,
   deliberately **not** `platform-admins`, which means "operator of this
   cluster" and is read by ArgoCD and Grafana.

6. **`refresh_token_threshold` is set explicitly.** It defaults to `seconds=0`,
   which `views/token.py` treats as "always renew": a new refresh token on every
   refresh, with the old one marked `revoked = True`. One lost response on a
   mobile radio, or two screens refreshing at once, and the next refresh is
   `invalid_grant` plus a `SUSPICIOUS_REQUEST` event — a forced re-login, the
   exact thing the requirement forbids. Wird uses `days=3` against a
   `refresh_token_validity` of `days=90` (default `days=30`).

7. **`offline_access` must be bound as a property mapping.** Listing
   `refresh_token` in `grant_types` issues nothing on its own: `views/token.py`
   gates issuance on `SCOPE_OFFLINE_ACCESS` being in the authorization code's
   scope, and the refresh endpoint raises `invalid_scope` without it. No
   existing blueprint here binds it, because no existing app needed a refresh
   token.

8. **`sub_mode` is left at its default (`hashed_user_id`).** Grafana and fleet
   set `user_email` because they key attribution on the address. An app that
   stores per-user rows against `sub` must not: `User.email` is mutable and not
   unique, so a user who changes their address returns as a new, empty account,
   and whoever later takes that address inherits their data.

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
  shape is wrong the blueprint logs and carries on, the provider still exists,
  and login still works — ungated. That failure mode is silent, which is why the
  verification steps read the database rather than the log, and why the negative
  test (authorize with **no** `code_challenge`) is the one that matters.

- **Known drift this does not fix:** every pre-existing database in
  `pigsty/pigsty.yml` omits `revokeconn`, so PUBLIC keeps CONNECT on them and
  `dbrole_readwrite` — a shared role — can write their tables. `wirddb` sets
  `revokeconn: true` and is the first that does. Fixing the others is its own
  change.

- **The skill and the runbook had to change with it.**
  `.claude/skills/authentik-oidc/SKILL.md` described the OIDC tier as always an
  `InfisicalSecret`; that is now the confidential case only.

[infra-bootstrap#251]: https://github.com/MohammadBnei/infra-bootstrap/issues/251
