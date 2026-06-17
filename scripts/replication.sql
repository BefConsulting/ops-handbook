-- replication.sql — streaming/logical replication status, lag, slots
-- Run in psql:  \i scripts/replication.sql
-- Run most of these on the PRIMARY; the standby section runs on a replica.

\echo '=== Am I a standby? ==='
SELECT pg_is_in_recovery() AS is_standby;

\echo ''
\echo '=== [PRIMARY] Connected replicas, state, and lag ==='
SELECT client_addr, application_name, state, sync_state,
       pg_size_pretty(pg_wal_lsn_diff(pg_current_wal_lsn(), sent_lsn))   AS sent_lag,
       pg_size_pretty(pg_wal_lsn_diff(pg_current_wal_lsn(), replay_lsn)) AS replay_lag_bytes,
       write_lag, flush_lag, replay_lag
FROM pg_stat_replication;

\echo ''
\echo '=== [STANDBY] Replay delay (run on the replica) ==='
SELECT pg_last_wal_receive_lsn() AS received,
       pg_last_wal_replay_lsn()  AS replayed,
       now() - pg_last_xact_replay_timestamp() AS replay_time_lag;

\echo ''
\echo '=== Replication slots & retained WAL (inactive slots = disk-fill risk) ==='
SELECT slot_name, slot_type, active, wal_status,
       pg_size_pretty(pg_wal_lsn_diff(pg_current_wal_lsn(), restart_lsn)) AS retained_wal
FROM pg_replication_slots
ORDER BY pg_wal_lsn_diff(pg_current_wal_lsn(), restart_lsn) DESC NULLS LAST;

\echo ''
\echo '=== [LOGICAL] Subscription progress (run on subscriber) ==='
SELECT subname, received_lsn, latest_end_lsn, last_msg_receipt_time
FROM pg_stat_subscription;
