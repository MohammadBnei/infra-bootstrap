# Runbook — authentik identity layer (ADR-0039)

Part runbook, part reference. authentik is the cluster's identity provider; the
expensive parts of operating it are not the YAML but the propagation chain in §9
and the field shapes in §8, neither of which produces an error when it is wrong.

**Related:** [ADR-0039](adr/0039-authentik-identity-layer.md) is the decision and
rationale. `.claude/skills/authentik-oidc/SKILL.md` (`/authentik-oidc`) is the
step-by-step procedure for connecting a new app. This file is the reference: what
is deployed, why it is shaped this way, and what fails silently.

## 1. Goal

Operate the deployed identity layer: change who can administer the cluster,
connect an application to it, and prove a change actually took effect rather than
merely appearing to.

The failure mode this document exists to prevent is uniform across every section
below: **the object is correct, every status is green, and nothing has happened.**
Blueprints do not hot-reload, the Infisical operator does not re-render on
template changes, and a blueprint that fails to apply logs and carries on. None
of those surfaces as an error anywhere.

Three instances of it, each one a **derived view mistaken for the thing itself**:

| What was read | What it actually was | Cost |
|---|---|---|
| Alloy reporting a loaded component | a component tailing a host path that did not exist | audit log written, rotated, never read |
| `blueprints_discovery` logging `Task finished` | a run that read the directory ~30s before the file landed | a blueprint that never applied, diagnosed for hours |
| ArgoCD's `grpc.request.claims` log field | a summary ArgoCD emits, not the token authentik issued | a fictional anomaly, a config change to route around it, and a total login outage (§6) |

**The rule: read the artefact, not a report about the artefact.** The database,
not the Application status. The stored token, not the log line naming the claims.
The file in the pod, not the ConfigMap in the API. Every verification command in
§11 is chosen on that basis, and the third row above is the sharpest: a config
change was shipped on the strength of a log field and it took login down.

## 2. Prerequisites

- `ssh k9s` reaches the cluster and `kubectl` there is bound to `ukubi-cluster`.
- Infisical CLI authenticated against project `8a3fa54f-be22-488a-bf51-55158f65c0f2`,
  env `dev`, for anything touching credentials (`docs/secrets.md`).
- Pigsty is up. authentik's database is **outside** the cluster — the ArgoCD
  Application being `Healthy` says nothing about whether Postgres is reachable.
- A merged PR to `main`. `gitops/bootstrap/` is self-syncing via the flat
  `bootstrap` Application (ADR-0021), so no `kubectl apply` follows a merge — but
  see §9, because "ArgoCD applied it" and "it took effect" are different claims.

## 3. What exists

authentik **2026.8.0** at `https://authentik.bnei.dev`, deployed by ArgoCD from
the upstream chart (`https://charts.goauthentik.io`) as a **platform** app —
`gitops/bootstrap/platform.applicationset.yaml`, sync wave 5 — with values in
`gitops/platform/values/authentik/values.yaml`. It is not in
`gitops/apps/registry.yaml`: that ApplicationSet hardcodes
`path: gitops/platform/common-app-chart` and requires a per-app git repo, so a
registry entry would render the wrong chart out of a repo that does not exist
(ADR-0039 Decision 1).

Route: `gitops/bootstrap/authentik-ingressroute.yaml`, Traefik `IngressRoute`
with the `cloudflare-origin-lock` middleware and **no forwardAuth** — authentik
cannot authenticate the requests that reach authentik. It is the one host in the
admin tier that must serve its own login flow unauthenticated.

### Database: Pigsty, port 5432

