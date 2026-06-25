-- replication.sql — streaming replication lag, slots, standby-side recovery
-- Run in psql:  \i scripts/replication.sql
--
-- Primary-side queries return rows only on the primary (or return no rows on a pure standby).
-- Standby-side queries return useful rows only when pg_is_in_recovery() = true.
-- Mixed cluster: run the whole file; irrelevant sections simply show no rows or NULLs.

\echo '=== 1. Streaming replication (PRIMARY) — who is connected, byte + time lag ==='
\echo '    look: state=streaming; replay_lag_bytes / replay_lag interval = how far behind'
\echo '    look: write_lag high = network/receive; flush_lag = standby WAL disk; replay_lag = apply bottleneck'
SELECT application_name,
       client_addr,
       client_hostname,
       state,
       sync_state,
       pg_size_pretty(pg_wal_lsn_diff(pg_current_wal_lsn(), sent_lsn))   AS send_lag_bytes,
       pg_size_pretty(pg_wal_lsn_diff(pg_current_wal_lsn(), write_lsn))  AS write_lag_bytes,
       pg_size_pretty(pg_wal_lsn_diff(pg_current_wal_lsn(), flush_lsn))  AS flush_lag_bytes,
       pg_size_pretty(pg_wal_lsn_diff(pg_current_wal_lsn(), replay_lsn))  AS replay_lag_bytes,
       write_lag,
       flush_lag,
       replay_lag
FROM pg_stat_replication
ORDER BY pg_wal_lsn_diff(pg_current_wal_lsn(), replay_lsn) DESC NULLS LAST;

\echo ''
\echo '=== 2. Replication slots (PRIMARY) — WAL retained on primary per consumer ==='
\echo '    look: active=false + large wal_retained = orphaned slot filling pg_wal'
\echo '    look: active=true + large wal_retained = consumer connected but far behind'
SELECT slot_name,
       slot_type,
       active,
       temporary,
       pg_size_pretty(pg_wal_lsn_diff(pg_current_wal_lsn(), restart_lsn)) AS wal_retained,
       safe_wal_size,
       pg_size_pretty(pg_wal_lsn_diff(pg_current_wal_lsn(), confirmed_flush_lsn)) AS logical_lag
FROM pg_replication_slots
ORDER BY pg_wal_lsn_diff(pg_current_wal_lsn(), restart_lsn) DESC NULLS LAST;

\echo ''
\echo '=== 3. Standby recovery position — receive vs replay (STANDBY or any recovering node) ==='
\echo '    look: pg_is_in_recovery=t; receive ahead of replay = replay queue on standby'
SELECT pg_is_in_recovery() AS in_recovery,
       pg_last_wal_receive_lsn() AS last_receive_lsn,
       pg_last_wal_replay_lsn()  AS last_replay_lsn,
       pg_size_pretty(
         pg_wal_lsn_diff(pg_last_wal_receive_lsn(), pg_last_wal_replay_lsn())
       ) AS replay_queue_bytes,
       pg_last_xact_replay_timestamp() AS last_replay_time,
       now() - pg_last_xact_replay_timestamp() AS replay_delay;

\echo ''
\echo '=== 4. WAL sender / receiver processes ==='
\echo '    look: walsender on primary; walreceiver on standby'
SELECT pid,
       usename,
       application_name,
       backend_type,
       state,
       wait_event_type,
       wait_event
FROM pg_stat_activity
WHERE backend_type IN ('walsender', 'walreceiver')
   OR application_name ILIKE '%walreceiver%';

\echo ''
\echo '=== 5. Hot-standby conflicts (STANDBY) — queries blocking or cancelled by replay ==='
\echo '    look: high deadlock/tablespace counts = long queries fighting replay'
SELECT datname,
       confl_tablespace,
       confl_lock,
       confl_snapshot,
       confl_bufferpin,
       confl_deadlock
FROM pg_stat_database_conflicts
WHERE datname IS NOT NULL
  AND (confl_tablespace + confl_lock + confl_snapshot + confl_bufferpin + confl_deadlock) > 0
ORDER BY confl_snapshot + confl_lock DESC;

\echo ''
\echo '=== 6. Replication-related settings ==='
SELECT name, setting, unit, source, pending_restart
FROM pg_settings
WHERE name IN (
  'wal_level', 'max_wal_senders', 'max_replication_slots',
  'hot_standby', 'hot_standby_feedback', 'max_standby_streaming_delay',
  'max_slot_wal_keep_size', 'wal_keep_size', 'synchronous_commit',
  'synchronous_standby_names'
)
ORDER BY name;
