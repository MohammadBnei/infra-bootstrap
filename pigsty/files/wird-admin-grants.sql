----------------------------------------------------------------------
-- wirddb baseline: wird-adminweb's least-privilege grants. ADR-0052.
--
-- Applied by Pigsty as this database's `baseline`, NOT by hand:
--   ./pgsql-db.yml -l pg-proxmox -e dbname=wirddb --tags pg_db_baseline
--
-- WHY A BASELINE AND NOT A RUNBOOK FULL OF psql. Pigsty's user model
-- (roles/pgsql/templates/pg-user.sql) emits role attributes, a password, a
-- comment and GRANTs of ROLES — it has no concept of a table grant. The only
-- declarative place for object privileges in this stack is a database baseline,
-- and roles/pgsql/tasks/database.yml's "load database baseline" task is gated
-- only on `database.baseline is defined`, not on the database being new — so it
-- re-applies on demand under the pg_db_baseline tag. Every statement below is
-- therefore written to be idempotent.
--
-- WHAT THIS FILE MUST NEVER CONTAIN: anything that is not a grant to
-- wird_admin. It runs against a live wirddb with `ignore_errors: true` on the
-- Ansible side (a failure here prints a green PLAY RECAP), so a DROP or an ALTER
-- in this file would be both destructive and silent.
--
-- The role itself is NOT created here. It is declared in pigsty.yml's pg_users
-- and created by `./pgsql-user.yml -l pg-proxmox -e username=wird_admin`, so its
-- password lives as a SCRAM verifier in that file and as plaintext only in
-- Infisical (DBUSER_WIRD_ADMIN_PASSWORD).
----------------------------------------------------------------------

-- CONNECT is not optional and not inherited: wirddb sets `revokeconn: true`,
-- and pg-db.sql's revoke block grants CONNECT back to exactly four roles —
-- replicator, dbuser_monitor, dbuser_dba and the owner. wird_admin is none of
-- them, so without this line adminweb cannot open a connection at all. The
-- revoke targets PUBLIC rather than named roles, so this grant survives every
-- later pgsql-db.yml run.
GRANT CONNECT ON DATABASE wirddb TO wird_admin;

GRANT USAGE ON SCHEMA public TO wird_admin;

-- Exactly the six tables wird's operations view reads, enumerated rather than
-- granted wholesale. `dbrole_readonly` would have been one line and would also
-- have handed over report_inbox, which wird's ADR-0026 keeps out of adminweb's
-- reach by design — and it is a SHARED cluster role, so it would have granted
-- the same reach to a dozen other database users.
--
-- Sources, confirmed against wird's main: users, set_prayers, sync_outcomes,
-- reports and root_senses are read in server/internal/store/admin.go;
-- corpus_meta in server/internal/store/store.go:150-153
-- (`SELECT corpus_version, built_at FROM corpus_meta WHERE id = 1`), which is
-- why it is here despite not appearing in admin.go. There is no `leaves` table —
-- that apparent reference is the English word in a comment at admin.go:253.
GRANT SELECT ON
    public.users,
    public.set_prayers,
    public.sync_outcomes,
    public.reports,
    public.root_senses,
    public.corpus_meta
  TO wird_admin;

-- The only write in the whole operations view (admin.go:216):
--   UPDATE reports SET category = nullif($2,''), status = $3, issue_url = nullif($4,'')
-- Column-scoped on purpose: a table-wide UPDATE would let the triage view rewrite
-- a report's body or its reporter.
GRANT UPDATE (category, status, issue_url) ON public.reports TO wird_admin;

-- Deliberately absent, and each one is a decision rather than an omission:
--   * no GRANT on report_inbox            (ADR-0026 keeps it out of reach)
--   * no INSERT or DELETE anywhere        (adminweb only triages existing rows)
--   * no USAGE on schema jidhr            (root_senses lives in public; if a
--                                          future query reaches into jidhr, add
--                                          USAGE and the table grant here, not
--                                          a blanket schema grant)
--   * no sequence privileges              (no INSERT, so nothing needs nextval)
--   * no ALTER DEFAULT PRIVILEGES         (a new table should NOT become readable
--                                          by adminweb automatically — that is
--                                          exactly the implicit growth this file
--                                          exists to prevent)
