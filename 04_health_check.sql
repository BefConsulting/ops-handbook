-- PostgreSQL 5-minute health check
-- Run: psql -d wavelo_lab -f 04_health_check.sql
-- Each query has a "WHAT TO CHECK" comment block explaining how to read it.


-- ============================================================
-- 1. ACTIVE QUERIES RIGHT NOW
-- ============================================================
-- WHAT TO CHECK:
--   duration         -> any query running for many seconds/minutes? That's your suspect.
--   state            -> 'active' = running now; 'idle in transaction' = DANGER (holds
--                       locks + blocks vacuum; usually an app that forgot to COMMIT).
--   wait_event_type  -> WHY a query is stalled:
--                          Lock   = blocked by another transaction (check query #4 in perf doc)
--                          IO     = waiting on disk (cold cache / slow storage)
--                          LWLock = internal contention (buffer/WAL pressure)
--                          Client = waiting on the app (often harmless)
--                          NULL   = actively running on CPU, not waiting
--   wait_event       -> the specific wait (e.g. DataFileRead, transactionid)
-- RED FLAGS: long-running 'idle in transaction', many rows all waiting on 'Lock'.
SELECT pid, now() - query_start AS duration, state, wait_event_type, wait_event, left(query, 120)
FROM pg_stat_activity
WHERE state != 'idle'
ORDER BY duration DESC;


-- ============================================================
-- 2. DATABASE-LEVEL STATS
-- ============================================================
-- WHAT TO CHECK:
--   cache_hit_pct    -> % of reads served from RAM. Want > 99% on an OLTP workload.
--                       Below ~95% means the working set doesn't fit in shared_buffers/RAM
--                       (too little RAM, bad indexes causing extra reads, or cold cache).
--   numbackends      -> active connections. Near max_connections? Add PgBouncer.
--   xact_rollback    -> high rollback ratio vs xact_commit = app errors / failed txns.
--   blks_read        -> pages fetched from disk (slow). blks_hit = from cache (fast).
-- NOTE: these are cumulative since last stats reset, so it's a long-run average,
--       not "right now". Use pg_stat_statements_reset() to get a fresh window.
SELECT datname, numbackends, xact_commit, xact_rollback, blks_read, blks_hit,
       round(100.0 * blks_hit / nullif(blks_hit + blks_read, 0), 2) AS cache_hit_pct
FROM pg_stat_database
WHERE datname = current_database();


-- ============================================================
-- 3. TABLE BLOAT / SEQ SCAN PRESSURE
-- ============================================================
-- WHAT TO CHECK:
--   seq_scan vs idx_scan -> a big table with high seq_scan and low idx_scan is the
--                           classic "missing index" signal. Tiny tables doing seq scans
--                           are fine (planner picks seq scan on purpose).
--   n_dead_tup           -> dead rows awaiting vacuum. High vs n_live_tup = BLOAT:
--                           slower scans, index bloat, wasted disk. Rule of thumb:
--                           investigate when dead_pct > ~20%.
--   n_live_tup           -> approx live row count (gauge table size).
--   last_autovacuum /    -> if NULL or very old on a busy table, autovacuum is falling
--   last_analyze            behind. Stale last_analyze => stale planner stats =>
--                           bad row estimates in EXPLAIN.
-- RED FLAGS: large n_live_tup + seq_scan >> idx_scan, or high n_dead_tup with old
--            last_autovacuum. Fix: add index, tune autovacuum, or VACUUM (ANALYZE).
SELECT relname, seq_scan, idx_scan, n_live_tup, n_dead_tup,
       last_vacuum, last_autovacuum, last_analyze
FROM pg_stat_user_tables
ORDER BY seq_scan DESC
LIMIT 15;
