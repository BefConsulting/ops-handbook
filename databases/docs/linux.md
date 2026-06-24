# Linux Host Tuning for PostgreSQL

The kernel and host settings that matter most when running a production PostgreSQL server. PostgreSQL ships tuned for portability, and the Linux defaults are tuned for general-purpose desktops/servers — neither is ideal for a dedicated, latency-sensitive database. This guide takes **each setting one at a time**: what it is, the **recommended value**, and **how to set it** (live + persistent).

**See also:** [best-practices.md](best-practices.md) (the PostgreSQL server-side counterpart) · [wal-and-checkpoints.md](wal-and-checkpoints.md) (checkpoint I/O) · [monitoring.md](monitoring.md)

> **Golden rule:** change one thing, measure, repeat. Most of these are kernel parameters — verify the live value before and after.

---

## How to set kernel parameters (sysctl)

Most settings here are **sysctl** parameters. There are three things you'll do with each:

```bash
# 1. VIEW the current value
sysctl vm.swappiness

# 2. SET it live (takes effect immediately, lost on reboot)
sudo sysctl -w vm.swappiness=1

# 3. PERSIST it across reboots — add to a file in /etc/sysctl.d/, then apply
echo 'vm.swappiness = 1' | sudo tee /etc/sysctl.d/30-postgresql.conf
sudo sysctl --system        # reloads all sysctl config files
```

> Put all your PostgreSQL host tuning in **one file** (e.g. `/etc/sysctl.d/30-postgresql.conf`) so it's reviewable and version-controlled (ship it via Ansible). The THP and I/O-scheduler knobs live under `/sys/...` instead and are best persisted via a `tuned` profile, `systemd` unit, or udev rule (shown in their sections).

---

## 1. Memory & overcommit

### Background: what memory overcommit is

Linux hands out **more memory than physically exists**, betting that processes won't actually use everything they ask for. When a program allocates (e.g. `malloc`), it gets *virtual* address space — a promise — and the kernel only maps real RAM when the program **touches** (writes to) a page. Because programs routinely reserve far more than they use (sparse allocations, `fork()` with copy-on-write, large arenas left mostly untouched), the kernel can safely "oversell" memory — much like an airline overbooking seats expecting no-shows.

**The risk — the OOM killer:** the bet fails when processes really do touch more memory than physically exists. The kernel can't conjure RAM, so it invokes the **OOM (Out-Of-Memory) killer**, which picks a process and kills it to reclaim memory. For PostgreSQL this is dangerous: the OOM killer tends to target a high-memory process and may kill the **postmaster** (the parent process) — which drops every connection and takes the **entire instance** down, looking like a crash.

---

### `vm.overcommit_memory`

**What it is:** the policy that decides whether the kernel grants a memory allocation. Three modes:
- `0` — **heuristic** (default): the kernel guesses whether an allocation is "reasonable" and allows modest overcommit. Can still summon the OOM killer.
- `1` — **always overcommit**: never refuses an allocation. Dangerous for general use.
- `2` — **never overcommit**: total allocations are capped (see `overcommit_ratio`); past the cap, allocations **fail cleanly** with an error instead of risking the OOM killer.

**Why `2` for Postgres:** when memory runs out, the *offending* backend gets an "out of memory" error and that one query aborts — but **the postmaster and the rest of the instance survive**. You trade one failed query for protecting the whole database, converting a catastrophic, random kill into a contained, predictable error. Exactly what you want on a 24×7 critical database.

> **Caveat:** mode `2` only helps if your *normal* working set fits under the cap. Size `shared_buffers`, `work_mem × peak connections`, and `maintenance_work_mem` deliberately, or you'll hit allocation failures during ordinary operation. The cap protects you from runaways; it doesn't excuse undersizing RAM.

**Recommended:** `2`

**How to set:**
```bash
sudo sysctl -w vm.overcommit_memory=2
echo 'vm.overcommit_memory = 2' | sudo tee -a /etc/sysctl.d/30-postgresql.conf
```

---

### `vm.overcommit_ratio`

**What it is:** when in mode `2`, this sets the size of the memory cap (the **CommitLimit**):

```
CommitLimit = swap + (overcommit_ratio% × RAM)
```

Once the sum of all allocations would exceed this, the next allocation fails. The default of `50` is far too conservative for a dedicated DB box (it would cap usable memory at ~half of RAM, leaving lots idle). Raise it — but **never to 100%**: the kernel itself, the **OS page cache** (which Postgres relies on, and which `effective_cache_size` assumes exists), and bursty allocations (connection spikes, several `work_mem` sorts at once, an autovacuum worker) all need the headroom. The `100% − ratio%` slice is your safety margin.

