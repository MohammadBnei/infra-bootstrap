# Runbook: the `wird_admin` DB role and the Wird agent service account

The four steps of ADR-0052 that are **not** in git, because each one is either a
credential or a privilege grant. Everything else in that ADR syncs itself.

Run these in order. Nothing here is idempotent-by-accident: each step says how to
check whether it has already been done.

---

## 0. Before any SQL: find the real primary

`pigsty/pigsty.yml`'s `pg_role` labels are a **label, not a mechanism** — that
file says so itself, and on 2026-10-03 they were **inverted**:

```
curl -s http://192.168.1.205:8008/cluster | jq -r '.members[] | "\(.name) \(.role) \(.state) \(.host)"'
pg-proxmox-1 leader   running   192.168.1.205
pg-proxmox-2 replica  streaming 192.168.1.207
```

…while the file labelled `.205` replica and `.207` primary. Everything below
therefore targets **`192.168.1.205`** explicitly rather than the VIP or the
label.

This matters beyond this runbook: every task in Pigsty's user/database path is
`ignore_errors: true` with the psql call ending in `|| true`, so a `pgsql-user`
or `pgsql-db` run aimed at the standby creates nothing and still prints a green
`PLAY RECAP`. That is how the first attempt at `dbuser_wird`/`wirddb` silently did
nothing (same file, line ~46).

The labels in `pigsty/pigsty.yml` were **corrected on 2026-10-03** to match. They
are still only labels — Pigsty does not reconcile them and the next Patroni
failover inverts them again with nothing to warn you — so re-run the `curl` above
before any `pgsql-*` run rather than trusting the file.

---

## 1. The `wird_admin` role on `wirddb`

### What it must be able to do, and nothing more

From wird's `server/internal/store/`, confirmed against `main`:

| Table | Grant | Why |
|---|---|---|
| `users`, `set_prayers`, `sync_outcomes`, `reports`, `root_senses` | `SELECT` | `admin.go` reads them |
| `corpus_meta` | `SELECT` | `store.go:150-153`, `SELECT corpus_version, built_at FROM corpus_meta WHERE id = 1` — the dashboard shows "corpus version unreadable" without it |
| `reports` | `UPDATE (category, status, issue_url)` | `admin.go:216`, the only write in the whole operations view |

Not `leaves` — there is no such table; the apparent reference is the English word
in a comment (`admin.go:253`, "the LEFT JOIN leaves s empty"). Not `report_inbox`,
no DDL, no sequences, no other writes. adminweb never migrates; wird-api does.

**Deliberately not `dbrole_readonly`.** Pigsty would make that a one-liner, and it
grants `SELECT` on every table in the database — including `report_inbox`, which
wird's ADR-0026 keeps out of adminweb's reach by design.

### Already done?

```bash
infisical run --projectId=8a3fa54f-be22-488a-bf51-55158f65c0f2 --env=dev -- \
  bash -c 'PGPASSWORD="$PG_SUPERUSER_PASSWORD" psql -h 192.168.1.205 -U postgres -d wirddb \
    -c "\du wird_admin" -c "\dp reports"'
```

### The password already exists, and so does its verifier

**`DBUSER_WIRD_ADMIN_PASSWORD` was created in Infisical on 2026-10-03**, and its
SCRAM-SHA-256 verifier is committed in `pigsty/pigsty.yml`'s `pg_users` entry —
the same arrangement as `dbuser_wird` and `dbuser_authentik`. `pgsql-user.yml`
applies that verifier, so nothing below ever handles the plaintext.

Regenerating the Infisical value without recomputing the verifier (or the other
way round) means the Secret and the role disagree, and adminweb fails
authentication with nothing in the pod log naming the cause.

It was generated as 43 alphanumerics so it needs no percent-encoding in a URL —
the trap `wird-secret.yaml` records for `DBUSER_WIRD_PASSWORD`. For reference,
this is how it was made:

```bash
PROJ=8a3fa54f-be22-488a-bf51-55158f65c0f2
PW=$(python3 -c "import secrets,string; print(''.join(secrets.choice(string.ascii_letters+string.digits) for _ in range(43)))")
infisical secrets set "DBUSER_WIRD_ADMIN_PASSWORD=$PW" --projectId="$PROJ" --env=dev --type=shared
```