Not an in-cluster Postgres and not the chart's bundled one — `postgresql.enabled:
false`. The connection targets `postgres.bnei.lan:5432`, i.e. Postgres directly
rather than pgbouncer on 6432: Pigsty's pgbouncer defaults to transaction
pooling, which breaks the prepared statements and persistent connections a Django
application relies on. The hostname rather than `192.168.1.232` because CoreDNS
forwards to Pi-hole precisely so pods can resolve the Pigsty VIP by name
(`ARCHITECTURE.md` §3) — the name survives an IP change.

The DB user is `dbuser_authentik`, declared in `pigsty/pigsty.yml` with a
**SCRAM-SHA-256 verifier** in place of a password. Pigsty passes `user.password`
verbatim into `ALTER USER … PASSWORD '…'` and Postgres stores a well-formed
verifier as-is instead of re-hashing it, so authentication is identical while what
lands in git is non-reversible. The plaintext half exists only in Infisical as
`DBUSER_AUTHENTIK_PASSWORD`.

> **Rotation must regenerate both halves together.** A verifier cannot be turned
> back into the password it verifies, so changing one side alone leaves the two
> silently inconsistent and the failure appears as an authentication error with
> no indication of which copy is stale.

### No Redis

ADR-0039 Decision 2 says Redis stays an in-cluster subchart. That is wrong for
this version and was never deployed. 2026.8.0 declares exactly two chart
dependencies — `postgresql` (conditional) and `authentik-remote-cluster` — and
exposes no redis, cache or broker values at all. Upstream moved session and task
state onto Postgres. One fewer component to run, patch and back up.

### Configuration is one Secret, all or nothing

`authentik.existingSecret.secretName: authentik-config` makes the chart skip
creating its own Secret and read **all** configuration from the named one; its own
warning is *"when set, `authentik.*` secret values are ignored"*. There is no
mixing `existingSecret` with individual values keys. So the non-secret settings
(host, database name, user, port) sit in `gitops/bootstrap/authentik-secret.yaml`
alongside the secret ones — they are not secrets, the mechanism is simply
all-or-nothing.

Key names are the chart's: `templates/_helpers.tpl` flattens nested maps with a
**double** underscore, so `authentik.postgresql.password` becomes
`AUTHENTIK_POSTGRESQL__PASSWORD`. A single underscore silently does nothing.

`log_level` is deliberately left in the values file rather than the Secret: it is
an operational knob someone will want to raise while debugging a login flow, and
it should be editable in git without touching Infisical.

## 4. Everything is a blueprint

No provider, application or group is ever created by clicking in the UI. A clicked
object is invisible to git, survives no rebuild, and cannot be reviewed.

Blueprints are mounted from `blueprints.configMaps` **and** `blueprints.secrets`
in the values file; the chart discovers any key ending in `.yaml`. There are two
delivery shapes, and the choice between them is not cosmetic:

| Shape | Used for | Why |
|---|---|---|
| `InfisicalSecret` whose template *is* the blueprint | anything embedding an OAuth2 client secret | the blueprint's structure stays in git — reviewable, diffable — while only the credential values are interpolated by the operator. A ConfigMap would put the client secret in plaintext in git |
| plain `ConfigMap` | group membership | carries no credential, so there is nothing to interpolate and nothing to hide — and it removes the Infisical operator from the propagation chain entirely (§9 step 2 does not apply) |

Current files:

| File | Contents |
|---|---|
| `gitops/bootstrap/authentik-blueprint-grafana.yaml` | Grafana's OAuth2 provider + application (Secret) |
| `gitops/bootstrap/authentik-blueprint-argocd.yaml` | ArgoCD's provider + application (Secret) |
| `gitops/bootstrap/authentik-blueprint-groups.yaml` | the `platform-admins` group (plain ConfigMap) |
| `gitops/bootstrap/grafana-oidc-secret.yaml` | the client pair materialised into `monitoring` |
| `gitops/bootstrap/argocd-oidc-secret.yaml` | the client pair materialised into `argocd` — see §7, this one is not symmetric with Grafana's |

The **same credential pair is consumed twice**, from opposite ends of the
exchange: authentik registers it on the provider via the blueprint, the app
presents it at the token endpoint via its own Secret. One pair, two namespaces,
one Infisical row.

## 5. Roles — one group, read by every app

`platform-admins` is the single place that says who operates this cluster.

| App | Where it is read | Expression |
|---|---|---|
| ArgoCD | `gitops/bootstrap/argocd-application.yaml` | `configs.rbac.policy.default: role:readonly` + `policy.csv: g, platform-admins, role:admin` + `scopes: "[groups, email]"` |
| Grafana | `gitops/platform/values/grafana/values.yaml` | `role_attribute_path: contains(groups[*], 'platform-admins') && 'Admin' \|\| 'Viewer'`, with `allow_assign_grafana_admin: false` |

Adding a person is one line in one file, not a per-app allowlist that drifts.

**It is deliberately not `authentik Admins`.** That built-in group already exists
and already contains this user. Reusing it would make "can administer the identity
provider" and "can administer the cluster" the same claim — so making someone an
authentik admin, for any reason, would silently hand them ArgoCD admin and Grafana
admin as well. Two separate powers, two separate groups.

**`is_superuser` is deliberately unset** on `platform-admins`. It is a label that
applications read; it grants nothing inside authentik itself.

**The `users:` list is replaced, not merged, on every apply.** That file is the
entire membership of the group. Deleting a line removes that person's access
everywhere the group is honoured — which is the point, and also the trap.

**Both role expressions fail closed *on a missing claim*.** A `groups` claim that
is absent or does not contain `platform-admins` yields Viewer in Grafana and
`policy.default` (`role:readonly`) in ArgoCD, never admin. An expression that
defaults high turns a broken group lookup into privilege escalation.

That property covers the *mapping*, and nothing else. It says nothing about how
the surrounding machinery fails: ArgoCD configured to fetch groups from the
userinfo endpoint does **not** degrade to `policy.default` when that call breaks —
it rejects the session outright and nobody logs in. See §6. Do not generalise
"the role expression fails closed" into "the login path fails closed".

`allow_assign_grafana_admin: false` grants org Admin, not Grafana **server**
admin. Server admin manages users, orgs and the instance itself; nothing about
operating this cluster needs it, and the local admin already has it.

**Local admin accounts stay enabled on both apps** (ADR-0039 Decision 6). A
Traefik `ClientIP()` break-glass route bypasses a *middleware*; it cannot bypass
an application's own OIDC redirect. ArgoCD is also what deploys authentik, so
dropping its local admin would make an authentik outage recoverable only through
`kubectl`. Federation here is additive, never a replacement.

## 6. Where the `groups` claim comes from

**It comes from the ID token.** An earlier revision of this runbook recorded an
"open anomaly" here — that the ID token arrived without a `groups` key. That was
wrong, and acting on it took ArgoCD login down. Both the misdiagnosis and the
outage are documented below, because the mistake is more instructive than the
correct answer.

There is **no dedicated `groups` scope mapping** in this instance. The complete
set present on 2026.8.0, read from the database:

```
openid  email  profile  entitlements  offline_access
ak_proxy  goauthentik.io/api  goauthentik.io/oidc/dcr  bound_key
```

Groups come from the **`profile`** mapping, whose expression includes:

```python
"groups": [group.name for group in request.user.groups.all()],
```

`user.groups.all()` returns `['authentik Admins', 'platform-admins']` for the
`akadmin` account, and both OAuth2 providers have `include_claims_in_id_token =
True`. That is the whole mechanism. Nothing else is required, and **no server-side
call to the userinfo endpoint is needed to obtain groups.**

### Read the token authentik actually issued

Not a log line about it — the stored token:

```bash
cat > /tmp/tok.py <<'PY'
from authentik.providers.oauth2.models import AccessToken
t = AccessToken.objects.filter(provider__name='argocd').order_by('-expires').first()
d = t.id_token.to_dict()          # NOT dict(t.id_token) — IDToken is not iterable
print('TOK:: keys=', sorted(d.keys()))
print('TOK:: groups=', d.get('groups', 'ABSENT'))
PY
ssh k9s "kubectl exec -i -n authentik deploy/platform-authentik-server -- ak shell" < /tmp/tok.py | grep 'TOK::'
```

Verified 2026-08-19:

```
TOK:: keys= ['acr','aud','auth_time','email','email_verified','exp','given_name',
             'groups','iat','iss','jti','name','nickname','picture',
             'preferred_username','sid','sub']
