-- slow_queries.sql — top queries by time/calls (requires pg_stat_statements)
-- Run in psql:  \i scripts/slow_queries.sql
--
-- Setup (one-time): pg_stat_statements must be preloaded.
--   1) postgresql.conf:  shared_preload_libraries = 'pg_stat_statements'
--   2) restart Postgres
--   3) CREATE EXTENSION pg_stat_statements;

\echo '=== Top 15 queries by TOTAL execution time ==='
SELECT calls,
       round(total_exec_time::numeric, 1)  AS total_ms,
       round(mean_exec_time::numeric, 2)   AS mean_ms,
       rows,
       round(100.0 * shared_blks_hit /
             nullif(shared_blks_hit + shared_blks_read, 0), 1) AS cache_hit_pct,
       left(query, 90) AS query
FROM pg_stat_statements
ORDER BY total_exec_time DESC
LIMIT 15;

\echo ''
\echo '=== Top 15 queries by MEAN execution time (slowest per call) ==='
SELECT calls,
       round(mean_exec_time::numeric, 2)  AS mean_ms,
       round(total_exec_time::numeric, 1) AS total_ms,
       rows,
       left(query, 90) AS query
FROM pg_stat_statements
WHERE calls > 1
ORDER BY mean_exec_time DESC
LIMIT 15;

\echo ''
\echo '-- To reset stats and start a fresh measurement window:'
\echo '--   SELECT pg_stat_statements_reset();'
