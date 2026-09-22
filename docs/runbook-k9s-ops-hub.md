# Runbook — the k9s-dashboard operational hub

Driving ansible/pigsty/kubectl from `k9s-dashboard` (`192.168.1.110`) instead of
from the operator's workstation.

## Why this exists

`README.md` says *"You run the actual tool (`ansible-playbook`, `kubespray`,
`pigsty`) on your Mac against this repo."* That holds only while the Mac is on
the LAN. Away from home, every target — the Patroni nodes, the PVE hosts, the
build-runner, Garage — is unreachable, and `.lan` DNS does not resolve.

`k9s-dashboard` is the one host that is reachable from outside (root SSH
port-forwarded, `82.65.231.50:49222`) **and** sits on the LAN with working
Pi-hole DNS. That makes it the natural hub, and this runbook is how it becomes
one without quietly becoming a second copy of every credential.

`DECISION.md` names `hermesagent` as where "operations live". That LXC is
currently **down** — `192.168.1.181:22` refuses connections and it has no DNS
record — and its Infisical machine-identity files live on it, so they are not
recoverable from a remote session. This hub does not replace that decision; it
is what works today.

## What it is allowed to hold

| | |
|---|---|
| Repo | `/opt/infra-bootstrap`, public HTTPS clone, no submodules |
| Ansible | `/opt/infra-bootstrap/kubespray-venv`, ansible-core **2.18.x** |
| Infisical | project-scoped, **read-only** service token at `/root/.hermes/cache/inf-token` |
| SSH keys to targets | **none at rest** — fetched per run to a `mktemp -d`, deleted after |
| Kubeconfig | pre-existing: a `cluster-admin` ServiceAccount token |

Two deliberate limits:

- **Read-only Infisical.** Ops runs only *fetch* (SSH keys, `PGBACKREST_S3_*`).
  Creating or rotating secrets stays on the workstation, so a compromise of this
  box cannot rewrite the secret store.
- **No target SSH keys on disk.** `driver.sh fetch-ssh-key` writes to a
  temporary directory under `umask 177` and the caller deletes it. The key that
  reaches every Pigsty node never persists here.

What that does **not** mitigate: this box already holds a long-lived
(`8760h`) cluster-admin token for the whole cluster, and root SSH to it is
exposed to the internet. Adding the hub raises what a compromise is worth. That
is the trade being made knowingly — see `docs/secrets.md`'s note that the
`SSH_K9S_DASHBOARD_KEY` blast radius "is the whole cluster, not just one host."

## First-time setup

Ansible cannot configure a box that has no ansible or git on it, so there is one
imperative step, then the playbook owns it.

```bash
# 1. minimal bootstrap, from anywhere
ssh k9s 'apt-get update -qq && apt-get install -y -qq git ansible'
ssh k9s 'git clone https://github.com/MohammadBnei/infra-bootstrap.git /opt/infra-bootstrap'

# 2. the playbook takes over, against itself
ssh k9s 'cd /opt/infra-bootstrap && ansible-playbook \
    -i ansible/inventories/k9s-dashboard/hosts.yml \
    -c local -l k9s-dashboard -e k9s_hub=true \
    ansible/playbooks/k9s-dashboard-configure.yml --tags hub'
```

The hub tasks are opt-in (`-e k9s_hub=true`) and skip Play 1, which needs a
control-plane connection and the `KUBECTL_VERSION`/`K9S_*` env vars.

### The Infisical token — minted on the workstation, never here

```bash
umask 177
infisical service-token create \
  --projectId=8a3fa54f-be22-488a-bf51-55158f65c0f2 \
  --scope='dev:/' --access-level=read \
  --name='k9s-hub (ops, read-only)' \
  --expiry-seconds=2592000 --token-only --silent > inf-token
scp inf-token k9s:/root/.hermes/cache/inf-token
ssh k9s 'chmod 600 /root/.hermes/cache/inf-token'
rm -f inf-token
```

**It expires in 30 days.** Nothing warns you: the symptom is every ops run
failing to fetch its SSH key. Re-run the block above to rotate.

## Daily use

```bash
ssh k9s
cd /opt/infra-bootstrap && git pull --ff-only
. /root/.hermes/cache/inf-env.sh
```

Then the pattern every run follows — fetch the key, use it, delete it:

```bash
TK=$(mktemp -d); chmod 700 "$TK"; trap 'rm -rf "$TK"' EXIT
.claude/skills/run-ukubi-ops/driver.sh fetch-ssh-key SSH_OLDPG_KEY "$TK/oldpg"
export ANSIBLE_HOST_KEY_CHECKING=False
cd pigsty
infisical run --projectId=8a3fa54f-be22-488a-bf51-55158f65c0f2 --env=dev --silent -- \
  ../kubespray-venv/bin/ansible-playbook --private-key="$TK/oldpg" \
  -l pg-proxmox -e username=<name> pgsql-user.yml
```

`--private-key` is not optional: `pigsty/ansible.cfg` is vendored upstream and
points at `/home/mohammad/.ssh/id_pigsty_rsa`, which exists nowhere. `pigsty/`
must not be edited, so it is overridden per invocation.

### Before any `pgsql-*` run, check who is actually leader

```bash
curl -s http://192.168.1.205:8008/cluster | jq '.members[] | {name, role, host}'
```

`pg_role` in `pigsty/pigsty.yml` is a label Pigsty never reconciles, and the
playbooks gate their SQL on it. When it disagrees with Patroni, writes are aimed
at a read-only standby and **the run still reports success** — every task in that
path is `ignore_errors: true` with the psql call ending in `|| true`. If they
disagree, fix `pigsty.yml` (PR) rather than passing `-e pg_role=primary`: the
override papers over an inventory that is lying to every other playbook too.

This happened for real on 2026-09-22 — see `docs/bootstrap-test-notes.md`.

### Proving a Postgres change landed

A green `PLAY RECAP` is not evidence. Connect and look:

```bash
TK=$(mktemp -d); .claude/skills/run-ukubi-ops/driver.sh fetch-ssh-key SSH_OLDPG_KEY "$TK/oldpg"
ssh -i "$TK/oldpg" vagrant@<leader> 'sudo -u postgres psql -At -f -' <<'SQL'
select 'is_replica: ' || pg_is_in_recovery();
select 'role: ' || coalesce((select rolname from pg_roles where rolname='<role>'), 'ABSENT');
SQL
rm -rf "$TK"
```

## What stays on the workstation

- Minting and rotating Infisical secrets (the hub token is read-only).
- `gh` / PR work — the hub has no GitHub credential, by design.
- Anything needing a key that is not in Infisical.
