# ADR-0055: NetBird as the daily SSH path to ukubi hosts — superseding ADR-0009 for SSH

**Status:** Accepted — decided 2026-10-11, approved by M BN after an
architecture interview and two adversarial review cycles. **Rolling out —
spike and k8s stages enrolled 2026-10-11** (7 hosts); an SSH login over the
mesh is not yet verified end-to-end. Operator view:
[`docs/runbook-netbird.md`](../runbook-netbird.md). Rollout past the spike is
gated on it (Rollout step 4). If the spike fails on the
automation half, Decision 3's light runs fall back to keys over the LAN and
the rest stands.
**Date:** 2026-10-11
**Related:**
- [ADR-0009](0009-reject-wireguard-tailscale.md): superseded for SSH access by this ADR.
- [ADR-0054](0054-netbird-control-plane-hosting-only.md): its "no cluster host is a peer" carve-out is amended here.
- [ADR-0039](0039-authentik-identity-layer.md): `platform-admins` is the access group.
- [ADR-0040](0040-cluster-internal-hardening-baseline.md): Cilium already runs WireGuard pod encryption.
- [ADR-0029](0029-postgres-automatic-failover-3-node-etcd-quorum.md): the etcd/Patroni nodes joining the mesh.

## Context

Two operator pains, equally weighted:

1. **Key handling.** Every host has its own `SSH_*_HOST/KEY/PORT/USER` set in
   Infisical (`docs/secrets.md`). Each session or playbook run means pulling a
   key and passing `-e ansible_ssh_private_key_file=`. Pigsty's live key is still
   named `SSH_OLDPG_KEY`.
2. **Off-LAN reach.** Away from home, nothing on `*.bnei.lan` is reachable. The
   only way in is root SSH to the k9s hub, port-forwarded publicly at
   `82.65.231.50:49222` — a box that holds a cluster-admin kubeconfig.

ADR-0054 had just put a NetBird control plane in the cluster, with native SSH
(v0.60+: OIDC/JWT auth through the IdP, group → OS-user mapping, fails closed).
ADR-0009 rejected a mesh as cluster access in three lines with no recorded
reasoning, so there was no argument to weigh against these two pains.

## Decision

### 1. Every host is a peer

Group `infra-nodes`, enrolled by setup keys — **one per rollout stage**
(the spike, each step-5 batch), reusable, usage limit = that stage's host
count + 2 (the spike re-enrolls on purpose), 7-day expiry, `no_log`, current
one in Infisical as `NETBIRD_INFRA_SETUP_KEY_<STAGE>` (one secret per stage). A single key sized to the whole
fleet would run out or expire mid-rollout. Peers: the five k8s VMs (three
control plane, two workers), `.205`/`.207`, the etcd witness `.197`, the three PVE hosts,
the LXCs (k9s hub, hermesagent, build-runner, garage, nfs) and Pi-hole `.55`.

- Client **pinned**, upgraded in lockstep with the laptops (NetBird SSH is not
  compatible across 0.60/0.61).
- NetBird SSH flags: `--allow-server-ssh --enable-ssh-root --enable-ssh-sftp`.
  SFTP because ansible's `copy`/`template` need it; `--check` never transfers a
  file, so a check-only test would miss this.
- **DNS management off on `infra-nodes`.** The client must not touch
  systemd-resolved, which is nodelocaldns/CoreDNS's upstream.
- LXCs are unprivileged: `/dev/net/tun` is passed with `pct set <id> --dev0
  /dev/net/tun` from the PVE host, which needs a container restart. garage
  (zot blobs, backups) and nfs (RWX pods) restart last, in a maintenance window.
- Pigsty's firewall (`node_firewall_mode: zone`, re-applied on every
  `node.yml`) gets **port 22022** in `node_firewall_public_port`. Trusting
  `100.64.0.0/10` would open Patroni 8008 and etcd 2379 to every peer,
  including the off-site Pi.
