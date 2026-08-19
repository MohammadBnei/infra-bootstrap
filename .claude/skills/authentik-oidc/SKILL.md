---
name: authentik-oidc
description: Connect an app to authentik as an OIDC client on ukubi-cluster — declarative blueprint, credentials via Infisical, no clicking in the UI. Use when the user asks to put an app behind authentik, federate a login, add SSO to a service, or wire OAuth2/OIDC to authentik.
user-invocable: true
allowed-tools:
  - Read
  - Bash(helm show values *)
  - Bash(helm template *)
  - Bash(ssh k9s kubectl get *)
  - Bash(ssh k9s kubectl exec -n authentik deploy/platform-authentik-server -- *)
  - Bash(ssh k9s kubectl logs *)
  - Bash(infisical secrets *)
  - Bash(git *)
---

# /authentik-oidc — put an app behind authentik

authentik is the cluster's identity provider (ADR-0039), at
`authentik.bnei.dev`, backed by Pigsty Postgres. This skill is for the **Native
OIDC tier**: apps that speak OIDC themselves. For apps that *don't*, the answer
is a forwardAuth proxy provider, which is a different shape and not covered here.

**Everything is declarative.** No step in this skill says "click" — providers
and applications are authentik *blueprints*, delivered as Kubernetes Secrets and
reconciled on every authentik restart. A provider created by hand in the UI is
invisible to git, survives no rebuild, and cannot be reviewed.

## The shape

Three pieces per app, all in `gitops/`:

| Piece | Where | Why |
|---|---|---|
| Blueprint (provider + application) | `gitops/bootstrap/authentik-blueprint-<app>.yaml` | An `InfisicalSecret` whose template *is* the blueprint YAML |
| Client credentials for the app | `gitops/bootstrap/<app>-oidc-secret.yaml` | Same two values, materialised into the app's namespace |
| App's own OIDC config | that app's values file | Endpoints + attribute mapping |

The **same credential pair is consumed twice**, from opposite ends: authentik
registers it on the provider, the app presents it at the token endpoint. One
pair, two namespaces.

### Why the blueprint is a Secret, not a ConfigMap

The chart mounts blueprints from `blueprints.configMaps` *or*
`blueprints.secrets` and discovers any key ending in `.yaml`. A blueprint
embeds an OAuth2 client secret, so a ConfigMap would put it in plaintext in git.

Using an `InfisicalSecret` template keeps the blueprint's **structure** in git —
reviewable, diffable — while only the credential values are interpolated by the
operator.

## Do this

### 1. Generate and store the credentials

```bash
PROJ=8a3fa54f-be22-488a-bf51-55158f65c0f2
CID=$(python3 -c "import secrets,string; print(''.join(secrets.choice(string.ascii_lowercase+string.digits) for _ in range(40)))")
CSEC=$(python3 -c "import secrets,string; print(''.join(secrets.choice(string.ascii_letters+string.digits) for _ in range(64)))")
infisical secrets set "<APP>_OIDC_CLIENT_ID=$CID"     --projectId="$PROJ" --env=dev --type=shared
infisical secrets set "<APP>_OIDC_CLIENT_SECRET=$CSEC" --projectId="$PROJ" --env=dev --type=shared
unset CID CSEC
```

Never echo either value. Add both to `docs/secrets.md`'s table.

### 2. Write the blueprint

Copy `gitops/bootstrap/authentik-blueprint-grafana.yaml` and change the app
name, slug and redirect URI. The model names and field shapes below are **verified
against the running 2026.8.0 instance**, not taken from docs.

