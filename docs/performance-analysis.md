# PostgreSQL Performance Analysis

A practical funnel for investigating slow Postgres — where to start, what to check, and how it connects to the EXPLAIN lab.

---

## 1. Start with the symptom (don't jump to EXPLAIN)

Ask:

| Question | Why |
|----------|-----|
| **What is slow?** | One query? Whole app? One endpoint? |
| **When?** | Always, peak hours, after a deploy? |
| **What changed?** | Schema, data volume, config, hardware? |
| **Who feels it?** | Users, batch jobs, replication lag? |

**Key point:** *"I scope the problem before tuning — is it CPU, I/O, locks, connections, or one bad query?"*

---

## 2. First 5-minute health check

Run these before deep diving:

```sql
-- Active queries right now
SELECT pid, now() - query_start AS duration, state, wait_event_type, wait_event, left(query, 120)
FROM pg_stat_activity
WHERE state != 'idle'
ORDER BY duration DESC;

-- Database-level stats
SELECT datname, numbackends, xact_commit, xact_rollback, blks_read, blks_hit,
       round(100.0 * blks_hit / nullif(blks_hit + blks_read, 0), 2) AS cache_hit_pct
FROM pg_stat_database
WHERE datname = current_database();

-- Table bloat / seq scan pressure
SELECT relname, seq_scan, idx_scan, n_live_tup, n_dead_tup,
       last_vacuum, last_autovacuum, last_analyze
FROM pg_stat_user_tables
ORDER BY seq_scan DESC
LIMIT 15;
```

Also check at OS level:

- **CPU** — pegged?
- **Disk I/O** — saturated?
- **RAM** — swapping?
- **Connections** — near `max_connections`?

---

## 3. The standard investigation order

```
Symptom
   │
   ▼
① Is Postgres healthy?     (connections, locks, vacuum, disk, memory)
   │
   ▼
② What is slow?            (pg_stat_statements, logs, pg_stat_activity)
   │
   ▼
③ Why is it slow?          (EXPLAIN ANALYZE, waits, buffers, row estimates)
   │
   ▼
④ Fix                      (index, rewrite query, config, schema, hardware)
   │
   ▼
⑤ Verify + monitor         (re-run EXPLAIN, watch p95 latency, alerts)
```

---

## 4. What to check (by layer)

### A. Connections & pooling

```sql
SELECT count(*), state FROM pg_stat_activity GROUP BY state;
```

- Too many connections → CPU overhead, memory pressure
- Fix: **PgBouncer**, reduce app pool size, close idle connections

### B. Locks & blocking

```sql
SELECT blocked.pid, blocked.query AS blocked_query,
       blocking.pid, blocking.query AS blocking_query
FROM pg_stat_activity blocked
JOIN pg_stat_activity blocking ON blocking.pid = ANY(pg_blocking_pids(blocked.pid));
```

- Long transactions holding locks → everything waits
- Fix: shorten transactions, fix missing indexes on FKs, kill runaway sessions

### C. Top slow / expensive queries — `pg_stat_statements`

```sql
SELECT calls, round(total_exec_time::numeric, 2) AS total_ms,
       round(mean_exec_time::numeric, 2) AS mean_ms,
       rows, shared_blks_read, shared_blks_hit,
       left(query, 100)
FROM pg_stat_statements
ORDER BY total_exec_time DESC
LIMIT 10;
```

**This is usually where you start for query tuning.**

Find queries with high `total_exec_time` or high `mean_exec_time` + high `calls`.

Enable it (if not already):

```sql
CREATE EXTENSION pg_stat_statements;
-- requires shared_preload_libraries = 'pg_stat_statements' in postgresql.conf + restart
```

### D. Cache hit ratio (table/index level)

```sql
SELECT relname,
       heap_blks_read, heap_blks_hit,
       round(100.0 * heap_blks_hit / nullif(heap_blks_hit + heap_blks_read, 0), 2) AS heap_hit_pct
FROM pg_stat_user_tables
ORDER BY heap_blks_read DESC
LIMIT 10;
```

- Low hit ratio on hot tables → working set bigger than RAM, or bad access patterns
- Fix: more RAM, better indexes, partition cold data

### E. Vacuum & bloat

```sql
SELECT relname, n_live_tup, n_dead_tup,
       round(100.0 * n_dead_tup / nullif(n_live_tup + n_dead_tup, 0), 2) AS dead_pct,
       last_autovacuum
FROM pg_stat_user_tables
WHERE n_dead_tup > 1000
ORDER BY n_dead_tup DESC;
```

- High `n_dead_tup` → bloat, slower scans, index bloat
- Fix: tune autovacuum, run `VACUUM (ANALYZE)`, fix long transactions blocking vacuum

