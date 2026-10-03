# ADR-0052: `wird-admin.bnei.dev` — a second forwardAuth provider, and the HS256 token nobody expected

**Status:** Accepted — decided 2026-10-03. Manifests merged. Both Infisical rows
(`WIRD_ADMIN_OIDC_CLIENT_SECRET`, `DBUSER_WIRD_ADMIN_PASSWORD`) were created
2026-10-03, and the `wird-agent` group membership is declared in
`authentik-blueprint-groups.yaml`. **The `wird_admin` role and its grants are live as of 2026-10-03**, applied
through Pigsty's own playbooks and verified by privilege tests (see Verified
live). **Still outstanding:** the `wird-agent` service account and its
app-password token, plus the group-membership line that waits on it —
[`docs/runbook-wird-admin-db-role.md`](../runbook-wird-admin-db-role.md) §2.
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

3. **A proxy provider's `client_id` and `client_secret` cannot be declared —
   they are generated, read back, and delivered through Infisical.** Verified
   against the running 2026.8.0: `ProxyProviderSerializer` exposes `client_id`
   as `read_only=True` and has **no `client_secret` field at all**, while
   `OAuth2ProviderSerializer` has both writable. That asymmetry is why
   `authentik-blueprint-wird.yaml` and `-hermes.yaml` can commit a `client_id`
   and this provider cannot. The blueprint importer validates through
   `model().serializer` and DRF drops unknown keys without error, so declaring
   them *succeeds and changes nothing*.

   The first version of this change declared both. It would have shipped a
   provider whose real `aud` and HMAC key were authentik's generated values while
   adminweb pinned mine — a permanent 401 for every user, with nothing in any log
   naming the cause. Caught in review before merge; recorded here because the
   failure is invisible and the next person will reach for the same pattern.

   So: the blueprint creates the provider, the runbook reads both values out into
   Infisical as `WIRD_ADMIN_OIDC_CLIENT_ID`/`_SECRET`, and
   `wird-admin-secret.yaml` delivers them as `OIDC_CLIENT_ID`/`OIDC_CLIENT_SECRET`.
   **Wird reads the audience from that Secret rather than hardcoding it**, which
   also survives a provider recreated on a rebuilt cluster.

4. **The forwarded token is HS256, signed with the provider's `client_secret`.**
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

5. **The header is `X-authentik-jwt`, on a Middleware of its own —
   `wird-admin-forwardauth` — not on the shared one.** The first version added it
   to `authentik-forwardauth`, which previews, `wedding.bnei.dev/admin` and
   `hermes.bnei.dev` all reference, on the reasoning that it was "additive and
   inert because they read none of it". That was wrong in a way worth recording:
   the header is a bearer credential, `intercept_header_auth` defaults to `True`
   on the previews provider, and preview pods run whatever an agent session
   started — so those pods would have received the operator's access token and
   could replay it as `Authorization: Bearer` against any other host that
   provider covers. One extra Middleware object buys that back. Taken from
   authentik's own Traefik middleware generator
   (`providers/proxy/controllers/k8s/traefik_3.py:120-133`), which forwards
   `X-authentik-username/groups/entitlements/email/name/uid/jwt` and
   `X-authentik-meta-jwks`. The outpost does **not** send `Authorization: Bearer`
   or `X-Forwarded-Access-Token`. The addition is additive and inert for the
   existing consumers, which read none of it.

6. **No scope mapping was added, and none was needed.** `set_oauth_defaults()`
   binds `openid`, `profile`, `email`, `entitlements` and `ak_proxy`
   automatically, and the stock `profile` mapping returns
   `"groups": [group.name for group in request.user.groups.all()]` — the same
   route ArgoCD and Grafana read `platform-admins` from. The handover asked for a
   custom mapping; it would have been dead weight.

7. **Authorization is two checks for two paths, and that is deliberate.** The
   `policybinding` to `platform-admins` gates the browser hop at `/authorize`.
   It does **not** gate the `client_credentials` or `password` grants, which
   `set_oauth_defaults()` force-enables and which cannot be turned off — so any
   directory user's username and password can mint a token for this audience.
   adminweb's own `platform-admins` check on the claim is what contains that.
   **Accepted risk, with a named consequence:** that check must never be relaxed
   to "any valid token for my audience", and the app's tests pin it.

