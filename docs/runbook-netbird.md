# Runbook: NetBird SSH mesh (ADR-0054, ADR-0055)

> **Status, 2026-10-11:** rolling out, spike stage. Three hosts are enrolled:
> `pg-etcd-witness` (.197), `k8s-worker-02` (.203) and the `build-runner` LXC
> (.111). The laptop sees all three as `<name>.bnei.mesh`. **SSH over the
> mesh has not been tested end-to-end yet.** Until it has, and until the
> cutover (ADR-0055 rollout step 7), keys over the LAN and the k9s hub
> remain the way in. Nothing below changes that.

## The model in five lines

1. **One control plane, in the cluster.** `netbird.bnei.dev` is `netbird-server`
   0.80.0 (management, signal, relay, STUN) plus the dashboard. Login goes
   through its embedded Dex to authentik. Its stores are on Pigsty.
2. **Every host is a peer in `infra-nodes`.** A host joins with a setup key.
   The key's auto group puts it there. The host's client runs an SSH server
   on port 22022.
3. **Your laptop is a peer in `platform-admins`.** That group is in your
   user's auto groups. Group propagation copies it onto your peers.
4. **One policy connects them.** `platform-admins-ssh-infra-nodes` (protocol
   `netbird-ssh`, port 22 only) lets `platform-admins` reach `infra-nodes`. By design, each
   SSH session asks for an authentik login (a JWT) in the browser and needs
   no SSH key. This is not yet verified on our hosts.
5. **Two playbooks keep it declared.** `netbird-configure.yml` talks to the
   API from your laptop. `netbird-client.yml` installs the client on the
   hosts over the LAN. The dashboard stays a first-class editor beside them.

```
                    authentik (authentik.bnei.dev)
                          ^  OIDC
                          |
   +----------------------+-----------------------------+
   |  ukubi-cluster       |                             |
   |  netbird-server pod: management, signal, relay,    |
   |                      embedded Dex (/oauth2)        |
   |  stores -> Pigsty (netbirddb, netbirdeventsdb,     |
   |                    netbirdidpdb)                   |
   |  TCP 443 via Traefik .233   STUN UDP 3478 via .235 |
   +--------^----------------------------^--------------+
            | control (gRPC, login)      | control
            |                            |
   +--------+---------+        +---------+---------------------+
   | laptop (peer)    |        | host peers, group infra-nodes |
   | group            |  WireGuard, peer to peer             |
   | platform-admins  |<======>| pg-etcd-witness               |
   | resolves         | (relay | k8s-worker-02                 |
   | *.bnei.mesh      | if P2P | build-runner                  |
   +------------------+  fails)| SSH server :22022             |
                               | --disable-dns: no *.bnei.mesh |
                               +-------------------------------+

   intended flow, NOT yet verified (spike step 4):
   ssh root@k8s-worker-02.bnei.mesh
     -> browser: authentik login -> JWT -> NetBird SSH server on the host
     -> local user root (allowed by the policy's user mapping)
```

The control plane only brokers the connection. SSH traffic flows directly
between the peers over WireGuard. When a direct path fails, it goes through
the relay in the pod. A short outage of the pod does not drop established
peer-to-peer tunnels, but relayed sessions die with it (ADR-0054 §7). It also
stops **new** sessions. The authentik login needs the
cluster, Traefik and Pigsty to be up.

## Where each thing lives

| Thing | Lives in | Changed by |
|---|---|---|
| Server deployment, config, authentik blueprint | git: `gitops/platform/values/netbird/`, `gitops/bootstrap/netbird-*.yaml`, `gitops/bootstrap/authentik-blueprint-netbird*.yaml` | PR + ArgoCD |
| Account settings: propagation on, DNS domain `bnei.mesh` | NetBird API | `netbird-configure.yml` |
| Groups `infra-nodes`, `platform-admins` (created only, members never written) | NetBird API | `netbird-configure.yml` |
| `platform-admins` in `mohammad@bnei.dev`'s auto groups | NetBird API | `netbird-configure.yml` |
| Policy `platform-admins-ssh-infra-nodes` | NetBird API | `netbird-configure.yml` |
| `ssh_enabled` on each host peer | NetBird API | `netbird-configure.yml -e netbird_enforce=true` |
| Setup key per stage (`infra-<stage>`) | NetBird API, plaintext in Infisical | `netbird-configure.yml -e netbird_setup_key_stage=…` |
| Client install and enrollment on the hosts | the hosts | `netbird-client.yml` |
| Which hosts are in which stage | git: `ansible/inventories/mesh/hosts.yml` | PR |
| Groups `laptop`, `All`; policies `SSH Access`, `pi-lab-443-policy`, `Default` (disabled) | NetBird API | **dashboard only**. The playbook never reads them for writing |
| Service user `ukubi` and its PAT | NetBird, PAT in Infisical as `NETBIRD_API_TOKEN` | **by hand, once**. Nothing can call the API before it exists |
| `NETBIRD_INFRA_SETUP_KEY_<STAGE>` (one per stage), `NETBIRD_API_TOKEN`, `PVE_SSH_PRIVATE_KEY` | Infisical `infra-bootstrap-1-ge1`, env `dev` | see [`secrets.md`](secrets.md) |

