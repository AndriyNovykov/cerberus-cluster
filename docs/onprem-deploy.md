# On-prem deployment guide

Bootstrap procedure for the Cerberus bare-metal Slurm cluster. Current target
topology (SV4):

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
sudo git clone -b on-prem-rework <repo-url> /opt/oci-hpc
sudo chown -R ubuntu:ubuntu /opt/oci-hpc
/opt/oci-hpc/bin/controller.sh
ssh-keygen -t ed25519 -N '' -f ~/.ssh/cluster.key
```

Distribute `~/.ssh/cluster.key.pub` into
`/home/ubuntu/.ssh/authorized_keys` on **every** node, including sv5 itself.

## 3. Build the Slurm package

```bash
/opt/oci-hpc/scripts/build-slurm-debs.sh
```

Output lands in `/opt/oci-hpc/slurm_debs/`. If you change `SLURM_VERSION`,
update `slurm_version` in `playbooks/roles/slurm/defaults/main.yml`.

## 4. Inventory and configuration

```bash
cp /opt/oci-hpc/samples/inventory.example /etc/ansible/hosts
```

Edit:
- Host IPs in `[controller]` and `[compute_configured]`.
- `admin_password` (Grafana admin), `cluster_name` if desired.
- Each compute host's `node_profile` must exist in
  `playbooks/group_vars/all.yml` `node_profiles`.

**GPU affinity:** the `gres_entries[].cores` values in `node_profiles` are
placeholders until verified on the real hardware. After the drivers are up
(step 5), run `nvidia-smi topo -m` on each GPU node and set the CPU ranges of
each GPU group, then re-run `bin/slurm_config.sh`. Wrong values only degrade
NUMA affinity; they don't block scheduling.

## 5. Deploy

```bash
/opt/oci-hpc/bin/configure.sh
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
sacct -u testuser                  # accounting rows appear
sudo reboot                        # on hgx01: node must return to service
                                   # unattended (FM before slurmd)
```

## Day-2 operations

- **Add a node**: profile in `group_vars/all.yml` (if new hardware type) +
  host line in `/etc/ansible/hosts`, then `bin/configure.sh`.
- **Slurm config change**: edit templates/profiles, run
  `bin/slurm_config.sh` (`--initial` to reset state).
- **CephFS migration**: when the Ceph cluster exists, set in
  `/etc/ansible/hosts`: `add_nfs=true`, `nfs_source_IP=<ganesha/mon IP>`,
  `nfs_source_path=<export>`, `nfs_target_path=/nfs/scratch`, re-run
  `bin/configure.sh`. Moving `/clusterhome` onto CephFS replaces the controller's
  nfs-server export; plan a maintenance window and rsync.
- **User onboarding**: `bin/onboard.sh` (set the variables at the top first).
  Ceph quota TODO is marked inside the script.

## Known gaps / follow-ups

- `healthchecks=False` in the inventory: `check_gpu_setup.py` still contains
  OCI metadata calls; re-enable after porting.
- Backups role was removed with the OCI layer (it uploaded to OCI Object
  Storage); reintroduce against Ceph RGW S3.
- No PXE/automated OS provisioning; consider MAAS when the node count grows
  (H200/MI355/B300 expansion).
- `/opt/oci-hpc` path retained for compatibility; renaming is a mechanical
  follow-up.