**Example** (64GB RAM, 4GB swap):

| `overcommit_ratio` | CommitLimit | Verdict |
|--------------------|-------------|---------|
| `50` (default) | 4 + 0.50×64 = **36GB** | too conservative; wastes ~28GB |
| `80` | 4 + 0.80×64 = **55.2GB** | sensible; leaves headroom for kernel + cache |
| `90` | 4 + 0.90×64 = **61.6GB** | aggressive; only on a tightly-profiled box |
| `100` | 4 + 1.00×64 = **68GB** | **never** — no room for page cache / kernel / bursts |

**Recommended:** `80`–`90` (with minimal swap and deliberately-sized memory)

**How to set:**
```bash
sudo sysctl -w vm.overcommit_ratio=80
echo 'vm.overcommit_ratio = 80' | sudo tee -a /etc/sysctl.d/30-postgresql.conf

# Verify the resulting limit and current usage:
grep -E 'Commit' /proc/meminfo
#   CommitLimit:  the computed cap (swap + ratio% of RAM)
#   Committed_AS: how much is currently promised — watch this vs CommitLimit
```

> There's also `vm.overcommit_kbytes` to express the RAM portion as an absolute value instead of a percentage (setting one zeroes the other). The ratio form is what almost everyone uses.

---

### `vm.swappiness`

**What it is:** a `0`–`100` bias controlling **how aggressively the kernel swaps anonymous memory (process heap/stack) to disk** versus reclaiming **page cache** (file-backed pages) when memory is tight. Higher = more willing to swap process memory; lower = prefer dropping reclaimable cache and keep process memory in RAM.

**Why low for Postgres:** `shared_buffers` and backend working memory are anonymous pages. If they get swapped out, every access becomes a slow **disk read instead of a RAM hit** — causing unpredictable latency spikes, exactly the jitter a 24×7 service must avoid.

**Why `1` and not `0`:** on modern kernels `0` more aggressively disables swapping, which can **trigger the OOM killer sooner** because the kernel won't use swap even as an emergency relief valve. `1` means "swap as little as possible, but still allow it as a last resort" — virtually all the benefit, without slamming the emergency exit shut. (Keep a **small swap** configured as that relief valve; don't remove swap entirely.)

**Recommended:** `1`

**How to set:**
```bash
sudo sysctl -w vm.swappiness=1
echo 'vm.swappiness = 1' | sudo tee -a /etc/sysctl.d/30-postgresql.conf

# Check whether anything is actually swapped:
free -h            # look at the Swap row
```

---

### Transparent Huge Pages (THP)

**What it is:** a kernel feature that automatically backs memory with 2MB "huge" pages and **defragments** memory in the background to form them. For databases, that background defrag (`khugepaged`) causes **unpredictable latency stalls**. PostgreSQL explicitly recommends disabling THP. (This is distinct from *explicit* huge pages below.)

**Recommended:** **disabled** (`never`) for both `enabled` and `defrag`

**How to set:**
```bash
# Live (lost on reboot):
echo never | sudo tee /sys/kernel/mm/transparent_hugepage/enabled
echo never | sudo tee /sys/kernel/mm/transparent_hugepage/defrag
```
Persist via a `tuned` profile (`[vm] transparent_hugepages=never`), a `systemd` unit, GRUB (`transparent_hugepage=never` kernel arg), or an Ansible task. Verify: `cat /sys/kernel/mm/transparent_hugepage/enabled` should show `[never]`.

---

### Explicit Huge Pages

**What it is:** *manually pre-allocated* 2MB pages (not the automatic THP). Backing `shared_buffers` with huge pages shrinks the CPU's page tables, so address translation is faster and uses less memory — a real win for large `shared_buffers`. Pair with `huge_pages = try` (or `on`) in `postgresql.conf`.

**Recommended:** size `vm.nr_hugepages` to cover `shared_buffers` (plus a little headroom)

**How to set:**
```bash
# Rough sizing: pages needed ≈ shared_buffers / 2MB. PG can tell you exactly:
#   postgres=# SHOW shared_memory_size_in_huge_pages;   (PG15+)
sudo sysctl -w vm.nr_hugepages=NNNN
echo 'vm.nr_hugepages = NNNN' | sudo tee -a /etc/sysctl.d/30-postgresql.conf
```
Then set `huge_pages = try` in `postgresql.conf` and restart Postgres. (`try` falls back gracefully if not enough huge pages are available; `on` refuses to start without them.)

