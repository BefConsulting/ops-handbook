-- cache.sql — buffer cache hit ratios (warm vs cold)
-- Run in psql:  \i scripts/cache.sql
-- Note: stats are cumulative since last reset (pg_stat_reset()).

\echo '=== Database-level cache hit ratio (want > 99% for OLTP) ==='
SELECT datname,
       blks_hit, blks_read,
       round(100.0 * blks_hit / nullif(blks_hit + blks_read, 0), 2) AS cache_hit_pct
FROM pg_stat_database
WHERE datname = current_database();

\echo ''
\echo '=== Per-table heap cache hit ratio (lowest first) ==='
SELECT relname,
       heap_blks_hit, heap_blks_read,
       round(100.0 * heap_blks_hit / nullif(heap_blks_hit + heap_blks_read, 0), 2) AS heap_hit_pct
FROM pg_statio_user_tables
WHERE heap_blks_hit + heap_blks_read > 0
ORDER BY heap_hit_pct ASC
LIMIT 20;

\echo ''
\echo '=== Per-index cache hit ratio (lowest first) ==='
SELECT relname, indexrelname,
       idx_blks_hit, idx_blks_read,
       round(100.0 * idx_blks_hit / nullif(idx_blks_hit + idx_blks_read, 0), 2) AS idx_hit_pct
FROM pg_statio_user_indexes
WHERE idx_blks_hit + idx_blks_read > 0
ORDER BY idx_hit_pct ASC
LIMIT 20;
