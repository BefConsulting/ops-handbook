# PostgreSQL EXPLAIN Lab

Telecom SaaS dummy data for learning `EXPLAIN (ANALYZE, BUFFERS)`.

**Study guides:**
- [POSTGRESQL_DEEP_DIVE.md](POSTGRESQL_DEEP_DIVE.md) — the big one: internals (MVCC/WAL/vacuum/bloat/planner), performance tuning, HA & scaling, security
- [PERFORMANCE_ANALYSIS.md](PERFORMANCE_ANALYSIS.md) — where to start, what to check, the full investigation funnel
- [WAL_AND_CHECKPOINTS.md](WAL_AND_CHECKPOINTS.md) — WAL vs dirty buffers, checkpoints, crash recovery
- [REPLICATION.md](REPLICATION.md) — physical/logical replication, lag, troubleshooting, HA best practices
- [CACHE.md](CACHE.md) — cold vs warm cache explained
- [scripts/](scripts/) — ready-to-run monitoring `.sql` files (`\i scripts/activity.sql`, etc.)

## Setup

```bash
export PATH="/opt/homebrew/opt/postgresql@16/bin:$PATH"

psql -f 01_schema.sql
psql -d wavelo_lab -f 02_seed.sql
psql -d wavelo_lab -f 03_explain_exercises.sql
```

## Tables

| Table | Rows | Purpose |
|-------|------|---------|
| `customers` | 10,000 | subscribers by region |
| `subscriptions` | 25,000 | plans linked to customers |
| `billing_events` | 200,000 | charge/refund event stream |

## How to read EXPLAIN (ANALYZE, BUFFERS)

Read the plan **bottom-up** (innermost node first), but **time flows top-down** (parent waits on children).

### Example output (annotated)

```
Limit  (cost=... rows=20 width=...) (actual time=12.3..12.4 rows=20 loops=1)
  Buffers: shared hit=842 read=120
  ->  Sort  (actual time=12.1..12.2 rows=20 loops=1)
        Sort Key: (sum(amount)) DESC
        Sort Method: top-N heapsort  Memory: 27kB
        Buffers: shared hit=840 read=120
        ->  HashAggregate  (actual time=8.5..10.2 rows=18000 loops=1)
              Buffers: shared hit=800 read=120
              ->  Seq Scan on billing_events  (actual time=0.02..4.1 rows=120000 loops=1)
                    Filter: (event_type = 'charge'::text)
                    Rows Removed by Filter: 80000
                    Buffers: shared hit=800 read=120
Planning Time: 0.15 ms
Execution Time: 12.45 ms
```

### Key fields

| Field | Meaning |
|-------|---------|
| `cost=0.00..X` | Planner estimate (startup..total). Arbitrary units, not ms. |
| `rows=N` | **Estimated** rows at this node |
| `actual time=A..B` | **Real** startup..total time in ms |
| `rows=N` (after actual time) | **Actual** rows returned |
| `loops=N` | How many times this node ran (important in Nested Loop) |
| `Buffers: shared hit=N` | Pages found in PostgreSQL buffer cache (fast) |
| `Buffers: shared read=N` | Pages read from disk (slow) |
| `Planning Time` | Time to build the plan |
| `Execution Time` | Time to run the query (excludes result transfer to client) |

### Common node types

| Node | When you see it | Good or bad? |
|------|-----------------|--------------|
| **Seq Scan** | Full table read, no useful index | OK for tiny tables; bad on large tables with selective filter |
| **Index Scan** | Index lookup, fetch matching rows | Good for selective queries |
| **Index Only Scan** | All columns served from index | Best — avoids heap fetch |
| **Bitmap Index Scan** | Build row bitmap from index, then heap | Good for moderate selectivity |
| **Nested Loop** | For each outer row, probe inner | Good when outer is tiny and inner is indexed |
| **Hash Join** | Build hash table on one side, probe other | Good for larger joins without selective index |
| **Merge Join** | Both sides sorted, merge | Good when both inputs already ordered |
| **Sort** | Sort in memory or spill to disk | Watch for `external merge` = disk sort (slow) |
| **HashAggregate** | GROUP BY via hash table | Normal for aggregations |

### Red flags to call out in interviews

1. **Estimates far from actual** — e.g. `rows=100` but `actual rows=120000` → stale stats; run `ANALYZE`
2. **High `shared read`** — data not in cache; cold cache or table larger than RAM
3. **Seq Scan on large table** with selective `WHERE` — missing or unused index
4. **Nested Loop with high `loops=`** — probing inner table millions of times
5. **Sort Method: external merge** — `work_mem` too low, sort spilled to disk
6. **Rows Removed by Filter** is huge — index not selective enough or wrong index

### Useful psql settings

```sql
\x on                          -- expanded output (easier to read)
SET track_io_timing = on;      -- adds I/O timing (PG 16+)
EXPLAIN (ANALYZE, BUFFERS, VERBOSE, SETTINGS, WAL)
SELECT ...;
```

### Reset lab (start over)

```bash
psql -f 01_schema.sql
psql -d wavelo_lab -f 02_seed.sql
```