---

## 2. Dirty page writeback (smooths I/O, avoids checkpoint stalls)

### Background

When Postgres (or anything) writes, the data first lands in the kernel's **page cache** as a "dirty" page — modified in RAM but not yet on disk. The kernel decides *when* to flush those dirty pages to storage. Four sysctls set the thresholds, as **two pairs controlling the same two thresholds** — one in **bytes**, one as a **percentage of available memory**. Pick *one* unit per threshold; setting the `_bytes` form non-zero zeroes its `_ratio` counterpart (whichever you set last wins).

The two thresholds, low to high:
1. **Background threshold** → kernel flusher threads **start writing in the background** (non-blocking). `vm.dirty_background_ratio` *or* `vm.dirty_background_bytes`.
2. **Hard (foreground) threshold** → the writing process is **forced to block** and flush synchronously — a latency cliff. `vm.dirty_ratio` *or* `vm.dirty_bytes`.

**Ratio vs bytes:** the `_ratio` forms scale with RAM, so on a big-memory host they permit a huge amount of dirty data (e.g. 256GB × default `dirty_ratio=20` ≈ 51GB) that then dumps all at once, colliding with Postgres checkpoints into an **I/O write storm**. On **large-RAM hosts prefer the `_bytes` forms** for a fixed, predictable, small-and-frequent flush. Always keep the background threshold well below the hard one (~1:2).

---

### `vm.dirty_background_ratio` / `vm.dirty_background_bytes`

**What it is:** the **background** flush threshold — how much dirty data may accumulate before flusher threads start writing it out in the background (applications keep running). `_ratio` is a percentage of memory; `_bytes` is an absolute amount.

**Recommended:** `vm.dirty_background_ratio = 5` (default `10`) on standard hosts; or `vm.dirty_background_bytes = 67108864` (64MB) on large-RAM hosts.

**How to set:**
```bash
# Ratio form (standard hosts):
sudo sysctl -w vm.dirty_background_ratio=5
# Bytes form (large-RAM hosts) — this zeroes vm.dirty_background_ratio:
sudo sysctl -w vm.dirty_background_bytes=67108864
```

---

### `vm.dirty_ratio` / `vm.dirty_bytes`

**What it is:** the **hard** threshold — once dirty data hits it, writing processes are forced to block and flush synchronously until back under the line. Must be **higher** than the background threshold. `_ratio` is a percentage of memory; `_bytes` is absolute.

**Recommended:** `vm.dirty_ratio = 10` (default `20`) on standard hosts; or `vm.dirty_bytes = 536870912` (512MB) on large-RAM hosts.

**How to set:**
```bash
# Ratio form:
sudo sysctl -w vm.dirty_ratio=10
# Bytes form (large-RAM hosts) — this zeroes vm.dirty_ratio:
sudo sysctl -w vm.dirty_bytes=536870912

# Persist whichever pair you chose in /etc/sysctl.d/30-postgresql.conf, then:
sudo sysctl --system
# Verify:
sysctl vm.dirty_background_ratio vm.dirty_ratio vm.dirty_background_bytes vm.dirty_bytes
```

---

## 3. Storage & filesystem

These are set at provisioning/mount time, not via sysctl.

### Filesystem choice
**What it is:** the filesystem under `PGDATA`. **Recommended:** `ext4` or `xfs` (both well-tested for Postgres); **avoid network filesystems (NFS)** for `PGDATA`. **How to set:** choose at volume creation (`mkfs.xfs` / `mkfs.ext4`).

### Mount option `noatime`
**What it is:** by default the FS writes an access timestamp on every file read; `noatime` disables that, removing pointless write I/O on reads. **Recommended:** enabled. **How to set:** add `noatime` to the mount options in `/etc/fstab`, then remount:
```
/dev/nvme1n1  /var/lib/pgsql  xfs  defaults,noatime  0 0
```

### Separate volumes for data / WAL
**What it is:** putting `PGDATA` and `pg_wal` on **separate block devices** isolates sequential WAL writes from random data I/O so they don't contend. **Recommended:** separate volumes for data and WAL (and optionally temp). **How to set:** mount a second device and point `pg_wal` at it (symlink or `initdb --waldir`).

### I/O scheduler
**What it is:** the kernel's disk request scheduler. On fast storage the simplest scheduler is best. **Recommended:** `none`/`noop` for NVMe, `mq-deadline` for SSD; avoid `cfq`. **How to set:**
```bash
echo none | sudo tee /sys/block/nvme0n1/queue/scheduler   # persist via udev rule
```

