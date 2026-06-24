# PostgreSQL Best-Practice Configuration

A checklist of what to tune at the **Linux host** level and in the **PostgreSQL** server for a production-grade deployment. Defaults ship conservative — these are the knobs that matter most. Each entry says **what it does** and **where you set it**.

**See also:** [wal-and-checkpoints.md](wal-and-checkpoints.md) (checkpoint sizing) · [deep-dive.md](deep-dive.md) §2 (memory/planner), §4 (security) · [performance-analysis.md](performance-analysis.md) · [../scripts/settings.sql](../scripts/settings.sql) (audit current values)

> **Golden rule:** change one thing, measure, repeat. Use `databases/scripts/settings.sql` to see current values, their `source`, and whether they need a restart.

---

## Part 1 — Linux host level

**Where these live:** almost all are **kernel parameters (sysctl)**. View one with `sysctl vm.swappiness`, set it live with `sysctl -w vm.swappiness=1`, and make it **persistent** by adding it to `/etc/sysctl.conf` or a file in `/etc/sysctl.d/*.conf`, then applying with `sudo sysctl --system`. The THP and I/O-scheduler knobs live under `/sys/...` and are best persisted via a `tuned` profile, `systemd`, or a udev rule.

### Memory & overcommit
| Setting | Recommended | What it does & where |
|---------|-------------|----------------------|
| `vm.overcommit_memory` | `2` | **sysctl.** Controls how the kernel hands out memory. `0` (default) lets the kernel guess and can summon the **OOM killer** — which may kill the postmaster and take the whole instance down. `2` = "no overcommit": allocations beyond the limit fail cleanly, so a runaway query errors instead of the server being killed. |
| `vm.overcommit_ratio` | `80`–`90` (little/no swap) | **sysctl.** Only used when `overcommit_memory=2`. Committable memory = `swap + ratio% of RAM`. Set high when you've sized memory deliberately and run minimal swap. |
| `vm.swappiness` | `1` (range `0`–`10`) | **sysctl.** How eagerly the kernel swaps RAM to disk. Low keeps PostgreSQL's shared buffers and page cache in RAM; high would swap out hot cache and tank latency. |
| Transparent Huge Pages (THP) | **disabled** (`never`) | **`/sys/kernel/mm/transparent_hugepage/{enabled,defrag}`.** THP's background defrag causes unpredictable latency stalls in databases. Disable it (PostgreSQL recommends against THP). |
| Explicit Huge Pages | size to cover `shared_buffers` | **`vm.nr_hugepages` sysctl.** Pre-allocates large (2MB) memory pages so the CPU's page tables are smaller and faster to walk. Pair with `huge_pages=try`/`on` in PostgreSQL. |

```bash
# Disable THP at runtime (persist via tuned/grub/systemd)
echo never > /sys/kernel/mm/transparent_hugepage/enabled
echo never > /sys/kernel/mm/transparent_hugepage/defrag
```

### Dirty page writeback (smooths I/O, avoids checkpoint stalls)

**The concept:** when Postgres (or anything) writes, the data first lands in the kernel's **page cache** as a "dirty" page — modified in RAM but not yet on disk. The kernel decides *when* to flush those dirty pages down to storage. These four sysctls set the thresholds. There are **two pairs that control the same two thresholds** — one expressed in **bytes**, one as a **percentage of available memory**. You pick *one* unit per threshold; setting the `_bytes` form to non-zero disables its `_ratio` counterpart, and vice-versa (whichever you set last wins, and reading the other back shows `0`).

The two thresholds, low to high:

1. **Background threshold** — when dirty data crosses this, the kernel's flusher threads **start writing in the background**. Applications keep running normally. → `vm.dirty_background_bytes` *or* `vm.dirty_background_ratio`.
2. **Hard (foreground) threshold** — when dirty data crosses this, the kernel **forces the writing process itself to block** and flush synchronously until it's back under the line. This is a latency cliff you want to avoid hitting. → `vm.dirty_bytes` *or* `vm.dirty_ratio`.

