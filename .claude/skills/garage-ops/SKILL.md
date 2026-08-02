---
name: garage-ops
description: Manage Garage S3 buckets and keys for ukubi-cluster (garage-storage LXC, 192.168.1.199). Use when the user asks to add/inspect/rotate a Garage bucket or S3 API key, or asks about exposing a bucket externally.
user-invocable: true
allowed-tools:
  - Read
  - Bash(ssh -i ~/.ssh/id_garage root@* garage bucket list)
  - Bash(ssh -i ~/.ssh/id_garage root@* garage bucket info *)
  - Bash(ssh -i ~/.ssh/id_garage root@* garage key list)
  - Bash(ssh -i ~/.ssh/id_garage root@* garage key info *)
  - Bash(ansible-playbook -i ansible/inventories/garage/hosts.yml ansible/playbooks/garage-configure.yml --check --diff)
  - Bash(ansible-playbook -i ansible/inventories/garage/hosts.yml ansible/playbooks/garage-configure.yml --list-tasks)
---

# /garage-ops — Garage S3 bucket/key operations

Garage runs on the off-cluster `garage-storage` LXC (`192.168.1.199`,
`ansible/playbooks/garage-configure.yml`) — **not** in Kubernetes. Its S3
API is reachable two ways:

- **LAN, internal consumers** (Longhorn, pgBackRest): `http://garage.bnei.lan:3900`
- **External, authenticated clients**: `https://s3.bnei.dev` (Traefik →
  `gitops/bootstrap/garage-s3.yaml`, ADR-0030)

Both hit the exact same Garage instance and the exact same set of
buckets — there's no separate "external bucket" concept. Access to any
given bucket is controlled entirely by which key you sign a request with
and what that key was granted, same as AWS S3 itself. Garage's admin API
(port 3903) is bound to `127.0.0.1` on the LXC only — it is never reachable
through either endpoint above, and must stay that way.

## Adding a new bucket + key (the supported path)

Bucket/key provisioning is config-driven in
`ansible/playbooks/garage-configure.yml`'s `garage_buckets` list — **don't**
create buckets/keys by hand over SSH, the playbook is idempotent and this
keeps everything reproducible and Infisical-tracked.

1. Add an entry:
   ```yaml
   garage_buckets:
     - name: "some-new-bucket"
       key_name: "some-new-bucket-key"
       infisical_prefix: "SOME_NEW_BUCKET_S3" # -> SOME_NEW_BUCKET_S3_ACCESS_KEY/_SECRET in Infisical
   ```
2. Re-run the playbook (see `ansible/README.md`'s "How to run" for
   prerequisites — `GARAGE_VERSION`/`GARAGE_SHA256` env vars, Infisical
   session, `ansible/inventories/garage/hosts.yml`'s `ansible_host`
   filled in):
   ```bash
   ansible-playbook -i ansible/inventories/garage/hosts.yml ansible/playbooks/garage-configure.yml
   ```
   This is a **mutating run against real infra** — build/explain the
   command, but only run it yourself if the user explicitly says to run it
   now in this session (same rule as `ansible-ops`). `--check --diff` is
   always safe to run directly to preview.
3. The new key gets read+write on exactly that one bucket
   (`garage bucket allow --read --write`) — nothing more, nothing shared
   with `k8s-longhorn-backup`/`pg-backup`'s keys.
4. Credentials land in Infisical as `<infisical_prefix>_ACCESS_KEY` /
   `<infisical_prefix>_SECRET`.

The bucket is now reachable at both `garage.bnei.lan:3900` and
`s3.bnei.dev` — whether it's "internal" or "external-facing" is just a
question of which endpoint and which key you hand out, not a separate
provisioning step.

## Read-only inspection (safe to run directly)

```bash
ssh -i ~/.ssh/id_garage root@192.168.1.199 garage bucket list
ssh -i ~/.ssh/id_garage root@192.168.1.199 garage bucket info <bucket>
ssh -i ~/.ssh/id_garage root@192.168.1.199 garage key list
ssh -i ~/.ssh/id_garage root@192.168.1.199 garage key info <key>   # no --show-secret, ID only
```

## Mutating one-off CLI (don't run — recommend the vars-list path instead)

`garage bucket create`, `garage key create`, `garage bucket allow` run by
hand over SSH work, but bypass Infisical and the playbook's idempotency —
state drifts from what's in git. If a one-off is genuinely needed, print
the exact SSH command and explain that it won't be tracked, rather than
running it.

## Security model — don't relax these without the user explicitly asking

- **Authenticated S3 API only.** No anonymous/public bucket reads. If
  asked for public/website-style access, that's a distinct Garage feature
  (bucket website config) with a different security posture — flag the
  trade-off, don't enable it silently.
- **Admin API (3903) stays localhost-only**, never gets a Service/route.
  There's no reason to change this — nothing remote consumes it.
- **One key per bucket, scoped to that bucket only** — never grant a key
  access to a second bucket "for convenience."
- Rotating a key: `garage key create <new-name>`, grant it, update the
  consumer, then `garage key delete <old-name>` — the vars-list re-run
  handles create+grant; deletion of a retired key is manual (the playbook
  never deletes keys, only creates/grants).