TOK:: groups= ['authentik Admins', 'platform-admins']
```

The claim was there all along.

### The misdiagnosis: a log field is not the token

What had been read was ArgoCD's `grpc.request.claims` **log field**, which is a
derived summary emitted by ArgoCD — not the token authentik issued. It omitted
`groups`. Reading it as "the claims" produced a confident, entirely fictional
anomaly, and a config change to route around it.

### ArgoCD MUST NOT be given `enableUserInfoGroups`

The change made to route around the non-existent anomaly was
`enableUserInfoGroups: true` + `userInfoPath: /application/o/userinfo/` +
`userInfoCacheExpiration: 5m` in `argocd-cm`. It made ArgoCD call authentik's
userinfo endpoint **server-side, from a pod**.

`authentik.bnei.dev` is proxied at Cloudflare (ADR-0038), and that request was
answered by Cloudflare, not authentik:

```
URL:: https://authentik.bnei.dev/application/o/userinfo/ => 403 :: b'error code: 1010\n'
```

Error 1010 is Cloudflare's **Browser Integrity Check**, which blocks non-browser
user agents. ArgoCD then tried to parse Cloudflare's HTML error page as JSON and
discarded the session:

```
rpc error: code = Unauthenticated desc = invalid session: error fetching user info
endpoint: failed to decode response body to struct: invalid character '<' looking
for beginning of value
```

Every user who had logged in through authentik saw "not logged in".

> **The userinfo path fails OPEN into a total outage, not closed into a lower
> role.** An earlier revision of this document claimed the opposite — that a
> broken userinfo call would merely demote the user to `policy.default`. It does
> not. ArgoCD treats the failure as an invalid session and rejects the request
> outright. A reassuring claim about a failure mode that had never been exercised
> is worse than no claim.

Fixed in **PR #187** by removing the three keys. Groups now come from the ID token;
`policy.csv` and `scopes` are unchanged and were never the problem. Verified live:
`argocd-cm`'s `oidc.config` carries `name`, `issuer`, `clientID`, `clientSecret`
and `requestedScopes` only, and the current `argocd-server` pod's log contains
zero `user info endpoint` errors.

### Grafana's `api_url` is a separate matter and stays

Grafana's `api_url: https://authentik.bnei.dev/application/o/userinfo/` is
unchanged. It takes the same public path and evidently passes Browser Integrity
Check today — but that is an observation about Cloudflare's current heuristics,
not a guarantee, and §10 covers the general rule. Grafana's group mapping has
never been observed resolving to Admin end to end; see §13.