### Reliable `fsync` / write caches
**What it is:** Postgres relies on `fsync` truly persisting data; volatile (non-battery/capacitor-backed) disk write caches can lie about writes and corrupt the DB on power loss. **Recommended:** disable volatile write caches; use battery-/capacitor-backed cache only. **How to set:** controller/`hdparm` settings per hardware; use **RAID10** with a battery-backed write cache for write-heavy workloads.

---

## 4. CPU, NUMA, scheduling

### CPU frequency governor
**What it is:** the policy that scales CPU clock speed. Power-saving governors ramp up lazily, adding latency to bursty DB work. **Recommended:** `performance`. **How to set:**
```bash
sudo cpupower frequency-set -g performance
# or: echo performance | sudo tee /sys/devices/system/cpu/cpu*/cpufreq/scaling_governor
```

### NUMA memory placement
**What it is:** on multi-socket (NUMA) servers, accessing memory on a remote node is slower; an unbalanced layout can hurt and even cause "zone reclaim" stalls. **Recommended:** test interleaving memory across nodes for the postmaster. **How to set:** start Postgres under `numactl --interleave=all` (via the service unit), and consider `vm.zone_reclaim_mode=0`.

---

## 5. Limits, network & misc

### File descriptors (`LimitNOFILE`)
**What it is:** Postgres opens many files (relations, sockets); too low a limit causes "too many open files" errors. **Recommended:** `65535`+. **How to set:** in the systemd unit (`LimitNOFILE=65535`) or `/etc/security/limits.conf`.

### `net.core.somaxconn`
**What it is:** maximum length of the queue of pending incoming connections; too low and connection bursts get dropped. **Recommended:** `1024`+. **How to set:** `sudo sysctl -w net.core.somaxconn=1024` (persist in `/etc/sysctl.d/`).

### TCP keepalives (`net.ipv4.tcp_keepalive_time`)
**What it is:** how long before the kernel probes an idle TCP connection, used to detect and clean up dead client/replica peers. **Recommended:** tune down from the default (e.g. `300`). **How to set:** `sudo sysctl -w net.ipv4.tcp_keepalive_time=300` (persist in `/etc/sysctl.d/`).

### Time synchronization
**What it is:** accurate clocks are essential for replication ordering and correlating logs across hosts. **Recommended:** run `chrony` (or NTP). **How to set:** `sudo systemctl enable --now chronyd`.

### `PGDATA` permissions & host security
**What it is:** the data directory must be private; the host should be locked down. **Recommended:** `PGDATA` mode `0700` owned by `postgres`; firewall the port; SELinux/AppArmor in enforcing mode. **How to set:** `chmod 0700`/`chown postgres` (initdb does this), plus your firewall/MAC tooling.

> **Note:** modern PostgreSQL (9.3+) uses `mmap` for shared memory, so the legacy `kernel.shmmax`/`kernel.shmall` tuning is no longer needed — *unless* you force `huge_pages`.

---

## Putting it together — a starter `/etc/sysctl.d/30-postgresql.conf`

```ini
# Memory / OOM protection
vm.overcommit_memory = 2
vm.overcommit_ratio  = 80
vm.swappiness        = 1

# Dirty page writeback (large-RAM host: byte-based)
vm.dirty_background_bytes = 67108864     # 64MB
vm.dirty_bytes            = 536870912    # 512MB

# Network
net.core.somaxconn          = 1024
net.ipv4.tcp_keepalive_time = 300
```
Apply with `sudo sysctl --system`. Handle THP, the I/O scheduler, CPU governor, `LimitNOFILE`, and mount options separately (tuned/systemd/udev/fstab) as shown above — and manage the whole lot as code with Ansible.

---

## Mapping to the interview

- *"Why set `vm.overcommit_memory=2`?"* → so an out-of-memory condition fails one allocation cleanly instead of the OOM killer killing the postmaster and downing the instance.
- *"Why `swappiness=1`, not `0`?"* → `1` minimizes swapping but keeps swap as an emergency relief valve; `0` can trigger the OOM killer sooner.
- *"Why not `overcommit_ratio=100`?"* → the OS page cache, kernel, and bursty allocations need headroom; 100% starves them and kills cache-dependent performance.
- *"Why disable THP?"* → background defrag causes unpredictable latency stalls; PG recommends against it (explicit huge pages are fine and beneficial).
- *"Why byte-based dirty thresholds on big-RAM hosts?"* → ratio-of-RAM lets tens of GB of dirty data accumulate, then dumps as an I/O storm at checkpoint time.