- **5432 is already public** on every Pigsty node (`all.vars`
  `node_firewall_public_port: [22, 80, 443, 5432]`, commented "remove in
  production!"), so on `wt0` it would be reachable by every mesh peer with only
  NetBird's ACL in the way. The enrollment PR removes it, after the spike
  confirms pod → Postgres traffic arrives from node IPs (the trusted intranet
  zone) rather than from a public-zone source.

### 2. Access: `platform-admins`, propagated to peers

The policy source is `platform-admins`. That is authentik's group, carried by
the JWT `groups` claim through the embedded Dex, if the spike proves it arrives
(the NetBird blueprint requests only `openid email profile` today). Otherwise it
is a NetBird-local group assigned by hand, as ADR-0054 already does for
`laptops`/`pi`.

Either way **user-group → peer propagation is on**, so the policy resolves to
the admin's laptop. A `laptops → infra-nodes` policy would give N MG's laptop
network reach to every node, with only the OS-user mapping in the way.

Posture check: **geolocation, FR only**. Add a country before travelling;
being locked out abroad until then is accepted (Decision 5 is the way in).

> **Amended 2026-10-11 — geolocation rejected during the spike.** At home the
> laptop reaches management through the Freebox hairpin, so management sees
> `192.168.1.254` with no country and `geo-fr-only` could never pass — the
> case the Consequences section anticipated ("the geo check goes"). The
> posture check is deleted and the policy has `source_posture_checks: []`.
> Access rests on the authentik JWT per SSH session plus `platform-admins`
> membership.

### 3. Light runs over the mesh, heavy runs over the LAN

- **Light** — ad-hoc commands, app playbooks — from the laptop over NetBird SSH,
  through a separate overlay inventory `ansible/inventories/mesh/hosts.yml`
  (~~`ansible_host: <mesh_name>.bnei.mesh`~~ `<name>.bnei.mesh`, the host's
  one name — see the Decision 4 amendment).
- **Heavy** — kubespray `cluster.yml` and upgrades, pigsty `node`/`pgsql`/`infra`,
  `gpu-node-configure.yml` (reboots a node), `pihole-configure.yml` (reapplies
  its only uplink) — from the **k9s hub over the LAN**, where the toolchain
  already lives (`docs/runbook-k9s-ops-hub.md`). These runs restart Traefik,
  Pigsty or the NetBird pod itself, and would sever their own transport.
- The kubespray inventory (Terraform-generated) and Pigsty's (IP host keys that
  etcd and Patroni derive URLs and certificates from) **stay on LAN IPs,
  unchanged**. Never `-e ansible_host=` — it applies to every host and
  collapses a run onto one machine.

### 4. Names: Pi-hole's, applied to peers

Pi-hole stays the source of truth. `pihole_hosts_records` moves to
`ansible/playbooks/vars/bnei-lan-records.yml`. The mesh overlay inventory
carries an explicit `mesh_name` per host, which is a Pi-hole short name such as
`postgres-1` or `proxmox`. `netbird-configure.yml` fails if a `mesh_name` is not
in the records file. It sets each peer's name through the API,
compare-before-write, so `postgres-1.bnei.mesh` resolves on every NetBird
client **that manages DNS — the laptops**. Infra peers have DNS
management off (Decision 1), so they cannot resolve `*.bnei.mesh`; nothing
run from an infra host may use the mesh overlay inventory. Peer DNS domain: `bnei.mesh`, never `netbird.bnei.dev` (that is the
management URL; claiming it would cut clients off from it).

> **Amended 2026-10-11 — one name per machine; the API rename is dropped.**
> A machine's name is its OS hostname, and that same string is its Proxmox
> name, k8s node name, ansible inventory alias, Pi-hole record and NetBird
> peer name. So peers keep the hostname they enroll with, and there is no
> `mesh_name` and no rename through the API: `postgres-1.bnei.mesh` above is
> `pg01.bnei.mesh`. Pi-hole records were renamed to match (`proxmox` → `bnei`,
> `postgres-1`/`-2` → `pg01`/`pg02`, `pi4` → `pihole`; live since the
> 2026-10-11 `pihole-configure.yml` run); service names (VIPs,
> endpoints) are a separate list. The records moved to
> `ansible/playbooks/vars/bnei-lan-records.yml` as planned. `netbird-client.yml`
> refuses a host whose inventory alias and IP are not in it (it does not
> check the OS hostname itself); `netbird-configure.yml` reports a user-less
> peer in `infra-nodes` whose name is not a known host, which is where a
> drifted OS hostname shows up. Pigsty stays keyed
> by IP. The rest of this Decision stands: laptops only, `bnei.mesh`.