## 7. The ArgoCD credential plumbing

Grafana is the easy case: credentials arrive as env vars from a Secret
(`GF_AUTH_GENERIC_OAUTH_CLIENT_ID` / `_SECRET` via `envValueFrom`), so they never
land in a ConfigMap.

ArgoCD's OIDC config lives in `argocd-cm`, a ConfigMap the argo-cd chart
**rewrites on every selfHeal**. The client secret can therefore go neither there
nor in `argocd-secret` — the same reasoning already worked out at length in the
`githubSecret` comment in `gitops/bootstrap/argocd-application.yaml`.

ArgoCD's escape hatch is a `$<secret-name>:<key>` reference in `argocd-cm`,
resolved at runtime against a Secret in ArgoCD's own namespace — **but only if
that Secret carries the label `app.kubernetes.io/part-of: argocd`**.

The lever that makes that declarative:

- `managedSecretReference` in the InfisicalSecret CRD has **no labels field**
  (confirmed against the installed CRD — its properties are `creationPolicy`,
  `secretName`, `secretNamespace`, `secretType`, `template`).
- **The Infisical operator copies the CR's labels *and* annotations onto the
  managed Secret.** So the label goes on the `InfisicalSecret` in the `infisical`
  namespace and lands on the Secret it creates in `argocd`. This was verifiable
  before relying on it: the pre-existing `grafana-oidc` Secret carries an
  `argocd.argoproj.io/tracking-id` annotation naming the *InfisicalSecret CR*
  rather than itself — an annotation that could only have been inherited.

> **Failure mode if the label is missing:** ArgoCD hands the literal string
> `$argocd-oidc:clientSecret` to authentik as the client secret. Nothing fails at
> startup. It surfaces at the token endpoint, *after* a successful authentik
> login, looking exactly like a wrong credential.

Before assuming the Grafana pattern applies to a new app, check whether its Helm
chart renders the file the credential goes into. If it does, the credential cannot
live in the values file.

## 8. Field shapes, verified against the running 2026.8.0

Everything in this section was **read off the running instance**, not taken from
documentation. **Re-read it after an authentik upgrade** — none of it is a stable
contract.

The blueprint schema lives at `/blueprints/schema.json` in the server pod. Its
models are under the **`definitions`** key, **not `$defs`**. A first pass querying
`$defs` reported that no proxy provider model existed at all, which is a
convincing-looking wrong answer produced by an empty `.get()` default.

```bash
ssh k9s "kubectl exec -i -n authentik deploy/platform-authentik-server -- ak shell" < probe.py
```

(Pipe a script over stdin. Any `kubectl exec` payload containing parentheses,
braces or spaces gets re-shelled and mangled by SSH — recorded four separate
times in `docs/bootstrap-test-notes.md`.)

### `model_authentik_providers_oauth2.oauth2provider`

**`required: []`** — the model declares **no required fields at all**. A missing
field is never flagged; it is silently defaulted, and some defaults are unusable.
Schema validation passing tells you the YAML is well-formed, not that the provider
will function. The only proof is a real login.

| Field | Shape / value | Why it matters |
|---|---|---|
| `grant_types` | must be set explicitly: `[authorization_code, refresh_token]` | Defaults to **empty**, and empty permits *no* grant. The provider is created, the discovery document is served and still advertises `authorization_code`, and every login fails. authentik logs `Invalid grant_type for provider`; the client sees only `invalid_request / The request is otherwise malformed`, which points nowhere near the cause |
| `redirect_uris` | list of **objects** — `{matching_mode, url}`, `matching_mode` ∈ `strict\|regex`; an optional `redirect_uri_type` ∈ `authorization\|logout` also exists | A bare string list is valid YAML, is accepted, and produces a provider that rejects every callback with no useful error |
| `sub_mode` | `user_email` | Must agree with what the app keys users on (`login_attribute_path` in Grafana, the `sub` claim in ArgoCD). If they disagree, logins **succeed** and map to the wrong user — worse than failing |
| issuer | derived from the **application slug**, with a trailing slash: `https://authentik.bnei.dev/application/o/<slug>/` | ArgoCD compares the issuer in the ID token against its configured string exactly. A missing trailing slash fails verification *after* a successful login, which reads as a broken callback rather than a typo |