| Setting | Recommended | What it does & where |
|---------|-------------|----------------------|
| `vm.dirty_background_ratio` | `5` (default `10`) | **sysctl.** Background threshold as a **percentage of available memory**. At this much dirty data, flusher threads start writing in the background (non-blocking). Default `10%` of RAM can be a lot of unflushed data on a big-memory host. |
| `vm.dirty_ratio` | `10` (default `20`) | **sysctl.** Hard threshold as a **percentage of available memory**. Once dirty data hits this, writers are **forced to block** and flush synchronously — a stall. Must be **higher** than `dirty_background_ratio`. |
| `vm.dirty_background_bytes` | e.g. `67108864` (64MB) | **sysctl.** Same background threshold, but as an **absolute byte count** instead of a percentage. Lower = flush early and often, so writeback is gentle. Setting this zeroes `dirty_background_ratio`. |
| `vm.dirty_bytes` | e.g. `536870912` (512MB) | **sysctl.** Same hard ceiling, as an **absolute byte count**. Once hit, processes block and write synchronously. Keep it above the background threshold but bounded. Setting this zeroes `dirty_ratio`. |

**Ratio vs bytes — which to use:**
- The **`_ratio`** variants are a percentage of memory, so the *actual* dirty-data limit scales (often surprisingly large) with RAM. On a 256GB host the default `dirty_ratio = 20` permits ~51GB of dirty pages to accumulate before a forced flush — which then dumps to disk all at once, colliding with Postgres checkpoints to produce an **I/O write storm** and latency spikes.
- The **`_bytes`** variants pin the threshold to a fixed, predictable amount regardless of RAM, so on **large-RAM hosts prefer `_bytes`** to keep writeback small and frequent. On smaller/standardized hosts the `_ratio` form is simpler and fine.
- Whichever pair you choose, keep the **background threshold well below the hard threshold** (e.g. ~1:2) so the kernel starts flushing gently long before any process is forced to block. The goal is steady trickle-flush, never a sudden synchronous dump.

```bash
# View current values
sysctl vm.dirty_background_ratio vm.dirty_ratio vm.dirty_background_bytes vm.dirty_bytes

# Example: large-RAM host — switch to byte-based thresholds (persist in /etc/sysctl.d/)
sysctl -w vm.dirty_background_bytes=67108864    # 64MB  → starts background flush
sysctl -w vm.dirty_bytes=536870912              # 512MB → forced synchronous flush
# (these two automatically set vm.dirty_background_ratio and vm.dirty_ratio to 0)
```

### Storage & filesystem
- **Filesystem:** `ext4` or `xfs` (both well-tested for PG). Avoid network filesystems (NFS) for `PGDATA`.
- **Mount option `noatime`** (in `/etc/fstab`): stops the FS from writing an access timestamp on every read.
- **Separate block devices/volumes** for data (`PGDATA`), WAL (`pg_wal`), and optionally temp — isolates sequential WAL writes from random data I/O.
- **I/O scheduler** (`/sys/block/<dev>/queue/scheduler`): `none`/`noop` for NVMe, `mq-deadline` for SSD; avoid `cfq`.
- Ensure **reliable `fsync`** — disable volatile disk write caches that aren't battery/capacitor-backed, or a power loss can corrupt the database.
- **RAID10** for write-heavy workloads; use a controller with a battery-backed write cache.

### CPU, NUMA, scheduling
- **CPU governor = `performance`** (set via `cpupower` or `/sys/devices/system/cpu/.../scaling_governor`): avoids the latency of frequency ramp-up.
- On NUMA servers, cross-node memory access is slower; test `numactl --interleave=all` for the postmaster to spread memory evenly.

