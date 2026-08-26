# Runbook — move pgBackRest from node-local repos to the shared Garage S3 repo

Implements [ADR-0042](adr/0042-pgbackrest-shared-repo-and-restore-command.md).
The `pigsty.yml` config is already committed; this is the run.

## Goal

Replace the two divergent node-local pgBackRest repos (`repo1-path=/pg/backup`
on each of `.205` and `.207`) with one shared repo in the Garage `pg-backup`
bucket, and give the cluster a `restore_command` so a lagging replica recovers
from the archive instead of needing `patronictl reinit`.

## Prereqs

- **The cluster must be healthy first.** Do not migrate a degraded cluster —
  the first full backup runs against the live primary.
  ```bash
  curl -s http://192.168.1.207:8008/cluster | python3 -m json.tool
  ```
  Both members present, replica `streaming`, timelines equal.
- Infisical session (`source ~/.hermes/cache/inf-env.sh`). The run **must** be
  Infisical-wrapped — `pigsty.yml` resolves the S3 credentials with
  `lookup('env', ...)`, and an unwrapped run renders them **empty** and writes a
  broken repo config with no error.
- SSH key — `pigsty/ansible.cfg` points at a key that does not exist, so pass it
  per invocation:
  ```bash
  SP=/tmp/pgfix && mkdir -p $SP
  .claude/skills/run-ukubi-ops/driver.sh fetch-ssh-key SSH_OLDPG_KEY "$SP/oldpg_key"
  ```
- Already verified, no need to re-check: the `PGBACKREST_S3_*` credentials
  authenticate against the `pg-backup` bucket (HTTP 200, empty), and both pg
  nodes reach `s3.bnei.dev:443`.

## Steps

### 1. Apply the repo config

```bash
cd pigsty
infisical run --projectId=8a3fa54f-be22-488a-bf51-55158f65c0f2 --env=dev -- \
  ./pgsql.yml -l pg-proxmox --tags pgbackrest --private-key="$SP/oldpg_key"
```

The `pgbackrest` tag runs, in order: create dir → write
`/etc/pgbackrest/pgbackrest.conf` → `stanza-create` → initial backup. The
stanza-create following the config write immediately is what keeps the
archive-push gap to seconds; `archive-async=y` with a 4 GiB queue absorbs it.

### 2. Two traps in that run — neither fails the playbook

**Both `stanza-create` and the initial backup are `ignore_errors: true`.** A
green PLAY RECAP is not evidence either worked. Verify explicitly (step 3).

**The initial backup will be SKIPPED.** It is guarded by
`/etc/pgbackrest/initial.done`, which already exists from the original
bootstrap, so the task prints "initial backup already done" and does nothing —
against a brand-new, empty repo. **You must take the first backup by hand**, on
the *live* primary:

```bash
ansible 192.168.1.207 -b --private-key="$SP/oldpg_key" \
  -m shell -a 'sudo -u postgres pgbackrest --stanza=pg-proxmox backup'
```

Related: `stanza-create` is gated on `pg_role == 'primary'`, which is the
**inventory** role — `pigsty.yml` still declares `.205` as primary while Patroni
has `.207` leading. If step 3 shows no stanza, run it manually on the live
primary:

```bash
ansible 192.168.1.207 -b --private-key="$SP/oldpg_key" \
  -m shell -a 'sudo -u postgres pgbackrest --stanza=pg-proxmox --no-online stanza-create'
```

### 3. Verify — before touching anything local

```bash
# the repo is S3, not /pg/backup
ansible pg-proxmox -b --private-key="$SP/oldpg_key" \
  -m shell -a 'grep -E "repo1-type|repo1-s3-bucket|repo1-path" /etc/pgbackrest/pgbackrest.conf'

# a real full backup exists in it
ansible 192.168.1.207 -b --private-key="$SP/oldpg_key" \
  -m shell -a 'sudo -u postgres pgbackrest --stanza=pg-proxmox info'

# restore_command actually took
ansible pg-proxmox -b --private-key="$SP/oldpg_key" \
  -m shell -a 'sudo -u postgres psql -tAc "show restore_command"'
```

Expected: `repo1-type=s3`, `repo1-s3-bucket=pg-backup`, `repo1-path=/pgbackrest`;
`info` showing **one full backup** and a WAL archive range; and a non-empty
`restore_command` on **both** nodes.

Cross-check the bucket is actually receiving data:

```bash
ssh -i ~/.ssh/id_garage root@192.168.1.199 garage bucket info pg-backup
```

Objects and size should be non-zero.

### 4. Prove the fragility is gone

**Until this passes, ADR-0042 is unproven, not implemented.** The whole point is
that a replica which falls behind recovers on its own:

1. Stop Postgres on the replica (`patronictl` pause or stop the service).
2. Generate enough WAL on the primary to push past what the leader retains —
   `max_slot_wal_keep_size` is 18 GB, so this is deliberate work, not a wait.
3. Start the replica.
4. It should fetch the missing segments via `restore_command` and reach
   `streaming` **without** a `patronictl reinit`. Watch
   `/pg/log/postgres/*.csv` for `restored log file` lines rather than the
   `requested WAL segment ... has already been removed` loop.

Verify streaming the real way, not by role string — the 2026-08-15 and
2026-08-25 entries in `bootstrap-test-notes.md` both record a replica that
reported `running` while being a static snapshot:

```bash
# on the leader
sudo -u postgres psql -c "select client_addr,state,sent_lsn,replay_lsn from pg_stat_replication"
# on the replica
sudo -u postgres psql -c "select status,sender_host,latest_end_lsn from pg_stat_wal_receiver"
```

### 5. Only then, retire the local repos

`/pg/backup` on both nodes still holds the pre-migration backups and is no
longer referenced. Leave it until step 4 passes and you are satisfied with the
S3 backup's age. Deleting it is a manual `rm`, not a playbook step.

## Verification summary

| Check | Expected |
|---|---|
| `repo1-type` on both nodes | `s3` |
| `pgbackrest info` | one full backup, WAL range present |
| `show restore_command` | non-empty on **both** nodes |
| `garage bucket info pg-backup` | non-zero objects |
| starved replica | reaches `streaming` with no `reinit` |
| `pg_stat_replication` on leader | replica listed as `streaming` |

## Rollback

Set `pgbackrest_method: local` in `pigsty.yml` and re-run step 1. The local
repos are untouched by this migration, so rollback is a config flip — provided
step 5 has not been done. That is the entire reason step 5 is last.

Note the rollback does **not** remove `restore_command`; with a local repo it
becomes inert again rather than harmful, but if you want it gone, empty
`pg_parameters` and re-run.