8. **`wird_admin` is DECLARED, not hand-created — and the split is forced by
   Pigsty's own model.** `roles/pgsql/templates/pg-user.sql` emits role
   attributes, a password, a comment and GRANTs of *roles*; it has no concept of
   a table grant. So the login role is a `pg_users` entry in `pigsty/pigsty.yml`
   (SCRAM verifier committed, plaintext only in Infisical, `roles: []`,
   `connlimit: 5`, `pgbouncer: false`) applied by
   `./pgsql-user.yml -l pg-proxmox -e username=wird_admin`, and the object
   privileges are `pigsty/files/wird-admin-grants.sql`, attached as wirddb's
   `baseline` and applied by
   `./pgsql-db.yml -l pg-proxmox -e dbname=wirddb --tags pg_db_baseline`.
   A baseline works on an existing database because
   `roles/pgsql/tasks/database.yml:100` gates that task on `database.baseline is
   defined`, not on the database being new — so it re-applies on demand, and
   every statement in the file is idempotent.

   `CONNECT` is in that file and is not optional: wirddb sets `revokeconn: true`,
   and `pg-db.sql` grants CONNECT back to only replicator, monitor, dba and the
   owner. The revoke targets PUBLIC, not named roles, so the grant survives later
   runs.

   The name breaks the `dbuser_*` convention every other entry follows,
   deliberately: wird's ADR-0026, this ADR and the DSN in
   `wird-admin-secret.yaml` all say `wird_admin`, and three documents agreeing
   beats a prefix.

9. **The grant list itself: read six tables, update three columns.**
   `SELECT` on `users`, `set_prayers`, `sync_outcomes`, `reports`, `root_senses`,
   `corpus_meta`; `UPDATE (category, status, issue_url)` on `reports`; nothing
   else — no DDL, no `report_inbox`, no sequences. Deliberately **not**
   `dbrole_readonly`, which Pigsty would have made a one-liner and which grants
   `SELECT` on every table including `report_inbox`, the one table wird's ADR-0026
   keeps out of reach. Delivered as `wird-admin-config`, a second Secret rather
   than two more keys in `wird-config`, so the boundary between adminweb's role
   and wird-api's is an actual grant and not a naming convention.

10. **The agent is a service account in the same group, not an exception.**
   adminweb applies one authorization rule to humans and machines alike. The
   account and its app-password token are minted out of band; the group
   membership is one `!Find` line in `authentik-blueprint-groups.yaml`, because
   that list is replaced on every apply and a UI click would be erased by the next
   one. The token goes to Infisical and then to the maintainer — nothing in
   `gitops/` reads it, and adminweb is never given a way to mint its own callers'
   tokens.

## Consequences

- **`!Find` returning None does NOT skip an entry — it invalidates the
   blueprint.** The first version of this change leaned on "self-healing" twice
   and both were wrong, verified against the serializers: `OutpostSerializer.providers`
   is a `ManyRelatedField` of `PrimaryKeyRelatedField` with `allow_null=False`,
   and `GroupSerializer.users` is a `BulkPrimaryKeyRelatedField` whose
   `to_internal_value` fails the field when fewer rows return than pks requested.
   So a cross-file `!Find` for the outpost list would have taken the **whole
   forwardAuth tier** down — previews' provider, its application and the outpost
   binding — and a premature `wird-agent` line in the groups blueprint would have
   stopped `platform-admins` being reconciled at all, including *removals*, and
   broken the ArgoCD/Grafana bindings that `!Find` it. Hence: the provider lives
   in `authentik-blueprint-forwardauth.yaml` with `!KeyOf`, and the group line
   lands with the account, not before. Only `PolicyBinding.target` keeps a
   cross-file `!Find`, where a rollback costs one gate.
- **The remaining cross-file `!Find` (the policy binding) is self-healing** The outpost
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
- **Pigsty runs work from anywhere, but `pigsty/ansible.cfg` hides how.** It pins
  `remote_user = vagrant` and
  `private_key_file = /home/mohammad/.ssh/id_pigsty_rsa` — a Linux path that on
  macOS resolves to `/System/Volumes/Data/home/mohammad/...` and fails with "no
  such identity". The key itself is in Infisical, under
  **`SSH_OLDPG_KEY`**: confirmed by deriving its public half and matching it
  against the cloud-init key `terraform/imported.tf` records for pg01.
  `docs/secrets.md` had already flagged that on 2026-07-30 ("appears to be a
  shared Pigsty admin key reused across old and new clusters … Confirm before
  assuming it's `.193`-only") — this ADR first claimed no such row existed, which
  was a reading failure, not a gap. The run pattern is therefore
  `-e ansible_ssh_private_key_file=<fetched path>`, as used for this change.
  Renaming the row to `SSH_PIGSTY_*` would be clearer and is worth doing
  deliberately rather than incidentally.
- **The k9s ops hub is the nearest control node and is half-equipped**: it has
  the repo at `/opt/infra-bootstrap`, `infisical` and `psql`, but no
  `ansible-playbook` — the pinned venv from
  `k9s-dashboard-configure.yml -e k9s_hub=true` has not been installed there.
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
