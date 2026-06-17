-- wal_checkpoints.sql — WAL position, checkpoint health, bgwriter activity
-- Run in psql:  \i scripts/wal_checkpoints.sql
-- Version note: PG17+ moved some counters to pg_stat_checkpointer / pg_stat_io.

\echo '=== Checkpoint health: timed vs requested (want pct_forced ~ 0) ==='
SELECT checkpoints_timed, checkpoints_req,
       round(100.0 * checkpoints_req /
             nullif(checkpoints_timed + checkpoints_req, 0), 1) AS pct_forced,
       checkpoint_write_time, checkpoint_sync_time
FROM pg_stat_bgwriter;

\echo ''
\echo '=== Buffer write sources (bgwriter vs checkpoint vs backend) ==='
SELECT buffers_checkpoint, buffers_clean, maxwritten_clean,
       buffers_backend, buffers_backend_fsync, buffers_alloc
FROM pg_stat_bgwriter;

\echo ''
\echo '=== Current WAL position & last checkpoint location ==='
SELECT pg_current_wal_lsn() AS current_lsn;
SELECT redo_lsn, checkpoint_lsn FROM pg_control_checkpoint();

\echo ''
\echo '=== pg_wal directory size & file count ==='
SELECT count(*) AS wal_files, pg_size_pretty(sum(size)) AS total_size
FROM pg_ls_waldir();

\echo ''
\echo '=== Key WAL / checkpoint settings ==='
SELECT name, setting, unit, source, context, pending_restart
FROM pg_settings
WHERE name IN ('checkpoint_timeout', 'max_wal_size', 'min_wal_size',
               'checkpoint_completion_target', 'wal_buffers', 'wal_compression',
               'full_page_writes', 'wal_segment_size')
ORDER BY name;
