# ADR-0061: Agent Vault as a private platform service

**Status:** Accepted, not live. Waits on merge, then one operator command
(Rollout).
**Date:** 2026-10-19
**Related:** [ADR-0004](0004-gitops-pattern-c-registry-applicationset.md)
(common-app-chart, no per-app chart), [ADR-0019](0019-longhorn-rollout-specifics.md)
(longhorn), [ADR-0023](0023-common-app-chart-hooks-and-oneoff-jobs.md) (hooks),
[ADR-0034](0034-in-cluster-oci-registry-zot-garage-backed.md) (zot's empty-hostname element),
[ADR-0049](0049-shared-commons-secrets-in-common-app-chart.md) (the shared
Infisical identity), [ADR-0060](0060-event-bridge.md) (the bridge executor,
a future second caller). agent-fleet: `docs/adr/0064` (definition pods,
whose interim real token this replaces) and `docs/adr/0065` (the
provisioner's side: reconcile, mint/revoke, egress lock).

## Context

agent-fleet's *definition* pods (agent-fleet ADR 0062/0064) run Claude Code
for a reviewed definition. Until now each one carries the real
`CLAUDE_CODE_OAUTH_TOKEN` in its env (0064's INTERIM), and none can push.
The plan is that a definition pod holds **no** real secret: it gets
placeholders and an `HTTPS_PROXY`, and a broker swaps in the real credential
per host and path.

Infisical Agent Vault does exactly that: a MITM proxy (`:14322`) with
per-vault services (`host/path` glob → credential) and short-lived session
tokens minted over an API (`:14321`). Spikes on this cluster (2026-10-18,
namespace `spike-vault`, deleted) showed:

- Claude Code (native binary) and Bun honour `HTTPS_PROXY` + the MITM CA,
  and the `bearer` auth type overwrites the whole `Authorization` header, so
  any placeholder works.
- `unmatched_host_policy=deny` turns every unmatched host or path into a 403.
- The path glob is a plain prefix with a greedy `*`. The safe rule shape is
  `github.com/<o>/<r>/*` + `github.com/<o>/<r>.git/*`, never `<r>*`.
- Minting needs an instance role of `member` or higher. A leaked session
  token cannot mint more.

## Decision

1. **A platform-common app on common-app-chart** (`agent-vault`, namespace
   `agent-vault`): an element in `platform-common-apps.applicationset.yaml`
   with `hostname: ""` (zot's reason), values in
   `gitops/platform/values/agent-vault/values.yaml`. One replica, `Recreate`
   strategy. The image is pinned by digest:
   `docker.io/infisical/agent-vault:0.40.0@sha256:4d490e25…`. It is a
   research-preview upstream, so bumps are deliberate.
2. **SQLite on a 1Gi longhorn PVC. This deviates from the plan, which said
   "backed by Pigsty Postgres".** Upstream does support Postgres (v0.40.0,
   `internal/store/open.go`: `DATABASE_URL` with a `postgres://` scheme opens
   Postgres, otherwise SQLite; GORM migrations under an advisory lock, the MITM CA stored
   in the DB, `docs/self-hosting/postgres.mdx`). It is not used because what
   it buys — stateless replicas, pgBackRest — is not needed by one replica of
   a store that is mostly a cache, and it costs a Pigsty database and user
   (an operator-run pigsty playbook, as `bridge` needed in ADR-0060), a
   `DATABASE_URL` secret, and a Pigsty dependency at bootstrap.
   - Upgrade path, if HA or Pigsty backups are ever wanted: upstream's
     `agent-vault migrate-db --to <url>` copies SQLite into Postgres in one
     transaction; then set `DATABASE_URL` and drop the PVC.
   - Most of the data is a cache: agent-fleet's provisioner re-reconciles
     services and credentials from git + Infisical every minute.
   - What only the PVC holds: the owner, the provisioner's agent, issued
     session tokens and the MITM CA (`$HOME/.agent-vault/ca`, `HOME=/data`).
   - If the PVC is lost: re-run the bootstrap command (Decision 5). The
     provisioner republishes the new CA at the next warm. Live tokens die,
     which fails closed.
   - longhorn because it is the class with replication and backups.
3. **ClusterIP only, no IngressRoute, `AGENT_VAULT_TELEMETRY=false`.**
   Telemetry is on by default and sends the owner's email. The UI is never
   exposed. An operator who needs it uses `kubectl port-forward`.
4. **NetworkPolicy, two ingress rules** (residuals in Consequences: same-node
   host identity, and any Application that adds a policy or a labelled pod):
   - `:14321` (API): only pods `app: provisioner` in namespace `agent-fleet`.
   - `:14322` (proxy): only pods carrying the `fleet.bnei.dev/definition`
     label (any value) in `agent-fleet`. The bridge executor (ADR-0060) will
     get its own `from` entry, keyed on `fleet.bnei.dev/executor`, when it
     ships. It never borrows the definition label.

   Plain NetworkPolicy ingress holds through the ClusterIP under Cilium
   chaining. Verified 2026-10-18 and again on this app's own render on
   2026-10-19, in a dev namespace with the selector pointed at it:

   | caller | `:14321` | `:14322` |
   |---|---|---|
   | `app: provisioner`, same namespace | reached | blocked |
   | `fleet.bnei.dev/definition`, same namespace | blocked | reached |
   | unlabelled, same namespace | blocked | blocked |
   | both labels, another namespace | blocked | blocked |

   The result is the same through the Service name and through the pod IP.
5. **Owner and provisioner identity: one documented operator command,
   `gitops/scripts/agent-vault-bootstrap.sh [--rotate]`.**
   - It registers the owner if the instance is uninitialized (first user =
     owner), logs in as the owner, closes self-registration
     (`agent-vault owner config set --invite-only`; upstream leaves it open,
     and with no SMTP a second user's verification code is only logged), and
     rotates or creates the `fleet-provisioner` agent with instance role
     `member`.
   - A refused owner login (401, the CLI's "invalid email or password") on
     an initialized instance stops the run with `INCIDENT`: someone else owns
     the instance or reset its password. An unreachable `/v1/status`, or a
     login that fails any other way, exits 1 without `INCIDENT` and changes
     nothing, so an outage never reads as a stolen owner.
   - It writes that agent's token to Infisical `agent-fleet-nygh`
     `/agent-vault` `AGENT_VAULT_TOKEN`. The provisioner mounts that path
     through its own InfisicalSecret (agent-fleet 0065).
   - It is idempotent and fails closed. A re-run while the stored token
     still authenticates changes nothing. Only a missing key or a token the
     vault refuses (401/403) leads to a rotation; an Infisical read error, an
     unreachable vault or any other vault answer aborts before anything
     changes. `--rotate`
     forces a new token, and the old one dies at once (outage:
     Consequences). If the Infisical write fails after a rotation, or the
     stream fails after the pod printed, the new token stays in its 0600 file
     and the script says so: retry the write, do not rotate again.
   - The pod's output must be exactly `NOOP` (stored token works) or exactly
     one `av_agt_` token. Anything else, including nothing, writes nothing
     and exits 1.
   - It revokes its owner session (`POST /v1/auth/logout`) on exit, also on
     HUP/INT/TERM/PIPE, and warns on stderr if the logout fails. A pod shell
     killed outright (SIGKILL) leaves the session to upstream's TTL.
   - `--lan` reaches `k9s-dashboard` through `node.sh --lan` when NetBird is
     down.
   - No credential goes on the operator machine's argv or its output. The
     inner script, the current token and the owner password ride the pod's
     stdin. The owner password is in no pod's env (Decision 6). The new token comes
     back on stdout into a 0600 file that `infisical secrets set --file`
     reads.
   - `gitops/scripts/test-agent-vault-bootstrap.sh` (CI) checks the
     fail-closed branches against stubs, and in every case that no token
     or the owner password reaches the output.
   - **A re-created agent does not inherit vaults. Trade-off.** If
     `fleet-provisioner` is ever deleted (UI, partial restore), the script's
     404 path creates a new one, and upstream makes only a vault's creator
     its admin (`handle_vaults.go`); the owner has no vault-admin override,
     only delete. The old agent's vaults then refuse the new one, and every
     definition warm on them fails closed. Remedy: delete those vaults as
     the owner (UI or `agent-vault vault delete`); the provisioner recreates
     them from git + Infisical at its next reconcile. Not automated: the
     only trigger is deleting the agent by hand.
   - Verified against a dev copy on 2026-10-19: run 1 created the token,
     run 2 changed nothing, and run 3 (`--rotate`) made the old token 401
     while the new one returned 200 on `GET /v1/vaults`. The new token
     created a vault (201) and minted a session (200), which proves the
     `member` role. The revised script was re-run the same day against the
     pinned image in a local container: first run on an uninitialized
     instance, no-op, `--rotate` (old token 401, new 200), a second
     self-registration refused 403 (invite-only), a changed owner password
     stopped with `INCIDENT`, and no token prefix in the vault's log.

   **Why not a hook (ADR-0023):** the owner step could be a PostSync hook,
   but the agent token is server-generated and must land in Infisical.
   - Writing it from inside the cluster needs a new in-cluster Infisical
     **write** grant (InfisicalPushSecret). That is a new pattern, and it is
     a stronger credential than the one it would deliver.
   - A hook for half the bootstrap would leave two mechanisms; one command
     does both.
   - **The register race (first user = owner) is narrowed, not closed.**
     Until bootstrap, Decision 4 admits only the provisioner to `:14321`,
     and it never registers. But same-node host identity (hostNetwork pods,
     node processes on the vault's node) is always admitted (Consequences),
     and the window lasts from the first sync until the operator runs the
     script, which is why Rollout runs it right after the sync. A stolen
     owner shows as the script's login failing on an initialized instance;
     the remedy is to delete the PVC and bootstrap again. The window
     **reopens on every PVC loss**: the pod comes back uninitialized,
     `/health` stays 200, and no alert fires. Not alerted on purpose: a
     probe of `/v1/status` would need a third caller admitted to `:14321`,
     which also opens `forgot-password` to it. The provisioner sees every
     authenticated route answer 503 "not initialized" and fails closed;
     surfacing that is agent-fleet 0065's. Closing it in the
     pod (self-registration at first boot) would put the owner password back
     in the server's env, which Decision 6 removes.
6. **Secrets live in two folders of `agent-fleet-nygh`, not a new project:**
   - `/agent-vault-server`: `AGENT_VAULT_MASTER_PASSWORD` (the only headless
     first-boot path) and `AGENT_VAULT_OWNER_PASSWORD`. The vault's
     InfisicalSecret syncs **only the master key** (common-app-chart's
     `infisical.keys`, a `template.data` filter), so the owner password is in
     no pod's env and in no Kubernetes Secret, whatever else the folder
     holds. Only the operator's bootstrap script reads it. The owner email is
     a fixed literal in the script (`agent-vault-owner@bnei.dev`), not a
     secret; the folder's `AGENT_VAULT_OWNER_EMAIL` key is unused.
     - A separate owner folder was tried first and dropped: it needed a
       manual move before merge, and folders are not a boundary here anyway
       (Consequences). The key filter holds from the first sync.
   - `/agent-vault`: `AGENT_VAULT_TOKEN` and the credential values. The
     provisioner reads this folder.

   Core's and the provisioner's existing InfisicalSecrets sync the project
   root non-recursively, so no folder lands in their Secrets.
   - **Why not a new project:** it needs a UI-created identity grant, a
     user step.
   - **Why not `platform-commons`:** these values are not shared between
     apps, and every app that opts in to commons can read that project
     (ADR-0049).
7. **Monitoring:** an HTTP readiness and liveness probe on `/health`. The
   cluster-wide `KubePodNotReady`, `KubeDeploymentReplicasMismatch` and
   `KubePodCrashLooping` rules already cover every namespace. Upstream has
   no metrics port.

## Consequences

- **Folders are sync configuration, not isolation. Accepted, ADR-0049
  class.** The shared `universal-auth-credentials` identity reads the whole
  of `agent-fleet-nygh`, so any InfisicalSecret in any namespace can name
  any folder.
  - That reaches `AGENT_VAULT_TOKEN`, which is a `member` agent with no
    expiry. It can `reveal` every credential of every vault the provisioner
    administers. Those are the same values `/agent-vault` already holds.
  - It also reaches the master and owner passwords, which give full control
    of the vault. Keeping the owner password out of the server's env (Decision
    6) narrows what a leak of the running process exposes, not this.
  - Upgrade path: a dedicated project, plus an identity granted only to the
    provisioner and the vault. Needs the Infisical UI.
- **Plain HTTP on `:14321` inside the cluster.** Credential values cross it
  when the provisioner sets them. It is fenced by Decision 4.
- **Same-node host identity is always admitted** by the ingress policy
  (Cilium's default host allow, for kubelet probes). This is the known
  residual of every NetworkPolicy here.
- **Any Application can widen the fence. Accepted, ADR-0049 class.** Every
  Application is `project: default`, so one whose values or `extraManifests`
  live in a repo this one does not review can add an allow NetworkPolicy in
  `agent-vault` (policies are additive) or run a pod labelled
  `app: provisioner` or `fleet.bnei.dev/definition` in `agent-fleet`. With
  the shared Infisical identity it could also sync the owner password.
  Upgrade path: an AppProject for user apps with namespace-restricted
  destinations.
- **Auth codes go to the vault's log.** With no SMTP, upstream logs password
  reset and email verification codes in clear. An unauthenticated
  `POST /v1/auth/forgot-password` for the owner's (literal) email from any
  caller admitted to `:14321` produces one; whoever can read it can reset the
  owner. Alloy drops those lines from namespace `agent-vault` before Loki
  (`gitops/platform/values/alloy/values.yaml`, verified on Alloy v1.20.1).
  That keeps them off Loki only: anyone who can read `pods/log` in
  `agent-vault` still sees them — cluster-admin, ArgoCD's `role:admin`
  (`platform-admins`, already owner-equivalent), and `thot-executor` (next
  bullet).
  Invite-only (Decision 5) stops the second-user path. A reset that happens
  anyway shows as the bootstrap script's `INCIDENT`.
- **`thot-executor` can read and rewrite the vault. Accepted, ADR-0032
  class.** Its ClusterRole grants `pods/log` get and `deployments` patch in
  every namespace, `agent-vault` included, and agent sessions drive it.
  - Read: the logged auth codes above.
  - Patch: it can rewrite `deploy/agent-vault`'s pod template (command or
    env: print `/proc/1/environ`, which still holds the master password, or
    set `AGENT_VAULT_ALLOW_PRIVATE_RANGES=true`) and read the result back
    through `pods/log` before selfHeal reverts it. It can also add
    `app: provisioner` or `fleet.bnei.dev/definition` to an `agent-fleet`
    pod template, which passes Decision 4's fence.
  - This is not new to the vault: the same patch-then-read-logs path
    already reaches every Secret any Deployment can mount, which ADR-0032's
    "no `secrets`" exclusion does not stop.
  - Upgrade path, cluster-wide rather than here: a ValidatingAdmissionPolicy
    that admits a `thot-executor` patch only when it changes nothing but
    `kubectl.kubernetes.io/restartedAt`.
- **`--rotate` is a short provisioner outage.** The old token dies at once.
  The new one arrives after Infisical's resync (60s) plus kubelet's
  Secret-volume refresh (60s or less). If the Infisical write fails after a
  rotation, retry the printed write command; do not rotate again.
- **The vault pod has no egress NetworkPolicy. Trade-off.** Its fence is
  upstream's dial guard, pinned on with `AGENT_VAULT_ALLOW_PRIVATE_RANGES=false`:
  the proxy refuses every RFC-1918, loopback, link-local and CGN address at
  connect time, per resolved IP, so it cannot relay a definition pod to a
  cluster Service, pod, node or the LAN directly. What stays open is the
  public internet, and that includes this homelab's own public surfaces: the
  WAN IP's Freebox port-forwards and Cloudflare-proxied `*.bnei.dev` lead
  back to Traefik's ingresses (Infisical, authentik, ArgoCD) and the
  `:49222` break-glass SSH, each behind its own login. Between a vault's creation and the provisioner setting
  `unmatched_host_policy=deny`, a definition pod could reach any public host
  through it, without a real credential; agent-fleet 0065 orders deny before
  any pod gets a session. An egress policy would need DNS (nodelocaldns on
  the host network, under Cilium chaining) and a `world` carve-out that has
  not been tested here; add it if the dial guard is ever turned off.
- **The pod mounts the default ServiceAccount token** (no chart knob to stop
  it). That account has no RBAC grants in namespace `agent-vault`. Add a
  chart knob if it ever needs one.
- **Inside the vault container, the current token is on busybox `wget`'s
  argv** during the bootstrap check. That process tree already holds every
  credential. Accepted.
- **Research-preview upstream.** The pin guards against drift. If the
  upstream is abandoned, the fallback is an executor-style broker (agent-fleet
  adr/0037).
- Log hygiene, dev copy at info level: a grep of the vault's log for the
  owner and master passwords, the two agent tokens and the `av_agt_`/`av_sess_`/
  `Bearer` prefixes counted **0**. It did not look for auth codes, which are
  there (above). agent-fleet 0065 repeats the check under proxied traffic.

## Rollout

1. Merge. ArgoCD syncs `agent-vault` (wave 10). The pod starts as soon as
   the Infisical operator has synced `/agent-vault-server`.
2. Run, once, **right after that sync** (Decision 5, register race), from an
   infra-bootstrap checkout on a NetBird peer in `platform-admins`:
   `gitops/scripts/agent-vault-bootstrap.sh`
3. Check that the stored `AGENT_VAULT_TOKEN` authenticates: a re-run of the
   script prints "nothing changed".
4. **Only then** merge agent-fleet's side (0065). The live P1 definitions
   warm today on 0064's interim real token; once 0065 deploys (agent-fleet
   releases and deploys every `main` push), their warms need a bootstrapped
   vault and the token, and fail closed without them. Merged first, it is
   an outage of working definitions until steps 1-3 are done. Repo sessions
   are unaffected either way.
   - 0065 must add a **new** InfisicalSecret for `/agent-vault`: the
     provisioner's existing one (`k8s/provisioner/infisicalsecret.yaml`)
     syncs `secretsPath: "/"` non-recursively and cannot see this folder.
     As of 2026-10-19 that branch is not pushed and has no PR; until it
     merges, nothing delivers the token, by design.

Done (2026-10-19, by the build agent): the folders `/agent-vault-server` and
`/agent-vault` exist in `agent-fleet-nygh`; the master and owner passwords
were generated (64 hex characters, `openssl rand -hex 32`) and never printed.
Nothing is left to do in Infisical before the merge: the key filter
(Decision 6) keeps the owner password out of the pod from the first sync.
Operator clean-up, any time (the build agent created it; its delete was
refused as a secret-store write): `infisical secrets delete
AGENT_VAULT_OWNER_EMAIL --type=shared --path=/agent-vault-server` in
`agent-fleet-nygh` `dev`, then drop its row in `docs/secrets.md` and the
mentions here and in the values file.
