# ADR-0062: The fleet GitHub App `ukubi-fleet`

**Status:** Accepted. Rollout complete 2026-10-21: every step below is done.
**Date:** 2026-10-20
**Related:** [ADR-0034](0034-in-cluster-oci-registry-zot-garage-backed.md)
(build runners keep the owner's PAT), [ADR-0060](0060-event-bridge.md) (the
bridge's own App, unchanged), [ADR-0061](0061-agent-vault.md) (the credential
broker, and the dedicated-project rule this ADR copies). agent-fleet: `docs/adr/0075`
(GitHub App identity and vault-delivered credentials for all
pods), which amends its 0064, 0065 and 0074.

## Context

agent-fleet acts on GitHub as the machine user `argocd-ukubi-bot`, with a
classic PAT (agent-fleet Infisical project `agent-fleet-nygh`, `/GH_TOKEN`).
That PAT is in every repo worker pod's env, it expires, and a person has to
renew it. Fleet membership is the bot's collaborator list (agent-fleet 0074).

The first definition that pushes, Opus (`opus-tech-hq/workspace`), needs a
credential scoped to one repo. A user token can't provide one:

- GitHub has no API to create a personal access token. The org PAT
  endpoints can only list, approve and revoke.
- A fine-grained PAT can't reach a repo where its owner is an outside
  collaborator. The bot is an outside collaborator on `opus-tech-hq/workspace`,
  and its fine-grained token there returns 404.

A GitHub App has neither limit. Its installation tokens are minted by API,
can be narrowed per request to a list of repository ids and a subset of
permissions, and last one hour.

An App already exists: `ukubi-bridge` (id 5370791, ADR-0060). It was
considered and rejected as the fleet's identity:

- Its key must stay in the bridge. The deliveries API
  (`GET /app/hook/deliveries`, `POST …/attempts`) and runner registration
  tokens need the App JWT, which an installation token can't stand in for
  (`ukubi-bridge/internal/github/reconcile.go:67,119,167`). So a single App
  would put a key that can write every installed repo in the pod behind the
  public `events.bnei.dev` ingress.
- It is private. A private App installs only on the account that owns it,
  so it can't reach `opus-tech-hq`.

## Decision

1. **A second, public GitHub App, `ukubi-fleet`, is agent-fleet's only
   GitHub identity.** ukubi-bridge is unchanged.
   - Created through the manifest flow: the operator clicks "create" once.
     The conversion (`POST /app-manifests/{code}/conversions`) returns the
     App id and its only private key; no second key is generated.
   - Public, because `opus-tech-hq` is a separate account.
   - Permissions: contents write, pull requests write, workflows write,
     issues write, metadata read, actions read, checks read, statuses read.
     No webhook. Never `administration`.
   - Installed on `MohammadBnei` (account id 43962695) and `opus-tech-hq`
     (344349211), on selected repos. **Installing it on a repo is how the
     repo joins the fleet** (agent-fleet 0075 amends 0074).
2. **Only those two accounts count.** A public App can be installed by
   anyone. agent-fleet's provisioner holds the account-id allowlist, ignores
   installations by any other account in both the repo listing and token
   minting, and logs them. It never deletes them automatically: a typo in
   the allowlist would then uninstall the real installations. Removing a
   foreign installation is a manual step.
3. **The key lives in a dedicated Infisical project, `fleet-github-app`,
   read by its own machine identity.** This is ADR-0061 Decision 6's
   reasoning: the shared `universal-auth-credentials` identity reads every
   project it is granted, and agent-fleet-nygh is synced whole into core's
   env. The provisioner mounts this project as **files**, in a directory of
   its own. The key never reaches an env var, a hook Job or core.
