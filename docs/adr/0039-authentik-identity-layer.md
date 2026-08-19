# ADR-0039: authentik as the cluster's identity layer

**Status:** Accepted (Native OIDC tier implemented 2026-08-19; forwardAuth, WebAuthn and `basic-admin-auth` retirement still pending — see the implementation notes at the end. Decision 2's Redis clause is wrong)
**Date:** 2026-08-18
**Depends on:** [ADR-0038](0038-cloudflare-proxy-dns01-and-origin-lock.md)
(`externalTrafficPolicy: Local` is what makes the LAN break-glass route below
possible at all)

## Context

There is no authentication layer in this cluster. There is one Traefik `basicAuth`
middleware, `basic-admin-auth`, and it is shared verbatim by Alertmanager, pgweb,
the agent-fleet dashboard, and every ephemeral e2e preview route. It is a single
`apr1` (MD5) htpasswd line with no per-user identity, no second factor, no session,
no revocation short of changing the one credential everywhere, and no audit trail of
who used it. Its hash is committed in the legacy `k8s-cluster` repo and
`gitops/bootstrap/basic-admin-auth-secret.yaml` records that it was deliberately
carried over unrotated during migration.

Everything else authenticates on its own or not at all. ArgoCD has a local admin and
no `dex.config`/`oidc.config`. Grafana has an admin password from a Secret and no
`[auth]` section. `proxmox.bnei.dev` reaches a hypervisor root login with its
middleware reference sitting commented out three lines below it in
`gitops/redirectors/proxmox.yaml`. `infisical.bnei.dev` exposes the secrets store
behind its own login form. `searxng` runs with `limiter: false`.

ADR-0038 puts a WAF and a geo filter in front of all of it, which reduces who can
knock. It does nothing about what happens when someone who is allowed to knock
reaches an admin service. That is this ADR.

The operator asked specifically for "special access for my devices for critical
services." The obvious mechanisms are mostly unavailable here: `DECISION.md` §3
forbids Wireguard/Tailscale (ADR-0009) and a service mesh (ADR-0011), and ADR-0006
rejected Infisical as a CA — so no VPN, no mesh identity, and no in-house PKI to
issue client certificates from. An IP allowlist does not survive roaming.

## Decision

1. **authentik is the identity provider**, deployed by ArgoCD from the upstream
   chart at `charts.goauthentik.io`. It therefore belongs in
   `gitops/bootstrap/platform.applicationset.yaml` — the `chartRepoURL`/`chartName`/
   `valuesPath` shape already used for longhorn, infisical and grafana — **not** in
   `gitops/apps/registry.yaml`, whose schema requires a per-app git repo and whose
   ApplicationSet template hardcodes `path: gitops/platform/common-app-chart`.
   A registry entry would render common-app-chart out of a nonexistent authentik
   repo, and `gitops/scripts/check-app-registry-sync.sh` would pass it, because it
   checks mirroring rather than shape.

2. **Postgres comes from Pigsty**, via a new `authentik` database and user in
   `pg_databases`, reached at the HA floating VIP `192.168.1.232`. The chart's
   bundled Postgres is documented upstream as demo-grade and `postgresql.enabled`
   already defaults to `false`. This is not the "external managed Postgres" ADR-0010
   rejected — Pigsty is self-hosted, on this LAN, and already carries HA failover,
   backups and monitoring that a second in-cluster Postgres would not. Redis stays
   an in-cluster subchart on `longhorn`.

3. **Four access tiers**, assigned by what each service can actually do:

   | Tier | Hosts | Gate |
   |---|---|---|
   | Public | `blog`, `dreamer`, `searxng`, `ente-*`, `api.voconsteroid.com` | Baseline middleware chain only |
   | Native OIDC | Grafana, ArgoCD, `fleet` | Federated to authentik as an OIDC provider |
   | forwardAuth | Alertmanager, pgweb, Proxmox, e2e previews | authentik proxy provider |
   | Critical | Proxmox, ArgoCD, Infisical, Alertmanager | The above **plus** a policy requiring WebAuthn |

   forwardAuth is used only where the application cannot federate. Where it can,
   OIDC is preferred: a forwardAuth header in front of a service that still has its
   own login is two authentication systems, not one.

   > **Amended 2026-08-19 by [ADR-0041](0041-fleet-native-oidc-not-forwardauth.md).**
   > `fleet` was in the forwardAuth row above, on the correct premise that
   > agent-fleet's `core` did not speak OIDC. It now does, and the rule in this
   > paragraph then points the other way. The move is not a preference: a
   > middleware gates the ingress, and the hole on that host (agent-fleet#200) is
   > a caller on the pod network that never reaches the ingress. The e2e previews
   > stay here — they route to a session's own dev-server pod, with no fleet code
   > in the request path to terminate OIDC with.

4. **"Special access for my devices" is WebAuthn passkeys, not client certificates.**
   A passkey is hardware-bound, non-exportable and phishing-resistant — the same
   properties a client certificate has — while roaming on mobile data and requiring
   no CA, no enrolment tooling and no revocation list. Critical-tier services get an
   authentik policy binding that requires a passkey, not merely password + TOTP.

   mTLS at the edge was considered and is structurally unavailable after ADR-0038:
   Cloudflare terminates TLS, so a client certificate never reaches Traefik. Any
   mTLS-gated host would have to stay grey-cloud, which republishes the origin IP
   and voids the perimeter for every other host.

5. **Break-glass is a LAN route that skips the auth chain.** Each admin host gets two
   routes: a higher-priority `Host(...) && ClientIP(192.168.1.0/24)` with no auth
   middleware, and the normal internet route with the full chain. Traefik v3 matches
   source IP in the routing rule natively, so this needs no OR-semantics workaround.
   Route `priority` is set explicitly rather than relying on Traefik's rule-length
   default, so a later rule edit cannot silently reorder them.

   **Pi-hole split-horizon entries for `*.bnei.dev` → `192.168.1.233` are mandatory,
   not optional.** Once records are proxied, a LAN client resolving `argocd.bnei.dev`
   receives a Cloudflare anycast address, egresses to Cloudflare and returns with a
   Cloudflare source IP; the `ClientIP()` route would never match. Split-horizon DNS
   is the sole enabling condition for this entire mechanism.

6. **ArgoCD and Grafana keep their local admin accounts.** A `ClientIP()` route
   bypasses a Traefik middleware; it cannot bypass an application's *own* OIDC
   redirect. Since ArgoCD is also what deploys authentik, dropping its local admin
   would make an authentik outage unrecoverable through anything but `kubectl`. The
   local admins are the second half of break-glass, and OIDC federation is additive.

7. **`basic-admin-auth` is retired**, not left alongside. Its consumers are:
   `gitops/bootstrap/alertmanager-ingressroute.yaml`,
   `gitops/platform/values/pgweb/values.yaml`, `gitops/redirectors/proxmox.yaml`,
   `agent-fleet/k8s/core.yaml` (external repo — the only one of the five
   external-repo apps that sets `ingress.middlewares`, so removing the Middleware
   without a coordinated agent-fleet PR leaves `fleet.bnei.dev`'s router in error),
   `agent-fleet/provisioner/internal/k8s/expose.go` (a hardcoded Go middleware map
   for e2e previews), and in the legacy repo `k8s-cluster/jaeger/service.yml` and
   `k8s-cluster/traefik/values.yml`. Retirement also removes the
   `gitops/bootstrap/basic-admin-auth-*.yaml` pair, the `docs/secrets.md` row, the
   `gitops/README.md` references, and — because `creationPolicy: Orphan` — requires
   a manual `kubectl delete secret authsecret -n default`.

   Until that lands, `BASIC_AUTH_HTPASSWD` is rotated to bcrypt. Note that
   `k8s-cluster/traefik/middlewares/basicauth.yml` is a *second* definition of the
   same Middleware with a hardcoded Secret, so re-running the legacy install
   instructions silently reverts the rotation.

## Consequences

- **authentik becomes a single point of failure for admin services**, mitigated but
  not eliminated by Decisions 5 and 6. An authentik outage costs browser access to
  Alertmanager and pgweb from outside the LAN; it does not cost cluster access.
- **It also becomes a dependency on Pigsty.** A Postgres failover, or the etcd DCS
  quorum that Patroni rides on, now sits underneath every admin login. This is a new
  coupling between the platform tier and the database tier that did not previously
  exist.
- **The observability stack ends up behind the thing it would be used to debug.**
  Grafana and Alertmanager are how an authentik failure would be diagnosed. The LAN
  route is the answer, which means diagnosing an authentik outage from outside the
  house is not supported.
- **A NetworkPolicy carve-out is required** for authentik → `192.168.1.232:5432`.
  That is exactly the pod-to-LAN-Postgres flow ADR-0040's default-deny exists to
  block, and it must be written before default-deny lands or authentik breaks.
- **Losing every enrolled passkey means losing critical-tier access** by the intended
  path. Recovery is the LAN route plus a local admin, which is why Decision 6 is not
  optional. At least two devices should be enrolled before the policy is enforced.
- **Two more secrets** (`AUTHENTIK_SECRET_KEY`, `AUTHENTIK_PG_PASSWORD`) join
  Infisical. A per-app Infisical project is preferred over the project root: the
  `envFrom` behaviour documented in `gitops/platform/values/zot/values.yaml` injects
  every root-path secret into the pod as environment variables, which for a
  root-scoped app currently means all 54 including `GARAGE_ROOT_TOKEN`.
- **e2e preview routes change auth mechanism**, so `agent-fleet`'s provisioner needs
  a coordinated change and image rebuild alongside the hostname rename in ADR-0038.
- **`searxng` and the public tier gain no authentication**, by design. They gain the
  baseline chain only.

## Alternatives considered

- **Authelia.** Materially lighter: a file-based user backend, no Postgres, no Redis
  for a single-instance deployment, and it now has an OIDC provider. Rejected on the
  operator's explicit preference for authentik, whose OIDC provider, WebAuthn
  handling and application catalogue are more mature — but it is the honest lazier
  option and would be the right call if authentik's operational weight becomes a
  problem.
- **oauth2-proxy in front of each service with an external IdP.** Rejected: it
  outsources identity for a homelab whose entire premise is self-hosting, and it
  gives no in-cluster OIDC provider for Grafana and ArgoCD to federate against.
- **Cloudflare Access.** Free for 50 users, enforces identity and device posture at
  the edge before traffic reaches the house, and would compose neatly with ADR-0038.
  Rejected as the primary mechanism: it places the identity plane entirely at a third
  party and provides no OIDC provider for in-cluster federation. It remains available
  as an additional outer layer for critical-tier hosts if passkeys prove insufficient.
- **Keep `basic-admin-auth`, just rotate it to bcrypt.** Rejected: it fixes the
  algorithm and none of the structural problems — still one shared credential, still
  no per-user identity, still no second factor, still no revocation, still no record
  of who authenticated.
- **mTLS client certificates at Traefik.** Rejected on two independent grounds:
  ADR-0006 and `DECISION.md` §3 leave no sanctioned CA to issue from, and ADR-0038's
  edge termination means a client certificate cannot reach the origin at all.
- **Revive the archived Ory stack** (`k8s-cluster/archive/ory/` — Kratos, Hydra,
  Oathkeeper; `DBUSER_ORY_PASSWORD` is still a live row in `docs/secrets.md`).
  Rejected: three services to operate where one suffices, and it was already
  abandoned once.


---

## Implementation note (added during implementation, 2026-08-19)

Appended rather than edited into the decisions above, per `DECISION.md` §5.

### Decision 2's Redis clause is wrong — there is no Redis

Decision 2 says *"Redis stays an in-cluster subchart on `longhorn`."* That is
not true of the version being deployed. authentik **2026.5.6** declares exactly
two chart dependencies:

```
postgresql              (condition: postgresql.enabled)
authentik-remote-cluster
```

and its values expose **no** redis, cache or broker keys at all — `authentik.*`
contains only `enabled, log_level, secret_key, events, web, email, outposts,
error_reporting, postgresql`. Upstream moved session and task state onto
Postgres. The only string matching "redis" anywhere in the chart is a Bitnami
common template vendored inside the postgresql subchart.

So the deployment is Postgres-only: one fewer component to run, patch, back up
and reason about. This is a simplification of the accepted decision, not a
deviation from its intent.

### The database password is committed as a SCRAM verifier, not plaintext

Decision 2 chose Pigsty for the database. Acting on that surfaced a problem the
ADR did not anticipate: `pigsty/pigsty.yml` is tracked in git and every existing
`pg_users` entry carries a **plaintext** password. `docs/secrets.md` §112 refers
to a `pigsty.yml.j2` that would keep values out of git — that file does not
exist, and Infisical contains no `DBUSER_*` secrets at all despite the docs
listing four. The documented convention was never implemented.

Rather than commit a sixth plaintext credential, `dbuser_authentik` stores a
**SCRAM-SHA-256 verifier**. `pigsty/roles/pgsql/templates/pg-user.sql:63` passes
`user.password` verbatim into `ALTER USER … PASSWORD '…'`, and Postgres stores a
well-formed verifier as-is instead of hashing it again, so authentication is
identical while what lands in git is non-reversible. The plaintext exists only
in Infisical as `DBUSER_AUTHENTIK_PASSWORD`.

Consequence: rotation now regenerates **both halves together**. A verifier
cannot be turned back into the password it verifies, so the two can silently
drift apart if only one is changed.

The five pre-existing plaintext passwords are a separate problem with a wider
blast radius (rotating them touches Infisical, Pigsty and every consuming app);
recorded in `docs/bootstrap-test-notes.md` rather than fixed here.

### The whole configuration goes through one Secret

`authentik.existingSecret.secretName` makes the chart skip creating its own
Secret and read **all** configuration from the named one — its own warning is
*"when set, `authentik.*` secret values are ignored"*. So the non-secret values
(host, database name, user, port) live in
`gitops/bootstrap/authentik-secret.yaml` too. They are not secrets; the
mechanism is simply all-or-nothing.

Key names are the chart's: `templates/_helpers.tpl` flattens nested maps with a
**double** underscore and uppercases, so `authentik.postgresql.password` becomes
`AUTHENTIK_POSTGRESQL__PASSWORD`. A single underscore silently does nothing.

### Port 5432, not pgbouncer's 6432

Pigsty runs pgbouncer alongside Postgres. authentik is a Django application, and
Pigsty's pgbouncer defaults to transaction pooling, which breaks prepared
statements and persistent connections. The connection targets Postgres directly.
`postgres.bnei.lan` is used rather than `192.168.1.232` because
`ARCHITECTURE.md` §3 records that CoreDNS forwards to Pi-hole explicitly so that
pods can resolve the Pigsty VIP by name.

---

## Implementation note 2 — what was actually built (2026-08-19)

Appended, not merged into the sections above, per `DECISION.md` §5.

**The operational reference is now
[`docs/runbook-authentik-identity.md`](../runbook-authentik-identity.md)** — what
is deployed, how a change propagates, what fails silently, and the field shapes
verified against the running instance. `/authentik-oidc`
(`.claude/skills/authentik-oidc/SKILL.md`) remains the step-by-step procedure for
connecting a new app.

### Built vs. proposed

| Decision | State |
|---|---|
| 1 — authentik from the upstream chart, as a platform app | **Built.** 2026.8.0 (deployed at 2026.5.6, upgraded in PR #174), `gitops/bootstrap/platform.applicationset.yaml` sync wave 5, values in `gitops/platform/values/authentik/values.yaml`, route in `gitops/bootstrap/authentik-ingressroute.yaml` behind `cloudflare-origin-lock` |
| 2 — Pigsty Postgres | **Built**, at `postgres.bnei.lan:5432` rather than the VIP literal and deliberately not pgbouncer's 6432. The Redis clause is void — see implementation note 1. The Consequences section's `AUTHENTIK_PG_PASSWORD` shipped as `DBUSER_AUTHENTIK_PASSWORD`, matching Pigsty's user naming |
| 3 — four access tiers | **Native OIDC tier only.** Grafana and ArgoCD are federated. The forwardAuth and critical tiers are not built (infra-bootstrap #183, agent-fleet #209) |
| 4 — WebAuthn passkeys | **Not built.** No policy binding exists yet |
| 5 — LAN `ClientIP()` break-glass | **Not built.** Blocked on the Pi-hole split-horizon entries, which are its enabling condition, not an optimisation |
| 6 — local admins kept | **Built and load-bearing.** `admin` on ArgoCD and Grafana both still work; this is what makes the whole layer revertible |
| 7 — `basic-admin-auth` retired | **Not done.** Its consumers span three repos and have to change in one go |

### Two structural findings the ADR did not anticipate

**Everything is a blueprint, in one of two shapes.** Anything embedding an OAuth2
client secret is an `InfisicalSecret` whose *template is the blueprint*: structure
in git, credentials interpolated by the operator. Anything that carries no
credential — currently only group membership — is a plain `ConfigMap`, which also
removes the operator from its propagation chain. Nothing is created by clicking.

**Roles converged onto one group.** `platform-admins`, declared in
`gitops/bootstrap/authentik-blueprint-groups.yaml`, is read by ArgoCD
(`g, platform-admins, role:admin` over a `role:readonly` default) and by Grafana
(`role_attribute_path`, defaulting to `Viewer`). It is deliberately **not**
authentik's built-in `authentik Admins`, which would have made "can administer the
IdP" and "can administer the cluster" the same claim. Both expressions fail closed.

### Groups come from the ID token — and one outage caused by believing otherwise

authentik's `profile` scope mapping emits `groups`, both providers have
`include_claims_in_id_token = True`, and the issued token carries
`groups: ['authentik Admins', 'platform-admins']`. Verified by reading the stored
`AccessToken.id_token` on 2026-08-19.

An earlier revision of this note and of the runbook recorded an "open anomaly"
here — an ID token that arrived without `groups`. What had been read was ArgoCD's
`grpc.request.claims` **log field**, a derived summary, not the token. Routing
around the non-existent anomaly with `enableUserInfoGroups` broke login for
everyone: ArgoCD appends `userInfoPath` to the **issuer**, and authentik's issuer
is already per-application, so the request went to
`…/application/o/argocd/application/o/userinfo/` — a 404 with an HTML body, which
ArgoCD parsed as JSON and treated as an invalid session. Fixed in PR #187 by
removing the three keys.

**No value of `userInfoPath` fixes it.** authentik's userinfo endpoint is not
underneath its issuer, so it cannot be expressed as a path relative to it —
`enableUserInfoGroups` is structurally incompatible with this IdP, not
environmentally unlucky. A first diagnosis blamed Cloudflare's Browser Integrity
Check and was wrong; the history is in `docs/bootstrap-test-notes.md`.

The consequence worth carrying forward: the userinfo path **fails open into an
outage**, not closed into a lower role. See the runbook §6 and §10.

### Consequence for Decision 3's remaining tiers

The embedded outpost's `providers` list is **replaced, not appended**, so the
entire forwardAuth tier has to live in a single blueprint file — unlike the Native
OIDC tier, which has one file per app. Separate files would silently unbind each
other. Runbook §8 carries the verified proxy-provider shape.
