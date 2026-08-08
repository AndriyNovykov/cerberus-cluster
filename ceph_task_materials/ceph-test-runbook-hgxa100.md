# Single-Node Ceph Test on `hgxa100`

**Target:** Supermicro AS-4124GO-NART, 2× EPYC 7742 (128c/256t), 2 TiB RAM, Ubuntu 24.04.4 LTS, kernel 6.8
**Location:** Equinix SV4, private cage EQIX:0105
**Prepared:** 25 July 2026

---

## Purpose and scope

Two questions this answers:

1. What is the real operational overhead of running Ceph — deployment, day-2 management, failure handling?
2. How does the existing compute cluster consume it — CephFS mounts, RBD volumes, S3 endpoints?

**What this test proves:** cephadm workflow, pool and CRUSH design, all three access methods (CephFS / RBD / RGW), client mount behaviour, dashboard and monitoring, genuine OSD add/remove and rebalance behaviour with 8 real OSDs.

**What it cannot prove:** host-level failure domain (single node), MON quorum behaviour (single MON), and — because SV4 has no fabric faster than 1 GbE — any throughput number worth quoting. Treat all performance figures from this test as meaningless unless you build the direct-DAC path in Step 8.

**Storage available:** 8× 3.84 TB NVMe = 30.72 TB raw → **20.5 TB usable at EC 4+2** (~16.4 TB at the 80% fill guideline).

**Resource cost on the host:** roughly 53 GB RAM (8 OSDs × 4 GB, plus mon 5 GB, mgr 4 GB, mds 8 GB, rgw 4 GB) out of 2 TiB, and about 120 W of additional draw.

---

## Step 0 — Pre-flight

Do these before touching anything.

### 0.1 Power (blocking)

Outlets 17 and 19 on the private rack's left PDU are dead. Outlet 17 caused this node's prior PSU input alert. Before adding sustained OSD load:

- Read and record voltage/load on both APC `APDU9941` PDUs (already an open action item in the colo notes).
- Confirm all four `PWS-2K21G-2R` PSU inputs are healthy in the BMC — you may currently be running 3+1 rather than 2+2.
- Confirm no cord is plugged into outlet 17 or 19.

### 0.2 Confirm the data drives are genuinely free

**Verified on this host, 27 July 2026:**

| Count | Size | Model | Role |
|---|---|---|---|
| 8 | 3.5 TiB | Samsung PM9A3 `MZQL23T8HCLS-00A07` (U.2, Gen4) | **DATA — for Ceph** |
| 2 | 1.7 TiB | Samsung PM9A3 `MZ1L21T9HCLS-00A07` (M.2) | **OS — DO NOT TOUCH** |

> ## NVMe device names are NOT stable on this host
>
> Observed directly: across a single reboot the OS drive moved from **`nvme4n1` to `nvme3n1`** (same disk — EFI UUID `E872-04FB`, root UUID `cdc92e84-edd2-4395-a846-babe198545ca`). NVMe enumeration follows PCIe probe order and varies boot to boot.
>
> **Never hard-code `nvmeXn1` paths.** A loop written against last boot's numbering will hand your running OS drive to Ceph.
>
> Select by model string instead — the two drive types are unambiguous (`MZQL23T8HCLS` = data, `MZ1L21T9HCLS` = OS):
>
> ```bash
> lsblk -dn -o NAME,SIZE,MODEL | grep MZQL23T8HCLS | awk '{print "/dev/"$1}'
> ```
>
> This must print exactly **eight** paths, and must never include the device returned by `findmnt -n -o SOURCE /`. Check both before proceeding.
>
> Once `ceph-volume` creates the OSDs it records them by LVM UUID, so enumeration drift stops mattering. The risk window is creation time only.

Raw capacity: 8 × 3.5 TiB = **28 TiB** → ~18.6 TiB usable at EC 4+2 (~14.9 TiB at 80% fill).