### Limits, network, misc
| Area | Recommended | What it does & where |
|------|-------------|----------------------|
| File descriptors | `LimitNOFILE=65535`+ | **systemd unit / `/etc/security/limits.conf`.** PG opens many files (relations, sockets); too low a limit causes "too many open files" errors. |
| `net.core.somaxconn` | `1024`+ | **sysctl.** Max queued incoming connections; raise so connection bursts aren't dropped. |
| TCP keepalives | tune `net.ipv4.tcp_keepalive_time` | **sysctl.** Detects dead client/replica peers so their connections get cleaned up. |
| Time sync | run `chrony`/NTP | **service.** Accurate clocks are essential for replication ordering and correlating logs across hosts. |
| Security | `PGDATA` mode `0700`, owned by `postgres` | **filesystem perms.** Plus firewall the port and run SELinux/AppArmor in enforcing mode. |

> Note: modern PostgreSQL (9.3+) uses `mmap` for shared memory, so the legacy `kernel.shmmax`/`kernel.shmall` sysctl tuning is no longer needed — unless you force `huge_pages`.

---

## Part 2 — PostgreSQL server

**Where these live:** in `postgresql.conf`, or set them at runtime with `ALTER SYSTEM SET ... ;` (which writes to `postgresql.auto.conf`). After changing, either `SELECT pg_reload_conf();` (for "reloadable" params) or restart (for ones marked `postmaster`). Check any value and how to apply it with the query in the last section.

### Memory
| Parameter | Recommended | What it does |
|-----------|-------------|--------------|
| `shared_buffers` | ~25% of RAM | PostgreSQL's **own** cache of table/index pages. The single most important memory setting. Don't exceed ~40% — the OS page cache also caches data, and double-buffering wastes RAM. (Requires restart.) |
| `effective_cache_size` | 50–75% of RAM | **Not an allocation** — it's a *hint* to the planner about how much data is likely cached (in `shared_buffers` + OS cache). Higher values make the planner favor **index scans** over sequential scans, because it assumes pages will be found in memory. |
| `work_mem` | 16–64MB | Memory for **one** sort or hash operation. It's **per node, per connection** — a complex query with many sorts × many connections can multiply this fast, so size it against peak concurrency, not just available RAM. Too low → sorts spill to disk (`external merge`). |
| `maintenance_work_mem` | 512MB–2GB | Memory for maintenance ops (VACUUM, CREATE INDEX, restores). Larger = faster index builds and vacuums. Only a few run at once, so it can be much bigger than `work_mem`. |
| `autovacuum_work_mem` | inherit or set | Like `maintenance_work_mem` but caps memory **per autovacuum worker**, so many workers don't collectively exhaust RAM. |
| `huge_pages` | `try` (or `on` once host configured) | Tells PG to back `shared_buffers` with the host's huge pages, reducing page-table overhead. `try` = use if available, else fall back. |

### WAL & checkpoints  ([details](wal-and-checkpoints.md))
| Parameter | Recommended | What it does |
|-----------|-------------|--------------|
| `wal_level` | `replica` (or `logical` for logical repl/CDC) | How much info is written to WAL. `replica` supports streaming replicas + PITR; `logical` additionally enables logical decoding. |
| `max_wal_size` | large enough that checkpoints are time-triggered | Soft cap on WAL between checkpoints. If WAL fills this before the timeout, a checkpoint is **forced** (`checkpoints_req` rises) — raise it until forced checkpoints ≈ 0. |
| `min_wal_size` | `1`–`2GB` | Floor of WAL files PG keeps and recycles instead of deleting, avoiding churn during bursts. |
| `checkpoint_timeout` | `15min` (`30min` write-heavy) | Max time between automatic checkpoints. Longer = fewer checkpoints and fewer full-page image writes, but longer crash recovery. |
| `checkpoint_completion_target` | `0.9` | Spreads a checkpoint's writes across 90% of the interval instead of dumping them at once — smooths the I/O spike. |
| `wal_compression` | `on` | Compresses full-page images in WAL — less WAL volume for a little CPU. |
| `wal_buffers` | `16MB` (or `-1` = auto) | Shared memory buffering WAL before it's flushed to disk. |

