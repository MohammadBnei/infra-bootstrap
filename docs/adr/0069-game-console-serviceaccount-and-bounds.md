# ADR-0069: The game console: the `ukubi-game` ServiceAccount and its bounds

**Status:** Proposed. Part 1 (the console's reads) is decided here; parts 2 to 4 are named only, and each is
decided with its slice, by amendment. Decided by M BN in mountain's R13 console design (the private repo), which
moves the cluster's day-to-day control into the game's server. Amends
[ADR-0068](0068-atlas-machine-principal-for-the-game.md) Decision 2: the game's copy of the app password moves to the
game's own project (Decision 5).
**Date:** 2026-10-28
**Related:** [ADR-0068](0068-atlas-machine-principal-for-the-game.md) (the game reads atlas as `atlas-game`; that
grant stays, and only where the game's copy of its password lives changes), [ADR-0032](0032-thot-rbac-and-alerting.md) (thot's read grant, the precedent and the upper bound),
[ADR-0040](0040-cluster-internal-hardening-baseline.md) (the API audit log, and the `CiliumNetworkPolicy` practice),
[ADR-0049](0049-shared-commons-secrets-in-common-app-chart.md) and [ADR-0062](0062-fleet-github-app.md) (an own
Infisical project read by an own identity).

## Context

The game (`ukubi-game`) draws the cluster as a town. Its server is gaining a console: the actions a signed-in
platform admin can run on what they select, offered by providers behind one Go interface. The page holds no
credential; the server does every read and every write itself, with its own identities.

The console lands in slices, and each needs a different grant:
1. **C1, reads:** what a building is (its pods, workloads, events, nodes, ArgoCD app), its describe and YAML views,
   and its logs.
2. **C2, Kubernetes writes:** restart, delete a pod, cordon, scale, and an exec shell.
3. **C3, ArgoCD:** history, the diff to git, sync, rollback.
4. **C4, the databases:** Patroni and Postgres.

Granting all of it up front would make the game cluster-admin in practice: every app is in the `default`
AppProject, so a free write on an Application or a Deployment deploys or mounts anything. So the grant grows one
slice at a time, and each step is an amendment of this ADR.

The game is not deployed yet. ADR-0068 left its deployment (image, app entry, hostname, sign-in) to its own change.
This ADR prepares the identity that deployment runs as.

## Decision

### Part 1: Read (C1)

1. **One ServiceAccount, `ukubi-game`, in namespace `ukubi-game`.**
   - Its credential is the projected token the kubelet mounts: bound to the pod, rotated, never stored. There is no
     token Secret and no kubeconfig for it, in Infisical or anywhere else.
   - The game's Deployment runs as it (`serviceAccountName: ukubi-game`). That line belongs to the change that
     deploys the game.
2. **A ClusterRole, `ukubi-game-read`, with `get`, `list` and `watch` on these resources and nothing else:**

   | Group | Resources | Why |
   |---|---|---|
   | core | `pods`, `nodes`, `services`, `persistentvolumeclaims` | a building's parts, the houses (nodes), and describe |
   | core | `pods/log` (`get` only) | logs, once and followed |
   | `apps` | `deployments`, `statefulsets`, `daemonsets`, `replicasets` | an app's workloads and add-ons, and a Deployment's describe |
   | `discovery.k8s.io` | `endpointslices` | a Service's backends (v1 `Endpoints` is deprecated since 1.33) |
   | `events.k8s.io` | `events` | every describe's events (core v1 events are the same objects; one API is enough) |

   - **Never, any verb:** wildcards; `secrets`; `rbac.authorization.k8s.io`; `apiextensions.k8s.io`;
     `pods/exec`, `pods/attach` and `pods/portforward`. Exec belongs to part 2.
   - **Which Secrets a workload references** is read from its pod spec (`envFrom`, `valueFrom`, volumes): names
     only. Each name links to the app's Infisical project. The game never reads a Secret's value.
   - It is cluster-wide because a town spans every namespace, thot's reason (ADR-0032). It is narrower than thot's
     grant: no ConfigMaps, no Traefik objects, no write verb. thot stays the broadest standing read grant.
3. **ConfigMaps are not in the read set.**
   - No C1 read needs a ConfigMap's content. A workload's ConfigMap references come from its pod spec, as its
     Secret references do, and show as names.
   - A cluster-wide ConfigMap read would hand the game every component's rendered configuration, platform
     components included (ArgoCD's, Cilium's, Grafana's), which the console never shows.
   - That does not make rendered values invisible. The YAML of a Deployment carries its literal `env:` values, as
     `common-app-chart` renders them with `toYaml`. Reading workloads reads those. The game redacts what it shows,
     but redaction is in the game's code, not a boundary at the API server. A value that matters belongs in a
     Secret, which is the repo's rule already.
4. **Applications are read through a Role in `argocd`, not a ClusterRole.** Applications live in `argocd` only
   (apps in other namespaces are not enabled), so the Role `ukubi-game` there grants `get`, `list` and `watch` on
   `applications.argoproj.io`, and the RoleBinding of the same name binds it. The game takes an app's namespace from
   the Application's own `destination`. The Role is brought forward from part 3: C1's building view shows an app's
   ArgoCD Application, so its reads land with the other reads. Part 3 widens this same Role.
5. **The game's own Infisical project, read by its own identity.** This is a human step (Rollout 2).
   - Project `ukubi-game` (env `dev`), read by machine identity `ukubi-game-reader` (universal auth, `viewer` on
     that project only). Its credentials are the k8s Secret `infisical/ukubi-game-universal-auth`, which the game's
     InfisicalSecret names in `credentialsRef`.
   - Not the shared `universal-auth-credentials` identity, which reads every project it is granted (ADR-0061
     Decision 6, ADR-0062 Decision 3). Not `platform-commons` either: nothing here is shared (ADR-0049).
   - Part 1 grants no token: the Kubernetes reads use the ServiceAccount. The project holds the game server's own
     env when the game is deployed, and later slices add their credentials to it (part 3 the ArgoCD token, part 4
     the Patroni password and the Postgres role's password).
   - The game's copy of the atlas app password lives here as `UKUBI_GAME_ATLAS_APP_PASSWORD`. Infisical references
     do not cross projects, so ADR-0068's rotation sets the same value in two places: `ATLAS_GAME_APP_PASSWORD` in
     `infra-bootstrap-1-ge1` (authentik's copy) and this one.
6. **A `CiliumNetworkPolicy` fences the namespace's egress** (`ukubi-game-egress-lock`). A plain NetworkPolicy
   cannot express DNS or the API server under this Cilium (ADR-0040's pilot). Egress only; ingress stays unenforced.
   It allows:
   - DNS: the `host` entity on 53, plus the `169.254.25.10` rule kept for cilium#18644 (searxng's shape);
   - the `kube-apiserver` entity on 6443: every read of this part. This rule is new on this cluster: no other policy
     has one, so it has no searxng or silverbullet precedent. It follows their reasoning (the API server's ClusterIP
     is DNATed before egress policy, so policy sees the node's API server on 6443), but it is untested (Rollout 3);
   - the town's reads, which the game already makes: atlas (`mountain`, 8080), authentik's in-cluster token
     endpoint (`authentik`, 9000) and agent-fleet core's client port (`agent-fleet`, 9091), as `toEndpoints` on
     namespace and port, with no pod labels. Each of them checks its caller;
   - Alertmanager (`monitoring`, 9093), its pods only, and at L7: `GET /api/v2/alerts` and nothing else.
     Alertmanager has no auth in-cluster (its forwardAuth gate is on the IngressRoute), so an L4 rule would also let
     the game create and delete silences and post alerts, a write. It is the cluster's first L7 HTTP rule (the
     working `rules.dns` is the DNS proxy, not Envoy), so it is untested too; if it does not hold, the read fails
     closed;
   - HTTPS (443) to the world, RFC 1918 excepted: GitHub's API, and the sign-in's OIDC calls, since
     `authentik.bnei.dev` resolves to Cloudflare from a pod.

   Nothing else. Loki, Patroni, Postgres and ArgoCD's API are added by the slices that use them.
7. **Where it lives:** `gitops/platform/ukubi-game/` (the ServiceAccount, the RBAC and the policy), applied by the
   standalone Application `platform-ukubi-game-bounds` (`gitops/bootstrap/ukubi-game-application.yaml`, wave 1).
   - `common-app-chart` renders no ServiceAccount, no RBAC and no object in another namespace. thot is the precedent:
     its grant is plain manifests here.
   - The grant stays out of the game's repo: this repo reviews every standing grant on the cluster.
   - The namespace carries `fleet.bnei.dev/client`, set by the Application (`managedNamespaceMetadata`). agent-fleet
     core's NetworkPolicy admits 9091 only from namespaces with that label, so granting it is this repo's call.
   - CI holds the grant to an exact list: every (group, resource, verb) of every Role and ClusterRole, every
     binding with its role and subject, and any `aggregationRule` or `nonResourceURLs`, across every file in
     `gitops/platform/ukubi-game/`. Anything added fails, whether a wildcard, `secrets`, an exec-equivalent
     (`nodes/proxy`, `pods/ephemeralcontainers`, `serviceaccounts/token`), `impersonate`, `escalate` or `bind`, a
     binding to `cluster-admin` or `view`, or an aggregated role.

### Part 2: Kubernetes writes (C2)

Decided with its slice, by amendment: the write verbs, the admission policy that bounds them, and the per-namespace
exec Roles with their exclusions.

### Part 3: ArgoCD (C3)

Decided with its slice, by amendment: the `argocd` Role's write verbs, the game's ArgoCD account and its token, and the
sync-policy changes that let a rollback hold.

### Part 4: Databases (C4)

Decided with its slice, by amendment: the game's Postgres role, Patroni's credential in the game's project, and the
egress to Patroni and Postgres.

## Rejected options

- **cluster-admin**, or any write verb in part 1. Writes are parts 2 to 4, each bounded on its own.
- **The built-in `view` ClusterRole.** It includes ConfigMaps and grows by aggregation whenever a chart labels a role
  `aggregate-to-view`, so what the game can read would change with no change here. The resources are listed instead.
- **A kubeconfig or a static token in Infisical.** A long-lived credential that can leave the pod, against a
  projected token that is bound to it and rotated.
- **Reusing `thot-executor`.** It patches workloads and deletes pods, and one identity for two systems would make the
  API audit log unable to say which one acted.
- **Per-namespace Roles for the reads.** Every new app namespace would need an edit before the town could show it.
  (Part 2's exec is per-namespace on purpose: there, each namespace is a decision.)
- **A ClusterRole for Applications.** They live in `argocd` only, so a Role there grants the same reads with less.
- **Reading Secrets to list a workload's references.** The pod spec already names them.
- **ConfigMaps in the read set:** Decision 3.
- **The shared `universal-auth-credentials` identity** for the game's secrets: it reads every project it is granted.
- **A plain NetworkPolicy:** it cannot carry DNS here (`host` identity), nor name the API server.
- **`toFQDNs` for GitHub and authentik.** Untested on this cluster. The searxng notes record DNS-rule pitfalls, so
  it stays out until it is proven; the world rule is port 443 only.

## Consequences

- **A stolen admin session reads what the role reads.** That is the shape of every workload, node and Service in the
  cluster, the literal env values in their pod specs, every Application, and the logs of every pod, platform pods
  included. Logs are the widest of these: whatever an app prints, a token included, can be read. Its limits are
  the game's own: `platform-admins` only, the session's lifetime and its revocation. None of them is at the API
  server, so part 1 is a read grant to whoever holds a valid session.
- **A compromised game pod reads the same,** with its ServiceAccount token, and it reaches only the destinations in
  Decision 6. It cannot silence an alert: the Alertmanager rule passes `GET /api/v2/alerts` only.
- **Reads never include a Secret's value.** RBAC grants no verb on `secrets`, so even a bug in the game cannot fetch
  one. The two ways a secret can still show are a literal in a pod spec and a line in a log. The game redacts both
  before it shows them, and the API server does not.
- **Every read is in the API server's audit log** as `system:serviceaccount:ukubi-game:ukubi-game` (ADR-0040
  Decision 2). The game's own journal is never the only record.
- **The cluster has two broad read grants now:** thot's, which stays the broadest, and this narrower one. ADR-0032's
  consequence still holds.
- **The namespace is default-deny on egress** from the first sync. Each new destination is an amendment here, and a
  missed one shows as a drop in Hubble, not a silent success. Tracing (`OTEL_EXPORTER_OTLP_TRACES_ENDPOINT`) is not
  allowed yet: the game treats a failed exporter as a warning, and the collector is added when it is chosen.
- **This repo admits the game to core's client port.** core's NetworkPolicy lets only namespaces labelled
  `fleet.bnei.dev/client` reach 9091, and this repo labels `ukubi-game` (Decision 7). agent-fleet's part is the
  game's client registration, the bearer core checks, when the game is deployed.
- **The game's deployment change carries `serviceAccountName: ukubi-game`.** `common-app-chart` has no
  `serviceAccountName` value today. That change adds one, or deploys the game as plain manifests.
- **One more standalone plain-manifest Application** (`platform-ukubi-game-bounds`), for thot's reason.

## Rollout

1. This ADR and its part 1 manifests. They are inert until the game runs as the account.
2. **Human steps, before the game is deployed:**
   - In Infisical: create project `ukubi-game` (env `dev`) and identity `ukubi-game-reader` (universal auth,
     `viewer` on that project only), and record the project's slug in `docs/secrets.md`.
   - Create the Secret `infisical/ukubi-game-universal-auth` from the identity's client id and secret, the way
     `fleet-github-app-universal-auth` was made (ADR-0062). It is never committed.
3. **After the first sync** (the cluster was down when this was written, so none of it is verified yet):
   - `kubectl auth can-i --as=system:serviceaccount:ukubi-game:ukubi-game` answers **yes** for `list pods -A`,
     `get pods --subresource=log -A`, `list deployments.apps -A`, `list events.events.k8s.io -A`, `list nodes`,
     `list applications.argoproj.io -n argocd`;
   - and **no** for `get secrets -A`, `list configmaps -A`, `create pods --subresource=exec -A`,
     `list clusterroles`, `list customresourcedefinitions`, `patch deployments.apps -A`,
     `list applications.argoproj.io -n default`;
   - and, because `can-i --as` never crosses the egress fence, a real `list pods -A` from inside a pod running as
     the account succeeds (the `kube-apiserver` rule), and from the same pod a `GET` on Alertmanager's
     `/api/v2/alerts` succeeds while a `POST /api/v2/silences` is refused (the L7 rule).
4. **When the game is deployed:** `hubble observe --namespace ukubi-game --verdict DROPPED` stays empty while the
   town loads and a pod's logs follow. A drop names the destination the fence is missing.
