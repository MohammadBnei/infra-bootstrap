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

**`redirect_uris` is a list of OBJECTS, not strings.** In 2026.x it is
`[{matching_mode, url}]`. A bare string list is valid YAML, is accepted, and
produces a provider that rejects every callback with no useful error.

**`sub_mode` and the app's login attribute must agree.** `sub_mode: user_email`
with an app expecting a username means logins succeed and map to the wrong user
— worse than failing.

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
