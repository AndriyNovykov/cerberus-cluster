# Open issues / remaining work

Status as of 2026-08-08. The 3-node test cluster (sv5 controller, hgxa100, lucid) is fully
deployed and green: Slurm + CephFS `/clusterhome` + single-node Ceph on hgxa100.

## Near-term (before or at the 24.04 rebuild)

- [ ] **Rebuild to Ubuntu 24.04 with final hostnames** — wipe all three nodes, no state
  preserved; first end-to-end run of the greenfield sequence in
  [docs/onprem-deploy.md](docs/onprem-deploy.md). Also the first validation of the
  controller-side roles (openldap/mysql/grafana/prometheus/slurmctld) on 24.04 — compute
  side is already 24.04-proven on hgxa100.
- [x] **Enroot/pyxis container smoke test** — done 2026-08-08: CPU + GPU containers
  verified on both nodes as an LDAP user. Fixes: AppArmor userns relaxation on 24.04+
  (nvidia-enroot role), pyxis pinned to v0.24.0 with loud build failure. Note for users:
  enroot registry syntax is `docker://REGISTRY#IMAGE:TAG`. Known deferred items: shared
  0777 enroot cache has multi-user ownership collision potential; each node pulls images
  independently (registry mirror later); enroot storage lands on the root fs while
  localdisk=False.
- [x] **Re-enable PAM hardening** — done 2026-08-09, live with `pam=True`: jobless LDAP
  users are denied on compute nodes, job holders get in and are adopted into the job
  cgroup, admin SSH survives. Two fixes were required first: (1) the slurm deb never
  contained pam_slurm_adopt.so — configure needs `--with-pam_dir=/usr/local/lib/security`
  or the module lands in /lib/security and fpm drops it (build-slurm-debs.sh now fails
  loudly); (2) compute_pam.yml needed `account sufficient pam_access.so` above the adopt
  line, otherwise pam_slurm_adopt (root-only exemption) denies the admin user too.
  Follow-ups: repeat runs churn/duplicate the pam_access line in common-auth (sssd role
  re-adds, slurm role comments — gate sssd's lineinfile on `not pam|bool`); the 25.10
  controller deb still lacks the .so (harmless — compute_pam never runs there; fixed deb
  comes with the 24.04 rebuild); flipping pam=False reverts nothing (manual runbook in
  the PAM plan file / git history).
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

## Pre-wipe batch (agreed 2026-08-08 — do these BEFORE the 24.04 rebuild)

The current cluster is disposable, making it the cheapest place to validate risky
changes. Order:

1. ~~**PAM hardening trial**~~ — done 2026-08-09, left ON (see near-term list for
   details and follow-ups).
2. **Pyxis/enroot smoke test** — `srun --container-image` has never been exercised
   (Apptainer path is verified; pyxis is not).
3. **Healthchecks port** — de-OCI `roles/healthchecks/files/check_gpu_setup.py`
   (metadata calls → node_profiles), flip `healthchecks=true`, verify a simulated GPU
   failure drains the node.
4. **Ceph observability** — enable the mgr Prometheus module, add a scrape job to sv5's
   Prometheus + alert rules (OSD down, fs near-full).
5. **`scripts/backup-controller-state.sh`** — passwords dir + slapcat + accounting
   mysqldump + cluster.key; not needed for this rebuild (no state kept) but must exist
   before real users do.

Then: rebuild → post-rebuild the near-term list above reaches "safe to onboard the
first real lab."
