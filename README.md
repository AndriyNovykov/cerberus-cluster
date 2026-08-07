# Cerberus on-prem Slurm cluster

Ansible stack that configures a bare-metal Slurm cluster: controller/login node,
GPU compute nodes, LDAP accounts, NFS shared storage, container runtime
(docker + enroot/pyxis), and a Prometheus/Grafana monitoring stack.

This branch is the on-prem rework of the original OCI `oci-hpc` quickstart fork
(the OCI/Terraform version lives on `main`). All cloud provisioning is gone:
nodes are installed by hand (or by your provisioning tool of choice) and
configured with Ansible from a static inventory. The deployment path on the
controller remains `/opt/oci-hpc` for compatibility with the many scripts and
roles that reference it.

See [docs/onprem-deploy.md](docs/onprem-deploy.md) for the full bootstrap
procedure.

## Layout

- `playbooks/site.yml` — the primary entrypoint; composes ~40 roles in
  `playbooks/roles/` (slurm, openldap/sssd, nvidia-driver/fabricmanager,
  nfs-server/client, grafana/prometheus, docker/enroot, ...).
- `playbooks/group_vars/all.yml` — the **node profile catalog**
  (`node_profiles`): GPU type/count, fabric-manager requirement, Slurm
  features, and gres.conf entries per hardware model. Each compute host picks
  a profile via the `node_profile` inventory variable.
- `samples/inventory.example` — template for `/etc/ansible/hosts`: host groups
  (`controller`, `login`, `monitoring`, `compute`, ...) plus the `[all:vars]`
  cluster configuration.
- `conf/queues.conf` — minimal queue definition consumed by the slurm role.
- `bin/` — operational scripts run on the controller:
  - `controller.sh` — one-time controller bootstrap (installs Ansible).
  - `configure.sh [playbook] [inventory]` — run site.yml against the cluster.
  - `slurm_config.sh [--initial]` — regenerate Slurm config only.
  - `onboard.sh` — LDAP + Slurm account onboarding for a new lab/user.
- `scripts/build-slurm-debs.sh` — build the Slurm .deb consumed by the slurm
  role (output in `/opt/oci-hpc/slurm_debs/`).

## Cluster model

- **Configless Slurm with dynamic nodes**: compute nodes run `slurmd -Z` and
  register with the controller carrying their profile's `Gres=` and
  `Feature=` strings — `slurm.conf` never enumerates nodes.
- **One default partition (`main`)**; hardware is targeted with
  `--gres=gpu:<Type>:<n>` or `--constraint=<feature>` (e.g. `a100`,
  `h100nvl`). NodeSets are generated from the profile features, so
  per-tenant or priority partitions can be layered on later without touching
  node definitions.
- **NVSwitch systems** (HGX baseboards, profile `fabric_manager: true`) get
  `nvidia-fabricmanager` version-matched to the driver, and slurmd is ordered
  after it — required for the GPUs to be usable at all.
- **Storage**: the controller exports `/clusterhome` (shared LDAP-user homes) and a cluster NFS share
  (interim). A future CephFS mounts via the `add_nfs` hook in the inventory
  without role changes.

## Adding a node type

1. Add a profile to `node_profiles` in `playbooks/group_vars/all.yml`
   (derive `gres_entries[].cores` from `nvidia-smi topo -m` on the node).
2. Add the host line to `/etc/ansible/hosts` with `node_profile=<name>`.
3. Run `/opt/oci-hpc/bin/configure.sh`.

## User management

LDAP-backed, via the `cluster` CLI on the controller:

```bash
cluster user add jane_doe --gid 9876
```

or the guided `bin/onboard.sh` (creates the lab group, Slurm account, user,
and SSH key).

## Origin

Forked from the [oracle-quickstart/oci-hpc](https://github.com/oracle-quickstart/oci-hpc)
stack (UPL-licensed) and maintained for CAIS; this branch removes the OCI
layer for on-prem deployments.
