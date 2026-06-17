-- activity.sql — live sessions, locks, and blocking
-- Run in psql:  \i scripts/activity.sql

\echo '=== Active (non-idle) sessions, longest first ==='
\echo '    look: queries running 30s+, or wait_event_type=Lock (blocked on something)'
SELECT pid,
       now() - query_start AS duration,
       state,
       wait_event_type,
       wait_event,
       left(query, 100) AS query
FROM pg_stat_activity
WHERE state <> 'idle'
ORDER BY duration DESC;

\echo ''
\echo '=== Idle-in-transaction sessions (hold locks, block vacuum) ==='
\echo '    look: any large idle_for — these pin the xmin horizon and stall autovacuum'
SELECT pid,
       now() - xact_start AS xact_age,
       now() - state_change AS idle_for,
       left(query, 100) AS last_query
FROM pg_stat_activity
WHERE state = 'idle in transaction'
ORDER BY xact_age DESC;

\echo ''
\echo '=== Blocking / blocked sessions ==='
\echo '    look: blocking_pid is the culprit; terminate with pg_terminate_backend(pid) if stuck'
SELECT blocked.pid                AS blocked_pid,
       left(blocked.query, 60)    AS blocked_query,
       blocking.pid               AS blocking_pid,
       left(blocking.query, 60)   AS blocking_query,
       blocked.wait_event_type,
       blocked.wait_event
FROM pg_stat_activity blocked
JOIN pg_stat_activity blocking
  ON blocking.pid = ANY (pg_blocking_pids(blocked.pid))
WHERE blocked.wait_event_type = 'Lock';

\echo ''
\echo '=== Connection counts by state ==='
\echo '    look: total near max_connections, or many "idle in transaction" = pooling/app issue'
SELECT state, count(*)
FROM pg_stat_activity
GROUP BY state
ORDER BY count(*) DESC;
