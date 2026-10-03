# ADR-0052: `wird-admin.bnei.dev` — a second forwardAuth provider, and the HS256 token nobody expected

**Status:** Accepted — decided 2026-10-03. Manifests merged. Both Infisical rows
(`WIRD_ADMIN_OIDC_CLIENT_SECRET`, `DBUSER_WIRD_ADMIN_PASSWORD`) were created
2026-10-03, and the `wird-agent` group membership is declared in
`authentik-blueprint-groups.yaml`. **Still outstanding:** the `wird_admin` DB role
on `wirddb` and the `wird-agent` service account plus its app-password token —
both in [`docs/runbook-wird-admin-db-role.md`](../runbook-wird-admin-db-role.md),
both needing a hand that is allowed to write to production Postgres and to the
authentik shell.
**Date:** 2026-10-03
**Related:** [ADR-0039](0039-authentik-identity-layer.md) (the identity layer and
its forwardAuth tier — this is the tier's second provider, where it had exactly
one), [ADR-0050](0050-public-oidc-client-for-native-apps.md) (Wird's native
client, which adminweb deliberately does *not* use),
[ADR-0051](0051-expose-hermes-dashboard.md) (two gates, and the blueprint
transaction semantics this repeats), Wird's own ADR-0026

## Context

Wird's operations view (`server/cmd/adminweb`) ships as its own image and its own
Deployment, sharing the `wird` namespace and nothing else with wird-api. It needs
a hostname, an authenticated gate, a `groups` claim carrying `platform-admins`,
a read-mostly database role, and a machine identity for the agent that polls
`/reports.json`.

The registry's previous comment said adminweb could not ship because Wird's
native OIDC provider binds no group scope mapping. That reasoning is now moot:
adminweb does not authenticate against Wird's native client at all.

## Decision

1. **forwardAuth, with its own proxy provider — not the shared one.** The tier
   had one provider (`e2e-previews`, `mode: forward_domain`, `cookie_domain
   bnei.dev`) serving previews, `wedding.bnei.dev/admin` and `hermes.bnei.dev`.
   adminweb needs its own `client_id` (it verifies `aud`) and its own
   authorization binding, so it gets its own provider. A second `forward_domain`
   provider on the same cookie domain would give the outpost two providers
   claiming one host mapping, so this one is **`forward_single`** with
   `external_host: https://wird-admin.bnei.dev`.

2. **The callback leg is ours, not the app's.** `set_oauth_defaults()` rebuilds a
   proxy provider's redirect URI from `external_host`, so authentik returns the
   browser to `https://wird-admin.bnei.dev/outpost.goauthentik.io/callback`. That
   path must reach the authentik Service, not adminweb.
   `common-app-chart`'s `ingress.middlewares` cannot express a second route, and
   the alternative was `extraManifests` in Wird's values file — kept here instead
   (`gitops/bootstrap/wird-admin-outpost-route.yaml`) because the route exists for
   an infra-side choice (the mode) and points at an infra-side Service. Wird's
   values file names only the middleware.

