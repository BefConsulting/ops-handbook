-- wal_checkpoints.sql — WAL position, checkpoint health, bgwriter activity
-- Run in psql:  \i scripts/wal_checkpoints.sql
-- Version note: PG17+ moved some counters to pg_stat_checkpointer / pg_stat_io.

\echo '=== Checkpoint health: timed vs requested (want pct_forced ~ 0) ==='
\echo '    look: high pct_forced = WAL hits max_wal_size before the timeout — raise max_wal_size'
SELECT checkpoints_timed, checkpoints_req,
       round(100.0 * checkpoints_req /
             nullif(checkpoints_timed + checkpoints_req, 0), 1) AS pct_forced,
       checkpoint_write_time, checkpoint_sync_time
FROM pg_stat_bgwriter;

\echo ''
\echo '=== Buffer write sources (bgwriter vs checkpoint vs backend) ==='
\echo '    look: high buffers_backend = backends flushing their own pages — bgwriter/checkpoint too weak'
SELECT buffers_checkpoint, buffers_clean, maxwritten_clean,
       buffers_backend, buffers_backend_fsync, buffers_alloc
FROM pg_stat_bgwriter;

\echo ''
\echo '=== Current WAL position & last checkpoint location ==='
\echo '    look: informational; the LSN diff between runs = how fast WAL is being generated'
SELECT pg_current_wal_lsn() AS current_lsn;
SELECT redo_lsn, checkpoint_lsn FROM pg_control_checkpoint();

\echo ''
\echo '=== pg_wal directory size & file count ==='
\echo '    look: size much larger than max_wal_size = inactive replication slot or stuck archiving'
SELECT count(*) AS wal_files, pg_size_pretty(sum(size)) AS total_size
FROM pg_ls_waldir();

\echo ''
\echo '=== Key WAL / checkpoint settings ==='
\echo '    look: do values match the workload? pending_restart=true means a restart is needed to apply'
SELECT name, setting, unit, source, context, pending_restart
FROM pg_settings
WHERE name IN ('checkpoint_timeout', 'max_wal_size', 'min_wal_size',
               'checkpoint_completion_target', 'wal_buffers', 'wal_compression',
               'full_page_writes', 'wal_segment_size')
ORDER BY name;
