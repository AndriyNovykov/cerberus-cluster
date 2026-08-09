# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## What this repository is

An **on-prem bare-metal Slurm cluster stack** (branch `on-prem-rework`) — originally a fork of
the OCI `oci-hpc` quickstart maintained for Lucid; the OCI/Terraform version lives on `main`.
There is no application to build/lint/test locally; the "product" is the Ansible playbooks and
operational scripts that configure hand-installed Ubuntu 24.04 nodes.

Two independent phases share one inventory:

- **Slurm/cluster phase** — `playbooks/site.yml` (below).
- **Ceph storage phase** — `playbooks/ceph.yml` + `roles/ceph-*`; cephadm owns the
  stateful lifecycle (see `docs/ceph.md`). Never referenced by site.yml; the Slurm stack
  consumes CephFS via `home_backend=cephfs` and the `[ceph:vars]` inventory block.

One layer does all the work:

- **Ansible** (`playbooks/`) — `playbooks/site.yml` is the primary entrypoint, composing ~40
  roles in `playbooks/roles/` (slurm, openldap/sssd, nvidia-driver/nvidia-fabricmanager,
  nfs-server/nfs-client, grafana/prometheus/metrics-exporter, docker/nvidia-enroot, lucid-*).
  It runs against a **hand-written static inventory** at `/etc/ansible/hosts`
  (template: `samples/inventory.example`) — there is no Terraform and no cloud metadata.

Key concepts:

- **`node_profiles`** in `playbooks/group_vars/all.yml` is the hardware catalog: GPU type/count,
  `fabric_manager` requirement, Slurm `features`, and `gres_entries` (with CPU affinity ranges
  derived from `nvidia-smi topo -m`). Each compute host selects one via the `node_profile`
  inventory variable. This replaces the old OCI shape if-ladders — new hardware = new profile +
  inventory line.
- **Configless Slurm with dynamic nodes**: compute nodes run `slurmd -Z` carrying their
  profile's `Gres=`/`Feature=` strings; `slurm.conf` never enumerates nodes. One default
  partition (`main`); target hardware via `--constraint=<feature>` or `--gres=gpu:<Type>:<n>`.
  NodeSets are generated from the union of profile features.
- **NVSwitch nodes** (profile `fabric_manager: true`, e.g. HGX A100) require
  nvidia-fabricmanager version-matched to the driver (`nvidia_driver_branch` in group_vars);
  slurmd is systemd-ordered after it. Without FM the GPUs are unusable.
- **Slurm packages are built locally** with `scripts/build-slurm-debs.sh` into
  `/opt/lucid-hpc/slurm_debs/` on the controller; `roles/slurm/tasks/common.yml` copies from
  there (fails with instructions if missing). Version pin: `slurm_version` in
  `roles/slurm/defaults/main.yml`.

## Deployed layout

The repo is deployed to **`/opt/lucid-hpc`** on the controller:

- `/opt/lucid-hpc/bin/` ⇄ `bin/` — `controller.sh` (bootstrap), `configure.sh` (run site.yml),
  `slurm_config.sh [--initial]`, `onboard.sh` (LDAP+Slurm user onboarding)
- `/opt/lucid-hpc/conf/queues.conf` — minimal static queue file loaded via `vars_files`
- `/etc/ansible/hosts` — the static inventory; host groups `controller`, `slurm_backup`,
  `login`, `monitoring`, `compute` (children `compute_to_add`+`compute_configured`), `nfs`

Full bootstrap procedure: `docs/onprem-deploy.md`.

## Conventions & gotchas

- **Ubuntu 24.04 only.** EL/OL task files still exist in some roles but are dead code; when
  editing a role touch the `ubuntu`/`debian` variant.
- All cluster variables flow from the inventory `[all:vars]` block plus
  `playbooks/group_vars/all.yml` — `group_vars` holds ssl vars, `node_profiles`, and
  `nvidia_driver_branch`; everything else comes from the inventory.
- First `configure.sh` run installs NVIDIA drivers; GPU nodes need a reboot, then re-run
  (idempotent).
- Storage today: controller exports `/home` and `/export/cluster` over NFS. CephFS later mounts
  via the `add_nfs`/`nfs_source_*` inventory hook — don't build new mount plumbing.
- `healthchecks=False` in the inventory: `roles/healthchecks` and the custom metrics under
  `roles/metrics-exporter` still contain OCI metadata calls (documented gaps); the
  `cluster_network` flag gates all RDMA-fabric behavior and is `False` until a real fabric
  exists.
- Syntax-check after playbook edits:
  `ansible-playbook --syntax-check playbooks/site.yml -i samples/inventory.example`