4. **Agent Vault serves repo pods too** (agent-fleet 0075).
   Rollout step 4 widens this repo's side:
   - the `:14322` NetworkPolicy rule admits agent-fleet's repo-pod label as
     well as `fleet.bnei.dev/definition`;
   - the vault's resources are raised to what the throughput spike measures;
   - the per-(actor, vault) rate limit (20 rps, burst 200, 64 concurrent;
     every repo pod of one owner shares a bucket) is turned off or raised.

   Configured 2026-10-21 after the PR4a spike, effective once ArgoCD syncs
   it (the vault itself is per ADR-0061's status): the `:14322` rule admits pods
   labelled `fleet.bnei.dev/vault-owner`, CPU is 250m request / 2 limit
   (500m throttled at 3 concurrent installs), and the rate-limit profile is
   `loose`. The spike also settled what repo pods accept: HTTP/2 and gRPC to
   external hosts do not work through the vault (HTTP/1.1 only), and the
   vault sees all repo-pod HTTPS in plaintext, passthrough hosts included
   (it re-signs every host). Both accepted. Repo pods also inherit the
   vault's refusal of private destinations, so their NO_PROXY must cover
   `.bnei.lan`, split-horizon `.bnei.dev` names and the cluster suffixes.

## Consequences

- **A leaked `ukubi-fleet` key means write access to every repo in the two
  allowlisted installations**, `main` branches included (none is protected).
  The key sits in one place (provisioner files), behind one identity.
- **A repo is onboarded once, but can be installed twice.** Fleet membership
  is the `ukubi-fleet` installation. Bridge events need a separate
  `ukubi-bridge` installation. Because ukubi-bridge is private, `opus-tech-hq`
  repos get no bridge events. Making it public is out of scope, and would
  first need an installation allowlist in the bridge: anyone's install would
  send validly signed webhooks to `events.bnei.dev`.
- **Every fleet session, admin or definition, opens PRs as the same
  `<slug>[bot]`.** ukubi-bridge's `BRIDGE_AGENT_LOGINS` gains that login,
  or fleet PRs get tagged `actor=bot`. Agent logins are trusted
  automatically. The bridge can't tell one agent from another by author;
  dropping a thread's own agent events is core's dispatcher's job, not the
  bridge's (agent-fleet #257).
  Definition sessions driven by audience members share that trusted login.
  This is accepted while no definition can open PRs; before one can,
  core's dispatcher keys trust on session provenance (agent-fleet 0075).
- Commits are authored `ukubi <ukubi@bnei.dev>` from config. The App is the
  transport credential.
- `argocd-ukubi-bot` keeps its non-fleet uses for now: `UKUBI_BOT_GH_PAT`.
  ADR-0034's runners use the owner's PAT and don't depend on the bot. Retiring
  the bot entirely is a later decision.

## Rollout

1. This ADR, plus agent-fleet 0075.
2. Operator: create `ukubi-fleet` and install it on every repo that should
   stay in the fleet, plus `agent-fleet` and the fleet-shared and genome
   source repos. This must happen before agent-fleet's step merges, because
   that step moves the provisioner's own git onto installation tokens.
   Installing early is harmless: membership still comes from the bot. Agent: create the `fleet-github-app` project
   and identity, and store `GITHUB_APP_ID` and `GITHUB_APP_PRIVATE_KEY`.
   agent-fleet then mints definition-vault tokens (Opus unblocked).
3. agent-fleet switches membership to installations; this repo's `gitops/bootstrap/fleet-repo-overrides.yaml`
   header comment changes with it.
4. The vault changes in Decision 4, merged and synced before agent-fleet
   moves repo pods onto the vault.
5. The bot is removed from the fleet repos, and agent-fleet-nygh `/GH_TOKEN`
   is deleted.

Done 2026-10-21: steps 2-3 as agent-fleet #278/#290, step 4 as #358 here,
then agent-fleet #307 (repo pods behind per-owner vaults) and #310 (a sidecar
egress router: only the three vault hosts go to the vault). Step 5: `/GH_TOKEN`
deleted; `argocd-ukubi-bot` removed from all 11 repos it was a collaborator on.
ArgoCD was never on the bot: `repo-creds-github-bnei` is the owner's own
fine-grained PAT. Watch the next release of `wedding-2026` and `vos-monolith`:
their workflows push with an Actions secret `PAT` whose owner was not checked.