### F. Missing / unused indexes

```sql
-- Tables with lots of seq scans and no index use
SELECT relname, seq_scan, idx_scan, n_live_tup
FROM pg_stat_user_tables
WHERE seq_scan > idx_scan AND n_live_tup > 10000
ORDER BY seq_scan DESC;

-- Indexes never used (candidates to drop)
SELECT indexrelname, idx_scan, pg_size_pretty(pg_relation_size(indexrelid))
FROM pg_stat_user_indexes
WHERE idx_scan = 0 AND schemaname = 'public';
```

### G. Replication lag (if HA)

```sql
SELECT client_addr, state, sent_lsn, write_lsn, flush_lsn, replay_lsn,
       pg_wal_lsn_diff(sent_lsn, replay_lsn) AS lag_bytes
FROM pg_stat_replication;
```

---

## 5. Deep dive on a specific query — EXPLAIN

Once you have the query from `pg_stat_statements` or logs:

```sql
EXPLAIN (ANALYZE, BUFFERS, VERBOSE)
-- paste the slow query here
;
```

**What to look for:**

| Red flag | Likely cause |
|----------|--------------|
| Seq Scan + high Rows Removed by Filter | Missing index |
| Estimated rows ≠ actual rows (10×+ off) | Stale stats → `ANALYZE` |
| Nested Loop + inner loops=millions | Bad join order / missing index |
| Sort Method: external merge | `work_mem` too low |
| High `shared read` | Cold cache or too much data touched |
| Hash Join on huge tables | May need index or rewrite |

Optional:

```sql
SET track_io_timing = on;   -- I/O timing per node
```

See [../lab/README.md](../lab/README.md) for the EXPLAIN field reference and [scenario_1.md](../lab/scenarios/scenario_1.md)–[scenario_3.md](../lab/scenarios/scenario_3.md) for worked examples.

---

## 6. Config knobs (after you know the bottleneck)

| Symptom | Check |
|---------|-------|
| Sorts spilling to disk | `work_mem` |
| Cache misses everywhere | `shared_buffers`, RAM, query shape |
| Checkpoints hammering disk | `checkpoint_timeout`, `max_wal_size` |
| Too many connections | `max_connections` + PgBouncer |
| Autovacuum falling behind | `autovacuum_vacuum_scale_factor`, per-table settings |
| Slow writes | WAL, disk latency, synchronous_commit settings |

**Don't randomly tune** — measure first, change one thing, re-measure.

---

## 7. Practical workflow (production)

```
1. Alert / ticket: "API slow"
2. pg_stat_activity     → anything blocked or running 30s+?
3. pg_stat_statements   → top queries by total time
4. EXPLAIN ANALYZE      → on the worst offender
5. Fix                  → index / rewrite / vacuum / config
6. Reset stats & watch  → SELECT pg_stat_statements_reset(); then monitor
```

For logs, enable slow query logging:

```
log_min_duration_statement = 1000   # log queries > 1s
```

---

## 8. Map to the EXPLAIN lab

| Scenario | Real-world equivalent |
|----------|----------------------|
| [scenario_1.md](../lab/scenarios/scenario_1.md) — Seq Scan | `pg_stat_user_tables.seq_scan` high, no index |
| [scenario_2.md](../lab/scenarios/scenario_2.md) — Bitmap Scan | Index exists, moderate selectivity |
| [scenario_3.md](../lab/scenarios/scenario_3.md) — Nested Loop | Point lookup + FK join (good pattern) |
| Exercise 4 — Hash Join | Full/analytical join, no selective filter |
| Exercise 5–6 — Sort/Aggregate | Heavy GROUP BY, needs index or rewrite |
| Exercise 7 — `lower(email)` | Function on column → index can't be used |
| Exercise 8 — Bitmap | Multi-column filter |

Run exercises: `psql -d pg_lab -f ../lab/03_explain_exercises.sql`

---

## 9. Summary framework

> *"I start with scope and symptoms, check connections and locks, use `pg_stat_statements` to find the expensive queries, then `EXPLAIN (ANALYZE, BUFFERS)` on those. I look at plan shape, estimate vs actual rows, buffer hits vs reads, and wait events. Then I fix the root cause — index, query rewrite, vacuum, or config — and verify with before/after metrics."*

---

## 10. Try it locally

In `pg_lab`:

```sql
-- What's slow? (requires pg_stat_statements enabled)
SELECT query, calls, mean_exec_time, total_exec_time
FROM pg_stat_statements
ORDER BY total_exec_time DESC
LIMIT 5;
```

Then pick a query from `03_explain_exercises.sql` and run full `EXPLAIN (ANALYZE, BUFFERS)` on it.
