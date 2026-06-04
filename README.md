# infra-bootstrap

Bootstrap configs for the homelab `ukubi-cluster`: kubespray inventory, Pigsty config, and Ansible playbooks for PVE post-install + VM provisioning.

**Source of truth for cluster design:** [`MohammadBnei/k8s-cluster/docs/infrastructure-desired.md`](https://github.com/MohammadBnei/k8s-cluster/blob/main/docs/infrastructure-desired.md)
**Runtime K8s manifests:** [`MohammadBnei/k8s-cluster`](https://github.com/MohammadBnei/k8s-cluster) (separate repo, GitOps via ArgoCD)

---

## Layout

| Path | Contents |
|---|---|
| `kubespray/` | git submodule → `kubernetes-sigs/kubespray` pinned at `v2.31.0` |
| `inventory/ukubi/` | our kubespray inventory (hosts, group_vars, addons) |
| `pigsty/` | Pigsty config (`pigsty.yml` + files) |
| `ansible/playbooks/` | PVE post-install, VM provisioning, K8s node prereqs |
| `ansible/inventories/` | Ansible inventories (PVE hosts) |
| `docs/` | runbooks (k8s bootstrap, pg bootstrap, pve post-install) |

## Workflow

1. **Agent (hermesagent)** drafts changes → commits on a feature branch → pushes → opens a PR
2. **You** review the PR on GitHub → merge to main
3. **You** run the actual tool (`ansible-playbook`, `kubespray`, `pigsty`) on your Mac against this repo

**Never commit secrets to this repo.** All secrets (DB passwords, k8s SA tokens, etcd certs) live in the **Infisical `infra-bootstrap` project** and are fetched at run time.

## Bootstrap (first time)

```bash
git clone git@github.com:MohammadBnei/infra-bootstrap.git
cd infra-bootstrap
git submodule update --init --recursive   # pulls kubespray
bin/install-requirements.sh               # installs ansible, infisical CLI, etc. on your Mac
infisical login                           # auth against Infisical
```

## Runbook pointers

- [docs/runbook-k8s-bootstrap.md](docs/runbook-k8s-bootstrap.md) — `kubespray` against `inventory/ukubi/`
- [docs/runbook-pg-bootstrap.md](docs/runbook-pg-bootstrap.md) — `pigsty` against `pigsty/pigsty.yml`
- [docs/runbook-pve-postinstall.md](docs/runbook-pve-postinstall.md) — `ansible-playbook ansible/playbooks/pve-postinstall.yml`

## Branch strategy

- Trunk = `main`
- All changes via feature branch + PR
- Agent pushes feature branches; you merge
- No direct commits to `main` (except initial scaffold)
