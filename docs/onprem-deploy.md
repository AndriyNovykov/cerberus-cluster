# On-prem deployment guide

Bootstrap procedure for the Cerberus bare-metal Slurm cluster.

## Full greenfield sequence (no prior state)

The complete from-scratch order; each step is detailed in the sections below
or in [ceph.md](ceph.md). Nothing survives from a previous deployment — fresh
certs, LDAP, munge key, Slurm cluster, and Ceph fsid are all generated.

```text
1. OS install on every node (hostname, static IP, admin user + NOPASSWD sudo,
   openssh-server, python3, controller pubkey in authorized_keys)
2. On the controller: clone repo to /opt/lucid-hpc, run bin/controller.sh,
   ssh-keygen ~/.ssh/cluster.key, distribute cluster.key.pub to all nodes
3. scripts/build-slurm-debs.sh (or copy a pre-built, version-matching deb
   into /opt/lucid-hpc/slurm_debs/)
4. cp samples/inventory.example /etc/ansible/hosts and edit: host lines,
   ceph groups, node_profiles per host, home_backend=nfs (bootstrap default —
   CephFS does not exist yet), pam=False (flip later, step 8)
5. bin/configure.sh          # full cluster on interim NFS homes
   (reboot GPU nodes if drivers were freshly installed; re-run)
6. ansible-playbook playbooks/ceph.yml                          # dry-run report
   ansible-playbook playbooks/ceph.yml -e ceph_confirm_destroy=true
   ansible-playbook playbooks/ceph.yml --tags pools
7. Flip home_backend=cephfs in /etc/ansible/hosts, re-run bin/configure.sh
8. Verify (section 6 below + ceph.md); cluster user add <first user>
9. Flip pam=True, re-run bin/configure.sh, re-verify: jobless LDAP SSH is
   now denied on compute; SSH into a node holding your job is adopted
```

Two hard ordering rules: the Ceph cluster must exist before
`home_backend=cephfs`, and `pam=True` only after LDAP-user SSH/jobs are
verified (step 6's testuser SSH check *fails by design* under PAM
hardening — pam_slurm_adopt denies LDAP users without a running job).
Everything else regenerates idempotently.

Current target topology (SV4):

| Host | Hardware | Role | node_profile |
|---|---|---|---|
| `sv5` | Dell R730 | controller + login/bastion (slurmctld/slurmdbd, MariaDB, OpenLDAP, NFS, Grafana/Prometheus) | — (cpu default) |
| `hgx01` | Supermicro HGX A100, 8x A100-SXM4-80GB (NVSwitch) | compute | `a100-hgx8` |
| `lucid` | EXXACT/ASUS ESC4000-E11, 1x H100 NVL | compute | `h100nvl-1` |

## 1. OS install (every node, manual)

- Ubuntu 24.04 LTS Server, hostname set to the inventory name.
- Static IP on the management network (1GbE today).
- Create the `ubuntu` user with passwordless sudo
  (`echo 'ubuntu ALL=(ALL) NOPASSWD:ALL' > /etc/sudoers.d/ubuntu`).
- Install `openssh-server` and `python3`.
- Disk layout:
  - OS on the first NVMe/SSD.
  - Leave data NVMe drives unformatted — the `localdisk` role RAIDs and
    mounts them at `nvme_path` (`/mnt/localdisk/`).

## 2. Controller bootstrap (`sv5`)

```bash
sudo git clone -b on-prem-rework <repo-url> /opt/lucid-hpc
sudo chown -R ubuntu:ubuntu /opt/lucid-hpc
/opt/lucid-hpc/bin/controller.sh
ssh-keygen -t ed25519 -N '' -f ~/.ssh/cluster.key
```

If the controller has no access to the git remote, seed it from a bundle
made on a workstation instead:

```bash
# workstation: git bundle create cerberus.bundle on-prem-rework && scp it over
sudo git clone -b on-prem-rework /tmp/cerberus.bundle /opt/lucid-hpc
```

Distribute `~/.ssh/cluster.key.pub` into
`/home/ubuntu/.ssh/authorized_keys` on **every** node, including sv5 itself.

## 3. Build the Slurm package

```bash
/opt/lucid-hpc/scripts/build-slurm-debs.sh
```

Output lands in `/opt/lucid-hpc/slurm_debs/`. If you change `SLURM_VERSION`,
update `slurm_version` in `playbooks/roles/slurm/defaults/main.yml`.

A deb built earlier on any Ubuntu box of the same release works too — copy
it into `/opt/lucid-hpc/slurm_debs/` and skip the build. The filename must
match `slurm-<slurm_version>_<ubuntu version>_amd64.deb`, and the package
must contain `usr/local/lib/security/pam_slurm_adopt.so`
(`dpkg -c <deb> | grep pam_slurm_adopt`) or PAM hardening will silently
skip.

## 4. Inventory and configuration