### Durability (don't disable in production)
| Parameter | Recommended | What it does |
|-----------|-------------|--------------|
| `fsync` | `on` | Forces WAL/data to physically reach disk. **Never turn off in production** — off means a crash can leave a corrupted, unrecoverable database. |
| `full_page_writes` | `on` | Writes a full image of a page the first time it changes after a checkpoint, protecting against **torn pages** (partial writes on crash). |
| `synchronous_commit` | `on` | Whether `COMMIT` waits for WAL to be durably flushed. `on` = no data loss on crash. Can be relaxed to `off`/`local` (or per-transaction) on hot paths if you accept losing the last fraction of a second of commits. |

### Autovacuum (keep it aggressive at scale)
| Parameter | Recommended | What it does |
|-----------|-------------|--------------|
| `autovacuum` | `on` | Background process that reclaims dead tuples (bloat) and refreshes planner stats. Never disable globally. |
| `autovacuum_max_workers` | `3`–`6` | How many tables can be vacuumed concurrently. Raise it when you have many tables. |
| `autovacuum_vacuum_scale_factor` | `0.05` (lower for big tables) | Vacuum triggers at `threshold + scale_factor × rows`. Default `0.2` (20%) means a 1B-row table waits for 200M dead rows — far too long. Override per-table for large tables. |
| `autovacuum_analyze_scale_factor` | `0.02`–`0.05` | Same idea for ANALYZE — keeps planner statistics fresh so row estimates stay accurate. |
| `autovacuum_vacuum_cost_limit` | raise (e.g. `2000`) | Autovacuum throttles itself with a cost budget; the gentle default lets it fall behind on busy systems. Raise to let it keep up. |
| `autovacuum_naptime` | `15s`–`30s` | How often the launcher checks whether tables need work. |
| Freeze params (`autovacuum_freeze_max_age`, …) | tune for high-XID workloads | Govern transaction-ID **freezing** to prevent wraparound. See [deep-dive.md](deep-dive.md) §1.3. |

### Planner
| Parameter | Recommended | What it does |
|-----------|-------------|--------------|
| `random_page_cost` | `1.1` on SSD/NVMe | The planner's estimated cost of a **random** page read relative to a sequential one. The default `4.0` assumes spinning disks and discourages index use; on SSD random reads are nearly as cheap as sequential, so lower it to favor index scans. |
| `effective_io_concurrency` | `200` for SSD/NVMe | How many concurrent I/O requests the storage can handle; enables prefetching for bitmap heap scans. |
| `default_statistics_target` | `100` (raise to `500`+ for skewed columns) | How many histogram buckets / distinct values ANALYZE collects per column. More detail = better selectivity estimates, at the cost of slightly slower ANALYZE and bigger stats. |
| `jit` | `off` for OLTP, `on` for analytics | Just-in-time compilation of expressions. Helps long analytical queries; its compile overhead hurts short OLTP queries. |

### Connections (cap them; pool instead)
| Parameter | Recommended | What it does |
|-----------|-------------|--------------|
| `max_connections` | `100`–`200` + **PgBouncer** | Hard cap on backends. Each connection is a process with RAM overhead; raising this is worse than putting a connection pooler (PgBouncer) in front. (Requires restart.) |
| `idle_in_transaction_session_timeout` | `5min` | Auto-terminates sessions stuck "idle in transaction" — those pin the xmin horizon (blocking vacuum) and may hold locks. |
| `statement_timeout` | `30s`–`60s` (per app) | Aborts any single query running longer than this — a safety net against runaway queries. |
| `lock_timeout` | `5s` | Gives up waiting for a lock after this long, so a blocked statement fails fast instead of stalling indefinitely. |
| `tcp_keepalives_idle` / `_interval` | set | Lets PG detect and clean up dead client connections. |