Verify they carry nothing. Run these **one at a time** — `lsblk -d` is not sufficient, it suppresses partitions and so hides every mountpoint:

```bash
lsblk -f                           # full tree with filesystem signatures
```
```bash
findmnt -n -o SOURCE /             # which device holds root THIS boot
```
```bash
cat /proc/mdstat                   # always prints something; expect no md arrays
```
```bash
sudo pvs; sudo vgs; sudo lvs       # expect no output at all
```
```bash
for d in $(lsblk -dn -o NAME,SIZE,MODEL | grep MZQL23T8HCLS | awk '{print $1}'); do
  echo "== $d"; sudo wipefs -n /dev/$d
done
```

Expected: blank FSTYPE on all eight data drives, `unused devices: <none>` from mdstat, no LVM output, and `wipefs` printing only the `==` headers with nothing beneath them. Any signature output means something is on that device — stop and investigate.

**Result on this host (27 July 2026): all eight confirmed clean.**

### 0.3 Service dependencies you are about to break

- `slurmdbd` runs here; the Slurm **controller** runs on `dgxh100` and will lose its accounting database.
- The cluster **login service** runs here.
- **This node is a `k3s` agent** (confirmed 27 July 2026 — `k3s-agent.service` is active). It is joined to a k3s server elsewhere, almost certainly `dgxh100`. Removing it drops a worker out of that cluster, along with the GPU Operator and ingress workloads scheduled on it.
- Other user accounts exist on the host (`eric`, `devin`) — worth a heads-up before you wipe.

Find out what you're detaching from before you do it:

```bash
sudo systemctl cat k3s-agent | grep -i server
sudo k3s kubectl get nodes 2>/dev/null || echo "agent only — check the server node"
```

Confirm with Zac (co-owner on the Critical Blockers list) before proceeding.

### 0.4 Time sync

```bash
timedatectl status                 # NTP service must be active and synchronised
sudo apt install -y chrony && systemctl enable --now chrony
```

Ceph will not form a healthy cluster with skewed clocks.

---

## Step 1 — Decommission existing services

Not a reinstall. Stop and disable what's running, leave the OS and NVIDIA stack intact.

```bash
# Slurm
sudo systemctl disable --now slurmd slurmdbd

# k3s — this host runs k3s-agent, NOT kubeadm.
# `kubeadm reset` does not apply, and k3s uses its own embedded containerd,
# so disabling containerd.service will not stop it.
sudo systemctl stop k3s-agent
sudo /usr/local/bin/k3s-agent-uninstall.sh

# Optional: drop the now-absent node from the k3s server (run on the server, likely dgxh100)
#   kubectl delete node hgxa100

# Confirm nothing holds the data drives
sudo lsof /dev/nvme* 2>/dev/null
```

Reboot and re-run the Step 0.2 checks — the eight data drives should come up clean and unclaimed.

> If leftover containerd or kubelet state causes trouble later, that's the point to fall back to a fresh Ubuntu 24.04 LTS install — and if you do, mirror the two OS drives with mdraid RAID1 while you're there. The colo notes flag the unmirrored OS drive as a standing risk on this host.

---

## Step 2 — Install cephadm

```bash
sudo apt update
sudo apt install -y cephadm podman lvm2
dpkg -l cephadm | tail -1
```

> **Do not run `cephadm add-repo --release squid` on Ubuntu 24.04.** Upstream does not publish a `debian-squid` repo for `noble`, so it 404s and leaves a broken entry in `/etc/apt/sources.list.d/ceph.list` that breaks every later `apt update`.
>
> It is also unnecessary: **Ubuntu noble-updates ships cephadm 19.2.3, which is Squid.** The daemons themselves run as containers pulled from quay.io, so the apt repo only ever mattered for host-side CLI tools — and `ceph-common` is in Ubuntu's repos too.
>
> If you already ran it: `sudo rm -f /etc/apt/sources.list.d/ceph.list && sudo apt update`

