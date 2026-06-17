# Monitoring Scripts

Ready-to-run PostgreSQL monitoring queries, grouped by topic. Each file is self-contained and labels its sections with `\echo`.

## How to run

From `psql`, connect to your database and source a file:

```sql
\c wavelo_lab
\i scripts/activity.sql
```

Run the whole suite at once (from the DBA repo root):

```sql
\i scripts/all.sql
```

> Paths are relative to psql's current directory. Either launch `psql` from the DBA repo root, or use absolute paths, e.g. `\i /Users/befman/git_repo/DBA/scripts/activity.sql`.

## Files

| File | What it shows |
|------|---------------|
| `activity.sql` | Active sessions, idle-in-transaction, blocking/blocked, connection counts |
| `cache.sql` | Buffer cache hit ratios (database, per-table, per-index) |
| `vacuum_bloat.sql` | Dead tuples, autovacuum status, freeze/wraparound pressure, xmin horizon |
| `wal_checkpoints.sql` | Checkpoint health (timed vs requested), bgwriter, WAL position, `pg_wal` size, settings |
| `replication.sql` | Streaming/logical replication status, lag, replication slots |
| `indexes.sql` | Seq-scan pressure (missing indexes), unused indexes, index sizes |
| `slow_queries.sql` | Top queries by total/mean time (**needs `pg_stat_statements`**) |
| `settings.sql` | Key config values grouped (memory, WAL, autovacuum, planner, replication) + non-default settings |
| `all.sql` | Sources all of the above (except `slow_queries.sql`) in one go |

## Notes

- Many stats (`pg_stat_database`, `pg_stat_user_tables`, `pg_stat_bgwriter`) are **cumulative since the last reset**. Use `SELECT pg_stat_reset();` / `SELECT pg_stat_statements_reset();` to start a fresh window.
- `slow_queries.sql` requires `pg_stat_statements` preloaded (`shared_preload_libraries`, then a restart and `CREATE EXTENSION pg_stat_statements;`).
- `replication.sql` mixes primary-side and standby-side queries — irrelevant ones just return no rows.
- Version note: PG17+ relocated some counters (`pg_stat_checkpointer`, `pg_stat_io`); these scripts target **PG16**.

**See also:** [../PERFORMANCE_ANALYSIS.md](../PERFORMANCE_ANALYSIS.md) · [../WAL_AND_CHECKPOINTS.md](../WAL_AND_CHECKPOINTS.md) · [../REPLICATION.md](../REPLICATION.md)