### Logging & observability (turn these on early)
| Parameter | Recommended | What it does |
|-----------|-------------|--------------|
| `logging_collector` | `on` | Captures stderr into managed log files. |
| `log_min_duration_statement` | `1000` (1s) | Logs any statement slower than this — your slow-query feed. |
| `log_checkpoints` | `on` | Logs each checkpoint's timing and buffers written — shows if checkpoints are too frequent. |
| `log_lock_waits` | `on` | Logs when a session waits past `deadlock_timeout` for a lock — surfaces contention. |
| `log_temp_files` | `0` | Logs every temp file written (i.e. `work_mem` spills to disk). |
| `log_autovacuum_min_duration` | `0` or `250ms` | Logs autovacuum runs so you can see if it keeps up. |
| `log_line_prefix` | `'%m [%p] %q%u@%d '` | Prefix on each log line: timestamp, pid, user, database — essential context. |
| `track_io_timing` | `on` | Records real time spent on I/O, shown in `EXPLAIN (ANALYZE, BUFFERS)` and `pg_stat_statements`. |
| `shared_preload_libraries` | `pg_stat_statements` (+ `auto_explain`) | Loads extensions at startup. `pg_stat_statements` aggregates query stats. (Requires restart.) |

### Replication (if applicable) ([details](ha-and-dr.md))
| Parameter | Recommended | What it does |
|-----------|-------------|--------------|
| `max_wal_senders` | `10` | Max concurrent WAL-sender processes (one per streaming replica or base backup). |
| `max_replication_slots` | `10` | Max replication slots (one per standby/subscriber) that track how far each consumer has read. |
| `hot_standby` | `on` | Allows read-only queries on a standby while it replays WAL. |
| `max_slot_wal_keep_size` | bound it | Caps how much WAL an inactive slot can pin — prevents a dead replica's slot from filling `pg_wal` and stopping the primary. |
| `archive_mode` + `archive_command` | `on` + pgBackRest/WAL-G | Ships completed WAL segments to archive storage — required for Point-In-Time Recovery. |

### Security essentials ([details](deep-dive.md) §4)
| Setting | Recommended | What it does |
|---------|-------------|--------------|
| `listen_addresses` | only needed interfaces | Which network interfaces PG binds to; don't expose `*` unless intended. |
| `password_encryption` | `scram-sha-256` | Hashing scheme for stored passwords; SCRAM is the modern, secure choice over `md5`. |
| `pg_hba.conf` | `scram-sha-256` + least-privilege host rules | The client authentication rulebook (who, from where, how). Never use `trust` over a network. |
| `ssl` | `on` with valid certs | Encrypts client↔server traffic in transit. |

---

## Applying & verifying changes

```sql
-- Most params: persists to postgresql.auto.conf
ALTER SYSTEM SET random_page_cost = 1.1;
SELECT pg_reload_conf();           -- for 'sighup' context params

-- Check what needs a restart vs reload, and where a value came from:
SELECT name, setting, unit, source, context, pending_restart
FROM pg_settings
WHERE name IN ('shared_buffers','random_page_cost','max_connections');
```

The `context` column tells you **how a change takes effect**:
- `postmaster` → **requires a full restart** (e.g. `shared_buffers`, `max_connections`, `shared_preload_libraries`).
- `sighup` → a reload is enough (`SELECT pg_reload_conf();` or `pg_ctl reload`).
- `superuser` / `user` → can be set per-session (`SET ...`) or per-role/per-database (`ALTER ROLE/DATABASE ... SET ...`).

The `source` column tells you **where the current value came from** (`default`, `configuration file`, `override`, etc.). Audit everything non-default with the **"Settings changed from default"** query in [../scripts/settings.sql](../scripts/settings.sql).

## Sizing & validation tools
- **PGTune** / **pgconfig** — generate sane starting values from RAM, CPU count, and workload type.
- **pgbench** — load-test before/after a change to confirm it actually helped.
- **`pg_stat_statements`** + [scripts/](../scripts/) — measure the real effect; never tune by guessing.
