# Task Brief — Integrate Ceph deployment into `cerberus-cluster`

Materials in this directory. Read `CLAUDE.md` at the repo root first.

---

## Objective

Take a working, validated monolithic Ansible playbook that deploys a Ceph storage cluster and integrate it into this repository as roles that follow existing conventions.

The playbook is functional and its logic has been proven against a live cluster. **This is a refactoring and integration task, not a design task.** Do not redesign the deployment approach.

---

## Materials in `ceph_task_materials/`

| File | What it is |
|---|---|
| `ceph-deploy.yml` | 7 plays, 41 tasks. Host prep → bootstrap → expansion → OSD creation → pools → teardown. **Written standalone, before the repo was visible. Treat as reference logic, not as a drop-in.** |
| `inventory.ini` | Standalone inventory with `[ceph]`/`[ceph_bootstrap]` groups. **Does not match this repo's convention — see below.** |
| `ceph-pilot-report.md` | Measured results and five errors caught during validation. Useful background. |
| `ceph-test-runbook-hgxa100.md` | The manual procedure the playbook automates. |

---

## Repo conventions this must follow

Established from `CLAUDE.md`, `samples/inventory.example`, and `playbooks/site.yml`.

**Roles live in `playbooks/roles/`** alongside the existing ~40. Naming is mostly hyphenated (`nfs-server`, `nvidia-driver`, `metrics-exporter`); follow that.

**Inventory is a single hand-written static file** at `/etc/ansible/hosts`, templated by `samples/inventory.example`. Do **not** introduce a standalone `inventory.ini`. Add a `[ceph]` group (and a `[ceph_bootstrap]` child or a `ceph_bootstrap=true` host var) to the existing scheme, alongside `controller`, `login`, `monitoring`, `compute`, `nfs`.

**Variables come from inventory `[all:vars]` plus `playbooks/group_vars/all.yml`.** `group_vars` holds ssl vars, `node_profiles` and `nvidia_driver_branch`; everything else lives in the inventory. Ceph tunables belong in the inventory's `[all:vars]` block under a `# --- ceph ---` heading, mirroring the existing `# --- storage ---` block. Role-internal defaults go in `roles/<role>/defaults/main.yml`.

**Ubuntu 24.04 only.** EL/OL task files in other roles are dead code. Write the `ubuntu`/`debian` variant.

**Syntax check is the test gate.** There is no `ansible-lint`, `yamllint`, `ansible.cfg`, or CI in this repo — do not invent a requirement to match a lint standard that does not exist. The documented check is:

```
ansible-playbook --syntax-check playbooks/site.yml -i samples/inventory.example
```

**Deployed path is `/opt/oci-hpc`** with ~200 references. Do not rename anything.

---

## IMPORTANT — client mounts are already planned for

`samples/inventory.example` and `CLAUDE.md` both anticipate CephFS:

> Storage today: controller exports `/home` and `/export/cluster` over NFS. CephFS later mounts via the `add_nfs`/`nfs_source_*` inventory hook — **don't build new mount plumbing.**

`site.yml:200-204` already implements that hook. So:

- **Do NOT write a new CephFS client role or mount tasks.** Wire CephFS into the existing `add_nfs` / `nfs_source_IP` / `nfs_source_path` / `nfs_target_path` / `nfs_options` variables.
- CephFS mounts with `-t ceph`, not `-t nfs`. The existing hook assumes NFS. Extending it cleanly — likely via `scratch_nfs_type`, which already exists and defaults to `nfs` — is in scope. Extending, not replacing.
- Coordinate with `nfs-server`, `nfs-client`, `home_nfs`. Do not duplicate or fight them.

---

## Architectural context

**cephadm is the orchestrator, not Ansible.** Ansible's scope is host preparation, cluster bootstrap, and host expansion. cephadm then places MONs, MGRs, MDS and RGW itself.

Do not extend Ansible into daemon placement. Do not reintroduce `ceph-ansible` — deprecated upstream in favour of cephadm, and the two conflict.

---

## CRITICAL INVARIANTS — do not remove or weaken

Each exists because of a specific failure during validation. A reasonable-looking refactor could silently destroy any of them.

### 1. Data devices selected by model string, never by device path

NVMe enumeration is **not stable across reboots**. On the validated host the OS drive moved from `nvme4n1` to `nvme3n1` between two boots, and `nvme3`/`nvme5` swapped roles. A hard-coded device list written before a reboot would have handed the running root disk to `ceph-volume`.

Selection must resolve at run time from a stable attribute. Using `ansible_devices` facts with a model match would be more idiomatic than the current `shell` + `lsblk` and is welcome — **provided the assertions below survive**.

### 2. Root device exclusion assertion

Abort if the device holding `/` appears in the OSD candidate list. Hard failure, not a warning.

### 3. Device count assertion

Abort if matched device count differs from the expected per-host count. Catches both a wrong model string and a missing or failed drive.