**Container engine note:** this host already had `docker-ce` installed. With both present cephadm prefers podman — confirm which it picked in the bootstrap output.

---

## Step 3 — Bootstrap the cluster

Replace `<HGXA100_IP>` with the node's address on the management network.

```bash
sudo cephadm bootstrap \
  --mon-ip <HGXA100_IP> \
  --single-host-defaults \
  --initial-dashboard-user admin \
  --dashboard-password-noupdate \
  --allow-fqdn-hostname
```

`--single-host-defaults` sets `osd_crush_chooseleaf_type = 0` (failure domain becomes OSD, not host), `osd_pool_default_size = 2`, and disables standby mgr modules. Without it every PG stays undersized forever.

Bootstrap prints the dashboard URL and a generated password. Store it in 1Password — the colo notes already flag credential hygiene as an open item.

```bash
sudo cephadm shell -- ceph -s        # expect HEALTH_OK with 1 mon, 1 mgr, 0 osds
sudo cephadm shell -- ceph orch host ls
```

Optional convenience — install the CLI on the host so you can drop `cephadm shell`:

```bash
sudo cephadm install ceph-common
ceph -s
```

---

## Step 4 — Add the eight OSDs

**Do not use `ceph orch apply osd --all-available-devices`** — it will claim the spare OS drive too. Add explicitly:

```bash
ceph orch device ls                  # the 8 data drives should show Available=Yes
```

**Resolve the device list fresh, in this boot's numbering.** Never reuse paths written down earlier:

```bash
ROOTDEV=$(findmnt -n -o SOURCE / | sed 's/p\?[0-9]*$//')
DATA=$(lsblk -dn -o NAME,SIZE,MODEL | grep MZQL23T8HCLS | awk '{print "/dev/"$1}')
echo "root is on: $ROOTDEV"
echo "$DATA" | tee /tmp/ceph-data-devs
echo "$DATA" | wc -l                 # MUST be 8
echo "$DATA" | grep -q "$ROOTDEV" && echo "ABORT: root disk in data list!" || echo "safe: root excluded"
```

Only proceed if that prints **8** and **safe: root excluded**. Then:

```bash
while read -r dev; do
  ceph orch daemon add osd hgxa100:$dev
done < /tmp/ceph-data-devs
```

Verify:

```bash
ceph -s                              # expect: 8 osds: 8 up, 8 in
ceph osd tree
ceph df
findmnt -n -o SOURCE /               # sanity: root still mounted, untouched
```

Expected raw capacity ≈ 28 TiB.

---

## Step 5 — Pool layout

This mirrors the production design: EC 4+2 for bulk data, replicated for metadata and block.

### 5.1 Erasure-coding profile

```bash
ceph osd erasure-code-profile set ec42 \
  k=4 m=2 \
  crush-failure-domain=osd

ceph osd erasure-code-profile get ec42
```

> `crush-failure-domain=osd` is what makes 4+2 possible on a single host. In production this becomes `host` across 6 nodes — that swap is the whole difference between this test and the real cluster.

### 5.2 CephFS

```bash
ceph osd pool create cephfs_data 128 128 erasure ec42
ceph osd pool set cephfs_data allow_ec_overwrites true
ceph osd pool create cephfs_metadata 32 32 replicated

ceph fs new testfs cephfs_metadata cephfs_data --force
ceph orch apply mds testfs --placement=1
```

The metadata pool **must** be replicated — erasure coding is not supported there. Same constraint applies to the RGW index pool below.

### 5.3 RBD (block, for VMs)

```bash
ceph osd pool create rbd_pool 64 64 replicated
ceph osd pool application enable rbd_pool rbd
rbd pool init rbd_pool
rbd create rbd_pool/testvol --size 100G
```

Replicated rather than EC deliberately: EC block volumes trigger read-modify-write on partial writes and are a poor fit for VM workloads.

### 5.4 RGW (S3-compatible object)

