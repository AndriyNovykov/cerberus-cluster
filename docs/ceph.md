# Ceph storage phase

Separate deployment phase (`playbooks/ceph.yml`), never referenced by `site.yml`. The
Slurm stack consumes the result (CephFS at `/clusterhome`) through inventory variables
only (`home_backend=cephfs`, `[ceph:vars]`).

## Design stance

- **cephadm is the orchestrator.** Ansible prepares hosts, runs a guarded one-shot
  `cephadm bootstrap`, joins hosts, and applies pools/services via `ceph orch` —
  then hands off. Daemon placement, OSD lifecycle, and **upgrades** belong to cephadm
  (`ceph orch upgrade start --image quay.io/ceph/ceph:vX.Y.Z`), never to Ansible re-runs.
- ceph-ansible is deprecated upstream. Do not resurrect it.
- The container image is pinned (`ceph_container_image` in
  `roles/ceph-bootstrap/defaults/main.yml`); bump it deliberately.

## Safety model (each rule traces to a failure in the July 2026 pilot)

1. **Data devices are selected by model string, never `/dev/nvmeXn1` path** — NVMe
   enumeration moved between reboots on the pilot host. Substring match on purpose
   (family prefix vs. full model string).
2. **Root device is asserted absent** from the candidate list; the run aborts otherwise.
3. **Device count is asserted** to equal `ceph_osds_per_host` before anything is touched.
4. **OSD creation is gated** on `-e ceph_confirm_destroy=true`; a plain run stops after
   printing exactly which devices would be consumed (dry-run report).
5. **Teardown** requires both `--tags teardown` (tagged `never`) and the same confirm flag.
6. Bootstrap output (contains the one-time dashboard password) is `no_log`; reset it with
   `ceph dashboard ac-user-set-password` if needed.

## Current deployment (interim, single node)

The HGX A100 node hosts the whole cluster: mon, mgr, MDS, and 8 OSDs on its data NVMes
(`ceph_data_device_model` filter). Consequences, all accepted until the dedicated
storage nodes arrive:

- **No node redundancy** — drive redundancy only. EC 4+2 with
  `crush-failure-domain=osd` tolerates two *drive* failures; a node outage takes
  storage down (and `/clusterhome` with it).
- Ceph daemons share the box with Slurm jobs; the `a100-hgx8` node profile reserves
  8 cores + 64 GB from Slurm (`CoreSpecCount`/`MemSpecLimit`).
- The monitoring stack is skipped (`ceph_deploy_monitoring=False`) — the cluster
  controller already runs Prometheus/Grafana.
- CephFS is mounted on the OSD host itself; acceptable with this much RAM, but a known
  anti-pattern to retire with the hardware.

Filesystem: `lucidfs` — EC 4+2 data pool (`allow_ec_overwrites`), replicated metadata
pool (size 3 / min_size 2), one MDS. RGW is a gated flag (`ceph_deploy_rgw`), default off.
A CephFS client key (`client.lucidfs`) is created by the pools role and stored on the
controller under `/etc/opt/oci-hpc/passwords/ceph/`; the `cephfs-client` role distributes
it and mounts `/clusterhome` on every node.

## Runbook

```bash
# 1. prep + bootstrap + host join; OSD step prints a dry-run device report and stops
ansible-playbook /opt/oci-hpc/playbooks/ceph.yml
# 2. after reviewing the report: consume the data devices
ansible-playbook /opt/oci-hpc/playbooks/ceph.yml -e ceph_confirm_destroy=true
# 3. pools, filesystem, MDS, client key
ansible-playbook /opt/oci-hpc/playbooks/ceph.yml --tags pools
# 4. idempotency check: a full re-run must report zero changes
ansible-playbook /opt/oci-hpc/playbooks/ceph.yml
```

Then flip `home_backend=cephfs` in `/etc/ansible/hosts` and run `bin/configure.sh`
(migrate any existing `/clusterhome` content first: rsync from the old NFS export into
the mounted CephFS).

## Migration to the dedicated storage nodes (future)

Deploy the new cluster fresh from this same phase — repoint `[ceph]`/`[ceph_bootstrap]`
to the storage nodes and set: `ceph_single_host=false`, `ceph_ec_failure_domain=host`,
`ceph_cluster_network=<replication cidr>`, per-host device model/counts, `ceph_mds_count=2`.
**Prefer 7+ hosts over 6 for EC 4+2**: with exactly 6, every PG spans all hosts and losing
two leaves zero margin (pilot report finding). Then rsync `/clusterhome` across, flip
`ceph_mon_ip`, and tear down the interim cluster (`--tags teardown`). MON addresses must
be static — a changed DHCP lease means monmap surgery.