```bash
cp /opt/lucid-hpc/samples/inventory.example /etc/ansible/hosts
```

Edit:
- Host IPs in `[controller]` and `[compute_configured]`.
- The `[ceph]`/`[ceph_bootstrap]` groups and `[ceph:vars]`
  (`ceph_public_network`, `ceph_data_device_model` — verify against
  `lsblk -o NAME,MODEL` on the storage host), plus `ceph_mon_ip` in
  `[all:vars]`.
- `admin_password` (Grafana admin), `cluster_name` if desired.
- Each compute host's `node_profile` must exist in
  `playbooks/group_vars/all.yml` `node_profiles`.
- Keep `localdisk=False` on clusters where a compute host doubles as a Ceph
  host (see the warning in the inventory) and `pam=False` until step 9.

**GPU affinity:** the `gres_entries[].cores` values in `node_profiles` are
placeholders until verified on the real hardware. After the drivers are up
(step 5), run `nvidia-smi topo -m` on each GPU node and set the CPU ranges of
each GPU group, then re-run `bin/slurm_config.sh`. Wrong values only degrade
NUMA affinity; they don't block scheduling.

## 5. Deploy

```bash
/opt/lucid-hpc/bin/configure.sh
```

First run installs the NVIDIA driver on the compute nodes; **reboot the GPU
nodes** when the play reports "reboot required", then re-run
`bin/configure.sh` (it is idempotent).

## 6. Verify

Controller:

```bash
systemctl status slurmctld slurmdbd mariadb slapd prometheus grafana-server
sinfo
showmount -e localhost   # /clusterhome and /export/cluster
```

lucid (H100 NVL):

```bash
nvidia-smi                                # driver up, 1 GPU
srun --gres=gpu:H100NVL:1 nvidia-smi -L
# containerized (pyxis/enroot) — note enroot separates the registry with '#':
srun --gres=gpu:H100NVL:1 --container-image="docker://nvcr.io#nvidia/cuda:12.4.1-base-ubuntu22.04" nvidia-smi -L
```

hgx01 (HGX A100 — fabric manager is mandatory):

```bash
systemctl status nvidia-fabricmanager     # active
nvidia-smi -q | grep -A2 -i fabric        # State: Success
systemctl show slurmd -p After | tr ' ' '\n' | grep fabricmanager
srun -w hgx01 --gres=gpu:A100:8 nvidia-smi topo -m
```

Cross-cutting:

```bash
cluster user add testuser          # on sv5
ssh lucid                          # as testuser: LDAP + /clusterhome NFS home work
                                   # (only before pam=True — see step 9)
sacct -u testuser                  # accounting rows appear
sudo reboot                        # on hgx01: node must return to service
                                   # unattended (FM before slurmd)
```

Healthchecks, monitoring, and backups (after the Ceph phase):

```bash
# GPU nodes: healthcheck passes, no "Healthcheck::" line
sudo python3 /opt/lucid-hpc/healthchecks/check_gpu_setup.py --slurm
# controller: ceph scrape target up + CephAlerts loaded
curl -s localhost:9090/api/v1/targets | grep -o '"job":"ceph"[^}]*'
curl -s localhost:9090/api/v1/rules | grep -c CephAlerts
# controller: first backup runs clean, tarball lands on CephFS
sudo /opt/lucid-hpc/scripts/backup-controller-state.sh
```

## Day-2 operations

- **Add a node**: profile in `group_vars/all.yml` (if new hardware type) +
  host line in `/etc/ansible/hosts`, then `bin/configure.sh`.
- **Slurm config change**: edit templates/profiles, run
  `bin/slurm_config.sh` (`--initial` to reset state).
- **Ceph / CephFS homes**: storage is its own phase — see [ceph.md](ceph.md).
  Deploy with `playbooks/ceph.yml`, then flip `home_backend=cephfs` in
  `/etc/ansible/hosts` and re-run `bin/configure.sh` (rsync existing
  `/clusterhome` content across first).
- **User onboarding**: `bin/onboard.sh` (set the variables at the top first).
  Ceph quota TODO is marked inside the script.
- **Backups**: `scripts/backup-controller-state.sh` (root) tars passwords,
  LDAP dumps, accounting DB, munge/cluster keys, and the inventory to
  `/clusterhome/.backups/controller/` (override with `BACKUP_DIR=`, retention
  via `RETENTION=`, default 14). A daily root cron is installed by
  `roles/backups`; log at `/opt/lucid-hpc/logs/backups/backup.log`. Restore
  notes are in the script header.

## Known gaps / follow-ups

- Controller backups land on CephFS, which currently lives on a compute node
  (hgxa100) — not true disaster recovery. Upgrade the backup destination to
  Ceph RGW S3 or off-site storage when either exists.
- No PXE/automated OS provisioning; consider MAAS when the node count grows
  (H200/MI355/B300 expansion).
- `/opt/lucid-hpc` path retained for compatibility; renaming is a mechanical
  follow-up.