```bash
ceph orch apply rgw testrgw --placement=1 --port=8000

radosgw-admin user create \
  --uid=testuser \
  --display-name="Ceph test user"
```

Record the `access_key` and `secret_key` from the output. Quick check:

```bash
curl http://<HGXA100_IP>:8000
# then point s3cmd / aws-cli --endpoint-url at it
```

---

## Step 6 — Client test from another host

This is the half that answers "how does the compute cluster consume it." Mount from `lucid` or `dh100`, **not** from `hgxa100` itself — a loopback mount tests nothing about the network path.

On `hgxa100`:

```bash
ceph fs authorize testfs client.lucid / rw
ceph auth get client.lucid          # copy the key
ceph config generate-minimal-conf   # copy to the client as /etc/ceph/ceph.conf
```

On `lucid`:

```bash
sudo apt install -y ceph-common
sudo mkdir -p /mnt/cephfs
# place ceph.conf and a keyring at /etc/ceph/ceph.client.lucid.keyring
sudo mount -t ceph client.lucid@.testfs=/ /mnt/cephfs
df -h /mnt/cephfs
```

Then exercise it the way the cluster actually would:

- Write and read a dataset-sized file tree
- Run a real training job with its dataset on `/mnt/cephfs`
- Map an RBD volume: `rbd map rbd_pool/testvol` and put a filesystem on it
- Push and pull objects through the S3 endpoint

**Expect ~118 MB/s.** That is the FortiSwitch, not Ceph.

---

## Step 7 — Exercise the operational surface

This is the actual point of the exercise. Work through:

```bash
ceph -s; ceph health detail          # what does degraded look like
ceph osd out <id>                    # watch rebalance
ceph osd in <id>
ceph orch ps                         # daemon inventory
ceph orch upgrade check              # upgrade workflow
ceph crash ls                        # crash reporting
```

- Pull an OSD out and watch recovery traffic and PG states
- Kill an OSD daemon and see how it's detected
- Walk the dashboard: pool creation, capacity forecasting, alerting
- Look at the bundled Prometheus/Grafana stack
- Practise `ceph config set` vs the old ceph.conf model

Time how long each takes. That number — not throughput — is what should inform the Lustre-vs-Ceph operational argument.

---

## Step 8 — Optional: a real 100GbE path

Only worth doing if you want throughput numbers.

`hgxa100` has ConnectX-6 Ethernet/InfiniBand; `dgxh100` has ConnectX-7 (to 400 Gb) and dual E810 (to 100 Gb). Both currently down. A **direct DAC between them, no switch**, gives a genuine high-speed client path:

1. Confirm both cards are in Ethernet mode (`mlxconfig -d <dev> q | grep LINK_TYPE`)
2. Connect a QSFP28/QSFP56 DAC directly between the two NICs
3. Assign a /30 on each end, no gateway
4. Add that subnet as the Ceph `public_network`, or mount over it explicitly
5. Re-run the Step 6 client tests

This touches `dgxh100`, which carries cluster control, MariaDB, LDAP and NFS — but bringing up an unused NIC and adding an IP is far less invasive than installing anything on it. Still worth Zac's sign-off.

---

## Step 9 — Teardown

```bash
ceph mgr module disable dashboard
sudo cephadm rm-cluster --force --zap-osds --fsid $(ceph fsid)
```

`--zap-osds` wipes the eight data drives. Verify with `lsblk` afterwards.

Aligns with the plan on record: SV4 nodes move to Santa Clara and the machines get wiped and reprovisioned as a new cluster.

---

## Carrying the result forward

What transfers directly to the production 6-node build:

- The pool layout in Step 5, with `crush-failure-domain` changed from `osd` to `host`
- The EC 4+2 profile, unchanged
- cephadm bootstrap and host-add workflow — production is the same commands, run six times
- Client mount configuration and keyring management
- Everything you learn in Step 7

What does not transfer: any throughput measurement, host-failure behaviour, and MON quorum behaviour. Those need the real cluster.