### 5. Break-glass and off-LAN recovery

The control plane, authentik, Traefik and Pigsty all live in the cluster. When
any of them is down, no new NetBird session can start. So:

- `sshd` stays on :22, key-based, everywhere. On every host but the hub:
  `Match Address *,!192.168.1.0/24,!fe80::/10,!<Freebox LAN /64>` →
  `AuthorizedKeysFile none`. The IPv6 entries matter: the Freebox hands out
  IPv6, and a LAN client that connects over v6 would otherwise lose key auth —
  heavy runs and break-glass included. The spike reads the real prefix and
  checks which family LAN SSH actually uses.
- **The Freebox forward `:49222` → k9s hub stays**, as the off-LAN recovery
  path only. On the hub the same `Match` points at
  `/etc/ssh/breakglass.pub`, so from outside it accepts **one break-glass key**
  and nothing else; fail2ban. Other hosts are reached with `ssh -J` through the
  hub, so the private key never sits on it.
- Keys: **add** the break-glass key (Infisical + offline). Remove only
  human-use keys. Untouched: the Hermes agent's `SSH_*` keys,
  `PVE_SSH_PRIVATE_KEY` (Terraform, and `netbird-client.yml`'s `pct` step for
  LXC tun), `SSH_OLDPG_KEY` (heavy Pigsty runs), and the PVE node
  entries in `/etc/pve/priv/authorized_keys` (migration and the node shell).

### 6. NetBird configuration as code: Ansible + REST

`ansible/playbooks/netbird-configure.yml` uses `uri` with a service-user PAT
(`NETBIRD_API_TOKEN`). It declares policies, ~~posture checks,~~ the DNS domain,
the propagation setting, setup keys and peer names. ~~It adopts the existing
`laptops`/`pi` groups and Pi SSH policy.~~ *(2026-10-11: no posture check —
see Decision 2's amendment — and it adopts nothing; the hand-clicked objects
stay dashboard-owned. See the amendment below.)* **Groups are POST-if-missing only and
never send `peers`** — the API's PUT replaces the whole member list. A human
runs it, like every playbook here.

**The dashboard stays a first-class editor.** Using both, or only the UI, must
never clash. A default run only creates what is missing and reports drift; it
overwrites a UI edit only with `-e netbird_enforce=true`, and only on the fields
it names. Objects are matched by name, so renaming a managed one in the UI makes
the next run create a duplicate. Everything it does not name is never written.

> **Amended 2026-10-11, after the first real runs.** The pre-existing
> hand-clicked objects are groups `laptop` and `All` and policies
> `SSH Access`, `pi-lab-443-policy` and `Default` (disabled) — not
> `laptops`/`pi` as written above. They stay dashboard-owned; the playbook
> does not adopt them. Hosts enroll with `ansible/playbooks/netbird-client.yml`
> (inventory `ansible/inventories/mesh/hosts.yml`, LAN addresses for now).
> **Only setup keys put peers in `infra-nodes`:** adding `infra-nodes` to a
> user's auto groups pulled a laptop in through propagation, and an enforce run
> switched its SSH server on. `netbird-configure.yml` now enables `ssh_enabled`
> only on peers with no owning user, and reports user-owned peers in
> `infra-nodes` as drift.

> **Amended 2026-10-11: the SSH rule needs ports.** A `netbird-ssh` rule
> without `ports` renders on the host as `ip saddr <source> accept` with no
> destination port, which opens every TCP port. The policy carries
> `ports: ["22"]` (NetBird redirects 22 to 22022).
>
> **Amended 2026-10-11: the mesh is SSH only, enforced client-side.** Hosts
> run `netbird up` with `--disable-client-routes --disable-server-routes`, so a
> route, network resource or exit node added in the dashboard never reaches
> a host. Applied to the three spike hosts with `-e netbird_reup=true`
> (verified on k8s-worker-02: `DisableClientRoutes`/`DisableServerRoutes`
> true in `/var/lib/netbird/default.json`).
>
> **Cilium and `wt0`:** Cilium auto-detects `wt0` and lowers its MTUs to match
> it. The pin `cilium_extra_values: {devices: [eth0]}` is applied
> (2026-10-11); see the progress note under Rollout.

