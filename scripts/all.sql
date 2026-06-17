-- all.sql — run the full monitoring suite at once
-- Run in psql:  \i scripts/all.sql
-- (Run from the DBA repo root so the relative paths resolve.)

\echo '##################### ACTIVITY #####################'
\i scripts/activity.sql

\echo '##################### CACHE ########################'
\i scripts/cache.sql

\echo '##################### VACUUM / BLOAT ###############'
\i scripts/vacuum_bloat.sql

\echo '##################### WAL / CHECKPOINTS ############'
\i scripts/wal_checkpoints.sql

\echo '##################### INDEXES ######################'
\i scripts/indexes.sql

\echo '##################### SETTINGS #####################'
\i scripts/settings.sql

\echo '##################### REPLICATION ##################'
\i scripts/replication.sql

\echo '##### slow_queries.sql skipped (needs pg_stat_statements) #####'
\echo '##### run manually: \i scripts/slow_queries.sql           #####'
