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
   "backed by Pigsty Postgres".** v0.40.0's store runs only its SQLite
   migrations, so Pigsty is not an option.
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
4. **NetworkPolicy, two ingress rules, nothing else admitted:**
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
     owner), logs in as the owner, and rotates or creates the
     `fleet-provisioner` agent with instance role `member`.
   - It writes that agent's token to Infisical `agent-fleet-nygh`
     `/agent-vault` `AGENT_VAULT_TOKEN`. The provisioner mounts that path
     through its own InfisicalSecret (agent-fleet 0065).
   - It is idempotent. A re-run while the stored token still authenticates
     changes nothing. `--rotate` forces a new token, and the old one dies at
     once (outage: Consequences).
   - No credential goes on the operator machine's argv or its output. The
     inner script and the current token ride the pod's stdin. The new token
     comes back on stdout into a 0600 file that `infisical secrets set
     --file` reads.
   - Verified against a dev copy on 2026-10-19: run 1 created the token,
     run 2 changed nothing, and run 3 (`--rotate`) made the old token 401
     while the new one returned 200 on `GET /v1/vaults`. The new token
     created a vault (201) and minted a session (200), which proves the
     `member` role.

   **Why not a hook (ADR-0023):** the owner step could be a PostSync hook,
   but the agent token is server-generated and must land in Infisical.
   - Writing it from inside the cluster needs a new in-cluster Infisical
     **write** grant (InfisicalPushSecret). That is a new pattern, and it is
     a stronger credential than the one it would deliver.
   - A hook for half the bootstrap would leave two mechanisms; one command
     does both.
   - The register race (first user = owner) is bounded by Decision 4: until
     bootstrap, only the provisioner can reach `:14321`, and it never
     registers. The script itself reaches the API on the pod's loopback.
6. **Secrets live in two folders of `agent-fleet-nygh`, not a new project:**
   - `/agent-vault-server`: `AGENT_VAULT_MASTER_PASSWORD` (the only headless
     first-boot path), plus `AGENT_VAULT_OWNER_EMAIL` and
     `AGENT_VAULT_OWNER_PASSWORD`. The vault pod reads this folder.
   - `/agent-vault`: `AGENT_VAULT_TOKEN` and the credential values. The
     provisioner reads this folder.

   Core's and the provisioner's existing InfisicalSecrets sync the project
   root non-recursively, so neither folder lands in their Secrets.
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
  either folder.
  - That reaches `AGENT_VAULT_TOKEN`, which is a `member` agent with no
    expiry. It can `reveal` every credential of every vault the provisioner
    administers. Those are the same values `/agent-vault` already holds.
  - It also reaches the master and owner passwords, which give full control
    of the vault.
  - Upgrade path: a dedicated project, plus an identity granted only to the
    provisioner and the vault. Needs the Infisical UI.
- **Plain HTTP on `:14321` inside the cluster.** Credential values cross it
  when the provisioner sets them. It is fenced by Decision 4.
- **Same-node host identity is always admitted** by the ingress policy
  (Cilium's default host allow, for kubelet probes). This is the known
  residual of every NetworkPolicy here.
- **`--rotate` is a short provisioner outage.** The old token dies at once.
  The new one arrives after Infisical's resync (60s) plus kubelet's
  Secret-volume refresh (60s or less). If the Infisical write fails after a
  rotation, re-run with `--rotate`.
- **Inside the vault container, the current token is on busybox `wget`'s
  argv** during the bootstrap check. That process tree already holds every
  credential. Accepted.
- **Research-preview upstream.** The pin guards against drift. If the
  upstream is abandoned, the fallback is an executor-style broker (agent-fleet
  adr/0037).
- Log hygiene, dev copy at info level: a grep of the vault's log for the
  owner and master passwords, the two agent tokens and the `av_agt_`/`av_sess_`/
  `Bearer` prefixes counted **0**. agent-fleet 0065 repeats the check under
  proxied traffic.

## Rollout

1. Merge. ArgoCD syncs `agent-vault` (wave 10). The pod starts as soon as
   the Infisical operator has synced `/agent-vault-server`.
2. Run, once, from an infra-bootstrap checkout on a NetBird peer in
   `platform-admins`:
   `gitops/scripts/agent-vault-bootstrap.sh`
3. agent-fleet's side (0065) can merge before or after. Each fails closed
   without the other: definition warms are refused, and repo sessions are
   unaffected.

Done (2026-10-19, by the build agent): the folders `/agent-vault-server` and
`/agent-vault` exist in `agent-fleet-nygh`, and `/agent-vault-server` holds
the three values above, generated and never printed.