### 7. Observability

Scrape `metricsPort: 9090` with a ServiceMonitor (zot's pattern), and add
NetBird's dashboards. Add an `http_2xx` blackbox probe on a server-owned
path of `https://netbird.bnei.dev` (not `/`, which is the dashboard's
catch-all); from inside the cluster it tests NAT hairpin, not the outside
path. Rules: down 5m = critical, degraded = warning. `PVEHostUnreachable` and
`PVEHostProbeStale` are scoped to PVE targets first — today both match every
blackbox probe.

## Rollout

1. This ADR and the docs it changes.
2. Observability (independent).
3. `netbird-configure.yml`, first part: account settings, groups, admin auto
   group, ~~posture check~~ (dropped during the spike), SSH policy, per-peer
   `ssh_enabled`, setup key. Pulled
   ahead of the spike so the spike runs on the declared state, not on clicks.
4. **Spike**, by hand, on the witness `.197`, one k8s worker (not
   `k8s-worker-01`, whose host `.165` is the bit-flip suspect) and one
   non-storage LXC. Log the results in `docs/bootstrap-test-notes.md`. Pass criteria:
   - From the LAN, an infra peer reaches management (hairpin), and the laptop
     passes the FR geo check from home.
   - The groups claim arrives, or the manual fallback is in place.
   - Propagation makes N MG's laptop fail at network level.
   - `ansible -m ping` plus a `copy` work with `-f 10` and `become`, as
     root/core/vagrant, with an acceptable number of JWT prompts.
   - A netbird pod restart during a looping ping: behaviour recorded.
   - A peer rename via the API carries the DNS label, and re-enrolling does not
     suffix it.
   - On the worker: `cilium status --verbose` devices exclude `wt0`,
     `cilium-dbg encrypt status` is clean, cross-node pod traffic works, and
     systemd-resolved is untouched.
   - LXC tun works.
   - The Freebox LAN IPv6 prefix, and which address family LAN SSH uses.
   - Pod → Postgres connections arrive from node IPs (so 5432 can leave the
     public zone).
5. ~~`netbird-configure.yml`, second part: peer names,~~ the records move, the
   overlay inventory. *(2026-10-11: peer renames dropped — Decision 4
   amendment. The records move is done; what remains is using the mesh
   inventory as the light-run overlay.)*
6. Enrollment, staged: witness → k8s workers one at a time → control plane →
   Patroni replica (from `patronictl list`, not the name) → leader →
   non-storage LXCs → PVE → Pi-hole → garage/nfs in a window.
7. Cutover: the `sshd` `Match` blocks, the break-glass key, `:49222` restricted
   to it, and the `k8s-ops`/`ansible-ops`/`run-ukubi-ops` skills.

**Progress (2026-10-11):** steps 1 and 3 done; step 2 partly (scrape, probe and
the critical alerts are live; NetBird's Grafana dashboards and the degraded =
warning rule are not); `netbird-configure.yml` part 1 run
for real. Step 4 in progress: the three spike hosts are enrolled, reach
management through the hairpin and show up on the laptop; the SSH,
ansible-over-mesh checks are not done. The geo pass criterion is
moot (Decision 2 amendment). Spike results so far:
- **Passed:** systemd-resolved is untouched (`--disable-dns`, no `wt0`
  link). LXC tun works. Infra peers reach management from the LAN. The
  Freebox LAN IPv6 prefix is `2a01:e0a:126d:910::/64`.
- **Found and fixed:** a `netbird-ssh` rule with no ports is an any-port
  rule (`ip saddr <peer> accept`, no dport). The policy now has
  `ports: ["22"]` (ee291339).
- **Passed after a fix:** "devices exclude `wt0`". Cilium had auto-detected
  `wt0` on k8s-worker-02 and lowered its MTUs there (`cilium_host`/`cilium_vxlan`
  1280, `cilium_wg0` 1200, against 1500/1500/1420 on worker-01). The pin
  `cilium_extra_values: {devices: [eth0]}` was applied 2026-10-11 by hand on
  k8s-cp-01 the way kubespray's role would (`cluster.yml --tags cilium`
  installs nothing on v2.31.0 — see `docs/bootstrap-test-notes.md`), then
  `rollout restart ds/cilium`. Configmap `devices: eth0`, worker-02 back to
  1500/1500/1420, endpoint health 5/5.