## UI and playbook coexist

You can use the dashboard, the playbook, or both. They do not fight:

- **A default run of `netbird-configure.yml` changes nothing that exists.** It
  creates missing objects and reports at the end, on two lines:
  - **Differs / Fixed:** drift on the fields the playbook owns.
  - **Needs a human (never changed by this playbook):** user-owned peers in
    `infra-nodes`, and admin emails with no NetBird user yet.
- **Task output is hidden play-wide**, because the PAT sits in the `uri`
  headers and Ansible does not mask it there. Asserts and the report stay
  visible. `-e netbird_debug=true` shows everything; never paste that
  output anywhere.
- **`-e netbird_enforce=true` makes the file win**, and only on the fields it
  names. Use it after an enrollment, or when you want to undo a UI edit.
- **Objects are matched by name.** If you rename `infra-nodes`,
  `platform-admins` or `platform-admins-ssh-infra-nodes` in the UI, the next
  run creates a second copy. Don't rename them.
- **Group members are never written.** A group PUT replaces the whole member
  list, so the playbook only creates groups. Membership comes from setup keys
  (hosts) and auto groups plus propagation (laptops).
- **Everything else is never touched**: other groups, other policies, peers
  outside `infra-nodes`.

## A `netbird-ssh` rule without ports opens every port

NetBird renders a policy rule with no `ports` on the host as `ip saddr
<source peer> accept`, with no destination port. That opens every TCP port
of the host to the source peers. The spike found this on 2026-10-11. The
policy now carries `ports: ["22"]`, and the playbook reports anything else
as drift. On `k8s-worker-02`, NetBird's nftables chain
`netbird-acl-input-rules` (table `ip netbird`) now allows only tcp 22 and
22022 from the laptop. NetBird redirects 22 to its SSH server on 22022.
Never save this policy without ports in the dashboard.

## Cilium must not use `wt0`

When a k8s node joins the mesh, Cilium auto-detects NetBird's `wt0` as one
of its devices (`Devices: [eth0 wt0]`, seen on `k8s-worker-02`). It is
harmless today (no kube-proxy replacement, no host firewall, iptables
masquerade). Still, the mesh is for SSH only and must never carry cluster
traffic. `wt0` also has MTU 1280, and Cilium lowered its own MTUs to match.
On k8s-worker-02, `cilium_host` and `cilium_vxlan` are 1280 and `cilium_wg0`
is 1200. On k8s-worker-01 they are 1500, 1500 and 1420. So worker-02 runs a
different tunnel MTU from the rest of the cluster. That is the silent
large-packet-hang hazard already noted in `k8s-net-cilium.yml`, which makes
the fix urgent.

`inventory/ukubi/group_vars/k8s_cluster/k8s-net-cilium.yml` pins
`cilium_extra_values: {devices: [eth0]}` (eth0 is the uplink on all five
VMs). **It is committed, not applied.** **Enroll no more k8s nodes until it
is.** The operator applies it from the laptop on the home LAN, with the local
`id_k8s_vms` key and `kubespray-venv`. The k9s hub has no k8s VM key, and its
checkout is behind.

```bash
cd kubespray && ../kubespray-venv/bin/ansible-playbook -i ../inventory/ukubi/hosts.yaml \
  cluster.yml --become --diff --tags cilium
kubectl -n kube-system rollout restart ds/cilium   # rollOutCiliumPods is unset: agents won't reload the configmap alone
```

After the restart, `cilium status --verbose` on k8s-worker-02 must list only
`eth0`, and its `cilium_host`/`cilium_vxlan` MTU must be back to 1500.

## The rule that matters: only setup keys put peers in `infra-nodes`

**Never add `infra-nodes` to a user's auto groups.** With propagation on,
that pulls the user's laptop into `infra-nodes`. The policy then treats the
laptop as an SSH target. This happened once on 2026-10-11: an enforce run
switched on the laptop's SSH server, and it was reverted by hand.

Since then, `netbird-configure.yml` switches `ssh_enabled` on only for peers
with no owning user. Hosts enrolled by setup key have none. A user-owned
peer found in `infra-nodes` is reported as drift and left alone.

## Users: `mohammad@` is the admin, `account@` is not

