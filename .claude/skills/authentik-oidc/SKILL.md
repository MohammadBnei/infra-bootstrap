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