### Create it the Pigsty way — two playbooks, no hand-rolled SQL

The role and its grants are both **declared**, in `pigsty/pigsty.yml` and
`pigsty/files/wird-admin-grants.sql`. Nothing here is typed into psql, because a
role created by hand is invisible to the file that is supposed to describe the
cluster.

The split is forced by Pigsty's own model: `roles/pgsql/templates/pg-user.sql`
emits role attributes, a password, a comment and GRANTs of **roles** — it has no
concept of a table grant. Object privileges therefore live in the database's
`baseline`, and `roles/pgsql/tasks/database.yml:100` applies a baseline whenever
one is *defined*, not only when the database is new.

**Run both from `pigsty/`, in this order.** The repo's README is explicit that
the human runs these:

```bash
cd pigsty

# 1. the login role: attributes, SCRAM password, connlimit 5, roles: []
./pgsql-user.yml -l pg-proxmox -e username=wird_admin

# 2. the object privileges, re-applied from files/wird-admin-grants.sql
# BOTH tags. `pg_db_baseline` alone runs psql against a file that was never
# uploaded: "copy baseline" (roles/pgsql/tasks/database.yml:44) is tagged
# pg_db_config, while "load database baseline" (:100) is tagged
# [pg_db_create, pg_db_baseline]. With only the latter, psql fails on a missing
# /pg/tmp/pg-db-wirddb-baseline.sql, ignore_errors swallows it, the recap is
# green, and wird_admin ends up with the role and none of its privileges.
./pgsql-db.yml -l pg-proxmox -e dbname=wirddb --tags pg_db_config,pg_db_baseline
```

Dry-run equivalents, if you want to see the shape first:

```bash
./pgsql-user.yml -l pg-proxmox -e username=wird_admin --check --diff
./pgsql-user.yml --list-tasks
```

### Then distrust the PLAY RECAP

Both of those tasks are `ignore_errors: true` with the psql call ending in
`|| true` — the same property that let the first `dbuser_wird`/`wirddb` attempt
report green having created nothing. A green recap is not evidence.

```bash
# on the primary (.205): did the baseline actually apply?
sudo -u postgres cat /pg/tmp/pg-db-wirddb-baseline.log

# and what the server now believes
sudo -u postgres psql wirddb -c '\du wird_admin' -c '\dp reports' -c '\dp corpus_meta'
```

`\dp reports` must show `wird_admin=r*/dbuser_wird` plus the column-scoped
`UPDATE`, and **not** `arwdDxt`.

### Verify, including the negatives

The positive test proves little on its own; the point of the role is what it
*cannot* do.

```bash
PGPASSWORD='<DBUSER_WIRD_ADMIN_PASSWORD from Infisical>' \
  psql -h 192.168.1.205 -U wird_admin -d wirddb <<'SQL'
SELECT count(*) FROM reports;                       -- expect a number
SELECT corpus_version FROM corpus_meta WHERE id=1;  -- expect a version
UPDATE reports SET status='triaged' WHERE false;    -- expect UPDATE 0, not an error
SELECT count(*) FROM report_inbox;                  -- EXPECT: permission denied
UPDATE reports SET body='x' WHERE false;            -- EXPECT: permission denied for column body
CREATE TABLE t_should_fail(i int);                  -- EXPECT: permission denied for schema public
SQL
```

Three of those six must fail. If `report_inbox` returns a count, something
granted `dbrole_readonly` or `PUBLIC` more than intended — check `\dp
report_inbox` and `\du wird_admin` before going further.

### The one thing still unverified

`pigsty/files/wird-admin-grants.sql` qualifies every table as `public.*`. If
`root_senses` or `corpus_meta` actually live in the `jidhr` schema, those two
grants fail — visibly, in the baseline log, with the rest of the file applying
fine. Check first and amend the file rather than adding a blanket `GRANT USAGE ON
SCHEMA jidhr`:

```bash
sudo -u postgres psql wirddb -c '\dt *.root_senses' -c '\dt *.corpus_meta'
```

---

## 2. The Wird agent's service account

