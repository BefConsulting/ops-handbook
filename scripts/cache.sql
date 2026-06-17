-- cache.sql — buffer cache hit ratios (warm vs cold)
-- Run in psql:  \i scripts/cache.sql
-- Note: stats are cumulative since last reset (pg_stat_reset()).

\echo '=== Database-level cache hit ratio (want > 99% for OLTP) ==='
\echo '    look: < 99% means lots of disk reads — undersized shared_buffers or cold cache'
SELECT datname,
       blks_hit, blks_read,
       round(100.0 * blks_hit / nullif(blks_hit + blks_read, 0), 2) AS cache_hit_pct
FROM pg_stat_database
WHERE datname = current_database();

\echo ''
\echo '=== Per-table heap cache hit ratio (lowest first) ==='
\echo '    look: tables at the top are reading from disk most — hot ones want more cache / better indexes'
SELECT relname,
       heap_blks_hit, heap_blks_read,
       round(100.0 * heap_blks_hit / nullif(heap_blks_hit + heap_blks_read, 0), 2) AS heap_hit_pct
FROM pg_statio_user_tables
WHERE heap_blks_hit + heap_blks_read > 0
ORDER BY heap_hit_pct ASC
LIMIT 20;

\echo ''
\echo '=== Per-index cache hit ratio (lowest first) ==='
\echo '    look: low ratio on a frequently-used index = its pages keep getting evicted from cache'
SELECT relname, indexrelname,
       idx_blks_hit, idx_blks_read,
       round(100.0 * idx_blks_hit / nullif(idx_blks_hit + idx_blks_read, 0), 2) AS idx_hit_pct
FROM pg_statio_user_indexes
WHERE idx_blks_hit + idx_blks_read > 0
ORDER BY idx_hit_pct ASC
LIMIT 20;
