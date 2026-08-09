# Open issues / remaining work

Status as of 2026-08-08. The 3-node test cluster (sv5 controller, hgxa100, lucid) is fully
deployed and green: Slurm + CephFS `/clusterhome` + single-node Ceph on hgxa100.

## Near-term (before or at the 24.04 rebuild)

- [ ] **Rebuild to Ubuntu 24.04 with final hostnames** — wipe all three nodes, no state
  preserved; first end-to-end run of the greenfield sequence in
  [docs/onprem-deploy.md](docs/onprem-deploy.md). Also the first validation of the
  controller-side roles (openldap/mysql/grafana/prometheus/slurmctld) on 24.04 — compute
  side is already 24.04-proven on hgxa100.
- [ ] **Enroot/pyxis container smoke test** — `srun --container-image` has never actually
  been exercised (Apptainer path is verified; the pyxis path is not).
- [ ] **Re-enable PAM hardening** — `pam=False` everywhere. After the rebuilt cluster is
  verified, flip it on and confirm the fixed `compute_pam.yml` (whitelists the real admin
  user + privilege group; only wires pam_slurm_adopt when the module exists). This is what
  keeps users without jobs off compute nodes.
- [ ] **Port the healthchecks role** — `roles/healthchecks/files/check_gpu_setup.py` still
  contains OCI metadata calls; `healthchecks=False` until cleaned. It is the
  GPU-drain-on-failure safety net; want it before real users.
- [ ] **Backups** — the OCI backups role was deleted. Minimum: script controller state
  (`/etc/opt/lucid-hpc/passwords/`, `slapcat`, accounting mysqldump, cluster.key) to CephFS
  or off-cluster. Proper: against Ceph RGW S3 once it exists.
- [x] **`/opt/oci-hpc` → `/opt/lucid-hpc` rename** — done 2026-08-08 (repo + live cluster).

## Blocked on hardware / infrastructure decisions

- [ ] **Data-plane networking** — everything rides 1 GbE today. Both GPU nodes have idle
  10 GbE+ NICs (lucid BCM57416 down, hgxa100 X710/ConnectX-6). Biggest available
  performance win with zero new hardware; CephFS I/O currently caps at ~110 MB/s/node.
- [ ] **12-node storage cluster** — repoint `[ceph]`/`[ceph_bootstrap]`,
  `ceph_ec_failure_domain=host`, `ceph_single_host=false`; **7+ hosts for EC 4+2** (pilot
  finding); migrate `/clusterhome`; tear down the hgxa100 interim cluster and drop its
  `CoreSpecCount` reservation. See [docs/ceph.md](docs/ceph.md).
- [ ] **AMD MI355 nodes** — the only genuinely new engineering on the roadmap:
  `nvidia-driver`/fabric-manager roles are NVIDIA-only, so AMD needs a ROCm driver role
  and amdgpu gres wiring (`/dev/dri/renderD*` pattern already exists in gres.conf.j2).
- [ ] **H100/H200/B300 nodes** — just new `node_profiles` entries + inventory lines
  (derive `gres_entries[].cores` from `nvidia-smi topo -m`).
- [ ] **Login/bastion CPU nodes** — `[login]` group is empty; slot in as inventory lines
  (MOTD and the login-node Slurm stanza already handle the group).
- [ ] **Container registry** — deferred by choice. Plan: Zot or Harbor (LDAP auth) backed
  by Ceph RGW S3; optionally a Distribution pull-through cache sooner.
- [ ] **RGW / S3** — one flag (`ceph_deploy_rgw=true`) when something needs it.

## Opportunistic / quality

- [ ] **Ceph observability** — the bundled monitoring stack is skipped
  (`ceph_deploy_monitoring=False`); wire the mgr Prometheus module into sv5's Prometheus
  and add basic alerts (OSD down, fs near-full).
- [ ] **Alert delivery** — Prometheus has rules but no receiver. The notifications role
  (goslmailer/Slack Slurm notifications) exists but was never installed; installing it
  also silences slurmctld's `MailProg is invalid` log noise.
- [ ] **Multi-tenant Slurm policy** — accounts/QOS/fairshare/per-lab partitions when real
  labs onboard; NodeSet scaffolding is already generated from profile features.

## Suggested order for the near-term block

rebuild → pyxis test → healthchecks → PAM → backup script — that sequence reaches
"safe to onboard the first real lab."