| User | Role | What it is |
|---|---|---|
| `mohammad@bnei.dev` | owner | The authentik login. It is the real admin, it owns the laptop peer, and `netbird_admin_emails` names it |
| `account@bnei.dev` | admin | The local account from the first boot ([ADR-0054](adr/0054-netbird-control-plane-hosting-only.md) §4). It is break-glass and owns no peers. Local login is off (`localAuthDisabled`); reverting that one line in the server config restores it. Password: `NETBIRD_OWNER_PASSWORD` |
| `nicolasmaigre@gmail.com` | admin | N MG, in `laptop`, deliberately **not** in `platform-admins` |
| `ukubi` | admin (service user) | Holds the PAT the playbook uses |

`account@bnei.dev` is also the operator's general email, so it is easy to
put it in `netbird_admin_emails` by mistake. An early draft of the playbook
did that, and it was caught before commit. The result: `platform-admins` lands on a user with no peers, and the laptop never
joins the group.

## Access model

| Use | Path | State |
|---|---|---|
| Human SSH, light runs (ad-hoc, app playbooks) | laptop over the mesh: `ssh root@<peer>.bnei.mesh` | spike, **not verified** |
| Heavy runs (kubespray, pigsty `node`/`pgsql`/`infra`, `gpu-node-configure.yml`, `pihole-configure.yml`) | the k9s hub, over the LAN ([`runbook-k9s-ops-hub.md`](runbook-k9s-ops-hub.md)) | unchanged |
| Off-LAN recovery | public `:49222` to the k9s hub | unchanged. Narrowed to one break-glass key at cutover |
| Enrollment itself | keys over the LAN | it has to be: the host is not a peer yet |

Heavy runs stay on the LAN because they restart Traefik, Pigsty or the
NetBird pod. Over the mesh, such a run would cut its own connection. The
kubespray and pigsty inventories keep their LAN IPs and are never repointed.

Not done yet: the sshd `Match` blocks that refuse keys from outside the LAN,
the break-glass key, the narrowing of `:49222`, and the skills' default
paths. All of these are ADR-0055 rollout step 7.

## DNS: `bnei.mesh` is for laptops only

Every peer gets `<name>.bnei.mesh`. Examples: `mohas-macbook-pro.bnei.mesh`,
`k8s-worker-02.bnei.mesh`. These names resolve only on clients that let
NetBird manage DNS, which means the laptops. The hosts run with
`--disable-dns`, so the client never touches systemd-resolved. That
resolver is the upstream of nodelocaldns and CoreDNS. Pi-hole stays
authoritative for `bnei.lan`, and nothing on a host may use a `.bnei.mesh`
name. Peer names are the hostnames for now. Rollout step 5 renames them to
Pi-hole short names (`mesh_name`).

## Prereqs

- An Infisical CLI session: `source ~/.hermes/cache/inf-env.sh`.
- `NETBIRD_API_TOKEN` in Infisical. It exists.
- On the LAN, with the SSH keys the mesh inventory names (`~/.ssh/id_*`).
  For LXCs, the playbook fetches `PVE_SSH_PRIVATE_KEY` itself.
- Under Claude Code's `!` prefix, append `2>&1 | cat` to ansible. Without it,
  ansible fails with `Ansible requires blocking IO on stdin/stdout/stderr`.

## Steps: enroll a stage

A stage is one group in `ansible/inventories/mesh/hosts.yml`. Today only
`spike` exists. **Before any stage with k8s nodes, apply the Cilium
`devices` pin (see above).** ADR-0055 step 6 sets the order of later stages: witness →
k8s workers one at a time → control plane → Patroni replica → leader →
non-storage LXCs → PVE → Pi-hole → garage/nfs in a window.

1. **Add the stage to the inventory.** The host name is the hostname, and
   `ansible_host` is the **LAN IP**. Copy the user and key from the host's
   own inventory, and keep it in sync with `inventory/ukubi/hosts.yaml`,
   `pigsty/pigsty.yml` or `terraform.tfvars`. For an LXC, add
   `netbird_lxc_ctid: <id>` and `netbird_pve_node: <pve host>`. Then add
   that PVE host to `pve_hosts` if it is missing.

2. **Mint the stage's setup key.** Set the usage limit to the host count + 2.
   The key auto-groups to `infra-nodes` and expires after 7 days. Its
   plaintext goes to Infisical as `NETBIRD_INFRA_SETUP_KEY_<STAGE>` (stage
   uppercased, `-` → `_`, e.g. `NETBIRD_INFRA_SETUP_KEY_SPIKE`), one secret
   per stage, written from a 0600 temp file, never on the command line. If
   the Infisical write fails, the playbook revokes the new key and fails.
   ```bash
   ansible-playbook ansible/playbooks/netbird-configure.yml \
     -e netbird_setup_key_stage=<stage> -e netbird_setup_key_usage_limit=<n+2>
   ```