```yaml
- model: authentik_providers_oauth2.oauth2provider
  id: <app>-provider
  identifiers:
    name: <app>
  attrs:
    name: <app>
    client_type: confidential
    client_id: "{{ .<APP>_OIDC_CLIENT_ID.Value }}"
    client_secret: "{{ .<APP>_OIDC_CLIENT_SECRET.Value }}"
    redirect_uris:
      - matching_mode: strict
        url: https://<app>.bnei.dev/<callback path>
    # REQUIRED. Defaults to empty, and empty means no grant is permitted —
    # every login fails with "Invalid grant_type for provider" in authentik's
    # log while the client shows only a generic malformed-request error.
    grant_types:
      - authorization_code
      - refresh_token
    sub_mode: user_email
    authorization_flow: !Find [authentik_flows.flow, [slug, default-provider-authorization-implicit-consent]]
    invalidation_flow: !Find [authentik_flows.flow, [slug, default-provider-invalidation-flow]]
    signing_key: !Find [authentik_crypto.certificatekeypair, [name, "authentik Self-signed Certificate"]]
    property_mappings:
      - !Find [authentik_providers_oauth2.scopemapping, [managed, "goauthentik.io/providers/oauth2/scope-openid"]]
      - !Find [authentik_providers_oauth2.scopemapping, [managed, "goauthentik.io/providers/oauth2/scope-email"]]
      - !Find [authentik_providers_oauth2.scopemapping, [managed, "goauthentik.io/providers/oauth2/scope-profile"]]
- model: authentik_core.application
  identifiers:
    slug: <app>
  attrs:
    name: <App>
    slug: <app>
    provider: !KeyOf <app>-provider
```

Then add the Secret name to `blueprints.secrets` in
`gitops/platform/values/authentik/values.yaml`.

### 3. Wire the app

Endpoints are the same for every app:

```
authorize   https://authentik.bnei.dev/application/o/authorize/
token       https://authentik.bnei.dev/application/o/token/
userinfo    https://authentik.bnei.dev/application/o/userinfo/
issuer      https://authentik.bnei.dev/application/o/<slug>/
```

Deliver `client_id`/`client_secret` as **env vars from a Secret**, never written
into a ConfigMap-backed config file.

## Traps

**`grant_types` must be set explicitly.** It defaults to empty, and empty
permits nothing. The provider is created, the discovery document is served and
still advertises `authorization_code`, and every login fails. authentik logs
`Invalid grant_type for provider`; the client sees only
`invalid_request / The request is otherwise malformed`, which points nowhere
near the cause. Confirmed by reading the stored value: `grant_types: {}`.

**`redirect_uris` is a list of OBJECTS, not strings.** In 2026.x it is
`[{matching_mode, url}]`. A bare string list is valid YAML, is accepted, and
produces a provider that rejects every callback with no useful error.

**`sub_mode` and the app's login attribute must agree.** `sub_mode: user_email`
with an app expecting a username means logins succeed and map to the wrong user
— worse than failing.

**Never `cat` a mounted blueprint.** It contains the client secret in
plaintext. Read the InfisicalSecret manifest in git instead — it has the same
structure with the values templated out. (Learned by leaking a pair this way on
2026-08-19 and having to rotate.)

**Rotating means restarting BOTH sides.** authentik's copy arrives as a mounted
file, which kubelet syncs within ~60s but which discovery only re-reads on a
worker restart. The app's copy is an env var, bound at container start and never
re-read.

**Env vars are bound at container start.** Rotating a client secret updates the
Secret but not the running process. The app's pod must be restarted, or it keeps
presenting the old one. This is the same trap that silently broke ACME renewal
on 2026-08-18 (`docs/bootstrap-test-notes.md`) — anything reading a rotated
secret through `env:` + `secretKeyRef` has it. Deployments carrying
`secrets.infisical.com/auto-reload: "true"` are restarted by the operator
automatically; add it rather than relying on remembering.

**Keep the app's local admin.** ADR-0039 Decision 6: a Traefik `ClientIP()`
break-glass route bypasses a *middleware*, but cannot bypass an app's own OIDC
redirect. ArgoCD is also what deploys authentik. Dropping local admins makes an
authentik outage unrecoverable through anything but `kubectl`.

**Default new users to the lowest role.** `role_attribute_path: "'Viewer'"` or
equivalent. Granting admin on first login makes OIDC a privilege escalation
rather than a convenience.

## Roles: one group, read by every app

Do not write a per-app allowlist. Membership lives in **one** blueprint —
`gitops/bootstrap/authentik-blueprint-groups.yaml`, a plain ConfigMap because
group membership carries no credential — and every app maps the same group
name to its own admin role:

| App | Where |
|---|---|
| ArgoCD | `configs.rbac.policy.csv: g, platform-admins, role:admin` |
| Grafana | `role_attribute_path: contains(groups[*], 'platform-admins') && 'Admin' \|\| 'Viewer'` |

Adding a person is then one line in one file, not an edit per app.

`platform-admins` is deliberately **not** authentik's built-in
`authentik Admins`. Reusing that would make "can administer the IdP" and "can
administer the cluster" the same claim, so making someone an authentik admin
would silently grant them everything else too.

Write the expression so a **missing** claim yields the LOW role. Both forms
above do: no `groups` claim means no match means Viewer / `policy.default`. An
expression that defaults high turns a broken group lookup into privilege
escalation.

### Groups are in the ID token. Do NOT reach for userinfo.

authentik's `profile` scope mapping emits `groups`, and providers default to
`include_claims_in_id_token = True`, so the ID token already carries what RBAC
needs. Read it from the token authentik actually issued, not from a log line:

```bash
ssh k9s kubectl exec -n authentik deploy/platform-authentik-server -- ak shell -c "
from authentik.providers.oauth2.models import AccessToken
t=AccessToken.objects.filter(provider__name='<app>').order_by('-expires').first()
print('TOK::', dict(t.id_token).get('groups','ABSENT'))" | grep TOK::
```

**An application's own log of 'the claims' is not the token.** ArgoCD's
`grpc.request.claims` field showed every profile claim and no `groups` key,
which read as authoritative and is not. The token had groups all along.

Acting on that misreading, `enableUserInfoGroups: true` +
`userInfoPath` were set on ArgoCD — and **that broke login for everyone**.
`authentik.bnei.dev` is proxied at Cloudflare, and a server-side request from
a pod is answered with Cloudflare **error 1010** (Browser Integrity Check
blocks non-browser user agents). ArgoCD tries to parse HTML as JSON and
invalidates the session:

```
invalid session: error fetching user info endpoint:
failed to decode response body to struct:
invalid character '<' looking for beginning of value
```

Every logged-in user is signed out — the userinfo path fails **open into a
total outage**, not closed into a lower role.

The general rule: **an in-cluster caller reaching a `*.bnei.dev` name transits
Cloudflare**, so anything on that path must survive Browser Integrity Check.
Prefer a claim already in the token, or an in-cluster Service address, over a
server-side call to a public hostname.

Verify the result rather than the config — ArgoCD will answer directly:

```bash
ssh k9s kubectl exec -n argocd deploy/argocd-server -- \
  argocd admin settings rbac can <email> sync applications '*/*' --namespace argocd
```

`Yes`/`No`, no interpretation needed. **The UI is not evidence**: ArgoCD hides
nothing based on RBAC — a read-only user sees every application, every
settings page and every action button, and only finds out on the click. That
is why a read-only login was mistaken for an admin one.

## When the app's config file is rewritten by its own chart

Grafana takes its credentials as env vars from a Secret, which is the easy
case. Some apps only read OIDC config out of a ConfigMap their chart owns and
overwrites on every sync — ArgoCD's `argocd-cm` is the example in this repo.
Writing the client secret there means committing it to git.

ArgoCD's escape hatch is a `$<secret-name>:<key>` reference in the ConfigMap,
resolved at runtime against a Secret in ArgoCD's own namespace. **That Secret
must carry the label `app.kubernetes.io/part-of: argocd`** or the reference
does not resolve — and it does not fail loudly: ArgoCD hands the literal string
`$argocd-oidc:clientSecret` to authentik as the client secret, so the failure
surfaces at the token endpoint, long after startup, looking like a wrong
credential.

`managedSecretReference` has no labels field (checked against the installed
CRD). The lever is that **the Infisical operator copies the CR's labels and
annotations onto the managed Secret** — so the label goes on the
`InfisicalSecret`'s own `metadata.labels`, in the `infisical` namespace, and
lands on the Secret it creates in `argocd`. See
`gitops/bootstrap/argocd-oidc-secret.yaml`.