**An app with a CLI needs a second redirect URI.** `argocd login --sso` uses a
loopback listener at `http://localhost:8085/auth/callback` — a different client
flow on the same provider. Omitting it does not break the browser login at all, so
the gap surfaces later, only for the CLI, as a `redirect_uri` mismatch.

### `model_authentik_providers_proxy.proxyprovider` — reference only, **not deployed**

Carried here so the forwardAuth tier (§13) does not have to rediscover it.

- `mode` enum: `proxy | forward_single | forward_domain`. The schema's own
  description: *"Enable support for forwardAuth in traefik and nginx auth_request.
  Exclusive with internal_host."*
- Other relevant properties: `cookie_domain`, `skip_path_regex`,
  `intercept_header_auth`, `basic_auth_enabled`, `external_host`, `internal_host`.
- The **embedded outpost** is named `authentik Embedded Outpost`, managed string
  `goauthentik.io/outposts/embedded`, and currently has **zero providers**. A proxy
  provider does nothing until it is bound to an outpost.
- **That outpost's `providers` list is replaced, not appended** — the same trap as
  the group's `users:` list. The whole forwardAuth tier therefore has to live in
  **one** blueprint file, unlike the Native OIDC tier which has one file per app.
  Separate files would silently unbind each other, last writer winning.
- The authentik Service exposes **80/443 only** (targetPorts 9000/9443; port 9000
  is not on the Service). A Traefik forwardAuth address is therefore
  `http://platform-authentik-server.authentik.svc.cluster.local/outpost.goauthentik.io/auth/traefik`.
- The **Base URL** system setting (System → Settings) is optional in 2026.8 and
  **required in 2026.11**. It is UI state, not chart config — nothing in the values
  file can express it. Proxy providers build their redirect URLs from it. Read live
  on 2026-08-19 as `https://authentik.bnei.dev`, i.e. **already non-empty**; the
  `TODO` in `gitops/platform/values/authentik/values.yaml` predates that. Re-check
  it before the forwardAuth tier lands and again after any upgrade, since it cannot
  be reconstructed from git.

## 9. Steps

### 9.1 The propagation chain — the most expensive thing to not know

**Nothing in this stack hot-reloads. Skipping any step leaves everything looking
healthy.**

```
1. merge                       -> ArgoCD applies the CR / ConfigMap
2. restart infisical-operator  -> ONLY when the CR TEMPLATE changed
3. confirm the file is mounted, THEN restart the authentik worker
4. restart the client app      -> only if ITS credentials changed (env vars)
```

**Step 2 — the operator does not re-render on template-only changes.** It
reconciles on *Infisical value* changes, not on CR template changes. Verified
2026-08-19: ArgoCD applied a CR whose template had gained `grant_types`, the live
CR contained it, and the managed Secret kept its old content indefinitely.

```bash
ssh k9s kubectl rollout restart deploy/platform-infisi-controller-manager -n infisical
```

Not needed for `authentik-blueprint-groups.yaml`, which is a plain ConfigMap with
no operator in its path.

**Step 3 — ordering, and this is the part that costs hours.** Blueprints are
applied by the **worker**, not the server: only the worker deployment gets the
blueprint volumes, so describing the server pod and finding no mount is expected
and means nothing.

`blueprints_discovery` reads the directory at boot and on a slow schedule — **it
does not watch it**. Kubelet syncs a ConfigMap or Secret volume asynchronously,
roughly a minute behind the API object. So a restart fired the moment ArgoCD
reports `Synced` boots a pod whose blueprint file has not landed yet, discovery
runs against a directory that does not contain it, and the next scheduled run is
far enough away to look like never.

Measured 2026-08-19 while adding the `platform-admins` group: worker pod up at
**10:23:55**, its only discovery run at **10:24:25** registered nothing, and
calling authentik's own `blueprints_find()` by hand *in that same pod* around
**10:26** returned the file correctly, with the right metadata and version. The pod
was healthy, the blueprint was valid, the restart was early. A second restart
applied it in seconds.

Everything was green throughout: ConfigMap present with the right content, volume
on the worker Deployment, file present in the pod, `blueprints_discovery` logging
both `Task started` **and** `Task finished`, and no warning, error or traceback at
any level.

