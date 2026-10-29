# Runbook — secret rotation after the 2026-10-18 Infisical export leak

| | |
|---|---|
| Incident | On 2026-10-18, `infisical export ... 2>&1 >/dev/null` printed every secret **value** at the root of `infra-bootstrap-1-ge1` (id `8a3fa54f-be22-488a-bf51-55158f65c0f2`, env `dev`, path `/`) into a local Claude Code transcript. The persisted file was deleted. Treat every value that existed at that moment as leaked. |
| Scope | The root of `infra-bootstrap-1-ge1` only. Per-app projects (`agent-fleet-nygh`, `ente-uovi`, `wird-8k-fc`, `wedding-2026-ih1x`, `platform-commons-76pb`, `agent-vault`, `fleet-github-app`, ...) were not exported. Where a root value is **duplicated** into one of them, the copy is leaked too and is rotated in the same row. |
| Status | Rotation deferred by the operator (M BN, GitHub `MohammadBnei`). A later session executes this runbook with the operator. |
| Done before this runbook | 2026-10-20: `PG_ADMIN_PASSWORD`, `PG_MONITOR_PASSWORD`, `PG_REPLICATION_PASSWORD`, `PATRONI_PASSWORD` were **created** after the leak (PR #351; `docs/bootstrap-test-notes.md`, entry 2026-10-20; break-glass in `docs/runbook-pg-bootstrap.md` §6). They are not leaked. zot's InfisicalSecret was narrowed to its 3 keys (PR #350). Do not re-rotate any of these. |

## Progress

**2026-10-20, batch 1** (values written by Claude, propagation by the operator):

| Key | State |
|---|---|
| `FLEET_SESSION_KEYS`, `MOUNTAIN_SESSION_KEY` | new value in Infisical; live after the core/mountain restart in `rot-batch1-apply.sh` |
| `BASIC_AUTH_HTPASSWD` (+ new `BASIC_AUTH_PASSWORD`) | bcrypt cost 12 replaces apr1; live on the next resync (Traefik watches the Secret) |
| `K8S_GRAFANA_ADMIN_PASSWORD` | new value; live after the in-pod reset in `rot-batch1-apply.sh` |
| `BRIDGE_ALERT_TOKEN`, `BRIDGE_CORE_TOKEN` + `BRIDGE_CLIENTS` | new values, hash checked; live after the bridge restart |
| `BRIDGE_GITHUB_WEBHOOK_SECRET` | new value; the App is repointed by `rot-batch1-apply.sh` right after the bridge restart |

Read-only checks done the same day:

- **NetBird:** all nine setup keys expired by 2026-10-18 (last used 2026-10-11/12). No peer was created after 2026-10-12. There are no routes and no networks. Two laptop peers predate the leak and are for the operator to confirm: `macbook-pro-de-nico3` and `emerald-eea` (in `platform-admins`). The six `NETBIRD_INFRA_SETUP_KEY_*` rows are dead values and can be deleted.
- **`argocd-ukubi-bot`:** no events on `infra-bootstrap`, `agent-fleet`, `editable-blog`, `wird` or `vos-monolith`, and no PRs, since 2026-10-18. Revoking the PAT is still needed (T2, operator).
- **Mesh SSH from the laptop goes through NetBird's SSH proxy** (`/etc/ssh/ssh_config.d/99-netbird.conf`: `ProxyCommand netbird ssh proxy`, an SSO login, `StrictHostKeyChecking no`). Stale `ControlMaster` sockets in `~/.ssh/control-*` made sessions return empty output. Use `ssh -S none`. The Postgres break-glass must use the LAN IPs.

## 0. What the export did and did not contain

The 121 key names in the project on 2026-10-20 are the input to this runbook.
Four of them (the PG/PATRONI rows above) postdate the leak. Anything created
after the export is not leaked; the CLI cannot show creation dates, so a row
marked **verify date** needs a check in the Infisical UI (secret → version
history) before you skip it.

**Not in the project, so not in this export** (each is held somewhere else):

| Credential | Where it lives | Note |
|---|---|---|
| `ARGOCD_INFISICAL_CLIENT_ID/SECRET` | operator's `ansible/playbooks/register-repos.env` → k8s Secret `infisical/universal-auth-credentials` (`register-repos.yml`) | `docs/secrets.md` lists it as a row, but it is not one of the 121 names |
| Hermes / operator CLI identity | `~/.hermes/cache/inf-cid`, `inf-csec` (`bin/inf-env.sh`) | |
| k9s hub read-only service token | `/root/.hermes/cache/inf-token` on `k9s-dashboard` (30-day expiry, `docs/runbook-k9s-ops-hub.md`) | |
| `agent-vault-universal-auth`, the `fleet-github-app` identity | k8s Secrets in ns `infisical` | ADR-0061, ADR-0062 |
| `K8S_BREAK_GLASS_TOKEN`, `KUBE_VAULT_PASSWORD`, `PG_BACKREST_REPO_PASSWORD`, `GRAFANA_ADMIN_PASSWORD` (Pigsty), `HAPROXY_ADMIN_PASSWORD`, `PGADMIN_PASSWORD`, `DBUSER_META/VIEW/INFISICAL/ORY_PASSWORD` | not at root today | **OPEN:** PR #350's commit message and `gitops/platform/values/zot/values.yaml` name `K8S_BREAK_GLASS_TOKEN` as a root secret. If it was deleted between 2026-10-18 and 2026-10-20 it was in the export. Check the project audit log for deletions since 2026-10-18 |

**Not secret, no rotation:** every `SSH_*_HOST/_PORT/_USER`, `SSH_PROXMOX_HOST/PORT/USER`,
every `*_OIDC_CLIENT_ID`, `BRIDGE_GITHUB_APP_ID`, `CF_ACCOUNT_ID`, `SMTP_HOST`,
`SMTP_PORT`, `SMTP_EMAIL`, `MOUNTAIN_TURNSTILE_SITE_KEY`, `WIRD_ANDROID_KEY_ALIAS`.
They tell an attacker where to aim (the k9s hub's public IP and `:49222`, for
example), nothing more.

**Reachability corrections found while writing this** (they change the order):

- `proxmox.bnei.dev` routes to `pveproxy :8006` behind the Cloudflare origin
  lock only, with no forwardAuth (`gitops/redirectors/proxmox.yaml`). So
  `PVE_API_TOKEN` works **from the internet**: an API token skips PVE's TFA,
  and the `Terraform` role includes `VM.Console` and `VM.Config.*` on `/`
  (`terraform/README.md` §A). It moves up to tier 2.
- `s3.bnei.dev` serves **every** Garage bucket (`gitops/redirectors/garage-s3.yaml`;
  SigV4 is the only check). So every `*_S3_*` key works from the internet,
  backup buckets included.
- `grafana.bnei.dev` keeps its local admin login form (`gitops/platform/values/grafana/values.yaml`,
  no auto-login). So `K8S_GRAFANA_ADMIN_PASSWORD` works from the internet.
- `BASIC_AUTH_HTPASSWD` gates `pgweb.bnei.dev` and `alertmanager.bnei.dev`.
  The value is an `apr1` hash, which is fast to crack offline.

## 1. Order of work

**Rotate by what works from the internet without a second factor, highest
blast radius first.** First comes anything that can re-read Infisical, because
whoever holds it re-reads every value you rotate afterwards. LAN-only
credentials follow in the normal rotation policy (`docs/secrets.md`,
"Rotation policy"). Low-value and do-not-rotate items come last.

| Tier | Theme |
|---|---|
| T1 | Infisical machine identities: confirm, harden, optionally rotate |
| T2 | `UKUBI_BOT_GH_PAT` (expires 2026-10-28), `PVE_API_TOKEN` |
| T3 | Session-signing keys and internet login passwords |
| T4 | NetBird: an admin can enroll a peer, which means root SSH on every host |
| T5 | Cloudflare and mail |
| T6 | k9s hub key, GitHub clone credentials, wird-agent token |
| T7 | ukubi-bridge |
| T8 | Alert tokens, Discord, Garage S3 keys |
| T9 | LAN-only: SSH keys, DB passwords, Garage RPC, Pigsty CA, Redis, Pi-hole |
| T10 | Low value, or do not rotate by default |
| — | `WIRD_ANDROID_*`: cannot be rotated in place. See §7 |

## 2. Before you start

- [ ] Operator on the LAN, or the NetBird mesh up on the laptop.
- [ ] k9s hub reachable: `ssh -i ~/.ssh/id_k9s_dashboard root@k9s-dashboard.bnei.mesh`
      (or `ssh k9s` on `:49222` as break-glass).
- [ ] Infisical UI open as M BN, with admin on `infra-bootstrap-1-ge1` and on
      every per-app project named in §5. Access Control → Identities must be
      editable.
- [ ] A **write-capable** Infisical CLI session on the workstation. The hub's
      token is read-only by design (`docs/runbook-k9s-ops-hub.md`), so
      `infisical secrets set` never runs there.
- [ ] Browser sessions for GitHub (`MohammadBnei` **and** `argocd-ukubi-bot`),
      Cloudflare, NetBird dashboard, authentik admin, SMTP2GO and Discord.
- [ ] `rot.py` (§4) saved to a scratch directory **outside the repo**.
- [ ] Nothing prints a value. Never use `echo`, `cat` on a Secret or mounted file,
      `kubectl get secret -o yaml`, `infisical export`, or bare
      `infisical secrets get`. `infisical secrets set` echoes the value in
      its result table, so it always runs inside `rot.py`, which drops the output.

## 3. Who does what

Each row in §5 tags its steps:

- **C — Claude can automate.** It generates random values and writes them to
  Infisical through `rot.py`, without printing them. It edits repo files and
  opens PRs. It runs read-only cluster checks through the hub
  (`kubectl get`, `logs`, jsonpath over metadata and key names), and makes
  read-only provider API calls with a stored token, printing only names and
  status codes.
- **P — Claude prepares, operator runs.** Claude's permission classifier
  blocks the following, so Claude writes them as a script in the scratchpad
  and the operator runs it with `! bash <script> 2>&1 | cat`:
  - merging PRs. On infra-bootstrap `main` this also needs
    `gh pr merge --admin` because of the `protect-main` ruleset;
  - creating rulesets or permission grants;
  - remote writes on the hub or the cluster (`kubectl rollout restart`,
    `kubectl patch`, `kubectl exec` that changes state, `argocd app sync`);
  - production DB logins;
  - `ansible-playbook`, kubespray and pigsty runs, unless the operator
    authorizes them explicitly in that session.
- **O — Operator only.** Anything that needs a browser, a console or a human
  identity: issuing and revoking tokens at a provider (GitHub PAT or App key,
  Cloudflare API token, NetBird service-user PAT, Discord webhook, SMTP2GO
  credential), the Infisical machine identity's client secret and trusted
  IPs, and authentik app passwords unless the repo has an API path. Once the
  operator copies a new value to the clipboard, Claude stores it with
  `rot.py set NAME --clipboard`, which also clears the clipboard. The value
  never enters the chat.

## 4. Writing a value without printing it

Save as `rot.py` outside the repo. It prints names, return codes, `match`
or `MISMATCH`, and the value's shape (length and charset). Never the value.
It was tested against a stub `infisical` before this runbook was written.

```python
#!/usr/bin/env python3
"""Rotate one Infisical secret without printing it. Prints names, rc, match, shape only.

  rot.py set NAME (--gen KIND | --clipboard | --file PATH | --from-project ID) [--project ID] [--keep-old] [--scram]
  rot.py cmp NAME PROJECT_ID OTHER_NAME OTHER_PROJECT_ID      # same / different
  rot.py shape NAME [--project ID]                            # length + charset of the current value
KIND: hex32 | urlsafe32 | urlsafe48 | alnum32 | alnum43 | alnum64
"""
import argparse, base64, hashlib, hmac, os, secrets, string, subprocess, sys

ROOT = "8a3fa54f-be22-488a-bf51-55158f65c0f2"
ALNUM = string.ascii_letters + string.digits
GEN = {
    "hex32": lambda: secrets.token_hex(32),
    "urlsafe32": lambda: secrets.token_urlsafe(32),
    "urlsafe48": lambda: secrets.token_urlsafe(48),
    **{f"alnum{n}": (lambda n=n: "".join(secrets.choice(ALNUM) for _ in range(n))) for n in (32, 43, 64)},
}

def inf(*a):  # output captured and dropped: `secrets set` echoes the value in its table
    return subprocess.run(["infisical", *a], capture_output=True, text=True)

def get(name, proj):
    r = inf("secrets", "get", name, f"--projectId={proj}", "--env=dev", "--plain")
    return r.returncode, r.stdout.rstrip("\n")

def put(name, value, proj):
    return inf("secrets", "set", f"{name}={value}", f"--projectId={proj}", "--env=dev", "--type=shared").returncode

def h(v):
    return hashlib.sha256(v.encode()).digest()

def scram(pw):  # Postgres SCRAM-SHA-256 verifier; not secret, goes into pigsty/pigsty.yml
    salt = os.urandom(16)
    salted = hashlib.pbkdf2_hmac("sha256", pw.encode(), salt, 4096)
    ck = hmac.new(salted, b"Client Key", "sha256").digest()
    sk = hmac.new(salted, b"Server Key", "sha256").digest()
    b = lambda x: base64.b64encode(x).decode()
    return f"SCRAM-SHA-256$4096:{b(salt)}${b(hashlib.sha256(ck).digest())}:{b(sk)}"

def shape(v):
    cls = [n for n, cs in (("hex", string.hexdigits), ("alnum", ALNUM), ("urlsafe", ALNUM + "-_"),
                           ("base64", ALNUM + "+/=")) if v and all(c in cs for c in v)]
    return f"len={len(v)} charset={cls[0] if cls else 'other'} lines={v.count(chr(10)) + 1}"

def main():
    p = argparse.ArgumentParser()
    s = p.add_subparsers(dest="cmd", required=True)
    a = s.add_parser("set"); a.add_argument("name"); a.add_argument("--project", default=ROOT)
    src = a.add_mutually_exclusive_group(required=True)
    src.add_argument("--gen", choices=GEN); src.add_argument("--clipboard", action="store_true")
    src.add_argument("--file"); src.add_argument("--from-project")
    a.add_argument("--keep-old", action="store_true"); a.add_argument("--scram", action="store_true")
    c = s.add_parser("cmp"); [c.add_argument(x) for x in ("name", "project", "other", "other_project")]
    sh = s.add_parser("shape"); sh.add_argument("name"); sh.add_argument("--project", default=ROOT)
    o = p.parse_args()

    if o.cmd == "cmp":
        (r1, v1), (r2, v2) = get(o.name, o.project), get(o.other, o.other_project)
        print(f"rc={r1},{r2}", "same" if r1 == r2 == 0 and hmac.compare_digest(h(v1), h(v2)) else "different")
        return
    if o.cmd == "shape":
        rc, v = get(o.name, o.project); print(o.name, f"rc={rc}", shape(v)); return

    if o.gen: v = GEN[o.gen]()
    elif o.clipboard:
        v = subprocess.run(["pbpaste"], capture_output=True, text=True).stdout.strip()
        subprocess.run(["pbcopy"], input="", text=True)  # clear the clipboard
    elif o.file: v = open(o.file).read().rstrip("\n")
    else:
        rc, v = get(o.name, o.from_project)
        if rc: sys.exit(f"{o.name}: read from {o.from_project} failed rc={rc}")
    if not v: sys.exit(f"{o.name}: empty value, nothing written")
    if o.keep_old:
        rc, old = get(o.name, o.project)
        print(f"ROTATION_OLD_{o.name}", f"rc={put(f'ROTATION_OLD_{o.name}', old, o.project) if rc == 0 else 'no-old'}")
    rc = put(o.name, v, o.project)
    rc2, back = get(o.name, o.project)
    print(o.name, f"set_rc={rc} get_rc={rc2}", "match" if hmac.compare_digest(h(back), h(v)) else "MISMATCH", shape(v))
    if o.scram: print("verifier:", scram(v))

if __name__ == "__main__":
    main()
```

Usage patterns:

```bash
python3 -I rot.py shape NETBIRD_SESSION_COOKIE_KEY          # learn the format before generating
python3 -I rot.py set FLEET_SESSION_KEYS --gen alnum64
python3 -I rot.py set NETBIRD_API_TOKEN --clipboard --keep-old   # operator copied it from the dashboard
python3 -I rot.py set DBUSER_HQ_PASSWORD --gen urlsafe32 --scram # prints the verifier for pigsty.yml
python3 -I rot.py set AGENTFLEET_FILES_S3_SECRET --from-project 8a3fa54f-be22-488a-bf51-55158f65c0f2 --project <agent-fleet-nygh id>
python3 -I rot.py cmp UKUBI_BOT_GH_PAT 8a3fa54f-be22-488a-bf51-55158f65c0f2 GH_TOKEN <agent-fleet-nygh id>
```

- `--keep-old` parks the leaked value as `ROTATION_OLD_<NAME>`, so the
  "old credential now returns 401" check can run after the provider revokes
  it. Delete the parked key as soon as that check passes:
  `infisical secrets delete ROTATION_OLD_<NAME> --projectId=8a3fa54f-be22-488a-bf51-55158f65c0f2 --env=dev`.
  It holds an already-leaked value, so parking it adds no exposure.
- The value is passed to `infisical secrets set` on argv, so it is visible in
  local `ps` for the duration of the call. This is accepted on the workstation.
  Never run `rot.py` on a shared host.
- **Value formats that matter:** DSN passwords (`DBUSER_WIRD`, `HQ`, `MOUNTAIN`,
  `BRIDGE`, `NETBIRD`) must have no `@ : / space quote`, so use `urlsafe32`.
  `DBUSER_WIRD_ADMIN` uses `alnum43` and `DBUSER_AUTHENTIK` uses `alnum32`.
  Before generating any other key, run `shape` on the current value and match it.

## 5. Propagation: how a new value reaches a pod

Read this once before T3. It is the most common way a rotation looks done
and is not.

1. **Value changes are picked up on resync.** Every InfisicalSecret here has
   `resyncInterval: 60`. Within about a minute of `rot.py set`, the operator
   rewrites the managed Secret.
2. **Template changes are not.** The operator does not re-render when only
   the CR's `template` changed (`docs/runbook-authentik-identity.md` §9.1). After
   a PR that changes a template, restart the operator:
   `kubectl -n infisical rollout restart deploy/platform-infisi-controller-manager` (P).
3. **Never delete a managed Secret to force a re-render.** They use
   `creationPolicy: Orphan`, so the operator does not recreate them. A deleted
   Secret was observed staying gone for 105 s, until the operator was restarted
   anyway (`docs/runbook-authentik-identity.md`). Restart the operator instead.
4. **common-app-chart InfisicalSecret CRs are ArgoCD `PreSync` hooks**
   (`gitops/platform/common-app-chart/templates/infisicalsecret.yaml`), so a
   template change in an app's `values.yaml` reaches the CR only on that app's
   next sync. Rule 2 still applies after that.
5. **Env vars bind at container start.** A pod reading the value via `env`
   or `envFrom` keeps the old value until restarted, unless its Deployment
   carries `secrets.infisical.com/auto-reload: "true"`. In this repo only
   **traefik**, **netbird** and **ente-museum** carry it
   (`gitops/platform/values/{traefik,netbird,ente-museum}/values.yaml`).
   zot's `autoReload` is deliberately `false`. User apps set it in their own
   repos; **OPEN:** check with
   `kubectl -n <ns> get deploy -o jsonpath='{range .items[*]}{.metadata.name}{" "}{.spec.template.metadata.annotations.secrets\.infisical\.com/auto-reload}{"\n"}{end}'`.
6. **authentik blueprints** that interpolate a credential (the `authentik-blueprint-*`
   InfisicalSecrets) are applied by the **worker** at boot. Confirm the
   file is mounted, then restart `deploy/platform-authentik-worker -n authentik`,
   and restart a second time before diagnosing anything
   (`docs/runbook-authentik-identity.md` §9.1 step 3).
7. **Verify by metadata only.** Use
   `kubectl -n <ns> get secret <name> -o jsonpath='{.metadata.resourceVersion}{" "}{.metadata.managedFields[*].time}{"\n"}'`,
   and for key names
   `kubectl -n <ns> get secret <name> -o go-template='{{range $k,$v := .data}}{{$k}}{{"\n"}}{{end}}'`.
   After that, check the app's behaviour: a login works and the old credential fails.

Restart commands below use `kubectl -n <ns> rollout restart deploy/<name>`.
Where the repo does not record the Deployment name, list them first with
`kubectl -n <ns> get deploy -o name` (C).

## 6. The rotation table

`Who` legend: **C** Claude automates · **P** Claude prepares, operator runs · **O** operator only.
"Consumers" are repo-relative paths. "Propagate" assumes §5.

### T1 — Infisical machine identities (not in the export: confirm, harden, optionally rotate)

| Keys | Unlocks / reachable from | Consumers | Rotation steps | Propagate | Verify | Who |
|---|---|---|---|---|---|---|
| `ARGOCD_INFISICAL_CLIENT_ID/SECRET` (identity behind `universal-auth-credentials`); the Hermes/CLI identity (`bin/inf-env.sh`); the hub service token | Read of every project the identity is granted on: `infra-bootstrap-1-ge1`, `platform-commons-76pb`, `ente-uovi`, ... (ADR-0049). `infisical.bnei.dev` is public | every `gitops/bootstrap/*-secret.yaml` and `authentik-blueprint-*.yaml` (`credentialsRef: universal-auth-credentials`); `gitops/platform/common-app-chart/templates/*infisicalsecret.yaml`; `ansible/playbooks/register-repos.yml` | 1. Confirm none of the 121 names is a client secret (done for this runbook: none is). 2. Infisical UI → each identity → Universal Auth: review **client secrets** and the identity's login audit since 2026-10-18 for unknown source IPs. 3. Set **Client Secret Trusted IPs** and **Access Token Trusted IPs** to `192.168.1.0/24` and `10.233.64.0/18` (pod CIDR, `inventory/ukubi/group_vars/k8s_cluster/k8s-cluster.yml`). 4. Recommended but not required by this leak: create a new client secret, update `register-repos.env`, re-create `universal-auth-credentials`, revoke the old secret | Re-create the Secret: `register-repos.yml` (P) or a prepared `kubectl create secret ... --dry-run=client -o yaml \| kubectl apply -f -` on the hub (P). Then restart the operator (P) | Operator logs show successful syncs: `kubectl -n infisical logs deploy/platform-infisi-controller-manager --since=5m` (C). The old secret returns 401: `infisical login --method=universal-auth` with the old pair, run by O. Hermes and hub ops runs still fetch | O (UI, trusted IPs, client secret) · P (Secret, restart) · C (log check) |

**OPEN (T1):** Which source IP does Infisical record for each caller? The
in-cluster operator talks to the backend Service directly (pod IP, or a node
IP if SNAT'd). LAN callers through `infisical.bnei.dev` may show the Freebox
hairpin address `192.168.1.254`, as NetBird does. Read the IPs off the
identity's login audit **before** enabling trusted IPs, or the cluster stops
syncing. Off-LAN operator logins will be refused by design.

### T2 — internet, no second factor, widest write access

| Keys | Unlocks / reachable from | Consumers | Rotation steps | Propagate | Verify | Who |
|---|---|---|---|---|---|---|
| `UKUBI_BOT_GH_PAT` | Push as `argocd-ukubi-bot` to `infra-bootstrap`, `agent-fleet`, `editable-blog`, `wird`, `vos-monolith` (scope per the 2026-10-20 security review). infra-bootstrap `main` has the `protect-main` ruleset; ADR-0062 notes the fleet repos' `main` branches are unprotected. github.com, internet. Expires 2026-10-28 | Nothing in this repo reads it (`grep`: no hits outside docs). `docs/secrets.md` says agent-fleet push/PR flows. ADR-0062 says agent-fleet uses `agent-fleet-nygh` `/GH_TOKEN`, a classic PAT of the same bot | 1. `rot.py cmp UKUBI_BOT_GH_PAT <root> GH_TOKEN <agent-fleet-nygh>` (C). 2a. **different**: O revokes the PAT now (bot → Settings → Developer settings → tokens). C deletes the root key. 2b. **same**: revoking breaks agent-fleet. Either bring forward ADR-0062 rollout step 2 (O creates and installs `ukubi-fleet`; C creates the `fleet-github-app` project rows) and accept fleet downtime until agent-fleet switches, or O issues a stop-gap classic PAT, expiry ≤ 30 days, minimum scopes, stored **only** in `agent-fleet-nygh` `/GH_TOKEN` (C via `--clipboard --project`). Then revoke the old one and delete `UKUBI_BOT_GH_PAT` from root. Do not mint a new broad PAT at root | agent-fleet core/provisioner restart if `/GH_TOKEN` changed (P; deployment names: OPEN) | Old token: `GET https://api.github.com/user` returns 401 (C, from `ROTATION_OLD_*`). Bot security log and `gh api repos/<owner>/<repo>/events` show no pushes, PRs or key additions by the bot since 2026-10-18 that the fleet did not make (C reads, O judges). Bot account: no unknown SSH keys, PATs or OAuth apps (O) | C (compare, store, read-only checks) · O (issue, revoke, App) · P (restarts) |
| `PVE_API_TOKEN` (`terraform@pve!provider`) | `Terraform` role on `/`, including `VM.Console` and `VM.Config.*` on every VM (`terraform/README.md` §A). That is root on k8s nodes and Postgres. Reachable from the internet via `proxmox.bnei.dev` (origin lock only, `gitops/redirectors/proxmox.yaml`) | `terraform/` (`bpg/proxmox`), `bin/create-k9s-dashboard.sh`, asserted present in `ansible/playbooks/{pihole,garage}-configure.yml` | On a PVE node as root: `pveum user token remove terraform@pve provider`, then `pveum user token add terraform@pve provider --privsep=0` (P). Its output is the secret: run it inside a prepared script that pipes the value straight into `rot.py set PVE_API_TOKEN --file <0600 tmp>` and shreds the file. Value format: `terraform@pve!provider=<uuid>` | none (read at run time) | `terraform plan` with the new token (P, `/terraform-ops`). Old token: `GET https://proxmox.bnei.dev/api2/json/version` returns 401 (C). PVE task log (`/var/log/pve/tasks/`) and `journalctl -u pveproxy` since 2026-10-18 show no `terraform@pve` activity the operator did not run (C reads via `node.sh --lan`, O judges) | P · C (store, checks) |

### T3 — session-signing keys and internet login passwords

| Keys | Unlocks / reachable from | Consumers | Rotation steps | Propagate | Verify | Who |
|---|---|---|---|---|---|---|
| `FLEET_SESSION_KEYS` | Forge a `fleet.bnei.dev` console session, i.e. drive agent-fleet (which holds GitHub and Claude credentials). Internet | `gitops/bootstrap/fleet-oidc-secret.yaml` → Secret `fleet-oidc` (ns `agent-fleet`) → core env | **Replace, do not prepend** (prepending keeps old cookies verifying): `rot.py set FLEET_SESSION_KEYS --gen alnum64` | restart core (P; Deployment name: OPEN) | Logged-in browsers are sent to authentik again. A new login works (O) | C · P |
| `MOUNTAIN_SESSION_KEY` | Forge mountain relay session and login-flow cookies. Internet | `gitops/bootstrap/mountain-oidc-secret.yaml` → `mountain-oidc` (ns `mountain`) | `rot.py set MOUNTAIN_SESSION_KEY --gen alnum64` | `kubectl -n mountain rollout restart deploy` (P) | Users signed out; a login works | C · P |
| `K8S_GRAFANA_ADMIN_PASSWORD` | Grafana server admin at `grafana.bnei.dev`: datasources (Loki logs, Prometheus, Pigsty VictoriaMetrics), contact points, users. Internet, login form kept on purpose | `gitops/bootstrap/grafana-admin-secret.yaml` → `grafana-admin` (ns `monitoring`) → `gitops/platform/values/grafana/values.yaml` `admin.existingSecret` | 1. `rot.py set K8S_GRAFANA_ADMIN_PASSWORD --gen alnum32` (C). 2. Grafana applies the admin password only on first DB init, so changing the Secret alone does nothing. Reset it in the pod: on the hub, `infisical secrets get K8S_GRAFANA_ADMIN_PASSWORD --plain ... \| kubectl -n monitoring exec -i deploy/<grafana> -- grafana cli admin reset-admin-password --password-from-stdin` (P). **OPEN:** confirm the flag exists in the running Grafana version | restart Grafana (P) so the env matches | `admin` login with the new password works. Grafana server admin → Users: no unknown users or API keys or service-account tokens since 2026-10-18 (O) | C · P · O |
| `BASIC_AUTH_HTPASSWD` | `pgweb.bnei.dev` (raw Postgres UI) and `alertmanager.bnei.dev` after an offline crack of the `apr1` hash. Internet | `gitops/bootstrap/basic-admin-auth-secret.yaml` → `authsecret` (ns `default`) → `basic-admin-auth` Middleware | 1. C generates a password and a bcrypt line (`htpasswd -nbBC 12 <user> <pw>`, inside a script). Store the hash in `BASIC_AUTH_HTPASSWD`, and the plaintext in a **new** row `BASIC_AUTH_PASSWORD` so it has a home. 2. PR adding the row to `docs/secrets.md` (C) | Traefik watches Secrets: no restart expected. If 401s persist, restart Traefik (P; ingress blip, ADR-0038) | `curl -s -o /dev/null -w '%{http_code}' https://pgweb.bnei.dev` returns 401, and 200 with the new credential (C) | C · P (merge) |
| `SILVERBULLET_ADMIN_PASSWORD` (undocumented, inferred) | Probably SilverBullet's local break-glass admin from the setup wizard (ADR-0058 step 3). `notes.bnei.dev` ingress is enabled | none in git: SilverBullet stores users in `users.json` on its PVC | O changes it in SilverBullet Admin → Users. C stores it with `--clipboard`. **OPEN:** confirm what the row is | none | Login with the new password works | O · C |

### T4 — NetBird (admin access means enrolling a peer, which means root SSH on every host)

| Keys | Unlocks / reachable from | Consumers | Rotation steps | Propagate | Verify | Who |
|---|---|---|---|---|---|---|
| `NETBIRD_API_TOKEN` | PAT of service user `ukubi`, role **admin**: setup keys, groups, policies, routes. `netbird.bnei.dev`, internet | `ansible/playbooks/netbird-configure.yml` only | NetBird dashboard → Team → Service Users → `ukubi`: create a new token, copy it (O). `rot.py set NETBIRD_API_TOKEN --clipboard --keep-old` (C). O deletes the old token | none (read at run time) | Old: `GET https://netbird.bnei.dev/api/users` with `Authorization: Token <old>` returns 401 (C). New: 200 (C) | O · C |
| `NETBIRD_AGENT_APP_PASSWORD` | `client_credentials` as `netbird-agent`, then a Dex exchange, then a NetBird SSH JWT. The JWT also works on the management API as role `user` for 24 h (`docs/runbook-netbird.md`, Users). authentik is internet-reachable | `gitops/bootstrap/authentik-blueprint-netbird.yaml` (token `key`, file `netbird-agent.yaml`); `ansible/scripts/node.sh` | `rot.py set NETBIRD_AGENT_APP_PASSWORD --gen alnum64` (C). The blueprint declares the token `key`, so the next worker apply sets it. **OPEN:** confirm the blueprint overwrites an existing token's key rather than skipping it; if not, delete the token in authentik first (O) | restart the authentik worker, twice if needed (P, §5 rule 6) | `ansible/scripts/node.sh k8s-cp-01 uptime` works with the new key (C). Old: the authentik token endpoint rejects it (C, from `ROTATION_OLD_*`) | C · P |
| `NETBIRD_INFRA_SETUP_KEY_SPIKE`, `_K8S`, `_PG`, `_PI`, `_PVE`, `_LXC` | Enroll a peer straight into `infra-nodes`. Reusable, 7-day expiry, usage limit = hosts + 2 (`docs/secrets.md`) | `ansible/playbooks/netbird-client.yml -e netbird_stage=<stage>` | Dashboard → Setup Keys: **revoke every `infra-*` key**, expired ones included (O). Delete the six rows from Infisical (C). Mint fresh per stage only when the next stage enrolls (`netbird-configure.yml -e netbird_setup_key_stage=<stage>`, P) | none | Setup Keys list shows nothing valid. Peer list: every peer in `infra-nodes` is a host in `ansible/playbooks/vars/bnei-lan-records.yml`, with nothing enrolled since 2026-10-18 that the operator did not do (C via API GET with the new token, O judges) | O · C |
| `NETBIRD_SESSION_COOKIE_KEY`, `NETBIRD_RELAY_AUTH_SECRET` | Embedded Dex session cookies (dashboard login); relay credential derivation (relay abuse). Internet | `gitops/bootstrap/netbird-config-secret.yaml` → `netbird-config` (ns `netbird`) | `rot.py shape` each, then `rot.py set` with a matching generator (C). **OPEN:** the exact format is not recorded in the repo | auto-reload restarts netbird-server. Relayed sessions drop and dashboard users are logged out | Dashboard login via authentik works. Mesh SSH via `node.sh` works (C) | C |
| `NETBIRD_OWNER_PASSWORD`, `NETBIRD_OWNER_PASSWORD_HASH` | Local `owner` (`account@bnei.dev`) break-glass. Dormant while `localAuthDisabled: true` | hash: `gitops/bootstrap/netbird-config-secret.yaml`; plaintext: operator only | `rot.py set NETBIRD_OWNER_PASSWORD --gen urlsafe32`, then the bcrypt cost-12 hash (`htpasswd -nbBC 12`, strip the `user:` prefix) into `_HASH`, inside one script (C) | auto-reload | Hash verifies against the plaintext (`htpasswd -vbB`, in-script) (C) | C |
| `NETBIRD_OIDC_CLIENT_SECRET` | Dex's upstream client at authentik. Needs a user login to be useful | `gitops/bootstrap/authentik-blueprint-netbird.yaml`; **and** the NetBird dashboard (Settings → Identity Providers, stored in `netbirddb`) | `rot.py set ... --gen alnum64` (C). O re-pastes it in the NetBird dashboard, fed from the clipboard by a prepared script, never typed in chat | restart the authentik worker (P) | Dashboard login via authentik works | C · P · O |

**After T4:** review the NetBird dashboard for unknown peers, setup keys,
**routes**, **network resources**, exit nodes, users, service-user tokens and
policies, and the Activity log since 2026-10-18 (O; C can list the same via
API GETs). Routes and network resources are forbidden here outright
(CLAUDE.md, ADR-0055), so any you find is hostile or a mistake.

### T5 — Cloudflare and mail

| Keys | Unlocks / reachable from | Consumers | Rotation steps | Propagate | Verify | Who |
|---|---|---|---|---|---|---|
| `CF_ACCOUNT_TOKEN` | DNS edit on **every record** in `bnei.dev` and `voconsteroid.com` (`gitops/bootstrap/traefik-cloudflare-secret.yaml` header): repoint any hostname, issue certs. Internet | `traefik-cloudflare-secret.yaml` → `traefik-cloudflare-dns` (ns `traefik`) → `CF_DNS_API_TOKEN` (`gitops/platform/values/traefik/values.yaml`) | Cloudflare → My Profile → API Tokens: create a token with `Zone → DNS → Edit`, scoped to the two zones (O). `rot.py set CF_ACCOUNT_TOKEN --clipboard --keep-old` (C). O deletes the old token | Traefik auto-reload restarts it: a brief ingress outage (`externalTrafficPolicy: Local`, one replica) | `GET https://api.cloudflare.com/client/v4/user/tokens/verify`: new `active`, old 401 (C). Traefik logs show no `9109` (C). DNS records in both zones match the expected list, with no record changed since 2026-10-18 that the operator did not change (C lists via API, O judges). Cloudflare audit log reviewed (O: the DNS token cannot read it) | O · C |
| `CLOUDFLARE_MFA_TEXT` (undocumented) | Name suggests Cloudflare account MFA recovery codes or a TOTP seed. Together with the account password (not in this project) that is full account takeover | none in git | **OPEN: confirm what it is.** If recovery codes: regenerate them in Cloudflare → My Profile → Authentication. If a TOTP seed: re-enroll the authenticator. Either way review active sessions (O). Then decide whether it belongs in an infra project at all. Recommendation: move it to a password manager and delete the row (C deletes on O's word) | none | Old codes rejected (O) | O |
| `SMTP_USERNAME`, `SMTP_PASSWORD` | SMTP2GO relay `mail-eu.smtp2go.com:587`: send mail as authentik's sender, passing SPF/DKIM for the domain. Internet | `gitops/bootstrap/authentik-secret.yaml` → `authentik-config`. **Not** ente: `ente-uovi`'s same-named keys are a different SMTP2GO account (`docs/secrets.md`) | SMTP2GO console: create a new SMTP user or reset its password, then delete the old one (O). Store both with `--clipboard` (C) | restart authentik server and worker (P) | authentik test email (Admin → System → Email) arrives (O). SMTP2GO activity log since 2026-10-18 shows only expected mail (O) | O · C · P |
| `MOUNTAIN_TURNSTILE_SECRET_KEY` | (Unused since ADR-0065: skip; delete once mountain's gate has held.) Turnstile `siteverify` for mountain enrollment. Low: lets someone validate tokens against your widget | `authentik-secret.yaml` → env → `gitops/bootstrap/authentik-blueprint-mountain-enrollment.yaml` | Cloudflare → Turnstile → widget → rotate secret key (O). `--clipboard` (C) | restart the authentik worker, then `ak apply_blueprint` the enrollment file, because an env change does not change the blueprint hash (P; `docs/secrets.md`) | Enrollment captcha passes (O) | O · C · P |

### T6 — k9s hub key, GitHub clone credentials, wird-agent token

| Keys | Unlocks / reachable from | Consumers | Rotation steps | Propagate | Verify | Who |
|---|---|---|---|---|---|---|
| `SSH_K9S_DASHBOARD_KEY` | root on `k9s-dashboard`, which holds an `8760h` cluster-admin token. Reachable from the internet on `:49222` | `bin/create-k9s-dashboard.sh`; very likely the operator's `~/.ssh/id_k9s_dashboard` too (**OPEN:** compare public halves) | 1. C generates a new ed25519 pair into a 0600 temp dir and stores the private half via `--file`, then shreds it. 2. P: append the new public key to the hub's `/root/.ssh/authorized_keys`, test login with it, remove the old line. 3. O replaces the laptop's `~/.ssh/id_k9s_dashboard`. 4. Finish **ADR-0055 rollout step 7** for the hub: a `Match` block so `:49222` accepts only `/etc/ssh/breakglass.pub`, plus fail2ban. C writes the playbook change (PR), P runs it. **Also rotate the hub's cluster-admin ServiceAccount token** if the hub was reachable with the leaked key: P recreates the token, O judges | none | Old key refused: `ssh -o IdentitiesOnly=yes -i <old> -p 49222 root@<public ip>` fails (O). `last` and `journalctl -u ssh` on the hub since 2026-10-18 show only known source IPs (C reads, O judges) | C · P · O |
| `GITHUB_APPS_PAT` | Fine-grained, read-only clone of private per-app repos. Internet | `ansible/playbooks/register-repos.yml` (from `register-repos.env`, not from Infisical) → ArgoCD `repo-creds-github-bnei` | O creates a new fine-grained PAT with the same repo list, then revokes the old one. C stores it (`--clipboard`). O updates `register-repos.env` | re-run `register-repos.yml` (P) | ArgoCD apps from user repos keep syncing (C: `kubectl -n argocd get applications`) | O · C · P |
| `GITHUB_APPS_SSH_KEY` (undocumented) | Per `gitops/README.md` line 159: the SSH credential ArgoCD uses for user-app repos. Read or write depends on how the deploy keys were added | **OPEN:** no consumer found in `register-repos.yml` (it uses `INFRA_BOOTSTRAP_SSH_KEY_FILE` and the HTTPS PAT). Possibly legacy | O lists deploy keys on the user-app repos and removes any matching this key's public half. If nothing uses it, C deletes the row | none | ArgoCD still syncs | O · C |
| `WIRD_AGENT_AUTHENTIK_TOKEN` | `client_credentials` as `wird-agent`, a Bearer for wird's `/reports.json` (user reports). Internet | not delivered to the cluster. Held by the maintainer and the Wird agent's environment (ADR-0052) | Regenerate the app password via `ak shell` per `docs/runbook-wird-admin-db-role.md` / ADR-0052 (P: `kubectl exec`). C stores it. O updates the Wird agent's environment | none | Old token: the authentik token endpoint rejects it (C) | P · C · O |

### T7 — ukubi-bridge

`docs/secrets.md` dates all of these 2026-10-18, the day of the leak, and the
order is unknown. The three cheap ones are rotated **unconditionally**. For the
other two, check the Infisical version history first.

| Keys | Unlocks / reachable from | Consumers | Rotation steps | Propagate | Verify | Who |
|---|---|---|---|---|---|---|
| `BRIDGE_GITHUB_WEBHOOK_SECRET` | Send validly signed webhooks to `events.bnei.dev/webhook/github`. Internet | `gitops/bootstrap/ukubi-bridge-secret.yaml` → `ukubi-bridge-config` (ns `ukubi-bridge`) | `rot.py set ... --gen hex32` (C). O pastes the same value into the App's webhook settings (from clipboard) | restart the bridge (P), if deployed (the service is built; its live state is to be checked) | App → Advanced → Recent deliveries show 2xx (O) | C · O · P |
| `BRIDGE_CORE_TOKEN` + `BRIDGE_CLIENTS` (both retired by ADR-0066 once the bridge accepts authentik tokens; skip if gone) | Privileged client `core` on the bridge API | token: not yet consumed (core's dispatcher, rollout step 4); `BRIDGE_CLIENTS` holds its sha256 | C generates `urlsafe48`, then in **one** script sets the token and rewrites `BRIDGE_CLIENTS`'s `core.token_sha256` (JSON; it holds hashes only) | restart the bridge (P) | Hash in `BRIDGE_CLIENTS` equals sha256 of the token (C, in-script) | C · P |
| `BRIDGE_ALERT_TOKEN` | Bearer for `/webhook/alertmanager` (cluster-internal, not yet used) | same Secret | `rot.py set ... --gen urlsafe48` | restart the bridge (P) | match | C |
| `BRIDGE_GITHUB_APP_PRIVATE_KEY` (verify date) | App JWT for `ukubi-bridge` (id 5370791): installation tokens on every installed repo, deliveries API, runner registration tokens | same Secret | If created before the export: App settings → generate a new key (O downloads the PEM). `rot.py set ... --file <pem>`, then shred (C). Restart, confirm a mint, then delete the old key in App settings (O) | restart the bridge (P) | The App settings list exactly one key (O) | O · C · P |
| `DBUSER_BRIDGE_PASSWORD` (verify date) | `dbuser_bridge` on `bridge`. LAN only | `pigsty/pigsty.yml` `pg_users` (SCRAM verifier); `ukubi-bridge-secret.yaml` | Cheap while the role does not exist yet (`docs/secrets.md`: "not yet created"): `rot.py set ... --gen urlsafe32 --scram`, and a PR replacing the verifier in `pigsty/pigsty.yml` (C). If the role exists, add the T9 DB-user steps | none until deployed | the verifier in git was generated from the stored value (C, in-script) | C · P (merge) |

### T8 — alert paths, Discord, Garage S3 keys

**`WEDDING_WALL_S3` is retired by PR #385 (infra-bootstrap). Do not rotate it.** The key is on the 2026-10-18 leak list and still works against `s3.bnei.dev`, so revoke it first, before anything else in this tier: `garage bucket deny --read --write wedding-wall --key wedding-wall-key`. Then, once the bucket is exported, delete the objects in `wedding-wall`, the bucket, and the key (`garage key delete wedding-wall-key`); delete the `WEDDING_WALL_S3_ACCESS_KEY`/`WEDDING_WALL_S3_SECRET` rows in this root project; and delete the `wedding-2026-ih1x` project that holds the copy. The rows below leave wedding out, and the checklist, OPEN item 5 and the appendix point back here.

| Keys | Unlocks / reachable from | Consumers | Rotation steps | Propagate | Verify | Who |
|---|---|---|---|---|---|---|
| `ALERT_WEBHOOK_TOKEN` | Bearer to agent-fleet core's alert webhook, which turns alerts into thot tasks (agents act). **OPEN:** whether core's endpoint is reachable via `fleet.bnei.dev` | `gitops/bootstrap/alertmanager-thot-secret.yaml` → `alertmanager-thot-token` (ns `monitoring`), mounted by Alertmanager and Grafana. **Must match** `ALERT_WEBHOOK_TOKEN` in `agent-fleet-nygh` | `rot.py set ALERT_WEBHOOK_TOKEN --gen hex32`, then `rot.py set ALERT_WEBHOOK_TOKEN --from-project <root> --project <agent-fleet-nygh>` (C) | restart core (P); restart Grafana (P). Alertmanager reads a mounted file; restart it only if the verify fails | Fire a test alert: core accepts it, with no 401 in Alertmanager's notification metrics (C reads) | C · P |
| `ALERTMANAGER_DISCORD_WEBHOOK_URL` | Post as the alert bot into the Discord channel (fake alerts). Internet | `gitops/bootstrap/alertmanager-discord-secret.yaml` → `alertmanager-discord-webhook` (ns `monitoring`): Alertmanager config and Grafana `extraSecretMounts` | Discord channel → Integrations → Webhooks: create a new webhook, delete the old one (O). `--clipboard` (C) | restart Grafana (P). Alertmanager as above | Test alert reaches Discord. The old URL returns 404 (C, from `ROTATION_OLD_*`) | O · C · P |
| `PGBACKREST_S3_ACCESS_KEY/SECRET`, `LONGHORN_S3_ACCESS_KEY/SECRET` | Read **and delete** the Postgres and Longhorn backups (`pg-backup`, `k8s-longhorn-backup`) via `s3.bnei.dev`. Internet. Do these first in T8 | pgBackRest: `pigsty/pigsty.yml` (env lookup) → `/etc/pgbackrest/pgbackrest.conf`. Longhorn: `gitops/bootstrap/longhorn-backup-secret.yaml` → `longhorn-backup-secret` | Garage rotation = bump `key_name` in `garage_buckets` (`ansible/playbooks/garage-configure.yml`; the `ente-photos-key-2` precedent), PR (C). Run `garage-configure.yml --tags bucket_ops` (P), which creates and grants the key and upserts Infisical. Delete the old key by hand: `garage key delete <old>` (P; the playbook never deletes) | pgBackRest: `./pgsql.yml -l pg-proxmox --tags pgbackrest` from the hub (P; `docs/runbook-pgbackrest-s3-migration.md`; render-to-temp diff first, per the 2026-10-20 notes). Longhorn: re-read at the next backup-target poll; restart `longhorn-manager` only if the target goes unavailable (P) | `pgbackrest --stanza=pg-proxmox info` shows `status: ok` and a new backup succeeds (P). Longhorn backup target `Available` and a manual backup completes (C/P). Bucket object counts are not lower than before (C, via the new key) | C · P |
| `AGENTFLEET_FILES_S3_ACCESS_KEY/SECRET` | Read and write the fleet file space (`agent-fleet-files`). Internet | **Copy** in `agent-fleet-nygh`, read by core (`docs/secrets.md`) | as above (bump `agent-fleet-files-key`), then `rot.py set ... --from-project <root> --project <agent-fleet-nygh>` for both keys (C) | restart core (P) | Fleet Files page upload and download work (O) | C · P |
| `ENTE_S3_*`, `WIRD_MODELS_S3_*`, `DROP_S3_*` (`WEDDING_WALL_S3_*`: see the T8 note) | Each bucket's objects (photos, model weights, shared files). Internet | ente: copy in `ente-uovi` (`gitops/platform/values/ente-museum/values.yaml`). wird-models: `gitops/bootstrap/wird-secret.yaml` **and** a copy in `wird-8k-fc`. drop: `gitops/bootstrap/drop-secret.yaml` | bump each `key_name`, run `bucket_ops` (P), copy to each per-app project with `--from-project` (C), delete the old keys (P) | ente-museum: auto-reload. wird, drop: `kubectl -n <ns> rollout restart deploy` (P) | each app's upload or download path works (O) | C · P · O |
| `ZOT_S3_ACCESS_KEY/SECRET` | Overwrite registry blobs, i.e. supply-chain into every node pull. Internet via S3 | `gitops/platform/values/zot/values.yaml` (`secretKeyRef`) | bump `zot-registry-key`, `bucket_ops` (P) | restart zot (P; `autoReload: false`). Also complete PR #350's own follow-up: operator restart, then confirm `zot-infisical` holds 3 keys (key-name go-template, C), then zot restart | `crane`/`buildah` pull of a known tag works. The next CI push succeeds (C/O) | C · P |

### T9 — LAN-only (normal rotation policy)

| Keys | Unlocks / reachable from | Consumers | Rotation steps | Propagate | Verify | Who |
|---|---|---|---|---|---|---|
| `PVE_SSH_PRIVATE_KEY` | `root@pam` on `.165` and server1 `.200`; likely all three PVE nodes, since `/etc/pve/priv/authorized_keys` is cluster-shared (**OPEN:** confirm) | `terraform/`, `bin/create-k9s-dashboard.sh`, `ansible/playbooks/pve-postinstall.yml`, `netbird-client.yml` (`pct` step), `ansible/inventories/mesh/hosts.yml` (`node_ssh_key_secret`) | C generates the pair and stores the private half via `--file`. P appends the public half to `/etc/pve/priv/authorized_keys`, tests, then removes **only** the old line. Never touch PVE node entries (ADR-0055 §5) | none | `node.sh --lan <pve> uptime` with the new key (C). Old key refused (P) | C · P |
| `SSH_OLDPG_KEY` | `vagrant` on `.193` **and** live `pg01`/`pg02` (`.205`/`.207`); heavy Pigsty runs | `ansible/inventories/mesh/hosts.yml`, `docs/runbook-k9s-ops-hub.md`, `.claude/skills/authentik-oidc/SKILL.md` | as above, on all three hosts' `~vagrant/.ssh/authorized_keys` (P). Update the public key recorded in `terraform/imported.tf` in a PR (C); the field is `ignore_changes`'d (**OPEN:** confirm, so the plan stays clean). Keep the root break-glass key (`docs/runbook-pg-bootstrap.md` §6) untouched | none | a pigsty `-m ping` from the hub with the new key (P) | C · P |
| `SSH_SERVER1_KEY`, `SSH_LAPTOP_KEY`, `SSH_PI4_KEY`, `SSH_PG_ETCD_WITNESS_KEY` | root or user SSH on server1, ex-laptop, the Pi 4 (Pi-hole, `bnei.lan` DNS), the etcd witness | `SSH_PI4_KEY`: `.claude/skills/run-ukubi-ops/driver.sh`, `ansible/playbooks/pihole-configure.yml`, `ansible/inventories/{mesh,pihole}/hosts.yml`. Others: agent SSH only (`docs/secrets.md`) | per host: new pair (C), authorized_keys swap (P) | none | `node.sh --lan <host>` with the new key (C) | C · P |
| `DBUSER_AUTHENTIK_PASSWORD`, `DBUSER_HQ_PASSWORD`, `DBUSER_MOUNTAIN_PASSWORD`, `DBUSER_NETBIRD_PASSWORD`, `DBUSER_WIRD_PASSWORD` | Each app's own database on `postgres.bnei.lan:5432` | `pigsty/pigsty.yml` `pg_users` (SCRAM verifiers); `gitops/bootstrap/{authentik,hq,mountain,netbird-config,wird,wird-admin}-secret.yaml` (`wird-admin-secret.yaml` names `DBUSER_WIRD_PASSWORD` too) | 1. `rot.py set <KEY> --gen urlsafe32 --scram` (`alnum32` for authentik) and a PR swapping the verifier in `pigsty/pigsty.yml` (C). 2. After merge, on the hub: `./pgsql-user.yml -l pg-proxmox -e username=<role>` with the OLDPG key (P; `docs/runbook-k9s-ops-hub.md`). Check the Patroni leader first | right after step 2: restart the app (P): `authentik` server+worker, `hq`, `mountain`, `wird`. netbird auto-reloads. The window between steps is an auth outage for that app; keep it short | app healthy, no `password authentication failed` in its logs (C) | C · P |
| `DBUSER_WIRD_ADMIN_PASSWORD` | `wird_admin`, read-mostly on `wirddb` | `gitops/bootstrap/wird-admin-secret.yaml`. The role is created by SQL, not `pg_users` | `rot.py set ... --gen alnum43 --scram` (C). `ALTER ROLE wird_admin PASSWORD '<verifier>'` as `dbuser_dba` on the leader (P; `docs/runbook-wird-admin-db-role.md`) | restart wird-adminweb (P) | adminweb loads reports (O) | C · P |
| `GARAGE_ROOT_TOKEN` | Garage `rpc_secret`: node RPC on `:3901`. LAN | `ansible/playbooks/garage-configure.yml` (reads it back from `/etc/garage.toml`) | Manual: the playbook refuses to regenerate it on a live node. Edit `rpc_secret` in `/etc/garage.toml` and restart garage (single node) (P). Store with `--file` (C). **OPEN:** confirm the single-node restart is safe with a new secret | none | `garage status` healthy, S3 consumers fine (C/P) | P · C |
| `CA_PIGSTY_KEY`, `CA_PIGSTY_CRT` | Sign etcd and Postgres server certs, so MITM on the LAN | `pigsty/roles/{ca,etcd,pgsql}`; also named in `wird-secret.yaml` and `shared-infisicalsecret.yaml` comments | Full CA rotation: `docs/runbook-pg-ca-rotation-etcd-quorum.md` (P, a planned window). `docs/secrets.md` says the row was a placeholder; check whether it holds a real key (`rot.py shape`, C) before deciding | per runbook | per runbook | P |
| `REDIS_MAIN_PASSWORD` | Pigsty `redis-main` on pg02; ArgoCD's external Redis. The same value is committed in `pigsty/pigsty.yml` (`redis_password`), so it was already in git | `gitops/bootstrap/argocd-redis-secret.yaml` → `argocd-redis`; `gitops/bootstrap/argocd-application.yaml` | Pigsty `redis` config change plus Infisical, then restart ArgoCD components (P). Remove the plaintext from `pigsty.yml` in the same PR (C) | restart argocd server, repo-server, controller (P) | ArgoCD UI loads, apps sync (C) | C · P |
| `PIHOLE_WEBPASSWORD` | Pi-hole admin UI, LAN | `ansible/playbooks/pihole-configure.yml` (first install only; v6 stores a hash) | `pihole setpassword` on the Pi (P) fed from a generated value (C) | none | login works (O) | C · P |
| `WIRD_ADMIN_OIDC_CLIENT_SECRET`, `WIRD_ADMIN_OIDC_CLIENT_ID` | HMAC key of the forwarded JWT wird-adminweb trusts. Forging needs a direct path to the pod (in-cluster) | `gitops/bootstrap/wird-admin-secret.yaml` | Generated by authentik, not settable (`ProxyProviderSerializer` has no `client_secret`). Rotating means recreating the provider and reading both back via `ak shell` (P; ADR-0052 runbook). **OPEN:** is it worth it at this tier | restart wird-adminweb (P) | adminweb login via authentik works | P · C |

### T10 — low value, or do not rotate by default

| Keys | Why low / why not | Action | Who |
|---|---|---|---|
| `GRAFANA_OIDC_CLIENT_SECRET`, `ARGOCD_OIDC_CLIENT_SECRET`, `FLEET_OIDC_CLIENT_SECRET`, `MOUNTAIN_OIDC_CLIENT_SECRET`, `SILVERBULLET_OIDC_CLIENT_SECRET` (+ their `_ID`s) | A client secret alone does not log anyone in. It needs a user's authorization code | Rotate last, one at a time: `rot.py set ... --gen alnum64` (C). Restart the authentik worker (P), then the app: Grafana and core restart (env). ArgoCD reads `$argocd-oidc:clientSecret` (**OPEN:** whether argocd-server picks it up without a restart). SilverBullet needs a re-paste in Admin → Authentication (O) | C · P · O |
| `AUTHENTIK_SECRET_KEY` | `docs/runbook-authentik-identity.md`: treat as **immutable**. Changing it invalidates every session **and** every unique user ID. Apps on `sub_mode: hashed_user_id` (fleet, hermes, hq, netbird, silverbullet, wird) would see every user as new: NetBird's admin, Wird users' data mapping | **Do not rotate** without an explicit operator decision. **OPEN:** confirm against authentik upstream docs what an attacker can forge with it alone (cookie signing vs server-side sessions). Record the accepted risk in `docs/secrets.md` | O decides |
| `NETBIRD_STORE_ENCRYPTION_KEY` | Encrypts columns in `netbirddb`, so it is only useful with DB access (LAN, `dbuser_netbird`). Rotating without re-encryption makes existing rows unreadable | Do not rotate. Rotating `DBUSER_NETBIRD_PASSWORD` (T9) removes the access path. **OPEN:** whether netbird-server supports re-keying | O decides |
| `ZOT_HTPASSWD` | bcrypt cost 12 of a random 40-char password: infeasible to crack. The plaintext is in `platform-commons-76pb` and GitHub Actions secrets, which were not exported | No action for this leak | — |

## 7. `WIRD_ANDROID_KEYSTORE_P12`, `_KEYSTORE_PASSWORD`, `_KEY_ALIAS`, `_KEY_PASSWORD`

The Wird release signing keystore and its passwords were in the export.
`docs/secrets.md` calls losing this keystore the one unrecoverable loss in the
estate. **It cannot be rotated like a password.** Android accepts an update
only if it is signed by the installed app's key, so a new key alone strands
every installed copy.

What the leak enables: anyone holding it can sign an APK that Android accepts
as an **update** to installed Wird, with access to its data. They still have to
get it onto a phone (sideload, or a store account they would also need).

Options, for the operator. Claude researches; nothing here is decided:

1. **APK Signature Scheme v3 key rotation** (`apksigner rotate`): new key plus
   a proof-of-rotation lineage. Installed apps on Android 9+ accept updates
   signed by the new key. **OPEN:** Wird's `minSdk`, and whether the lineage
   flags (e.g. `--set-installed-data false` on the old signer) actually stop a
   later APK signed only with the old key.
2. If Wird goes to Play: enroll in Play App Signing with a **new** upload key,
   so the leaked key never reaches Play.
3. Accept the risk and record it, if distribution is closed enough.

Whatever is chosen: **never delete the current keystore**, and keep both
copies in step (`infra-bootstrap-1-ge1` root **and** `wird-8k-fc` root, which
is the copy `apk.yml` signs with). Also revisit the `wird-8k-fc` grants to
`ci-oidc` and `k8s-cluster` (`docs/secrets.md`, "Who else can read the
keystore copy").

## 8. Undocumented keys

Keys among the 121 with no row in `docs/secrets.md`:

| Key | Inferred from | Consumer | Status |
|---|---|---|---|
| `ALERT_WEBHOOK_TOKEN` | header of `gitops/bootstrap/alertmanager-thot-secret.yaml` | Alertmanager and Grafana → agent-fleet core (thot) | Documented in that file only. Add a row (C) |
| `CLOUDFLARE_MFA_TEXT` | name only | none | **OPEN:** what it is (T5) |
| `DROP_S3_ACCESS_KEY/SECRET` | `gitops/bootstrap/drop-secret.yaml`, `garage-configure.yml` (`drop` bucket, ADR-0059) | drop at `files.bnei.dev` | Add a row (C) |
| `ENTE_S3_ACCESS_KEY/SECRET` | `garage-configure.yml` (`ente-photos-key-2`), `gitops/platform/values/ente-museum/values.yaml` | ente-museum, via a copy in `ente-uovi` | Add a row (C) |
| `GITHUB_APPS_SSH_KEY` | `gitops/README.md` line 159 | **OPEN:** no live consumer found | T6 |
| `SILVERBULLET_ADMIN_PASSWORD` | ADR-0058 step 3 (local break-glass admin) | SilverBullet `users.json` | **OPEN:** confirm (T3) |
| `NETBIRD_INFRA_SETUP_KEY_K8S`, `_LXC`, `_PG`, `_PI`, `_PVE` | the `NETBIRD_INFRA_SETUP_KEY_<STAGE>` pattern row | `netbird-client.yml` | Covered by the pattern. Revoke (T4) |
| `SSH_PROXMOX_HOST/PORT/USER` | `docs/secrets.md` SSH table (no `_KEY` row exists) | agent SSH | Not secret. **OPEN:** which key pairs with it (probably `PVE_SSH_PRIVATE_KEY`) |

## 9. Checklists

Tick in order. "Done" means the verify column passed, not that the value was written.

### T1
- [ ] Infisical audit: identity logins and secret reads since 2026-10-18 reviewed; source IPs recorded.
- [ ] Project audit: keys deleted since 2026-10-18 listed (`K8S_BREAK_GLASS_TOKEN`?); any found added to this runbook.
- [ ] Trusted IPs set on `universal-auth-credentials`' identity and the Hermes identity; cluster still syncs.
- [ ] (Optional) `ARGOCD_INFISICAL_CLIENT_SECRET` rotated; old one returns 401.

### T2
- [ ] `UKUBI_BOT_GH_PAT` vs `agent-fleet-nygh` `/GH_TOKEN` compared.
- [ ] Bot PAT revoked; bot account and repo events reviewed.
- [ ] `ukubi-fleet` App path or stop-gap PAT decided; `UKUBI_BOT_GH_PAT` deleted from root.
- [ ] `PVE_API_TOKEN` re-issued; `terraform plan` clean; old token 401 at `proxmox.bnei.dev`; PVE task log reviewed.

### T3
- [ ] `FLEET_SESSION_KEYS` replaced (not prepended); core restarted.
- [ ] `MOUNTAIN_SESSION_KEY` replaced; mountain restarted.
- [ ] Grafana admin password reset in the pod; users and tokens reviewed.
- [ ] `BASIC_AUTH_HTPASSWD` replaced; `BASIC_AUTH_PASSWORD` row added.
- [ ] `SILVERBULLET_ADMIN_PASSWORD` identified and changed.

### T4
- [ ] `NETBIRD_API_TOKEN` replaced; old token 401.
- [ ] `NETBIRD_AGENT_APP_PASSWORD` replaced; `node.sh` works.
- [ ] All `infra-*` setup keys revoked; six Infisical rows deleted.
- [ ] Session cookie key and relay secret replaced; netbird restarted.
- [ ] Owner password and hash replaced together.
- [ ] `NETBIRD_OIDC_CLIENT_SECRET` replaced in Infisical **and** the dashboard.
- [ ] Peers, setup keys, routes, network resources, users, tokens, policies and the activity log reviewed.

### T5
- [ ] `CF_ACCOUNT_TOKEN` replaced; old token 401; DNS records and audit log reviewed.
- [ ] `CLOUDFLARE_MFA_TEXT` identified; codes or TOTP regenerated; row moved out or deleted.
- [ ] SMTP2GO credential replaced; test mail sent; activity reviewed.
- [ ] Turnstile secret rotated; blueprint re-applied. (Void since ADR-0065: the key is unused.)

### T6
- [ ] k9s hub key replaced on the hub and the laptop; old key refused; hub SSH log reviewed.
- [ ] ADR-0055 step 7 `Match` block and break-glass key on the hub merged and applied.
- [ ] Hub cluster-admin token decision taken.
- [ ] `GITHUB_APPS_PAT` replaced; `register-repos.yml` re-run.
- [ ] `GITHUB_APPS_SSH_KEY` traced, removed or rotated.
- [ ] `WIRD_AGENT_AUTHENTIK_TOKEN` regenerated and handed over.

### T7
- [ ] Webhook secret, core token (+ `BRIDGE_CLIENTS`), alert token replaced.
- [ ] App private key and `DBUSER_BRIDGE_PASSWORD` creation times checked; rotated if needed.

### T8
- [ ] `ALERT_WEBHOOK_TOKEN` replaced in both projects; test alert accepted.
- [ ] Discord webhook replaced; old URL 404.
- [ ] Backup keys (`PGBACKREST_S3`, `LONGHORN_S3`) replaced; backups verified.
- [ ] `AGENTFLEET_FILES`, `ENTE`, `WIRD_MODELS`, `DROP`, `ZOT` keys replaced; per-app copies updated; old Garage keys deleted.
- [ ] `WEDDING_WALL_S3` revoked, then its bucket, key, root rows and `wedding-2026-ih1x` project deleted (the T8 note).
- [ ] zot: `zot-infisical` holds 3 keys; zot restarted.

### T9
- [ ] `PVE_SSH_PRIVATE_KEY`, `SSH_OLDPG_KEY`, `SSH_SERVER1/LAPTOP/PI4/PG_ETCD_WITNESS_KEY` replaced on their hosts.
- [ ] Five `pg_users` DB passwords rotated (Infisical + verifier + `pgsql-user.yml` + app restart).
- [ ] `DBUSER_WIRD_ADMIN_PASSWORD` rotated by SQL.
- [ ] `GARAGE_ROOT_TOKEN`, `CA_PIGSTY_*`, `REDIS_MAIN_PASSWORD`, `PIHOLE_WEBPASSWORD`, `WIRD_ADMIN_OIDC_*` scheduled or done.

### T10 and §7
- [ ] OIDC client secrets rotated one at a time, or explicitly deferred.
- [ ] `AUTHENTIK_SECRET_KEY`, `NETBIRD_STORE_ENCRYPTION_KEY`: accepted risk recorded in `docs/secrets.md`.
- [ ] Wird keystore option chosen and recorded.

## 10. Final verification

- [ ] Every `ROTATION_OLD_*` key deleted from Infisical.
- [ ] Old credentials fail: Infisical universal-auth secret (if rotated) 401; GitHub bot PAT 401; PVE token 401; NetBird PAT 401; Cloudflare token 401; Discord webhook 404; k9s hub old key refused; old Garage keys absent from `garage key list`.
- [ ] Reviews done: NetBird peers/keys/routes/activity; Cloudflare audit log and DNS records; GitHub bot account and repo events; PVE task log; k9s hub SSH log; Infisical audit log; SMTP2GO activity; Grafana users and tokens.
- [ ] Cluster healthy: `kubectl get applications -n argocd` all Synced/Healthy; no CrashLoopBackOff; operator logs clean (C).
- [ ] `docs/secrets.md` updated: new rows from §8, the "verify date" outcomes, accepted risks, and a pointer to this runbook (C, PR; P merges).
- [ ] An entry in `docs/bootstrap-test-notes.md` for anything that broke during rotation.

## 11. OPEN items (not established from the repo)

1. Whether any key was deleted from the root between 2026-10-18 and 2026-10-20. `K8S_BREAK_GLASS_TOKEN` is named as a root secret in PR #350's message, but is not among the 121.
2. Creation time versus export time for every 2026-10-18 key: `BRIDGE_*`, `DBUSER_BRIDGE_PASSWORD`.
3. The source IPs Infisical records for the in-cluster operator, Hermes and LAN callers (needed before trusted IPs).
4. Whether `UKUBI_BOT_GH_PAT` equals `agent-fleet-nygh` `/GH_TOKEN`, and what else uses it.
5. Project IDs for `agent-fleet-nygh` and `platform-commons-76pb` (needed for `--project`). Known: `wird-8k-fc` `4da1abaa-3a51-4fed-9329-1b164f3c67cd`, `ente-uovi` `c018d40d-dfe0-4cc2-bbc8-857cac934af0`. (`wedding-2026-ih1x` is deleted, not rotated: the T8 note.)
6. Whether the workstation CLI session has write access on each per-app project.
7. Deployment names for agent-fleet core, Grafana, and the user apps, and which carry the auto-reload annotation.
8. Whether ukubi-bridge is deployed and its DB role created.
9. Whether agent-fleet core's alert webhook is reachable from the internet.
10. What `CLOUDFLARE_MFA_TEXT` and `SILVERBULLET_ADMIN_PASSWORD` hold, and whether `GITHUB_APPS_SSH_KEY` has any consumer.
11. The value format of `NETBIRD_SESSION_COOKIE_KEY` and `NETBIRD_RELAY_AUTH_SECRET` (use `rot.py shape`).
12. Whether the authentik blueprint overwrites the existing `netbird-agent` token key on re-apply.
13. Whether the operator's `~/.ssh/id_k9s_dashboard` is the same key as `SSH_K9S_DASHBOARD_KEY`.
14. Whether `PVE_SSH_PRIVATE_KEY` is accepted on all three PVE nodes (shared `/etc/pve/priv/authorized_keys`).
15. Whether `terraform/imported.tf` ignores `user_account` changes for pg01/pg02.
16. Grafana's `reset-admin-password --password-from-stdin` support in the running version, and whether ArgoCD picks up a changed OIDC secret without a restart.
17. What `AUTHENTIK_SECRET_KEY` alone lets an attacker forge (upstream docs).
18. Wird `minSdk`, distribution channel, and the v3 rotation lineage semantics (§7).
19. Whether Cloudflare WAF or geo rules in front of `proxmox.bnei.dev` narrow the T2 exposure (not in git).
20. Whether `CA_PIGSTY_KEY` at root holds a real key or the placeholder `docs/secrets.md` describes.

## Appendix — every key in the project, by tier

All 121 names at the root on 2026-10-20. T1 has no row here: its credentials are not in the project (§0).

| Tier | Keys |
|---|---|
| DONE (created 2026-10-20) (4) | `PATRONI_PASSWORD`, `PG_ADMIN_PASSWORD`, `PG_MONITOR_PASSWORD`, `PG_REPLICATION_PASSWORD` |
| T2 (2) | `PVE_API_TOKEN`, `UKUBI_BOT_GH_PAT` |
| T3 (5) | `BASIC_AUTH_HTPASSWD`, `FLEET_SESSION_KEYS`, `K8S_GRAFANA_ADMIN_PASSWORD`, `MOUNTAIN_SESSION_KEY`, `SILVERBULLET_ADMIN_PASSWORD` |
| T4 (13) | `NETBIRD_AGENT_APP_PASSWORD`, `NETBIRD_API_TOKEN`, `NETBIRD_INFRA_SETUP_KEY_K8S`, `NETBIRD_INFRA_SETUP_KEY_LXC`, `NETBIRD_INFRA_SETUP_KEY_PG`, `NETBIRD_INFRA_SETUP_KEY_PI`, `NETBIRD_INFRA_SETUP_KEY_PVE`, `NETBIRD_INFRA_SETUP_KEY_SPIKE`, `NETBIRD_OIDC_CLIENT_SECRET`, `NETBIRD_OWNER_PASSWORD`, `NETBIRD_OWNER_PASSWORD_HASH`, `NETBIRD_RELAY_AUTH_SECRET`, `NETBIRD_SESSION_COOKIE_KEY` |
| T5 (5) | `CF_ACCOUNT_TOKEN`, `CLOUDFLARE_MFA_TEXT`, `MOUNTAIN_TURNSTILE_SECRET_KEY`, `SMTP_PASSWORD`, `SMTP_USERNAME` |
| T6 (4) | `GITHUB_APPS_PAT`, `GITHUB_APPS_SSH_KEY`, `SSH_K9S_DASHBOARD_KEY`, `WIRD_AGENT_AUTHENTIK_TOKEN` |
| T7 (6) | `BRIDGE_ALERT_TOKEN`, `BRIDGE_CLIENTS`, `BRIDGE_CORE_TOKEN`, `BRIDGE_GITHUB_APP_PRIVATE_KEY`, `BRIDGE_GITHUB_WEBHOOK_SECRET`, `DBUSER_BRIDGE_PASSWORD` |
| T8 (18) | `AGENTFLEET_FILES_S3_ACCESS_KEY`, `AGENTFLEET_FILES_S3_SECRET`, `ALERTMANAGER_DISCORD_WEBHOOK_URL`, `ALERT_WEBHOOK_TOKEN`, `DROP_S3_ACCESS_KEY`, `DROP_S3_SECRET`, `ENTE_S3_ACCESS_KEY`, `ENTE_S3_SECRET`, `LONGHORN_S3_ACCESS_KEY`, `LONGHORN_S3_SECRET`, `PGBACKREST_S3_ACCESS_KEY`, `PGBACKREST_S3_SECRET`, `WEDDING_WALL_S3_ACCESS_KEY`, `WEDDING_WALL_S3_SECRET`, `WIRD_MODELS_S3_ACCESS_KEY`, `WIRD_MODELS_S3_SECRET`, `ZOT_S3_ACCESS_KEY`, `ZOT_S3_SECRET`. `WEDDING_WALL_S3_*` is retired by PR #385, not rotated: the T8 note. |
| T9 (18) | `CA_PIGSTY_CRT`, `CA_PIGSTY_KEY`, `DBUSER_AUTHENTIK_PASSWORD`, `DBUSER_HQ_PASSWORD`, `DBUSER_MOUNTAIN_PASSWORD`, `DBUSER_NETBIRD_PASSWORD`, `DBUSER_WIRD_ADMIN_PASSWORD`, `DBUSER_WIRD_PASSWORD`, `GARAGE_ROOT_TOKEN`, `PIHOLE_WEBPASSWORD`, `PVE_SSH_PRIVATE_KEY`, `REDIS_MAIN_PASSWORD`, `SSH_LAPTOP_KEY`, `SSH_OLDPG_KEY`, `SSH_PG_ETCD_WITNESS_KEY`, `SSH_PI4_KEY`, `SSH_SERVER1_KEY`, `WIRD_ADMIN_OIDC_CLIENT_SECRET` |
| T10 (6) | `ARGOCD_OIDC_CLIENT_SECRET`, `FLEET_OIDC_CLIENT_SECRET`, `GRAFANA_OIDC_CLIENT_SECRET`, `MOUNTAIN_OIDC_CLIENT_SECRET`, `SILVERBULLET_OIDC_CLIENT_SECRET`, `ZOT_HTPASSWD` |
| T10, do not rotate by default (2) | `AUTHENTIK_SECRET_KEY`, `NETBIRD_STORE_ENCRYPTION_KEY` |
| §7 (keystore) (3) | `WIRD_ANDROID_KEYSTORE_P12`, `WIRD_ANDROID_KEYSTORE_PASSWORD`, `WIRD_ANDROID_KEY_PASSWORD` |
| not secret (35) | `ARGOCD_OIDC_CLIENT_ID`, `BRIDGE_GITHUB_APP_ID`, `CF_ACCOUNT_ID`, `FLEET_OIDC_CLIENT_ID`, `GRAFANA_OIDC_CLIENT_ID`, `MOUNTAIN_OIDC_CLIENT_ID`, `MOUNTAIN_TURNSTILE_SITE_KEY`, `NETBIRD_OIDC_CLIENT_ID`, `SILVERBULLET_OIDC_CLIENT_ID`, `SMTP_EMAIL`, `SMTP_HOST`, `SMTP_PORT`, `SSH_K9S_DASHBOARD_HOST`, `SSH_K9S_DASHBOARD_PORT`, `SSH_K9S_DASHBOARD_USER`, `SSH_LAPTOP_HOST`, `SSH_LAPTOP_PORT`, `SSH_LAPTOP_USER`, `SSH_OLDPG_HOST`, `SSH_OLDPG_PORT`, `SSH_OLDPG_USER`, `SSH_PG_ETCD_WITNESS_HOST`, `SSH_PG_ETCD_WITNESS_PORT`, `SSH_PG_ETCD_WITNESS_USER`, `SSH_PI4_HOST`, `SSH_PI4_PORT`, `SSH_PI4_USER`, `SSH_PROXMOX_HOST`, `SSH_PROXMOX_PORT`, `SSH_PROXMOX_USER`, `SSH_SERVER1_HOST`, `SSH_SERVER1_PORT`, `SSH_SERVER1_USER`, `WIRD_ADMIN_OIDC_CLIENT_ID`, `WIRD_ANDROID_KEY_ALIAS` |