Check for this shape before assuming the Grafana pattern applies: if the app's
Helm chart renders the config the credential goes into, the credential cannot
live in the values file.

## Redirect URIs: the CLI is a second one

An app with a command-line client usually authenticates through a loopback
listener, which is a **different redirect URI on the same provider**. ArgoCD's
`argocd login --sso` uses `http://localhost:8085/auth/callback` alongside the
web UI's `https://argocd.bnei.dev/auth/callback`.

Omitting it does not break the browser login, so the gap shows up later, only
for the CLI, as a `redirect_uri` mismatch. Add both up front.

## `required: []` in that schema means nothing

The oauth2provider model declares **no required fields at all**. A missing field
is never flagged — it is silently defaulted, and some defaults are unusable.
`grant_types` defaulting to empty is the sharp one: empty permits nothing, so
every login fails while the provider, the application and the discovery document
all look correct.

So schema validation passing tells you the YAML is well-formed, not that the
provider will function. The only proof is a real login.

## Getting the runtime facts yourself

Do not trust this file's slugs after an authentik upgrade — re-read them.

Model names and field shapes, from the instance's own schema:

```bash
ssh k9s kubectl exec -n authentik deploy/platform-authentik-server -- cat /blueprints/schema.json \
  | python3 -c "
import sys,json; d=json.load(sys.stdin); defs=d.get('\$defs',{})
m=defs['model_authentik_providers_oauth2.oauth2provider']
print('required:', m.get('required')); print('properties:', sorted(m['properties']))
print('redirect_uris:', json.dumps(m['properties']['redirect_uris'])[:300])"
```

Flow slugs, scope-mapping `managed` strings and signing keys live in the
database, not in any file. Query via a Pigsty node (`pigsty/ansible.cfg` carries
a broken Vagrant `private_key_file`, so override it — see
`docs/bootstrap-test-notes.md`):

```bash
.claude/skills/run-ukubi-ops/driver.sh fetch-ssh-key SSH_OLDPG_KEY "$SP/oldpg_key"
cd pigsty && ansible 192.168.1.205 -b --private-key="$SP/oldpg_key" -m shell \
  -a "su - postgres -c \"psql -d authentik -tAc 'SELECT slug FROM authentik_flows_flow ORDER BY slug'\""
rm -f "$SP/oldpg_key"
```

## Changing a blueprint: the four-step propagation chain

**Skipping either restart leaves everything looking healthy while nothing has
changed.** This is the single most time-consuming thing about the workflow, and
none of it surfaces as an error.

```
1. merge                     -> ArgoCD applies the updated InfisicalSecret CR
2. restart infisical-operator -> ONLY needed when the CR TEMPLATE changed
3. restart authentik worker   -> discovery re-reads and re-applies the blueprint
                              -> CHECK THE FILE IS MOUNTED FIRST; kubelet syncs
                                 the volume ~a minute behind the API object, and
                                 discovery only reads at boot
4. restart the client app     -> only if ITS credentials changed (env vars)
```

### Step 2 is the non-obvious one

The Infisical operator reconciles on **Infisical value changes**, not on CR
template changes. Verified 2026-08-19: ArgoCD applied a CR whose template gained
a new field, the live CR contained it, and the managed Secret kept its old
content indefinitely. Restarting the operator forces a full reconcile:

```bash
ssh k9s kubectl rollout restart deploy/platform-infisi-controller-manager -n infisical
```

**Do NOT delete the managed Secret to force regeneration.** These use
`creationPolicy: Orphan`, so the operator does not own them and will not
recreate one that vanishes — observed staying gone for 105 seconds until the
operator was restarted anyway. Deleting is strictly worse than restarting: same
outcome, plus a window where the app's mount is missing.

### Verifying each step rather than assuming

```bash
# 1. did ArgoCD apply the CR?
ssh k9s kubectl get infisicalsecret <name> -n infisical -o yaml | grep <new-field>

# 2. did the operator re-render the Secret? (decode, do not cat the mount)
kubectl get secret <name> -n authentik -o json | python3 -c \
  "import sys,json,base64;print(base64.b64decode(json.load(sys.stdin)['data']['<key>.yaml']).decode())" \
  | grep <new-field>

# 3. did authentik apply it? (the DB is the only honest answer)
psql -d authentik -tAc "SELECT grant_types FROM authentik_providers_oauth2_oauth2provider"
```