The agent calls `/reports.json` with `Authorization: Bearer`, which the proxy
provider lets through because `intercept_header_auth` is on. The token comes from
the client-credentials grant, which `set_oauth_defaults()` force-enables on every
proxy provider.

```bash
# In the authentik server pod. A service_account user, no password, no sessions.
kubectl -n authentik exec deploy/platform-authentik-server -- ak shell -c "
from authentik.core.models import User, Token, TokenIntents, UserTypes
u, created = User.objects.update_or_create(
    username='wird-agent',
    defaults={'name': 'Wird agent (reports triage)', 'type': UserTypes.SERVICE_ACCOUNT},
)
t, _ = Token.objects.update_or_create(
    identifier='wird-agent-app-password',
    defaults={'user': u, 'intent': TokenIntents.INTENT_APP_PASSWORD, 'expiring': False},
)
print('created' if created else 'existed')
"
```

Then add it to the group — **one line in git**, not a click:

```yaml
# gitops/bootstrap/authentik-blueprint-groups.yaml, in platform-admins' users:
            - !Find [authentik_core.user, [username, wird-agent]]
```

**That line is already committed** (2026-10-03). It is inert until the account
exists: `!Find` does not create the user, so authentik drops the unresolved entry
from the m2m list and the group keeps `akadmin` alone. Minting the account is what
activates it — which is why the `ak shell` step above comes first and this needs
no further edit.

The list is replaced on every apply, which is why membership lives there and not
in the UI: a click would be erased by the next sync.

### Hand the token over without it touching a transcript

Read it straight into Infisical, so the value is never printed:

```bash
TOKEN=$(kubectl -n authentik exec deploy/platform-authentik-server -- ak shell -c "
from authentik.core.models import Token
print(Token.objects.get(identifier='wird-agent-app-password').key)
" | tail -1)
infisical secrets set "WIRD_AGENT_AUTHENTIK_TOKEN=$TOKEN" \
  --projectId=8a3fa54f-be22-488a-bf51-55158f65c0f2 --env=dev --type=shared
unset TOKEN
```

It goes to the maintainer from there. It is deliberately **not** delivered into
the cluster: nothing in `gitops/` reads it, and adminweb must never be given a
way to mint its own caller's tokens.

### Mint and test a token

```bash
T=$(curl -s https://authentik.bnei.dev/application/o/token/ \
  -d grant_type=client_credentials \
  -d client_id=5gOqSotRlzaM2moPIvlRiS6UQNqBJHnysQ0wKqhR \
  -d client_secret="$WIRD_ADMIN_OIDC_CLIENT_SECRET" \
  -d username=wird-agent \
  -d password="$WIRD_AGENT_AUTHENTIK_TOKEN" \
  -d scope="openid profile email" | jq -r .access_token)

curl -s -H "Authorization: Bearer $T" https://wird-admin.bnei.dev/reports.json | head -c 200
```

The token is HS256-signed with the provider's `client_secret` — a proxy provider
has no signing key — so adminweb verifies it with the same value it gets as
`OIDC_CLIENT_SECRET`. See ADR-0052.

---

## 3. Read the provider's generated client id and secret into Infisical

**This step is not optional and it is not a convenience.** A proxy provider's
`client_id` and `client_secret` cannot be declared: verified against the running
2026.8.0, `ProxyProviderSerializer` exposes `client_id` as `read_only=True` and
has **no `client_secret` field at all** (while `OAuth2ProviderSerializer` has
both writable — which is why `authentik-blueprint-wird.yaml` and `-hermes.yaml`
commit a `client_id` and this cannot). The blueprint importer validates through
`model().serializer`, and DRF drops unknown keys without error, so declaring
them succeeds, changes nothing, and leaves authentik's generated pair in place.

adminweb needs both: the secret is the HS256 key for the forwarded JWT, the id is
the `aud` it pins. Read them out after the blueprint has applied:

```bash
PROJ=8a3fa54f-be22-488a-bf51-55158f65c0f2
read -r CID CSEC < <(kubectl -n authentik exec deploy/platform-authentik-server -- \
  ak shell -c "
from authentik.providers.proxy.models import ProxyProvider
p = ProxyProvider.objects.get(name='wird-admin')
print(p.client_id, p.client_secret)
" | tail -1)

infisical secrets set "WIRD_ADMIN_OIDC_CLIENT_ID=$CID"     --projectId="$PROJ" --env=dev --type=shared
infisical secrets set "WIRD_ADMIN_OIDC_CLIENT_SECRET=$CSEC" --projectId="$PROJ" --env=dev --type=shared
unset CID CSEC
```

