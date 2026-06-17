-- vacuum_bloat.sql — dead tuples, autovacuum status, freeze / wraparound pressure
-- Run in psql:  \i scripts/vacuum_bloat.sql

\echo '=== Dead tuples & last (auto)vacuum per table ==='
SELECT relname,
       n_live_tup, n_dead_tup,
       round(100.0 * n_dead_tup / nullif(n_live_tup + n_dead_tup, 0), 2) AS dead_pct,
       last_vacuum, last_autovacuum, last_analyze, last_autoanalyze
FROM pg_stat_user_tables
ORDER BY n_dead_tup DESC
LIMIT 20;

\echo ''
\echo '=== Autovacuum running right now ==='
SELECT pid, now() - xact_start AS duration, left(query, 100) AS query
FROM pg_stat_activity
WHERE query LIKE 'autovacuum:%'
ORDER BY duration DESC;

\echo ''
\echo '=== Freeze / wraparound pressure per table (oldest XID first) ==='
SELECT c.relname,
       age(c.relfrozenxid) AS xid_age,
       round(100.0 * age(c.relfrozenxid) /
             current_setting('autovacuum_freeze_max_age')::float, 1) AS pct_to_forced_av
FROM pg_class c
WHERE c.relkind = 'r'
ORDER BY age(c.relfrozenxid) DESC
LIMIT 20;

\echo ''
\echo '=== Database-level XID age (wraparound watch) ==='
SELECT datname, age(datfrozenxid) AS xid_age
FROM pg_database
ORDER BY xid_age DESC;

\echo ''
\echo '=== Oldest snapshot pinning the xmin horizon (blocks vacuum) ==='
SELECT pid, state, backend_xmin,
       now() - xact_start AS xact_age, left(query, 80) AS query
FROM pg_stat_activity
WHERE backend_xmin IS NOT NULL
ORDER BY xact_age DESC;
