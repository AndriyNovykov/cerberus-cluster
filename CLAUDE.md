# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## What this repository is

This is an OCI (Oracle Cloud Infrastructure) HPC/GPU Slurm cluster stack — a fork of the
`oci-hpc` quickstart maintained for CAIS (Center for AI Safety). It deploys a Slurm cluster
(controller + optional HA backup + login + compute nodes on RDMA cluster networks or instance
pools) via **OCI Resource Manager (ORM)**. There is no application to build/lint/test locally;
the "product" is the Terraform + Ansible + scripts that get deployed.

Two layers do all the work:

- **Terraform** (`*.tf` at repo root, plus `autoscaling/tf_init/`) — provisions OCI IaaS:
  controller (`controller.tf`, `slurm_ha.tf`), login node (`login.tf`), compute nodes
  (`compute-nodes.tf`, `instance-pool*.tf`, `cluster-network*.tf`, `compute-cluster.tf`),
  networking (`network.tf`), shared storage (`fss.tf`), monitoring/DB (`monitoring.tf`,
  `mysql.tf`), and Marketplace images (`marketplace.tf`, `oci_images.tf`). `locals.tf` and
  `variables.tf` centralize computed values and inputs; `schema.yaml` defines the ORM UI form.
- **Ansible** (`playbooks/`) — configures the nodes after provisioning. `playbooks/site.yml` is
  the primary entrypoint; behavior is composed from ~60 roles in `playbooks/roles/`
  (slurm, openldap/sssd, nvidia-*, rdma-interface, nfs-*, grafana/influxdb/telegraf, etc.).
  `playbooks/group_vars/all.yml` holds shared vars.

`bin/` scripts are the **day-2 operational glue** that runs on the controller and stitches the
two layers together (calls the OCI SDK for IaaS changes, then re-runs the relevant playbooks).

## Deployed layout (important for reading the code)

The repo is deployed to **`/opt/oci-hpc`** on the controller. README instructions and scripts
reference absolute paths there, which map directly to this repo:

- `/opt/oci-hpc/bin/`  ⇄  `bin/`
- `/opt/oci-hpc/playbooks/`  ⇄  `playbooks/`
- `/opt/oci-hpc/conf/queues.conf` — live queue/instance-type config (template: `conf/queues.conf.example`)
- `/opt/oci-hpc/autoscaling/clusters/<name>/` — per-cluster Terraform state for autoscaled/manual clusters
- `/opt/oci-hpc/logs/` — `create_<cluster>_<date>.log`, `delete_...`, `crontab_slurm.log`
- `/etc/ansible/hosts` — the generated Ansible inventory (roles branch on host groups: `controller`, `slurm_backup`, `login`, `compute`, `monitoring`)

## Key operational commands (run on the controller)

Resize an existing cluster network (add/remove/reconfigure nodes; wraps `resize.py` + Ansible):
```bash
/opt/oci-hpc/bin/resize.sh add 3 --cluster_name compute-1-hpc
/opt/oci-hpc/bin/resize.sh remove --nodes inst-abc-woodcock
/opt/oci-hpc/bin/resize.sh reconfigure          # re-runs cluster-creation playbooks on all nodes
```
Manual cluster create/delete (used by autoscaling too):
```bash
/opt/oci-hpc/bin/create_cluster.sh <NodeCount> <clustername> <instance_type> <queue_name>
/opt/oci-hpc/bin/delete_cluster.sh <clustername> [FORCE]
```
Apply queue config changes after editing `conf/queues.conf`:
```bash
/opt/oci-hpc/bin/slurm_config.sh            # regenerate Slurm partitions from queues.conf
/opt/oci-hpc/bin/slurm_config.sh --initial  # reset Slurm to initial state
```
Autoscaling is a cronjob (cluster-per-queued-job; idle clusters torn down after a grace period):
```bash
* * * * * /opt/oci-hpc/autoscaling/crontab/autoscale_slurm.sh >> /opt/oci-hpc/logs/crontab_slurm.log 2>&1
```
User management (LDAP, when controller is the LDAP server): `cluster user add <name> [--gid 9876] [--nossh]`

Diagnostics (aliases on the controller): `validate` (`scripts/validation.py` — node-count consistency,
PCIe bandwidth, GPU throttle, `/etc/hosts` md5), `max_nodes` (`scripts/max_nodes_partition.py`),
`scripts/collect_logs.py` (nvidia bug report + sosreport + console history).

## Running Ansible / Terraform directly

- Configure step invoked by the stack: `bin/configure.sh [playbook] [inventory]` — defaults to
  `playbooks/site.yml` against `/etc/ansible/hosts`. Autoscaled clusters use `bin/configure_as.sh`.
- Terraform is normally driven by ORM, not `terraform apply` by hand. Requires provider
  `oracle/oci >= 6.9.0`, Terraform `>= 1.2` (`versions.tf`). `provider.tf` is intentionally
  commented out — ORM injects credentials; uncomment only for local/instance-principal runs.

## Conventions & gotchas

- **`queues.conf` is the source of truth** for shapes/queues. Instance types are selected from a
  job via `--constraint <instance_type>` or `-p <queue>`; there is one default instance-type per
  queue and one default queue. Leave all fields present even when unused. `permanent: true` clusters
  are never auto-torn-down; the initial stack cluster is also never spun down.
- **Resizing ≠ autoscaling.** Resizing changes an existing cluster's size (may hit RDMA-island
  capacity limits since RDMA is non-virtualized); autoscaling launches a *new* cluster per job and
  never resizes up. Resizing via the OCI console alone does **not** run the Ansible reconfig — always
  go through `resize.sh` so `/etc/hosts`, Slurm, and topology stay consistent.
- **Multi-OS support** (`OL7`/`OL8`/`Ubuntu 22.04`): roles branch on `ansible_os_family` and have
  per-distro task files (e.g. `roles/sssd/tasks/{el-7,el-8,debian}.yml`). When editing a role, update
  every OS variant, not just one. On Ubuntu the instance username is `ubuntu`, on OL it is `opc`.
- Unreachable nodes block cluster modification unless `--remove_unreachable` is passed to `resize.sh`.
- `.gitignore` only excludes `.DS_Store`; be careful not to commit generated state or secrets.