> **The rule: confirm the file, then restart — and try a second restart before
> believing any deeper theory.** The fix and the cause are the same action at
> different times.

```bash
ssh k9s kubectl exec -n authentik deploy/platform-authentik-worker -- \
  find /blueprints/mounted -maxdepth 2 -name '*.yaml'
ssh k9s kubectl rollout restart deploy/platform-authentik-worker -n authentik
```

There is a **separate, previously recorded** failure with an identical symptom:
`blueprints_discovery` *enqueued at worker boot and never executed* — `Task
enqueued` with no matching `Task started`, no error anywhere, other tasks in the
same queue running normally. The earlier Grafana incident (2026-08-19,
`docs/bootstrap-test-notes.md`) was attributed to that enqueue failure and **did
not rule out the mount race**. Both are real; neither can be distinguished from
the other by the symptom. Restart twice before diagnosing.

**Step 4 — env vars bind at container start.** Rotating a credential updates the
Secret but not the running process, so the app keeps presenting the old one.

### 9.2 Add a person to the admin group

1. Add one line to `users:` in `gitops/bootstrap/authentik-blueprint-groups.yaml`:
   ```yaml
   - !Find [authentik_core.user, [username, <username>]]
   ```
   `!Find` resolves to the user's primary key. It does **not** create the account
   and does not manage it — declaring an `authentik_core.user` entry instead would
   put this file in charge of the account itself, which is not wanted.
2. PR, review, merge. ArgoCD applies the ConfigMap.
3. **Confirm the file is mounted** in the *worker*, then restart the worker (§9.1
   step 3). No operator restart — this is a plain ConfigMap.
4. Verify with the Group query in §11. Do not verify by logging in and looking at
   the ArgoCD UI (§10).

> `users:` is **replaced, not merged**. The list in that file is the entire
> membership; removing a line removes that person from ArgoCD admin *and* Grafana
> Admin at once.

### 9.3 Connect a new app

**The operational procedure is `/authentik-oidc`
(`.claude/skills/authentik-oidc/SKILL.md`).** It carries the copy-paste blueprint,
the credential-generation commands and the per-step verification. This runbook is
the reference and the rationale; the skill is what to follow. The shape it walks:

1. Generate `<APP>_OIDC_CLIENT_ID` / `<APP>_OIDC_CLIENT_SECRET` into Infisical
   (never echoed), and add both rows to `docs/secrets.md`.
2. Write `gitops/bootstrap/authentik-blueprint-<app>.yaml` — an `InfisicalSecret`
   whose template is the blueprint, with the §8 field shapes.
3. Register the Secret name in `blueprints.secrets` in
   `gitops/platform/values/authentik/values.yaml`. A blueprint not listed there is
   never mounted and never applies.
4. Write `gitops/bootstrap/<app>-oidc-secret.yaml` to materialise the same pair
   into the app's namespace — and check §7 first: if the app's chart rewrites the
   file the credential goes into, the Grafana pattern does not apply.
5. Configure the app: `authorize` and `token` endpoints, `issuer` with its
   trailing slash, and a group→role mapping that fails closed. **Take groups from
   the ID token** — the `profile` scope carries them (§6). Configure a server-side
   `userinfo` call only if the app cannot read the claim, and then read §10 first:
   that call leaves the cluster and comes back through Cloudflare.
6. Walk the propagation chain (§9.1), then verify with §11.

## 10. Traps and safety rules

**An in-cluster caller reaching a `*.bnei.dev` name transits Cloudflare.** Pods
resolve those names publicly, so a pod-to-pod-looking request to
`https://authentik.bnei.dev/...` leaves the cluster, is answered by Cloudflare's
edge, and must survive **Browser Integrity Check** — which exists to block
non-browser user agents, i.e. exactly what a server-side HTTP client is. When it
does not survive, the caller receives an HTML error page (`error code: 1010`) with
a 403, and whatever was expecting JSON fails in whichever way that library fails.

This holds today for the OIDC authorization redirect (a browser makes it) and for
Grafana's userinfo call, which is precisely why it stayed invisible until
something with a plainer user agent tried the same path and took ArgoCD login down
(§6). It is heuristic, not a rule: a probe from a pod with `curl` returned
authentik's own **401** rather than Cloudflare's 1010 on 2026-08-19, so *one*
client getting through proves nothing about another.

> **Prefer a claim already in the token, or an in-cluster Service address
> (`platform-authentik-server.authentik.svc.cluster.local`), over a server-side
> call to a public hostname.** If a public hostname is unavoidable, exercise the
> exact failure — the success path tells you nothing.