`gitops/bootstrap/wird-admin-secret.yaml` delivers both into `wird-admin-config`
as `OIDC_CLIENT_ID` and `OIDC_CLIENT_SECRET`. **Wird must read `OIDC_AUDIENCE`
from that Secret rather than hardcoding it** — the id in their values file today
(`5gOqSotRlzaM2moPIvlRiS6UQNqBJHnysQ0wKqhR`) was my invention and authentik will
not use it.

Rotating: delete the provider's secret in authentik and re-run this step; the
blueprint will not fight you, because it never owned these values.

## 3b. The old, wrong instruction — kept so nobody repeats it

`WIRD_ADMIN_OIDC_CLIENT_SECRET` was originally generated here and declared in the
blueprint. That is now the value authentik ignores; step 3 overwrites it with the
real one. The row created on 2026-10-03 is therefore stale until that happens.

**`WIRD_ADMIN_OIDC_CLIENT_SECRET` was created in Infisical on 2026-10-03**, so
both `gitops/bootstrap/authentik-blueprint-wird-admin.yaml` and
`gitops/bootstrap/wird-admin-secret.yaml` resolve. Nothing to do here.

**Do not rotate it casually.** It is the HMAC key on both sides: rotating it
means the authentik blueprint and the app Secret must land in the same
propagation pass, or every request 401s on a signature error. For reference, this
is how it was made:

```bash
PROJ=8a3fa54f-be22-488a-bf51-55158f65c0f2
CSEC=$(python3 -c "import secrets,string; print(''.join(secrets.choice(string.ascii_letters+string.digits) for _ in range(64)))")
infisical secrets set "WIRD_ADMIN_OIDC_CLIENT_SECRET=$CSEC" --projectId="$PROJ" --env=dev --type=shared
unset CSEC
```

One row, two consumers: authentik signs with it, adminweb verifies with it. If
they ever diverge every request 401s on a signature error with nothing in either
log naming the cause.

---

## 4. After all of it: the propagation chain

Blueprints are discovered at authentik **worker boot** only, and the policy file
sorts before the provider file, so expect to restart more than once — hermes
needed three passes for exactly this reason (ADR-0051):

```bash
kubectl -n infisical rollout restart deploy/platform-infisical-operator   # only because a CR template changed
kubectl -n authentik exec deploy/platform-authentik-worker -- find /blueprints/mounted -name '*wird-admin*'
kubectl -n authentik rollout restart deploy/platform-authentik-worker     # then, and again if needed
```

Verify in the database, not the log, and select the FKs explicitly — a NULL-FK
row looks fine under `SELECT *`:

```bash
kubectl -n authentik exec deploy/platform-authentik-server -- ak shell -c "
from authentik.core.models import Application
from authentik.policies.models import PolicyBinding
from authentik.outposts.models import Outpost
a = Application.objects.filter(slug='wird-admin').first()
print('app:', a)
print('bindings:', [(b.order, b.group and b.group.name, b.enabled) for b in PolicyBinding.objects.filter(target=a)])
print('outpost providers:', [p.name for p in Outpost.objects.get(managed='goauthentik.io/outposts/embedded').providers.all()])
"
```

The outpost list must contain **both** `e2e-previews` and `wird-admin`. If
`wird-admin` is missing, the `!Find` in
`authentik-blueprint-forwardauth.yaml` applied before the provider existed —
restart the worker again.

## Checks that close ADR-0052

```bash
curl -sI https://wird-admin.bnei.dev/ | head -1          # 302 to authentik
curl -s -o /dev/null -w '%{http_code}\n' https://wird-admin.bnei.dev/reports.json   # 302, not 200
```

Then in a browser: a `platform-admins` member reaches the dashboard; a directory
user outside the group gets 403 from adminweb (not from authentik — the group
check is adminweb's, which is what makes the forced `password` grant survivable).
