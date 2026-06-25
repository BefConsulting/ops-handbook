# PostgreSQL DBA Reference

A working reference for PostgreSQL administration and reliability: internals, performance, high availability, and a hands-on lab. Examples target **PostgreSQL 16** (Homebrew on macOS) but apply broadly.

Part of the [ops-handbook](../README.md).

## Layout

```
databases/
├── docs/      Study guides (concepts, tuning, HA/DR)
├── lab/       Hands-on EXPLAIN lab (schema, seed data, scenarios)
└── scripts/   Ready-to-run monitoring SQL
```

## Documentation (`docs/`)

| Guide | What's inside |
|-------|---------------|
| [docs/deep-dive.md](docs/deep-dive.md) | The big one: internals (MVCC / WAL / vacuum / bloat / planner), performance tuning, HA & scaling, security |
| [docs/performance-analysis.md](docs/performance-analysis.md) | Where to start, what to check — the full investigation funnel |
| [docs/linux.md](docs/linux.md) | Linux host/kernel tuning — sysctl, memory/overcommit, swappiness, dirty-page writeback, THP/huge pages, storage, CPU, limits |
| [docs/best-practices.md](docs/best-practices.md) | Production config checklist — PostgreSQL server tuning (links to linux.md for the host) |
| [docs/monitoring.md](docs/monitoring.md) | SLIs / SLOs / error budgets for Postgres — example metrics, alert rules, and dashboards |
| [docs/pgbouncer.md](docs/pgbouncer.md) | Hands-on: set up PgBouncer connection pooling locally on macOS |
| [docs/pgbackrest.md](docs/pgbackrest.md) | Hands-on: set up pgBackRest backups + WAL archiving locally on macOS |
| [docs/recovery.md](docs/recovery.md) | Restore from backup + Point-In-Time Recovery (PITR) with pgBackRest |
| [docs/wal-and-checkpoints.md](docs/wal-and-checkpoints.md) | WAL vs dirty buffers, checkpoint tuning, crash recovery |
| [docs/cache.md](docs/cache.md) | Cold vs warm cache, and how it shows up in `EXPLAIN` buffers |
| [docs/ha-and-dr.md](docs/ha-and-dr.md) | Replication, failover automation (Patroni/DCS), disaster recovery & PITR |
| [docs/patroni.md](docs/patroni.md) | Hands-on: build a 3-node Patroni HA cluster locally on macOS |

## Hands-on lab (`lab/`)

A sample SaaS database (customers / subscriptions / billing) for practising `EXPLAIN (ANALYZE, BUFFERS)`.

```bash
cd lab
export PATH="/opt/homebrew/opt/postgresql@16/bin:$PATH"
psql -f 01_schema.sql
psql -d pg_lab -f 02_seed.sql
psql -d pg_lab -f 03_explain_exercises.sql
```

See [lab/README.md](lab/README.md) for the EXPLAIN field reference, node types, red flags, and [worked scenarios](lab/scenarios/).

## Monitoring scripts (`scripts/`)

Self-contained `.sql` files grouped by topic. From `psql` (launched at the repo root):

```sql
\c pg_lab
\i scripts/activity.sql      -- or any single file
\i scripts/all.sql           -- run the whole suite
```

See [scripts/README.md](scripts/README.md) for the full list.

## Suggested reading order

1. [docs/deep-dive.md](docs/deep-dive.md) — build the mental model
2. [lab/README.md](lab/README.md) — practise reading plans
3. [docs/performance-analysis.md](docs/performance-analysis.md) — a repeatable troubleshooting method
4. [docs/wal-and-checkpoints.md](docs/wal-and-checkpoints.md) + [docs/cache.md](docs/cache.md) — write path & memory
5. [docs/best-practices.md](docs/best-practices.md) — production config checklist (host + server)
6. [docs/ha-and-dr.md](docs/ha-and-dr.md) → [docs/patroni.md](docs/patroni.md) — availability & recovery
7. [docs/pgbackrest.md](docs/pgbackrest.md) → [docs/recovery.md](docs/recovery.md) — backups, WAL archiving, and PITR
8. [docs/pgbouncer.md](docs/pgbouncer.md) — connection pooling in front of the database