**Do NOT delete a managed Secret to force a re-render.** These use
`creationPolicy: Orphan`, so the operator does not own them and will not recreate
one that vanishes — observed staying gone for 105 seconds until the operator was
restarted anyway. Strictly worse than restarting the operator: same outcome, plus
a window in which the app's mount is missing.

**Never `cat` a mounted blueprint, and never `kubectl get secret -o yaml`.** Both
print live credentials to a terminal and a transcript. A Cloudflare token and a
Grafana OIDC pair were both leaked this way during this work and had to be
rotated. Read the `InfisicalSecret` manifest in git instead — identical structure,
values templated out — or use a jsonpath scoped to `.metadata`.

**Add `secrets.infisical.com/auto-reload: "true"`** to any Deployment consuming a
rotatable credential through `env:` + `secretKeyRef`, rather than relying on
remembering to restart it. This is the same trap that silently broke ACME renewal
on 2026-08-18.

**ArgoCD's UI hides nothing based on RBAC.** A `role:readonly` user sees every
application, every settings page and every action button, and finds out only on
the click. This caused a read-only login to be mistaken for an admin one. Grafana,
by contrast, names the role and hides editing controls. **Do not use the UI as
evidence of permission** — use the `rbac can` query in §11.

**`..data` symlinks are harmless.** A Secret or ConfigMap mount creates `..data`
and `..<timestamp>` symlink directories alongside the real filename. authentik's
discovery skips any path with a part starting with `.`
(`blueprints/v1/tasks.py`), so the timestamped copy is ignored and the plain
symlink is picked up. Verified by running `rglob` in the pod: it yields both, and
only the dotted one is filtered. Alarming to look at, not the problem.

**`IntegrityError` on `blueprintinstance_name_path` at startup** is a known benign
race between server and worker both running discovery. Harmless if it does not
recur.

## 11. Verification

`ak shell -c` writes a large volume of JSON startup logs to stdout. **Prefix every
print with a marker and grep for it**, or the output is unreadable.

```bash
# is the blueprint registered and applied? (the DB is the only honest answer)
ssh k9s kubectl exec -n authentik deploy/platform-authentik-server -- ak shell -c "
from authentik.blueprints.models import BlueprintInstance
for b in BlueprintInstance.objects.filter(path__contains='mounted'): print('BP::', b.name, b.status)"

# who is in the group?
ssh k9s kubectl exec -n authentik deploy/platform-authentik-server -- ak shell -c "
from authentik.core.models import Group
for g in Group.objects.all(): print('GROUP::', g.name, [u.username for u in g.users.all()])"

# is the file in the WORKER pod (not the server)?
ssh k9s kubectl exec -n authentik deploy/platform-authentik-worker -- \
  find /blueprints/mounted -maxdepth 2 -name '*.yaml'

# does the provider exist and serve discovery?
curl -s https://authentik.bnei.dev/application/o/<slug>/.well-known/openid-configuration | head -c 300

# does ArgoCD actually grant what you think? Yes/No, no interpretation needed.
ssh k9s kubectl exec -n argocd deploy/argocd-server -- \
  argocd admin settings rbac can platform-admins sync applications '*/*' --namespace argocd

# what claims did authentik ACTUALLY issue? (see the script in §6 — read the
# stored token, never a log field claiming to summarise it)
```

`argocd admin settings rbac can <subject>` evaluates a subject **in isolation**,
without group membership. A `platform-admins` member therefore correctly shows
`sync -> No` when queried by email and `sync -> Yes` when queried by group name.
Both were observed; neither is a bug. Query the **group** to test the policy, the
**email** only to test a per-user rule.

A blueprint that fails to apply does not crash authentik — it logs and carries on,
so a green ArgoCD Application proves nothing:

```bash
ssh k9s kubectl logs -n authentik deploy/platform-authentik-worker --since=20m | grep blueprints_discovery
```

**None of the above proves a login works.** They test the objects, not the
exchange. `argocd-cm` should also be read directly after any OIDC change — the
chart rewrites it on every selfHeal, so what is in git and what is served are
separate facts:

```bash
ssh k9s "kubectl get cm argocd-cm -n argocd -o jsonpath='{.data.oidc\.config}'"
ssh k9s kubectl logs -n argocd deploy/argocd-server --since=1h | grep -c 'user info endpoint'
```

Expect the config to carry `name`, `issuer`, `clientID`, `clientSecret` and
`requestedScopes` and **nothing about userinfo** (§6), and the error count to be
zero.

Finally: **drive a real login, and check the role it lands in.** "The provider
exists", "a user can log in" and "that user is an admin" are three different
claims. §8 is a list of ways the first can be true while the second is false, and
§6 is what happens when the third is assumed from a log line.

