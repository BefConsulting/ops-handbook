-- settings.sql — key configuration values and their source/context
-- Run in psql:  \i scripts/settings.sql
-- Reading the columns: source = where the value came from (default/config file/ALTER SYSTEM),
--   context = when a change takes effect (postmaster=restart, sighup=reload, user=per-session).

\echo '=== Memory settings ==='
\echo '    look: shared_buffers ~25% RAM, effective_cache_size ~50-75% RAM, work_mem per-sort (x connections!)'
SELECT name, setting, unit, source, context
FROM pg_settings
WHERE name IN ('shared_buffers', 'effective_cache_size', 'work_mem',
               'maintenance_work_mem', 'wal_buffers')
ORDER BY name;

\echo ''
\echo '=== Checkpoint / WAL settings ==='
\echo '    look: max_wal_size big enough to avoid forced checkpoints; synchronous_commit affects durability'
SELECT name, setting, unit, source, context, pending_restart
FROM pg_settings
WHERE name IN ('checkpoint_timeout', 'max_wal_size', 'min_wal_size',
               'checkpoint_completion_target', 'wal_level', 'wal_compression',
               'full_page_writes', 'synchronous_commit')
ORDER BY name;

\echo ''
\echo '=== Autovacuum settings ==='
\echo '    look: scale_factor too high on big tables delays vacuum; freeze_max_age governs wraparound safety'
SELECT name, setting, unit, source, context
FROM pg_settings
WHERE name LIKE 'autovacuum%'
   OR name IN ('vacuum_freeze_min_age', 'vacuum_freeze_table_age')
ORDER BY name;

\echo ''
\echo '=== Planner cost settings ==='
\echo '    look: random_page_cost should be ~1.1 on SSD (default 4.0 assumes spinning disk)'
SELECT name, setting, unit, source
FROM pg_settings
WHERE name IN ('random_page_cost', 'seq_page_cost', 'effective_io_concurrency',
               'default_statistics_target')
ORDER BY name;

\echo ''
\echo '=== Connection / replication settings ==='
\echo '    look: max_connections sane (pool instead of raising); slots/senders set for replication'
SELECT name, setting, unit, source, context
FROM pg_settings
WHERE name IN ('max_connections', 'max_wal_senders', 'max_replication_slots',
               'max_slot_wal_keep_size', 'hot_standby', 'synchronous_standby_names',
               'idle_in_transaction_session_timeout')
ORDER BY name;

\echo ''
\echo '=== Settings changed from default (source <> default) ==='
\echo '    look: this is everything intentionally tuned on this server — review for surprises'
SELECT name, setting, unit, source
FROM pg_settings
WHERE source NOT IN ('default', 'override')
ORDER BY name;