## The blueprint will not apply until you restart the worker

**This is the step that costs an hour if you do not know it.**

Blueprints are applied by the **worker**, not the server — only the worker
deployment gets the `blueprints.secrets` volume, so describing
`platform-authentik-server` and finding no mount is expected and means nothing.

`blueprints_discovery` is enqueued when the worker boots. Observed on 2026-08-19:
it was enqueued at pod start and **never executed** — the log showed
`Task enqueued` with no matching `Task started` or `Task finished`, while other
tasks in the same queue ran normally. The blueprint sat mounted and correct,
and no provider was created. Nothing reported an error anywhere.

So after adding or changing a blueprint Secret:

```bash
ssh k9s kubectl rollout restart deploy/platform-authentik-worker -n authentik
```

Discovery then runs and the objects appear within seconds.

### Restart AFTER the file is mounted, not on merge

**Order matters, and getting it wrong looks exactly like the failure above.**
`blueprints_discovery` reads the directory at boot and on a slow schedule — it
does not watch it. Kubelet syncs a ConfigMap or Secret volume asynchronously,
around a minute behind the API object. So a restart fired on merge boots a pod
whose blueprint file has not landed yet, discovery finds nothing, and the next
run is far away.

Measured 2026-08-19: worker pod up at 10:23:55, the only discovery run at
10:24:25 registered nothing, and calling `blueprints_find()` by hand in that
same pod two minutes later returned the file. The pod was fine. The restart was
just early.

Confirm the file is there, *then* restart:

```bash
ssh k9s kubectl exec -n authentik deploy/platform-authentik-worker -- \
  find /blueprints/mounted -maxdepth 2 -name '*.yaml'
ssh k9s kubectl rollout restart deploy/platform-authentik-worker -n authentik
```

A second restart is the fix whenever the objects have not appeared and the file
is present — cheap, and the first thing to try before reading any logs.

### Diagnosing when it still does not work

In order, because each step rules out the one below:

```bash
# 1. is the file actually in the WORKER pod? (not the server)
ssh k9s kubectl exec -n authentik deploy/platform-authentik-worker -- \
  find /blueprints/mounted -maxdepth 3

# 2. did discovery run, or only get enqueued?
ssh k9s kubectl logs -n authentik deploy/platform-authentik-worker --since=20m \
  | grep blueprints_discovery

# 3. is the blueprint registered, and did it apply?
#    (via a Pigsty node — see docs/bootstrap-test-notes.md for the key override)
psql -d authentik -tAc \
  "SELECT name,path,status FROM authentik_blueprints_blueprintinstance"

# 4. did the objects appear?
psql -d authentik -tAc "SELECT count(*) FROM authentik_providers_oauth2_oauth2provider"
```

A Kubernetes Secret mount looks alarming but is fine: it creates `..data` and
`..<timestamp>` symlink directories alongside the real filename. authentik's
discovery skips any path containing a part starting with `.`
(`blueprints/v1/tasks.py`), so the timestamped copy is ignored and the plain
symlink is picked up. Verified — `rglob` yields both and only the dotted one is
filtered.

## Verify

A blueprint that fails to apply does **not** crash authentik — it logs and
carries on, so a green Application proves nothing:

```bash
ssh k9s kubectl logs -n authentik -l app.kubernetes.io/name=authentik --since=5m | grep -iE "blueprint|<app>"
```

Then confirm the provider actually exists, rather than assuming the blueprint
was read:

```bash
curl -s https://authentik.bnei.dev/application/o/<slug>/.well-known/openid-configuration | head -c 300
```

An `IntegrityError` on `blueprintinstance_name_path` at startup is a known
benign race between the server and worker both running discovery — harmless if
it does not recur.

Finally, drive a real login. "The provider exists" and "a user can log in" are
different claims.
