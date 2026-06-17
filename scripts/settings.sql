-- settings.sql — key configuration values and their source/context
-- Run in psql:  \i scripts/settings.sql

\echo '=== Memory settings ==='
SELECT name, setting, unit, source, context
FROM pg_settings
WHERE name IN ('shared_buffers', 'effective_cache_size', 'work_mem',
               'maintenance_work_mem', 'wal_buffers')
ORDER BY name;

\echo ''
\echo '=== Checkpoint / WAL settings ==='
SELECT name, setting, unit, source, context, pending_restart
FROM pg_settings
WHERE name IN ('checkpoint_timeout', 'max_wal_size', 'min_wal_size',
               'checkpoint_completion_target', 'wal_level', 'wal_compression',
               'full_page_writes', 'synchronous_commit')
ORDER BY name;

\echo ''
\echo '=== Autovacuum settings ==='
SELECT name, setting, unit, source, context
FROM pg_settings
WHERE name LIKE 'autovacuum%'
   OR name IN ('vacuum_freeze_min_age', 'vacuum_freeze_table_age')
ORDER BY name;

\echo ''
\echo '=== Planner cost settings ==='
SELECT name, setting, unit, source
FROM pg_settings
WHERE name IN ('random_page_cost', 'seq_page_cost', 'effective_io_concurrency',
               'default_statistics_target')
ORDER BY name;

\echo ''
\echo '=== Connection / replication settings ==='
SELECT name, setting, unit, source, context
FROM pg_settings
WHERE name IN ('max_connections', 'max_wal_senders', 'max_replication_slots',
               'max_slot_wal_keep_size', 'hot_standby', 'synchronous_standby_names',
               'idle_in_transaction_session_timeout')
ORDER BY name;

\echo ''
\echo '=== Settings changed from default (source <> default) ==='
SELECT name, setting, unit, source
FROM pg_settings
WHERE source NOT IN ('default', 'override')
ORDER BY name;
