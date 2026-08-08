# Ceph Pilot Report — `hgxa100`

**Date:** 27–28 July 2026
**Operator:** Andriy
**Cluster fsid:** `5a07f571-8a13-11f1-bb98-7cc25556550a`
**Status at close:** running, HEALTH_OK, CephFS mounted on two GPU hosts

---

## Purpose

Two questions, both answered:

1. **What is the real operational overhead of deploying and running Ceph?**
2. **How would the existing compute cluster consume it?**

This was a decision-support exercise, not a benchmark. The numbers that matter are the operational ones.

---

## Environment

| | |
|---|---|
| Host | `hgxa100` — Supermicro AS-4124GO-NART, Equinix SV4 private cage EQIX:0105 |
| CPU / RAM | 2× AMD EPYC 7742 (128c/256t), 2 TiB |
| GPUs | 8× A100-SXM4-80GB (idle during pilot; unaffected) |
| OS | Ubuntu 24.04.4 LTS, kernel 6.8 |
| Data drives | 8× Samsung PM9A3 3.84 TB U.2 NVMe Gen4 → **28 TiB raw** |
| OS drives | 2× Samsung PM9A3 1.92 TB M.2 (one root, one unused) |
| Ceph | 19.2.5 Squid, deployed by cephadm 19.2.3 under podman 4.9.3 |
| Network | Single 1 GbE X710 link (ConnectX-6 ports down); all hosts on flat 10.20.10.0/24 |
| Clients | `lucid` (10.20.10.21, shared cage), `dgxh100` (10.20.10.27, private cage) |

**Prep work:** PSU fault on the left PDU repaired; k3s agent, Slurm worker and `slurmdbd` decommissioned; all eight data drives verified free of partitions, RAID metadata, LVM and filesystem signatures.

---

## Headline result: deployment overhead

**Under one hour from bare metal to a working three-interface cluster.**

| Time | Milestone |
|---|---|
| 23:32 | cephadm installed from Ubuntu repos |
| 23:34 | `cephadm bootstrap` complete — MON, MGR ×2, dashboard, Prometheus, Grafana, alertmanager |
| ~23:42 | 8 OSDs created, HEALTH_OK, 28 TiB raw |
| ~23:50 | EC 4+2 profile; CephFS, RBD and RGW pools; MDS and RGW daemons |
| 00:13 | First client mount from `lucid` |
| 01:11 | Second client mount from `dgxh100`, cross-cage read verified |

Nineteen daemons running, no manual configuration files written, no packages built. The orchestrator did the work.

---

## Storage performance (measured on-node, network excluded)

`rados bench`, 4 MiB objects, run on `hgxa100` so the 1 GbE link is not a factor.

### At default concurrency (`-t 16`)

| Pool | Bandwidth | Avg latency | IOPS |
|---|---|---|---|
| Replicated 2× | 1,251 MB/s | 51.1 ms | 312 |
| EC 4+2 write | 989 MB/s | 64.4 ms | 247 |
| EC 4+2 read | 1,216 MB/s | 52.0 ms | 304 |

### At realistic concurrency (`-t 128`)

| Pool | Bandwidth | Avg latency | Max latency | Stddev BW |
|---|---|---|---|---|
| Replicated 2× | **3,073 MB/s** | 166 ms | 0.23 s | 151 |
| EC 4+2 | **2,654 MB/s** (86%) | 192 ms | 0.30 s | 197 |

**These are floors, not ceilings.** Every result satisfies Little's Law to within 1% — concurrency × object size ÷ latency reproduces the measured bandwidth exactly. The benchmark was queue-depth-limited, never disk-limited. Corroborating that: at 3,073 MB/s with 2× replication the drives were absorbing 6,146 MB/s, or 768 MB/s each, well below PM9A3 capability.

**EC 4+2 costs ~14% throughput and ~16% latency versus 2× replication** on full-object writes. Better than published guidance suggested. Note this is EC's best case; its real penalty is read-modify-write on *partial* stripes, which is why RBD should stay on replication.

---

## Client performance (over 1 GbE, from `lucid`)

| Test | Result | Bound by |
|---|---|---|
| Single-stream write, `oflag=direct` | 77 MB/s | Latency — no pipelining |
| Single-stream read, caches dropped | 115 MB/s | Network (line rate) |
| 4-way parallel write | 117 MB/s | Network (line rate) |

The 77 MB/s figure is a benchmark artifact, not a Ceph limit: ~13.6 ms per synchronous 1 MiB write against a 0.4 ms RTT. Adding concurrency recovered full line rate. **Ceph added no measurable overhead on the read path.**

SV4 has no fabric above 1 GbE, so these numbers describe the FortiSwitch, not the storage.

---

## Operational drills

| Drill | Result |
|---|---|
| `osd out` → recovery to HEALTH_OK | under 2 min |
| `osd in` → backfill complete | **140 s** for ~22 GiB (~160 MiB/s per OSD) |
| Graceful daemon stop → detected | 1 s |
| `SIGKILL` daemon → detected | **2 s** |
| Recovery throughput (throttled) | 186–388 MiB/s |
| `mon_osd_down_out_interval` | 600 s |
| 2 of 8 OSDs **out** | All PGs active; 27% objects degraded |
| 3 of 8 OSDs **out** | All PGs still active |
| 3 of 8 OSDs **down** | **72 of 273 PGs (26%) inactive** |
| Recovery from 3 down | Full, no data loss |