- **Found and fixed:** the route flags (`--disable-client-routes`,
  `--disable-server-routes`) are on all three spike hosts.

**Step 6 started (2026-10-11 ~23:23):** the `k8s` stage is enrolled with
`NETBIRD_INFRA_SETUP_KEY_K8S` (limit 6) and `-e netbird_serial=1`. The hosts
were `k8s-worker-01`, then `k8s-cp-01`/`-02`/`-03`, one at a time, with 0
failures. Then `-e netbird_enforce=true` turned on `ssh_enabled`. After the
run: 5/5 nodes Ready, every Cilium agent saw 5/5 healthy, and etcd was ok
through `/readyz`. `wt0` is up on all four and the Cilium MTUs stayed
1500/1500/1420, so the eth0 pin holds. `<node>.bnei.mesh:22022` is reachable
from the laptop. Remaining stages: `pg`, `lxc`, `pve`, `pi`, `storage`.

## Consequences

- **One NetBird client update reaches every hypervisor, Patroni node and DNS at
  once.** Pinned and staged for that reason.
- Each k8s node runs two WireGuard stacks (Cilium's and NetBird's).
- ~~**The geo check may deny laptops at home.**~~ *Superseded 2026-10-11: it
  did, and the geo check was removed (Decision 2 amendment).* Through NAT loopback the Freebox
  may SNAT to its LAN address, and Traefik trusts forwarded headers from
  Cloudflare only, so management can see a `192.168.x` source with no country.
  ADR-0054's hairpin fallback (a Pi-hole override to `.233`) makes that
  certain. The spike tests it from home. If home is denied, the geo check
  goes, not the reverse.
- The public `:49222` forward stays, narrowed to one key.
- Infisical gains `NETBIRD_INFRA_SETUP_KEY_<STAGE>` (one per stage), `NETBIRD_API_TOKEN` and the
  break-glass key. Per-host human keys are removed once cutover is verified.

## Alternatives considered

- **One LAN routing peer, keys kept.** Fixes reach, not key handling. Also
  rejected on its own: off-LAN, SSH is the only need — UIs are already public
  behind authentik and kubectl runs on the hub.
- **Only the hub as a peer.** Closes nothing but the forward.
- **Plain sshd over the mesh.** Same gap as the routing peer: keys stay.
- **The control plane outside k8s.** Survives a cluster outage, but reverses
  ADR-0054's hosting decision; `:49222` covers recovery more cheaply.
- **Split DNS / a NetBird `bnei.lan` zone with mesh IPs.** Records would point at
  mesh IPs that only allow SSH. PVE `:8006`, psql, redis, the registry and
  `k8s.bnei.lan` would then break from the laptops, even at home.
- **NetBird → Pi-hole sync of `*.bnei.mesh`.** No consumer: LAN devices without
  NetBird cannot reach `100.x`. It would also make LAN DNS depend on the cluster API.
- **Terraform `netbirdio/netbird` (0.0.x).** Pre-1.0 and a second tool;
  the DNS work is Ansible anyway.
- **The NetBird Kubernetes operator.** Recommends cert-manager, uses Gateway API
  (both banned), alpha, and has no policy CRDs.
- **The NetBird reverse proxy.** Needs Traefik in TLS passthrough, duplicates
  Traefik + Cloudflare + forwardAuth, and passes no identity to the backend.
- **Event streaming, flow logs, peer approval, SCIM, HA.** Enterprise-licensed
  on self-hosted.
- **Infisical as an SSH CA.** Forbidden (ADR-0006).
