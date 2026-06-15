# PostgreSQL Deep Dive — DBRE Interview Prep

Four core areas for a Senior Database Reliability Engineer role:

1. [Core Internal Concepts](#1-core-internal-concepts) — MVCC, WAL, vacuum, bloat, the planner
2. [Advanced Performance Tuning](#2-advanced-performance-tuning)
3. [Architecture, HA & Scaling](#3-architecture-ha--scaling)
4. [Security](#4-security)

Each topic follows: **what it is → what goes wrong → how to monitor → how to fix.**

---

# 1. Core Internal Concepts

## 1.1 MVCC (Multi-Version Concurrency Control)

### What it is
PostgreSQL never updates a row in place. Every `UPDATE` or `DELETE` creates a **new row version (tuple)** and marks the old one as expired. Readers see a **snapshot** of the data as of their transaction start, so **readers never block writers and writers never block readers**.

Each tuple carries hidden system columns:

| Column | Meaning |
|--------|---------|
| `xmin` | Transaction ID (XID) that **created** this tuple |
| `xmax` | XID that **deleted/expired** this tuple (0 if live) |
| `ctid` | Physical location (page, offset) of the tuple |

A tuple is visible to your transaction if `xmin` is committed and ≤ your snapshot, and `xmax` is either empty or not yet committed.

```sql
SELECT xmin, xmax, ctid, * FROM customers WHERE id = 42;
```

### `xmax` is not always a deletion (and not a live lock)
A **visible** row can show a non-zero `xmax`. `xmax` doubles as a **row-lock marker**, not just a deleter XID:

- A **foreign-key insert** on a child row takes a `FOR KEY SHARE` lock on the parent row, stamping the parent's `xmax`. `SELECT … FOR UPDATE/SHARE` does the same.
- The **infomask** bits (e.g. `HEAP_XMAX_LOCK_ONLY`) tell the visibility check it's a lock, so the row stays alive.

A set `xmax` does **not** mean a lock is currently held. Row locks live in shared memory and are released when the transaction ends; Postgres does **not** eagerly clear `xmax` on commit. So the value lingers as a stale physical marker, resolved lazily at read time and only physically cleared later by **freezing**.

- Check live locks with `pg_locks`, **not** `xmax`.
- Plain `VACUUM` won't clear it on a **live, young** tuple — freezing is gated by `vacuum_freeze_min_age` (default 50M XIDs). Force it with `VACUUM (FREEZE) <table>;`.
- The `xmax` system column shows the **raw** header field; it ignores infomask, so it can still display an old XID even after the lock is logically invalid.

### What goes wrong
- **Dead tuples accumulate** — old versions left behind by UPDATE/DELETE. Until vacuumed, they sit in the table consuming space → **bloat**.
- **Transaction ID wraparound** — XIDs are 32-bit (~4 billion). If old tuples aren't "frozen" before the XID counter wraps, Postgres would see future data as past → catastrophic. Postgres force-shuts down to prevent this.
- **Long-running transactions** — hold back the "xmin horizon," preventing vacuum from cleaning *any* dead tuple newer than that transaction. One idle transaction can bloat the whole DB.

### How to monitor
```sql
-- Dead tuples per table
SELECT relname, n_live_tup, n_dead_tup,
       round(100.0 * n_dead_tup / nullif(n_live_tup + n_dead_tup,0), 2) AS dead_pct
FROM pg_stat_user_tables ORDER BY n_dead_tup DESC;

-- Oldest transaction (wraparound risk) — age in XIDs
SELECT datname, age(datfrozenxid) AS xid_age
FROM pg_database ORDER BY xid_age DESC;

-- Long-running / idle-in-transaction sessions (block vacuum)
SELECT pid, state, now() - xact_start AS xact_age, left(query,80)
FROM pg_stat_activity
WHERE state != 'idle'
ORDER BY xact_age DESC;
```
Wraparound danger zone: `xid_age` approaching `autovacuum_freeze_max_age` (default 200M). Alert well before 1–1.5 billion.

### How to fix
- Keep autovacuum healthy and aggressive (see 1.3).
- Kill or fix **idle-in-transaction** sessions; set `idle_in_transaction_session_timeout`.
- For wraparound emergencies: `VACUUM (FREEZE)` the oldest tables.
- Keep transactions short; don't leave them open during app think-time.

### When does freezing happen automatically?
Freezing marks old tuples as "permanently visible to everyone" so their `xmin` no longer matters — this is what prevents XID wraparound. Key parameters:

| Parameter | Default | Role |
|-----------|---------|------|
| `vacuum_freeze_min_age` | 50M | A tuple's XID must be this old before a vacuum freezes it |
| `vacuum_freeze_table_age` | 150M | Table age past this → next vacuum becomes an **aggressive** full scan |
| `autovacuum_freeze_max_age` | 200M | Hard limit → forces an **anti-wraparound autovacuum** even if autovacuum is off |

Three ways it triggers automatically:

1. **Piggyback on a normal autovacuum** — when autovacuum runs (dead-tuple threshold), it also freezes any tuple older than `vacuum_freeze_min_age` on pages it's already scanning. Mostly "free."
2. **Aggressive vacuum** (age > `vacuum_freeze_table_age`, 150M) — scans every not-yet-frozen page, not just dirty ones; catches pages bloat-driven vacuums skip.
3. **Anti-wraparound autovacuum** (age > `autovacuum_freeze_max_age`, 200M) — forced safety net; runs even with `autovacuum = off`, zero dead tuples, or nobody asking. **Cannot be disabled.**

```
XID age:  0 ── 50M ──────── 150M ──────── 200M ──────── ~2B
               freeze       aggressive    anti-wraparound  EMERGENCY
               eligible     vacuum        autovacuum FORCED shutdown
```

**Insert-only tables are the classic trap:** no dead tuples → bloat-based autovacuum never fires → XID age silently climbs until a massive freeze storms at 150M/200M. PG13+ added `autovacuum_vacuum_insert_threshold` (default 1000) to vacuum/freeze insert-heavy tables sooner.

Monitor freeze pressure:
```sql
SELECT relname, age(relfrozenxid) AS xid_age,
       round(100.0 * age(relfrozenxid) / 200000000, 1) AS pct_to_wraparound_av
FROM pg_class WHERE relkind = 'r' ORDER BY xid_age DESC;
```

### Tuning the freeze parameters (per-table / per-db / cluster)
**Naming gotcha:** system GUCs and per-table storage params use different prefixes for the same concept.

| Concept | System GUC | Per-table storage param |
|---------|-----------|--------------------------|
| Min age to freeze a tuple | `vacuum_freeze_min_age` | `autovacuum_freeze_min_age` |
| Age forcing aggressive scan | `vacuum_freeze_table_age` | `autovacuum_freeze_table_age` |
| Age forcing anti-wraparound | `autovacuum_freeze_max_age` | `autovacuum_freeze_max_age` |

**Cluster-wide** (`postgresql.conf` / `ALTER SYSTEM` + `SELECT pg_reload_conf()`):
```sql
ALTER SYSTEM SET vacuum_freeze_min_age   = 50000000;   -- user context, reload
ALTER SYSTEM SET vacuum_freeze_table_age = 150000000;  -- user context, reload
ALTER SYSTEM SET autovacuum_freeze_max_age = 200000000;-- postmaster -> RESTART required
```

**Per-database** (only the two `user`-context GUCs; `autovacuum_freeze_max_age` is postmaster-only, so **not** settable per-db):
```sql
ALTER DATABASE wavelo_lab SET vacuum_freeze_min_age   = 20000000;
ALTER DATABASE wavelo_lab SET vacuum_freeze_table_age = 100000000;
```

**Per-table** (use the `autovacuum_`-prefixed names; what autovacuum workers actually honor):
```sql
ALTER TABLE billing_events SET (
  autovacuum_freeze_min_age   = 10000000,
  autovacuum_freeze_table_age = 80000000,
  autovacuum_freeze_max_age   = 150000000
);
-- TOAST side has its own: toast.autovacuum_freeze_min_age, etc.
ALTER TABLE billing_events RESET (autovacuum_freeze_min_age);
```

**Key rules / gotchas:**
- **Cap:** per-table `autovacuum_freeze_max_age` = `min(your_value, cluster value)`. You can only make a table freeze *earlier*, never raise the ceiling above the global.
- **Who reads what:** autovacuum reads the per-table `autovacuum_freeze_*` params; a **manual `VACUUM` uses the system GUCs** and ignores table storage params. `VACUUM (FREEZE)` forces min age = 0.
- **Trade-off:** lower freeze ages = more frequent, smaller freezes (more I/O/WAL churn, no surprise storms); higher ages = less routine work but risk of a massive forced anti-wraparound vacuum at a bad time.

**When to tune:**

| Goal | Tune |
|------|------|
| Huge insert-only table, avoid one giant storm | Lower `autovacuum_freeze_max_age` (100–150M) + set `autovacuum_vacuum_insert_threshold` |
| Spread freeze work over time | Lower `vacuum_freeze_min_age` (10–20M) so tuples freeze opportunistically |
| High-churn OLTP table | Fix bloat knobs first (`autovacuum_vacuum_scale_factor`); freezing rides along |
| Large DB nearing wraparound | Lower `vacuum_freeze_table_age`; raise `autovacuum_max_workers` / lower cost delay so vacuums finish |

---

## 1.2 WAL (Write-Ahead Log)

### What it is
Before any change hits the data files, it's written to the **WAL** — an append-only log of changes. This guarantees **durability** (the D in ACID): on crash, Postgres replays WAL to recover committed transactions. WAL is also the foundation of **replication** and **point-in-time recovery (PITR)**.

Flow:
```
Change -> WAL buffer -> WAL on disk (fsync at COMMIT) -> later, dirty pages
                                                          flushed to data files
                                                          at a CHECKPOINT
```

Key terms:
- **LSN (Log Sequence Number)** — a byte position in the WAL stream; how Postgres tracks progress and replication lag.
- **Checkpoint** — point where all dirty buffers are flushed to data files; bounds crash recovery time.
- **full_page_writes** — first change to a page after a checkpoint writes the whole page to WAL (protects against torn pages).

### What goes wrong
- **WAL fills the disk** — a stuck replica, an inactive **replication slot**, or `archive_command` failing causes WAL to pile up and fill `pg_wal/` → server stops. Inactive slots are a classic outage cause.
- **Checkpoint spikes** — too-frequent or bursty checkpoints cause I/O storms and latency spikes.
- **Slow fsync** — commits stall if storage can't keep up with WAL flushes.

### How to monitor
```sql
-- Replication slots — watch for inactive slots retaining WAL
SELECT slot_name, active, wal_status,
       pg_size_pretty(pg_wal_lsn_diff(pg_current_wal_lsn(), restart_lsn)) AS retained_wal
FROM pg_replication_slots;

-- Current WAL position
SELECT pg_current_wal_lsn();

-- Checkpoint stats (PG16: pg_stat_checkpointer; older: pg_stat_bgwriter)
SELECT * FROM pg_stat_bgwriter;
```
OS: watch `pg_wal/` directory size and disk free space.

### How to fix
- Drop or fix **inactive replication slots** (`pg_drop_replication_slot`).
- Tune checkpoints: raise `max_wal_size`, set `checkpoint_completion_target = 0.9` to spread I/O.
- Ensure `archive_command` succeeds (and alert if it fails).
- Put `pg_wal` on fast, low-latency storage.

---

## 1.3 VACUUM & Autovacuum

### What it is
**VACUUM** reclaims space from dead tuples (makes it reusable), updates the **visibility map** (enables index-only scans), and **freezes** old tuples to prevent XID wraparound. **Autovacuum** does this automatically in the background per-table when dead tuples cross a threshold.

- `VACUUM` — marks dead space reusable, does **not** return disk to the OS.
- `VACUUM FULL` — rewrites the whole table, returns space to OS, but takes an **ACCESS EXCLUSIVE lock** (blocks everything). Avoid on live tables.
- `ANALYZE` — updates planner statistics (not space-related, but usually run together).

Autovacuum triggers when:
```
dead_tuples > autovacuum_vacuum_threshold
            + autovacuum_vacuum_scale_factor * reltuples
```
Default scale factor 0.2 = vacuum after 20% of the table is dead. **Too high for big tables** — a 100M-row table waits for 20M dead rows.

### What goes wrong
- **Autovacuum can't keep up** — high write rate, too few workers, cost limits too conservative → bloat grows faster than it's cleaned.
- **Blocked by long transactions** — vacuum can't remove tuples newer than the oldest snapshot.
- **VACUUM FULL in production** — locks the table, causes an outage.

### How to monitor
```sql
SELECT relname, n_dead_tup, last_autovacuum, autovacuum_count
FROM pg_stat_user_tables ORDER BY n_dead_tup DESC;

-- Autovacuum running now
SELECT pid, now()-xact_start AS dur, query
FROM pg_stat_activity WHERE query LIKE 'autovacuum%';
```
Use the `pgstattuple` extension to measure true bloat percentage.

### How to fix
- **Per-table tuning** for big/hot tables:
```sql
ALTER TABLE billing_events SET (
  autovacuum_vacuum_scale_factor = 0.02,   -- vacuum at 2% dead, not 20%
  autovacuum_vacuum_cost_limit = 2000       -- let it work faster
);
```
- Raise `autovacuum_max_workers`, lower `autovacuum_vacuum_cost_delay`.
- Reclaim bloat without full lock: `pg_repack` (online rebuild).
- Fix long/idle transactions blocking the xmin horizon.

---

## 1.4 Bloat

### What it is
Wasted space from dead tuples (table bloat) and stale index entries (index bloat). Causes larger-than-necessary tables/indexes → more pages to scan → slower queries and more cache pressure.

### What goes wrong / how to monitor / how to fix
- **Monitor:** `pgstattuple`, `pgstatindex`, or the well-known bloat estimation queries; `n_dead_tup` as a proxy.
- **Causes:** under-vacuuming, long transactions, high churn (frequent UPDATE/DELETE), low `fillfactor` misuse.
- **Fix:** tune autovacuum (1.3), `pg_repack` for tables, `REINDEX CONCURRENTLY` for indexes.

```sql
REINDEX INDEX CONCURRENTLY idx_billing_events_subscription_id;
```

---

## 1.5 The Query Planner / Optimizer

### What it is
A **cost-based** optimizer. It estimates the cost of alternative plans (scan types, join methods, join orders) using **table statistics** collected by ANALYZE, and picks the cheapest. Stats live in `pg_statistic` (readable via `pg_stats`): row counts, most-common values, histograms, null fraction, n_distinct.

Cost knobs (relative, not ms): `seq_page_cost` (1.0), `random_page_cost` (4.0 default; lower to ~1.1 for SSDs), `cpu_tuple_cost`, `effective_cache_size` (hint about OS cache size).

### What goes wrong
- **Stale statistics** → wildly wrong row estimates → bad plan (e.g. Nested Loop with millions of loops). The #1 planner problem.
- **Correlated columns** — planner assumes independence; e.g. `city` and `zip` are correlated, so it underestimates combined selectivity.
- **`random_page_cost` too high on SSD** → planner avoids index scans it should use.
- **Bad row estimates from expressions** — `WHERE lower(email)=...` can't use column stats.

### How to monitor
```sql
-- Compare estimated vs actual rows (the key planner signal)
EXPLAIN (ANALYZE, BUFFERS) SELECT ...;
-- big gap between "rows=" (estimate) and "actual rows=" -> stats problem

-- Inspect stats freshness
SELECT relname, last_analyze, last_autoanalyze FROM pg_stat_user_tables;
```

### How to fix
- `ANALYZE` (or fix autovacuum's analyze cadence).
- **Extended statistics** for correlated columns:
```sql
CREATE STATISTICS stat_city_zip (dependencies) ON city, zip FROM addresses;
ANALYZE addresses;
```
- Tune `random_page_cost` for SSD/NVMe.
- Increase `default_statistics_target` for skewed columns (more histogram detail).
- Rewrite expressions to be index-friendly or add expression indexes.

---

# 2. Advanced Performance Tuning

## 2.1 Methodology
Always **measure → change one thing → re-measure**. Start at `pg_stat_statements` (find expensive queries), drill with `EXPLAIN (ANALYZE, BUFFERS)`, then decide: index, rewrite, schema, or config. See `PERFORMANCE_ANALYSIS.md`.

## 2.2 Indexing strategy

| Index type | Use for |
|------------|---------|
| **B-tree** | Default; equality + range, sorting, most queries |
| **Hash** | Equality only (rarely worth it over B-tree) |
| **GIN** | Multi-value columns: `jsonb`, arrays, full-text search |
| **GiST** | Geometric, ranges, nearest-neighbor, full-text |
| **BRIN** | Huge, naturally-ordered tables (e.g. time-series); tiny footprint |
| **SP-GiST** | Non-balanced structures (quadtrees, IP ranges) |

Techniques:
- **Composite indexes** — column order matters; leftmost-prefix rule. Put equality columns first, range last.
- **Covering / INCLUDE indexes** — `CREATE INDEX ... INCLUDE (col)` enables **index-only scans** (no heap fetch).
- **Partial indexes** — `WHERE status='active'`; smaller, faster, used in scenario 6.
- **Expression indexes** — `CREATE INDEX ON customers (lower(email))` to fix the scenario-7 problem.

**What goes wrong:** over-indexing slows writes and bloats; unused indexes waste space; wrong column order makes a composite index useless.

**Monitor unused indexes:**
```sql
SELECT indexrelname, idx_scan, pg_size_pretty(pg_relation_size(indexrelid))
FROM pg_stat_user_indexes WHERE idx_scan = 0;
```
**Build without locking writes:** `CREATE INDEX CONCURRENTLY`.

## 2.3 Memory tuning

| Parameter | Role | Rough guidance |
|-----------|------|----------------|
| `shared_buffers` | PG's own page cache | ~25% of RAM |
| `effective_cache_size` | Planner hint for OS+PG cache | ~50–75% of RAM |
| `work_mem` | Per-operation sort/hash memory | Careful: it's **per node per connection** |
| `maintenance_work_mem` | VACUUM, CREATE INDEX, REINDEX | 256MB–1GB+ |

**`work_mem` is the classic trap:** set too low → sorts/hashes spill to disk (`Sort Method: external merge` in EXPLAIN). Set too high × many connections × multiple nodes per query → **OOM**. Tune per-workload, not globally high.

```sql
-- See if a sort spilled to disk
EXPLAIN (ANALYZE, BUFFERS) SELECT ... ORDER BY ...;
-- "Sort Method: external merge  Disk: 12000kB"  -> raise work_mem for this query
```

## 2.4 Connection management
Each connection is a backend process (~few MB + work_mem usage). Thousands of connections → memory + context-switch overhead. **Use PgBouncer** (transaction pooling) in front. Right-size app pools; more connections ≠ more throughput past CPU core count.

## 2.5 Partitioning (also a scaling tool)
Declarative partitioning by **range** (time), **list** (region), or **hash**. Benefits: **partition pruning** (planner skips irrelevant partitions), cheaper maintenance (drop old partition instead of DELETE), parallel-friendly.

```sql
CREATE TABLE billing_events (...) PARTITION BY RANGE (event_at);
CREATE TABLE billing_events_2026_06 PARTITION OF billing_events
  FOR VALUES FROM ('2026-06-01') TO ('2026-07-01');
```
**What goes wrong:** queries without the partition key can't prune (scan all partitions); too many partitions inflate planning time.

## 2.6 Configuration cheat-sheet of pain
| Symptom | Likely knob |
|---------|-------------|
| Disk sort spills | `work_mem` |
| Low cache hit ratio | `shared_buffers`, RAM, indexing |
| Checkpoint I/O spikes | `max_wal_size`, `checkpoint_completion_target` |
| Index scans avoided on SSD | `random_page_cost` |
| Autovacuum behind | per-table scale factors, `autovacuum_max_workers` |

---

# 3. Architecture, HA & Scaling

## 3.1 Process & memory architecture
PostgreSQL is **process-based** (not threaded). One **postmaster** parent forks a **backend** per connection. Background processes: **WAL writer**, **checkpointer**, **background writer**, **autovacuum launcher/workers**, **archiver**, **stats collector**, and **WAL sender/receiver** for replication. Shared memory holds `shared_buffers`, WAL buffers, lock tables.

## 3.2 Replication

### Physical (streaming) replication
Byte-for-byte WAL shipping to standbys. Whole-cluster copy. Standbys can serve **read-only** queries (hot standby).
- **Synchronous** — primary waits for standby to confirm WAL flush → zero data loss (RPO=0), higher latency.
- **Asynchronous** — primary doesn't wait → low latency, small risk of data loss on failover.

```sql
-- On primary: watch each replica's lag
SELECT client_addr, state, sync_state,
       pg_wal_lsn_diff(pg_current_wal_lsn(), replay_lsn) AS replay_lag_bytes
FROM pg_stat_replication;
```

### Logical replication
Replicates **selected tables** at the row level via publish/subscribe (decoded from WAL). Cross-version, selective, allows writes on subscriber. Used for **major-version upgrades with near-zero downtime**, partial replication, CDC.
```sql
-- Publisher
CREATE PUBLICATION pub_billing FOR TABLE billing_events;
-- Subscriber
CREATE SUBSCRIPTION sub_billing CONNECTION 'host=... dbname=...' PUBLICATION pub_billing;
```
**What goes wrong:** logical replication doesn't replicate DDL, sequences need care, large transactions lag, conflicts on the subscriber.

### Replication problems to monitor
- **Replication lag** (bytes/seconds) — slow standby, network, or heavy standby queries.
- **Inactive slots retaining WAL** (see 1.2) — fills primary disk.
- **Conflicts on standby** — long read queries vs replay (`max_standby_streaming_delay`).

## 3.3 High Availability (failover)

### The need
Single primary = single point of failure. HA = automatic detection + promotion of a standby + redirecting traffic.

### Tools
- **Patroni** — the de-facto standard. Uses a **DCS** (Distributed Configuration Store: etcd / Consul / ZooKeeper) for **leader election** and to avoid **split-brain**. Handles automatic failover, promotion, and reconfiguration.
- **repmgr**, **pg_auto_failover** — alternatives.
- **Connection routing:** HAProxy, **PgBouncer**, or a VIP so apps follow the new primary.

### Key concepts
- **RPO** (Recovery Point Objective) — how much data you can lose. Sync replication → RPO 0.
- **RTO** (Recovery Time Objective) — how fast you recover. Patroni → seconds–minutes.
- **Split-brain** — two primaries accepting writes. Prevented by **quorum/consensus** in the DCS and **fencing/STONITH**.
- **Failover vs switchover** — unplanned (failure) vs planned (maintenance).

**What goes wrong:** DCS quorum loss stalls failover; flapping; standby too far behind to promote safely; clients not redirected.

## 3.4 Backup & Recovery (PITR)
- **Logical:** `pg_dump` / `pg_dumpall` — portable, slow to restore, per-DB/table.
- **Physical:** `pg_basebackup` + continuous WAL archiving → **PITR** (restore to an exact moment, e.g. just before a bad `DELETE`).
- **Tools:** `pgBackRest`, `Barman`, `WAL-G` — parallelism, compression, incremental, retention, S3.

**Golden rule:** a backup you haven't restored is not a backup. Test restores and measure RTO regularly.

## 3.5 Scaling
- **Vertical** — bigger box. Simplest, has a ceiling.
- **Read scaling** — add read replicas; route reads via app or proxy. Watch replica lag for read-after-write consistency.
- **Connection scaling** — PgBouncer.
- **Partitioning** — manage huge tables (3.x / 2.5).
- **Sharding** — horizontal split across nodes: app-level, or **Citus** extension. Adds cross-shard query/transaction complexity.
- **CDC / event streaming** — **Debezium** reading logical replication → **Kafka** for downstream systems (very relevant to Wavelo's event-driven architecture).

---

# 4. Security

## 4.1 Authentication — `pg_hba.conf`
Host-Based Authentication: rules matched top-down by `{type, database, user, address, method}`.

| Method | Notes |
|--------|-------|
| `scram-sha-256` | **Use this.** Modern password auth (PG 10+). |
| `md5` | Legacy, weak — migrate off. |
| `cert` | TLS client certificates. |
| `peer` / `ident` | OS-user based (local). |
| `trust` | **No auth — never in production.** (Default local dev only.) |

```
# TYPE  DATABASE  USER       ADDRESS         METHOD
hostssl all       all        10.0.0.0/8      scram-sha-256
```
**What goes wrong:** a stray `trust` line, `0.0.0.0/0` exposure, or `md5` left enabled. Audit `pg_hba.conf` regularly; `SELECT * FROM pg_hba_file_rules;`.

## 4.2 Authorization — roles & privileges
Roles are users **and** groups. Grant the **least privilege** needed.

```sql
CREATE ROLE app_read NOLOGIN;
GRANT CONNECT ON DATABASE wavelo_lab TO app_read;
GRANT USAGE ON SCHEMA public TO app_read;
GRANT SELECT ON ALL TABLES IN SCHEMA public TO app_read;
ALTER DEFAULT PRIVILEGES IN SCHEMA public GRANT SELECT ON TABLES TO app_read;  -- future tables
CREATE ROLE alice LOGIN PASSWORD '...' IN ROLE app_read;
```
- Object ownership matters; owners and superusers bypass most checks.
- **`ALTER DEFAULT PRIVILEGES`** so new tables inherit grants — commonly forgotten.

**What goes wrong:** over-granting (everyone superuser), `PUBLIC` having default privileges, broad `GRANT ALL`.

## 4.3 Row-Level Security (RLS)
Per-row access control — essential for **multi-tenant** SaaS (each CSP sees only its rows).
```sql
ALTER TABLE billing_events ENABLE ROW LEVEL SECURITY;
CREATE POLICY tenant_isolation ON billing_events
  USING (tenant_id = current_setting('app.tenant_id')::bigint);
```
**What goes wrong:** policies not `FORCE`d for table owners; performance cost if the policy predicate isn't indexable.

## 4.4 Encryption
- **In transit:** TLS (`ssl = on`, `hostssl`, enforce min TLS version). Mandatory for remote connections.
- **At rest:** filesystem/volume encryption (LUKS, cloud KMS-backed disks). Core Postgres has no built-in transparent column encryption — use disk encryption + app/`pgcrypto` for specific columns.
- **Secrets:** never plaintext in configs; use a secret manager.

## 4.5 Auditing & compliance
- `log_connections`, `log_disconnections`, `log_statement = 'ddl'` (or `mod`).
- **pgAudit** extension for detailed, compliance-grade audit logs (who ran what).
- Track DDL changes, privilege grants, failed logins.

**What goes wrong:** logging everything (`log_statement='all'`) kills performance and logs secrets; insufficient logging fails audits.

## 4.6 Hardening checklist
- `scram-sha-256` everywhere; no `trust`/`md5` in prod.
- TLS enforced; restrict `listen_addresses` and `pg_hba.conf` to known CIDRs.
- Least-privilege roles; no app using superuser.
- Patch promptly (minor versions = security fixes).
- RLS for multi-tenant; pgAudit for compliance.
- Encrypt at rest + in transit; rotate credentials.
- Restrict superuser; separate DBA accounts; `idle_in_transaction_session_timeout` set.

---

## Quick interview map (Wavelo DBRE)

| They ask about... | Section |
|-------------------|---------|
| "Walk me through MVCC / why bloat happens" | 1.1, 1.4 |
| "WAL, replication slots filling disk" | 1.2, 3.2 |
| "Autovacuum tuning at scale" | 1.3 |
| "A query got slow — how do you debug?" | 2.1, `PERFORMANCE_ANALYSIS.md` |
| "Index strategy / work_mem" | 2.2, 2.3 |
| "Design HA / automatic failover" | 3.3 (Patroni, DCS, split-brain) |
| "Backup strategy / PITR" | 3.4 |
| "Multi-tenant isolation / security" | 4.2, 4.3 |

**See also:** [README.md](README.md) · [PERFORMANCE_ANALYSIS.md](PERFORMANCE_ANALYSIS.md) · [CACHE.md](CACHE.md) · [scenario_1.md](scenario_1.md)–[scenario_3.md](scenario_3.md)