**Last verified state (2026-08-19):**

```
BP:: grafana-oidc successful
BP:: argocd-oidc successful
BP:: platform-groups successful
GROUP:: platform-admins ['akadmin']
platform-admins sync applications '*/*' -> Yes
TOK:: groups= ['authentik Admins', 'platform-admins']
argocd-cm oidc.config: no userinfo keys (PR #187)
argocd-server 'user info endpoint' errors: 0
```

## 12. Rollback

**Federation is fully revertible**, and that is by design rather than luck.

| Change | How to undo |
|---|---|
| Grafana OIDC | Remove the `auth.generic_oauth` block from `gitops/platform/values/grafana/values.yaml`. The local admin from `admin:` still works |
| ArgoCD OIDC | Remove `configs.cm.oidc.config` (and the `rbac` block if desired) from `gitops/bootstrap/argocd-application.yaml`. The local `admin` account still works |
| Group membership | `git revert`, then confirm the mount and restart the worker (§9.1). Membership is replaced wholesale on apply, so a revert is exact |
| A blueprint | Removing the file also requires removing its name from `blueprints.secrets`/`configMaps`. Deleting the blueprint does **not** delete the objects it created — those remain in authentik's database until removed there |
| The whole layer | Delete the `authentik` entry from `platform.applicationset.yaml`. The Pigsty `authentik` database and `dbuser_authentik` survive; removing those is a `pigsty/pigsty.yml` change and a pigsty run |

**An authentik outage does not lock you out of ArgoCD or Grafana** — because the
local admins were kept. That is the entire reason ADR-0039 Decision 6 exists, and
it is the property to preserve when anything here changes. ArgoCD is what deploys
authentik; if ArgoCD's only login path ran through authentik, an authentik failure
would be recoverable through nothing but raw `kubectl`.

What is **not** cleanly reversible: `AUTHENTIK_SECRET_KEY`. Upstream is explicit
that changing it after first install invalidates every session and every unique
user ID. Treat it as immutable.

## 13. Not built yet

- **forwardAuth tier** — `fleet.bnei.dev`, e2e previews, Alertmanager, pgweb,
  Proxmox. Design and task list in infra-bootstrap issue
  [#183](https://github.com/MohammadBnei/infra-bootstrap/issues/183) and agent-fleet
  issue [#209](https://github.com/MohammadBnei/agent-fleet/issues/209). Retiring the
  shared `basic-admin-auth` credential (an `apr1`/MD5 hash that is in
  `k8s-cluster`'s git history) spans three repos and has to land in one go. §8 has
  the verified proxy-provider shape and the one-file constraint.
- **WebAuthn passkeys** on the critical tier (Proxmox, ArgoCD, Infisical,
  Alertmanager) — ADR-0039 Decision 4. At least two devices should be enrolled
  before any policy enforces it.
- **LAN `ClientIP()` break-glass routes**, plus the Pi-hole split-horizon DNS
  entries they depend on. Split-horizon is the *enabling condition*, not a nicety:
  once records are proxied, a LAN client resolving `argocd.bnei.dev` reaches
  Cloudflare and arrives back at the origin with a Cloudflare source IP, so the
  `ClientIP()` match never fires.
- **Re-check the Base URL setting** (§8) before the forwardAuth tier and after any
  upgrade — it is UI state that no manifest can reconstruct.
- **In-cluster traffic to `*.bnei.dev` hairpins through Cloudflare** (§10). PR #187
  removed the one caller that this broke; the underlying condition is untouched and
  will bite the next server-side integration. Two options, neither taken yet:
  - a **CoreDNS rewrite** pointing `*.bnei.dev` at the Traefik VIP `192.168.1.233`,
    which keeps the traffic on the LAN and out of Cloudflare entirely — the same
    split-horizon idea the break-glass routes need from Pi-hole, one layer down;
  - a **Cloudflare Configuration Rule disabling Browser Integrity Check** for
    hostnames that serve API clients. The perimeter plan already anticipated such
    exemptions for `s3`, `ente-api` and `fleet`; `authentik` belongs on that list,
    since it is by definition talked to by machines.
- **Confirm Grafana's `role_attribute_path` actually resolves to Admin.** It has
  never been observed working end to end — a login that lands in Viewer is
  indistinguishable from one where the group never arrived, and Grafana's userinfo
  call takes the same Cloudflare path that broke ArgoCD's. It evidently passes
  Browser Integrity Check today; that is an observation, not a guarantee.

Log anything surprising to `docs/bootstrap-test-notes.md`, not to memory.
