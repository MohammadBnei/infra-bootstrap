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

**Fix the labels in `pigsty/pigsty.yml` while you are here** — swap `pg_role`
between `.205` and `.207` — or the next person reads a file that lies. (This
session could not: editing that file is blocked for it.)

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

### The password already exists — use it, do not regenerate it

**`DBUSER_WIRD_ADMIN_PASSWORD` was created in Infisical on 2026-10-03.** Read it
from there; the `CREATE ROLE` below takes it as `:'pw'`. Regenerating it would
mean the Secret and the role disagree and adminweb would fail authentication with
nothing in the pod log naming the cause.

It was generated as 43 alphanumerics so it needs no percent-encoding in a URL —
the trap `wird-secret.yaml` records for `DBUSER_WIRD_PASSWORD`. For reference,
this is how it was made:

```bash
PROJ=8a3fa54f-be22-488a-bf51-55158f65c0f2
PW=$(python3 -c "import secrets,string; print(''.join(secrets.choice(string.ascii_letters+string.digits) for _ in range(43)))")
infisical secrets set "DBUSER_WIRD_ADMIN_PASSWORD=$PW" --projectId="$PROJ" --env=dev --type=shared
```

### The SQL

Run it as the superuser against the **primary**. `\set` keeps the password out of
the statement log as a literal:

```bash
infisical run --projectId=8a3fa54f-be22-488a-bf51-55158f65c0f2 --env=dev -- \
  bash -c 'PGPASSWORD="$PG_SUPERUSER_PASSWORD" psql -h 192.168.1.205 -U postgres -d wirddb \
    -v pw="$DBUSER_WIRD_ADMIN_PASSWORD" -f -' <<'SQL'
-- ADR-0052. Least privilege for wird-adminweb; wird-api keeps dbuser_wird.
CREATE ROLE wird_admin LOGIN PASSWORD :'pw'
  NOSUPERUSER NOCREATEDB NOCREATEROLE NOREPLICATION NOBYPASSRLS;

GRANT CONNECT ON DATABASE wirddb TO wird_admin;
GRANT USAGE ON SCHEMA public TO wird_admin;

GRANT SELECT ON public.users, public.set_prayers, public.sync_outcomes,
                public.reports, public.root_senses, public.corpus_meta
  TO wird_admin;

GRANT UPDATE (category, status, issue_url) ON public.reports TO wird_admin;
SQL
```

If `root_senses` or `corpus_meta` turn out to live in the `jidhr` schema rather
than `public` (wird owns both), add `GRANT USAGE ON SCHEMA jidhr` and qualify
those two names — check with
`\dt *.root_senses` before assuming. This session could not check: direct queries
against this database are blocked for it.

### Verify, including the negatives

The positive test proves little on its own; the point of the role is what it
*cannot* do.

```bash
PGPASSWORD='<the password>' psql -h 192.168.1.205 -U wird_admin -d wirddb <<'SQL'
SELECT count(*) FROM reports;                      -- expect a number
SELECT corpus_version FROM corpus_meta WHERE id=1; -- expect a version
UPDATE reports SET status='triaged' WHERE false;    -- expect UPDATE 0, not an error
SELECT count(*) FROM report_inbox;                 -- EXPECT: permission denied
UPDATE reports SET body='x' WHERE false;            -- EXPECT: permission denied for column body
CREATE TABLE t_should_fail(i int);                  -- EXPECT: permission denied for schema public
SQL
```

Three of those five must fail. If `report_inbox` returns a count, something
granted `dbrole_readonly` or `PUBLIC` more than intended — check
`\dp report_inbox` and `\du wird_admin` before going further.

### Record the hash so Pigsty does not fight it

`pigsty/pigsty.yml` declares every other login role with its SCRAM hash
committed and the plaintext in Infisical. A role created by hand is invisible to
that file, so the next `pgsql-user` run neither knows nor resets it — but the
file stops describing reality. Read the hash back and add a `pg_users` entry
with `roles: []` (no `dbrole_readwrite`, no `dbrole_readonly`):

```bash
infisical run --projectId=8a3fa54f-be22-488a-bf51-55158f65c0f2 --env=dev -- \
  bash -c 'PGPASSWORD="$PG_SUPERUSER_PASSWORD" psql -h 192.168.1.205 -U postgres -At \
    -c "SELECT rolpassword FROM pg_authid WHERE rolname = '"'"'wird_admin'"'"'"'
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

That list is replaced on every apply, so it must be added there rather than
granted in the UI. `!Find` does not create the account, which is why step 2 runs
first; until it does, the `!Find` resolves to None and authentik drops it from the
list, leaving the group as it was. (This session could not make that edit: adding
a member to `platform-admins` is blocked for it, correctly.)

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

## 3. The provider's client secret — DONE

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