3. **Install and enroll.** The playbook passes `/dev/net/tun` to each LXC that
   lacks it. It does this with `pct set --devN` and **a reboot of the
   container**, which interrupts whatever runs there. It then installs
   `netbird=<netbird_version>`, holds the package, and runs `netbird up` with
   `--management-url=https://netbird.bnei.dev --allow-server-ssh
   --enable-ssh-root --enable-ssh-sftp --disable-dns --disable-client-routes
   --disable-server-routes`, the key passed by file. The two route flags keep
   the mesh SSH only: a route or exit node added in the dashboard never
   reaches a host.
   ```bash
   ansible-playbook -i ansible/inventories/mesh/hosts.yml \
     ansible/playbooks/netbird-client.yml -e netbird_stage=<stage>
   ```

4. **Switch SSH on, management side.** The client flag alone is not enough.
   The peer's `ssh_enabled` (the dashboard's per-peer "SSH Access" toggle)
   must be on too.
   ```bash
   ansible-playbook ansible/playbooks/netbird-configure.yml -e netbird_enforce=true
   ```

Both playbooks are safe to re-run. `netbird-client.yml` skips `netbird up`
on a host that is already connected to management. The repo, the pinned
install and the hold still run every time, which is how a version bump works.

## Steps: bump the client version

NetBird SSH is not compatible across 0.60/0.61 (ADR-0055), so treat any bump
as breaking until tested. Move
the server, the laptops and the hosts together.

1. Bump the server tag in `gitops/platform/values/netbird/values.yaml`.
2. Update the laptops.
3. Change `netbird_version` in `netbird-client.yml`.
4. Re-run `netbird-client.yml` once per stage. The playbook releases the
   apt hold, installs the pinned version, and holds it again.

`-e netbird_reup=true` is a separate tool. It runs `netbird down`, then
`netbird up <flags>` **without** a setup key, to apply new flags on an
enrolled host. The peer is already registered and logs back in with its own
WireGuard key, so no setup-key use is spent. **Pending:** the three spike
hosts were enrolled before `--disable-client-routes`/`--disable-server-routes`
existed and need one `-e netbird_reup=true` run to get them.

## Verification

```bash
# drift report, changes nothing
ansible-playbook ansible/playbooks/netbird-configure.yml

# on a host
netbird status            # Management: Connected, SSH server on
# from the laptop
netbird status -d         # the host peers appear, with *.bnei.mesh names
ssh root@k8s-worker-02.bnei.mesh   # spike check, not yet done
```

Monitoring: Prometheus scrapes the server's `:9090`. The blackbox exporter
probes `https://netbird.bnei.dev` through the Freebox hairpin.
`NetBirdServerDown` and `NetBirdUnreachable` are critical and go to Discord.

## Troubleshooting

**A host peer does not appear on the laptop.** Check in this order:

1. **Is the laptop in `platform-admins`?** Dashboard → Peers → your laptop →
   groups. If it is not, check that `platform-admins` is in
   `mohammad@bnei.dev`'s auto groups and that propagation is on. A default
   run of `netbird-configure.yml` reports both.
2. **Is the host in `infra-nodes`?** If it is not, it enrolled with the wrong
   key, or someone removed it in the UI.
3. **Is `ssh_enabled` on for the peer?** A default run lists the peers where
   it is off. `-e netbird_enforce=true` fixes it.
4. **Is the host connected?** Run `netbird status` on the host over the LAN.
   On an LXC, check that `/dev/net/tun` exists.

**A posture check?** There is none. A geo check (FR only) was tried and
dropped on 2026-10-11. At home the laptop reaches management through the
Freebox hairpin, so management sees `192.168.1.254` with no country, and
the check could never pass. Access rests on the authentik JWT per session
plus `platform-admins` membership.

**A host cannot resolve `*.bnei.mesh`.** This is by design (`--disable-dns`).

**The drift report says a peer is owned by a user and should not be in
`infra-nodes`.** Someone added `infra-nodes` to a user's auto groups. Remove
it in the dashboard. See the rule above.

## Rollback

- **One host:** run `netbird down` and `apt-mark unhold netbird && apt remove
  netbird` on the host, then delete the peer in the dashboard. LAN keys were
  never removed, so nothing else changes.
- **The policy:** disable `platform-admins-ssh-infra-nodes` in the dashboard.
  A default run then reports drift and does not re-enable it. Only
  `netbird_enforce=true` does.
- **The whole mesh:** nothing depends on it before cutover. Heavy runs and
  break-glass never used it.
