-- indexes.sql — missing-index signals, unused indexes, index sizes
-- Run in psql:  \i scripts/indexes.sql

\echo '=== Seq-scan pressure: large tables scanned more than indexed (missing index?) ==='
SELECT relname, seq_scan, idx_scan, n_live_tup,
       seq_tup_read,
       round(seq_tup_read::numeric / nullif(seq_scan, 0), 0) AS avg_rows_per_seqscan
FROM pg_stat_user_tables
WHERE seq_scan > COALESCE(idx_scan, 0)
  AND n_live_tup > 10000
ORDER BY seq_scan DESC
LIMIT 20;

\echo ''
\echo '=== Unused indexes (never scanned) — candidates to drop ==='
SELECT s.relname AS table_name,
       s.indexrelname AS index_name,
       s.idx_scan,
       pg_size_pretty(pg_relation_size(s.indexrelid)) AS index_size
FROM pg_stat_user_indexes s
JOIN pg_index i ON i.indexrelid = s.indexrelid
WHERE s.idx_scan = 0
  AND NOT i.indisprimary
  AND NOT i.indisunique
ORDER BY pg_relation_size(s.indexrelid) DESC;

\echo ''
\echo '=== Largest indexes ==='
SELECT schemaname, relname AS table_name, indexrelname AS index_name,
       idx_scan,
       pg_size_pretty(pg_relation_size(indexrelid)) AS index_size
FROM pg_stat_user_indexes
ORDER BY pg_relation_size(indexrelid) DESC
LIMIT 20;