### Failure detection has two distinct modes

A dying **process** closes its sockets, so the monitor sees connection resets and reacts in ~2 s. That covers crashes, OOM kills and segfaults. A dying **host** produces no teardown, so detection falls back to `osd_heartbeat_grace` at 20 s plus peer reporting. Both belong in an SLA; only the first was testable here.

### `out` is not `down`

Marking OSDs out only zeroes their CRUSH weight. The daemons stay up and keep serving from their acting sets, so **all PGs remained active with three of eight OSDs out**. Draining for planned replacement never risks availability. Only stopping the daemons produced inactive PGs.

### Recovery is deliberately throttled

Recovery ran at 186–388 MiB/s against ~3 GB/s of demonstrated write capability — the mclock scheduler's `balanced` profile protecting client I/O. The profile (`balanced`, `high_client_ops`, `high_recovery_ops`) is a **business decision**: how long will you sit at reduced redundancy to avoid degrading a tenant's training run?

Extrapolating 160 MiB/s per OSD to production — six nodes, five OSDs each, ~100 TB stored, ~16.7 TB per node, five OSDs backfilling in parallel:

> **~6 hours to restore full redundancy after permanent node loss** at the default profile.

The 600 s out-interval means this applies only to *permanent* loss. Reboots, kernel upgrades and quickly-fixed crashes cost nothing but peering.

---

## The finding that changes the production design

Three of eight OSDs down took 26% of PGs offline. **Production will be worse, and the difference is structural.**

On this host, CRUSH scatters each PG's 6 shards across a *choice* of 8 OSDs, so damage is uneven — most PGs lost only one or two shards. With **6 nodes at host-level failure domain**, every PG places exactly one shard per host, using all six. The arithmetic becomes deterministic:

| Hosts lost | Shards remaining | Result |
|---|---|---|
| 1 | 5 of 6 | Healthy, degraded |
| 2 | 4 of 6 | Reconstructable — **zero margin** |
| 3 | 3 of 6 | **Every PG down** |

Not 26%. All of it.

### Recommendation: build 7 nodes, not 6

With 7 hosts CRUSH selects 6 of 7 per PG, restoring the uneven distribution observed here. A third host failure would kill only the subset unlucky enough to span all three. It also lets you take a node down for maintenance while retaining tolerance for a genuine failure, rather than consuming the entire margin.

The seventh chassis is already in the BOM as an organ-donor spare. Promoting it to production costs one set of drives and materially improves the failure envelope.

---

## Corrections made during the pilot

Recorded because each was a real error caught by testing rather than reading.

1. **NVMe device names are not stable across reboots on this host.** The OS drive moved `nvme4n1` → `nvme3n1`, and `nvme3`/`nvme5` swapped roles. A hard-coded device list written before the reboot would have handed the running root disk to `ceph-volume`. Fixed by selecting on model string (`MZQL23T8HCLS`) with an abort check against `findmnt`.
2. **EC write stalls were pool warm-up, not erasure coding.** Initial EC runs showed 0 MB/s troughs and 2.49 s tails, attributed to EC's write path. Clean runs after PG settling showed 0.30 s max latency and tight variance. The initial reading was wrong.
3. **`cephadm add-repo --release squid` 404s on Ubuntu 24.04** and leaves a broken apt source. Unnecessary: noble-updates already ships cephadm 19.2.3, which is Squid.
4. **The CephFS mount helper takes the client name without the `client.` prefix.** Passing `client.lucid` makes it seek `ceph.client.client.lucid.keyring` and fail with a misleading "no mds is up".
5. **`systemctl stop` measures graceful shutdown, not failure.** Detection latency required `SIGKILL`.

---

## What this pilot could not prove

| Untested | Why | Needs |
|---|---|---|
| Host-level failure domain | Single node | 4+ node cluster |
| MON quorum behavior | Single MON | 3 MONs |
| Real throughput | 1 GbE ceiling | 100 GbE fabric |
| Network-partition detection | All heartbeat peers local | Multi-node |
| Multi-client scaling | One benchmark process | Production workload |
| RBD and RGW client paths | Deferred — pools built, unused | ~30 min when needed |

---

## Actions arising

| # | Action | Rationale |
|---|---|---|
| 1 | **Build 7 storage nodes, not 6** | 6-node EC 4+2 has zero margin at two host failures |
| 2 | Decide the mclock profile | Governs the ~6 h redundancy-restoration window |
| 3 | Settle the pool capacity split | RBD needs 3× replication; 20 TB of VM storage costs ~40 TB of EC capacity |
| 4 | Re-verify storage-vs-network balance | On-node numbers suggest storage may bottleneck before 100 GbE |
| 5 | Exercise RBD and RGW before committing | Unified storage is the core rationale and remains undemonstrated |
| 6 | Set DHCP reservation for any production MON | MON addresses are baked into the monmap |

---

## Verdict

Ceph deployed in under an hour, served two GPU hosts across two cages at line rate, survived every failure injected, and self-healed without operator intervention every time. The operational overhead that made Lustre look expensive did not materialize here — cephadm and the orchestrator absorbed most of it.

The pilot supports the decision to use Ceph, with one amendment: **seven nodes rather than six.**
