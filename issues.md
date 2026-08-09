# Open issues / remaining work

Status as of 2026-08-09. The 3-node test cluster (sv5 controller, hgxa100, lucid) is fully
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
  Follow-ups: ~~pam_access churn in common-auth~~ fixed 2026-08-09 (sssd's lineinfile
  gated on `not pam|bool`; live duplicates deduped; full configure run verified
  no-churn); the 25.10 controller deb still lacks the .so (harmless — compute_pam never
  runs there; a verified 24.04 deb with the .so was pre-built on hgxa100 2026-08-09 and
  stashed off-cluster at `~/cerberus-artifacts/` on the admin workstation for the
  rebuild); flipping pam=False reverts nothing (manual runbook in the PAM plan file /
  git history).
- [x] **Port the healthchecks role** — done 2026-08-09, live with `healthchecks=true`:
  check_gpu_setup.py de-OCI'd (metadata/OCA/RTTCC/mlxlink/link-flapping/meshpinger
  deleted — no RDMA fabric; git history keeps them); expected GPU count now comes from
  `node_profile.json` written by the role from `this_node_profile`. Kept checks: ECC,
  row remap, XID, bus, GPU count, optional --bw-test. Verified on the live cluster:
  clean pass on both GPU nodes, simulated failure (expected-GPU mismatch on lucid)
  drained the node via the 300s HealthCheckProgram cycle with reason
  `Healthcheck:: Missing GPU Error`, resume + LDAP-user GPU job OK afterwards.
- [x] **Backups (minimum)** — done 2026-08-09: `scripts/backup-controller-state.sh`
  (root) tars passwords dir, slapcat dumps, accounting mysqldump, munge key,
  cluster.key, `/etc/ansible/hosts`, and queues.conf to
  `/clusterhome/.backups/controller/` (0600, retention 14, BACKUP_DIR/RETENTION
  overridable; restore notes in the header). Daily 00:30 root cron installed by the
  new `roles/backups` from site.yml. Verified live: contents complete, SQL restore
  drill into a scratch DB (31 tables), retention pruning, idempotent role. Proper:
  destination moves to Ceph RGW S3 / off-site (CephFS lives on hgxa100 — survives a
  controller wipe, not a storage-host loss).
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

- [x] **Ceph observability** — done 2026-08-09: mgr Prometheus module enabled on :9283
  (ceph.yml `--tags monitoring`), scraped by the controller Prometheus (job `ceph`),
  `ceph.rules.yml` alerts (scrape-dead, HEALTH_WARN/ERR, OSD down, >85% full,
  promtool-validated on deploy), ceph-mixin cluster dashboard in Grafana. Drill-tested
  live: stopping osd.7 sent CephOSDDown+CephHealthWarning pending, recovery cleared
  them. Bundled cephadm stack stays off. Design intent (recorded in docs/ceph.md):
  observability later centralizes on an off-prem VictoriaMetrics/Grafana fed by
  per-cluster agents (vmagent remote_write); the scrape job + rules are self-contained
  to lift out unchanged — sv5's Prometheus/Grafana is the interim pilot.
- [ ] **Alert delivery** — Prometheus has rules but no receiver. The notifications role
  (goslmailer/Slack Slurm notifications) exists but was never installed; installing it
  also silences slurmctld's `MailProg is invalid` log noise. Plan against the future
  central observability stack (decided 2026-08-09: off-prem cloud VictoriaMetrics +
  Grafana, per-cluster vmagent remote_write, central vmalert + per-cluster dead-man
  alert) rather than building per-cluster Alertmanager.
- [ ] **Multi-tenant Slurm policy** — accounts/QOS/fairshare/per-lab partitions when real
  labs onboard; NodeSet scaffolding is already generated from profile features.

## Pre-wipe batch (agreed 2026-08-08 — do these BEFORE the 24.04 rebuild)

The current cluster is disposable, making it the cheapest place to validate risky
changes. Order:

1. ~~**PAM hardening trial**~~ — done 2026-08-09, left ON (see near-term list for
   details and follow-ups).
2. ~~**Pyxis/enroot smoke test**~~ — done 2026-08-08 (see near-term list).
3. ~~**Healthchecks port**~~ — done 2026-08-09, live and drain-tested (see near-term
   list).
4. ~~**Ceph observability**~~ — done 2026-08-09, drill-tested (see opportunistic list).
5. ~~**`scripts/backup-controller-state.sh`**~~ — done 2026-08-09, restore-drilled
   (see near-term list).

**Pre-wipe batch complete (2026-08-09).** Then: rebuild → post-rebuild the near-term
list above reaches "safe to onboard the first real lab."

## 24.04 rebuild checklist (planned 2026-08-10)

Follow the greenfield sequence in [docs/onprem-deploy.md](docs/onprem-deploy.md)
(audited 2026-08-09 against the current repo). SV4-specific notes:

- [ ] Hostname change is `hgxa100` → `hgx01` only (sv5, lucid keep theirs). Update
  the `[compute_configured]`, `[ceph]`, `[ceph_bootstrap]` host lines and
  `ceph_mon_ip` accordingly.
- [ ] Skip the deb build: copy the pre-built, verified
  `slurm-24.05.1-1_24.04_amd64.deb` from the admin workstation
  (`~/cerberus-artifacts/`, sha256 starts 79034796) into
  `/opt/lucid-hpc/slurm_debs/`. It contains pam_slurm_adopt.so.
- [ ] Seed the repo onto sv5 via git bundle (no git-remote access from the cluster).
- [ ] Inventory: start from the updated `samples/inventory.example` —
  `localdisk=False` (hgx01's data NVMes belong to Ceph; RAIDing them via the
  localdisk role would destroy the OSD plan), `pam=False` initially,
  `home_backend=nfs` initially, `healthchecks=true`, real 10.20.10.x IPs, set
  `admin_password`.
- [ ] Verify `ceph_data_device_model=MZQL23T8HCLS` still matches hgx01's data drives
  (`lsblk -o NAME,MODEL`); OS drives are MZ1L21T9HCLS and must not match.
- [ ] Order: configure (NFS homes) → reboot GPU nodes → configure → ceph.yml
  (dry-run, then `-e ceph_confirm_destroy=true`, then `--tags pools`) →
  `home_backend=cephfs` + configure → verify per doc §6 (incl. healthcheck run,
  ceph Prometheus target, first backup) → `pam=True` + configure → re-verify
  (jobless LDAP SSH denied, job-holder adopted, admin SSH intact).
- [ ] `nvidia-smi topo -m` on both GPU nodes: a100-hgx8/h100nvl-1 `gres_entries`
  cores should carry over (same hardware), confirm anyway; `slurm_config.sh` if
  they changed.
- [ ] Known losses at wipe (intentional, no state kept): CephFS-hosted backups,
  Grafana/Prometheus history, LDAP test users, the old Ceph fsid.