3. **The forwarded token is HS256, signed with the provider's `client_secret`.**
   This is the finding that changed the app's code, and it is not in the docs:
   `providers/proxy/models.py`'s `set_oauth_defaults()` forces `signing_key =
   None` on every proxy provider, and `providers/oauth2/models.py`'s `jwt_key()`
   then returns `(self.client_secret, HS256)` — "No Certificate at all, assume
   HS256". It is called from `providers/proxy/api.py:71,77`, the serializer path
   blueprints take, so **a blueprint cannot pin an RS256 signing key on a proxy
   provider**; a declared one is silently reset. Consequences:
   - adminweb verifies with the shared secret, not a JWKS. `X-authentik-meta-jwks`
     is useless for this provider.
   - That secret therefore crosses a trust boundary, which is why
     `authentik-blueprint-wird-admin.yaml` is the tier's only `InfisicalSecret`
     while the others are plain ConfigMaps: one Infisical row, two consumers
     (authentik signs, adminweb verifies).
   - It also *narrows* an existing hazard. Every native provider here shares one
     signing certificate, so a Grafana or ArgoCD token verifies cleanly against
     another's JWKS and only `aud` separates them. A per-provider HMAC key means
     a token from elsewhere is not merely wrong-audience, it is unverifiable.

4. **The header is `X-authentik-jwt`,** added to the shared
   `authentik-forwardauth` Middleware's `authResponseHeaders`. Taken from
   authentik's own Traefik middleware generator
   (`providers/proxy/controllers/k8s/traefik_3.py:120-133`), which forwards
   `X-authentik-username/groups/entitlements/email/name/uid/jwt` and
   `X-authentik-meta-jwks`. The outpost does **not** send `Authorization: Bearer`
   or `X-Forwarded-Access-Token`. The addition is additive and inert for the
   existing consumers, which read none of it.

5. **No scope mapping was added, and none was needed.** `set_oauth_defaults()`
   binds `openid`, `profile`, `email`, `entitlements` and `ak_proxy`
   automatically, and the stock `profile` mapping returns
   `"groups": [group.name for group in request.user.groups.all()]` — the same
   route ArgoCD and Grafana read `platform-admins` from. The handover asked for a
   custom mapping; it would have been dead weight.

6. **Authorization is two checks for two paths, and that is deliberate.** The
   `policybinding` to `platform-admins` gates the browser hop at `/authorize`.
   It does **not** gate the `client_credentials` or `password` grants, which
   `set_oauth_defaults()` force-enables and which cannot be turned off — so any
   directory user's username and password can mint a token for this audience.
   adminweb's own `platform-admins` check on the claim is what contains that.
   **Accepted risk, with a named consequence:** that check must never be relaxed
   to "any valid token for my audience", and the app's tests pin it.

7. **`wird_admin`, a role that can read six tables and update three columns.**
   `SELECT` on `users`, `set_prayers`, `sync_outcomes`, `reports`, `root_senses`,
   `corpus_meta`; `UPDATE (category, status, issue_url)` on `reports`; nothing
   else — no DDL, no `report_inbox`, no sequences. Deliberately **not**
   `dbrole_readonly`, which Pigsty would have made a one-liner and which grants
   `SELECT` on every table including `report_inbox`, the one table wird's ADR-0026
   keeps out of reach. Delivered as `wird-admin-config`, a second Secret rather
   than two more keys in `wird-config`, so the boundary between adminweb's role
   and wird-api's is an actual grant and not a naming convention.

8. **The agent is a service account in the same group, not an exception.**
   adminweb applies one authorization rule to humans and machines alike. The
   account and its app-password token are minted out of band; the group
   membership is one `!Find` line in `authentik-blueprint-groups.yaml`, because
   that list is replaced on every apply and a UI click would be erased by the next
   one. The token goes to Infisical and then to the maintainer — nothing in
   `gitops/` reads it, and adminweb is never given a way to mint its own callers'
   tokens.

## Consequences

- **Two cross-file `!Find`s have known, self-healing failure modes.** The outpost
  list in `authentik-blueprint-forwardauth.yaml` references this provider by
  `!Find` (because `!KeyOf` resolves only within one blueprint), and the policy
  file references the application the same way. Both fail closed and both
  self-heal on the next discovery pass — but blueprint discovery runs at **worker
  boot** only, and the policy file sorts before the provider file, so expect more
  than one restart. ADR-0051 needed three. The runbook's §4 is the check: the
  outpost's provider list must name both `e2e-previews` and `wird-admin`.
- **`hermes`, `wedding/admin` and the preview hosts now receive one more response
  header.** Harmless — they read none of it — but `X-authentik-jwt` is a signed
  credential in transit, so it reaches exactly the hosts the routes send it to and
  should not be logged.
- **A fourth consumer of the Pigsty primary that is not described by
  `pigsty.yml`.** `wird_admin` is created by SQL, not by a `pg_users` entry, so
  the file stops being a complete description of who can log in. The runbook says
  to read the SCRAM hash back and add the entry with `roles: []`.
- **`pigsty.yml`'s `pg_role` labels were found inverted** while picking a target
  for that SQL: Patroni reports `.205` leader, the file said `.207` primary. The
  file's own comment predicts this and warns that a `pgsql-*` run against the
  standby creates nothing and still prints a green `PLAY RECAP`. Correcting the
  labels is in the runbook's §0 — it is a label, not a mechanism, but the next
  reader deserves one that is true.
- **Nothing here is reachable until the four out-of-band steps run.** The two
  Infisical rows gate both the provider blueprint and the app Secret; without the
  DB role adminweb starts and fails its first query; without the service account
  the agent path does not exist. The Application will sync and the host will 302
  to authentik regardless, which is the right order: gated and broken beats open
  and working.