### 4. Destruction gate

OSD creation stays behind `ceph_confirm_destroy`, defaulting to `false`. A default run must complete prep, bootstrap and expansion **without touching a disk**, printing the devices it *would* consume.

### 5. No `cephadm add-repo` on Ubuntu 24.04

It 404s on `noble` and leaves a broken apt source that breaks every later `apt update`. Unnecessary anyway — `noble-updates` ships cephadm 19.2.3, which is Squid. Keep the task removing a stale `/etc/apt/sources.list.d/ceph.list`.

### 6. CephFS metadata pool must be replicated

Erasure coding is unsupported for CephFS metadata pools. Same for the RGW index pool.

### 7. RBD pool must be replicated, not erasure coded

EC block volumes trigger read-modify-write on partial stripes — poor for VM workloads. Deliberate, not an oversight.

### 8. Teardown stays tagged `never`

`cephadm rm-cluster --force --zap-osds` must not be reachable without both an explicit tag and the confirmation variable.

---

## Suggested structure

```
playbooks/roles/
  ceph-prep/        packages, chrony, time-sync check, apt source hygiene
  ceph-bootstrap/   cephadm bootstrap, fsid capture, SSH key distribution
  ceph-cluster/     orchestrator host add, public_network, OSD creation (guarded)
  ceph-pools/       EC profile, CephFS, RBD, RGW, mclock profile
playbooks/
  ceph.yml          standalone entrypoint, mirroring lucid_*.yml style
```

Split or merge as judgement dictates — four roles may be more granularity than this repo's style warrants; `ceph` plus `ceph-pools` may suffice. Match the surrounding code.

Decide deliberately whether Ceph plays join `site.yml` or stay in a separate entrypoint invoked like `slurm_config.yml`. Storage nodes are dedicated hardware, not Slurm compute — a separate entrypoint is probably right, but state the reasoning.

---

## Other integration points

**Secrets.** `cephadm bootstrap` emits a one-time dashboard password to stdout, currently only printed. The repo has a `passwords` role and `ssl` vars in `group_vars` — follow whatever pattern those establish. Set `no_log: true` where appropriate. No credentials in plaintext or logs.

**`cluster_network=False`** in the inventory gates all RDMA-fabric behaviour and stays false until a real fabric exists. Ceph's public/cluster network split should respect this flag rather than assuming a fabric.

**Idempotency.** Several tasks currently use unconditional `changed_when: true` and rely on `failed_when` catching "already exists". A second full run must report zero changed tasks.

**Firewall.** An `iptables` and a `firewall` role already run against `all`. Ceph needs 3300, 6789, 6800-7300, 8443, 9283. Extend the existing roles rather than adding new firewall logic.

---

## Two known-imperfect areas — improvement welcome

**Device discovery** shells out to `lsblk | grep | awk`. Functional, not idiomatic. `ansible_devices` facts filtered on model would be cleaner. Any rewrite must preserve invariants 1–3.

**Host expansion** parses `ceph orch host ls --format json` and loops `ceph orch host add`. Works but inelegant. Preserve the behaviour that adding an already-known host does not fail the run.

---

## Out of scope

- Redesigning the pool layout — EC 4+2 for CephFS data, replicated for metadata and RBD is settled
- Multi-cluster or multi-site
- Anything touching the running pilot cluster at `10.20.10.30`
- Migrating `/home` off the controller's NFS export — separate decision
- Monitoring beyond what cephadm deploys by default (though check whether the existing `prometheus`/`grafana` roles should scrape Ceph's exporter)

---

## Acceptance criteria

1. `ansible-playbook --syntax-check` passes for both `site.yml` and any new Ceph entrypoint, against `samples/inventory.example`
2. `samples/inventory.example` gains a `[ceph]` group and a documented `# --- ceph ---` vars block
3. A run without `ceph_confirm_destroy=true` completes prep, bootstrap and expansion, prints candidate devices, creates **no** OSDs
4. All eight invariants present and covered by an assertion or guard
5. Second consecutive run reports zero changes
6. Teardown unreachable without both the `teardown` tag and `ceph_confirm_destroy=true`
7. CephFS client mounting goes through the existing `add_nfs`/`nfs_source_*` hook — no new mount plumbing
8. No secrets in plaintext, logs, or version control
9. Role README documenting variables and the safety model, matching the style of existing role docs

---

## Reference

- cephadm install: https://docs.ceph.com/en/latest/cephadm/install/
- `--single-host-defaults` sets `osd_crush_chooseleaf_type=0`, `osd_pool_default_size=2`, disables standby mgr modules
- Production differs from the validated pilot in exactly two settings: `crush-failure-domain` becomes `host` rather than `osd`, and `--single-host-defaults` is omitted
- Target production cluster: 7 nodes, 5× 7.68 TB NVMe each, EC 4+2, ~143 TB usable
