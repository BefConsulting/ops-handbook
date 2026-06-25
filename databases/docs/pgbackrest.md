# pgBackRest Setup — local macOS (PostgreSQL 16)

A hands-on guide to setting up **pgBackRest** — a reliable, parallel backup & restore tool for PostgreSQL — against your local Homebrew PostgreSQL 16, so you can take real backups, archive WAL, and practise recovery (see [recovery.md](recovery.md) for restore & PITR).

**See also:** [recovery.md](recovery.md) (restore from backup + PITR) · [wal-and-checkpoints.md](wal-and-checkpoints.md) (WAL archiving) · [best-practices.md](best-practices.md) → Replication (archive settings)

---

## Why pgBackRest?

`pg_dump` is a *logical* backup (a SQL snapshot) — fine for small DBs, but it doesn't support **Point-In-Time Recovery** and is slow to restore at scale. pgBackRest does **physical** backups (file-level copies of the cluster) plus **WAL archiving**, which together give you:

- **Full / differential / incremental** backups (only changed files after the first full).
- **WAL archiving** → restore to *any* point in time (PITR), not just the moment of the backup.
- **Parallelism, compression, checksums, retention** — and restore validation.

```
PostgreSQL ──archive_command──▶ pgBackRest ──▶ repository (backups + archived WAL)
   │                                                      │
   └────────────── restore ◀──────────────────────────────┘
```

The two halves you configure: **(1)** Postgres pushes each completed WAL segment to the repo via `archive_command`; **(2)** pgBackRest takes periodic base backups. Restore = a base backup + replayed WAL.

---

## 0. Prerequisites

- Homebrew PostgreSQL 16 running locally, with a data directory at `/opt/homebrew/var/postgresql@16` (Apple Silicon default).
- The `pg_lab` database from [the lab](../README.md) is handy to back up.
- Run pgBackRest as **the same OS user that owns `PGDATA`** (on Homebrew that's your Mac user) — no `sudo` needed for a local single-host setup.

```bash
export PATH="/opt/homebrew/opt/postgresql@16/bin:$PATH"
psql -d postgres -tAc "show data_directory;"   # confirm your PGDATA path
```

## 1. Install

```bash
brew install pgbackrest
pgbackrest version
```

## 2. Create the repository directory

This is where backups and archived WAL live. Keep it on a path your user owns:

```bash
mkdir -p /opt/homebrew/var/pgbackrest
mkdir -p /opt/homebrew/var/log/pgbackrest
```

> In production the repo should be on **separate storage** (ideally offsite — S3/Azure Blob, which pgBackRest supports natively). Local disk is fine for learning, but a backup on the same disk as the data protects against nothing.

## 3. Configure `pgbackrest.conf`

pgBackRest reads `/etc/pgbackrest/pgbackrest.conf` (or `/etc/pgbackrest.conf`) by default. To keep everything local and avoid `sudo`, put it under Homebrew and pass `--config` (or export it):

Create `/opt/homebrew/etc/pgbackrest.conf`:

```ini
[global]
repo1-path=/opt/homebrew/var/pgbackrest
repo1-retention-full=2
log-path=/opt/homebrew/var/log/pgbackrest
log-level-console=info
log-level-file=detail
start-fast=y

[demo]
pg1-path=/opt/homebrew/var/postgresql@16
```

- **`[demo]`** is the **stanza** — a named configuration for one cluster. You'll pass `--stanza=demo` to every command.
- **`pg1-path`** must be the cluster's `PGDATA` (from step 0).
- **`repo1-retention-full=2`** keeps the last 2 full backups; older ones (and their WAL) expire automatically.
- **`start-fast=y`** triggers an immediate checkpoint so the backup starts without waiting.

**Make pgBackRest find this config.** Since it's not at the default `/etc/pgbackrest/pgbackrest.conf`, you must point pgBackRest at it on **every** command. The most reliable way is the explicit `--config` flag (used throughout this guide):

```bash
pgbackrest --config=/opt/homebrew/etc/pgbackrest.conf --stanza=demo <command>
```

To save typing, you *can* export an env var instead — **but it only applies in the shell where you ran the `export`** (a new terminal won't have it, which causes `ERROR: [037]: ... requires option: pg1-path`):

```bash
export PGBACKREST_CONFIG=/opt/homebrew/etc/pgbackrest.conf   # this shell only
```

> If you ever see **`ERROR: [037]: stanza-create command requires option: pg1-path`**, pgBackRest didn't read your config — it's looking in `/etc` and finding nothing. Add `--config=/opt/homebrew/etc/pgbackrest.conf` to the command (or re-`export` it in the current shell).

## 4. Point PostgreSQL at pgBackRest (WAL archiving)

Tell Postgres to archive WAL through pgBackRest. First find the **absolute path** to the binary — the `archive_command` is run by the PostgreSQL server, which has a minimal `PATH` that does *not* include `/opt/homebrew/bin`:

```bash
which pgbackrest      # e.g. /opt/homebrew/bin/pgbackrest
```

Then edit `postgresql.conf` (or use `ALTER SYSTEM`), using that absolute path:

```sql
ALTER SYSTEM SET wal_level = 'replica';
ALTER SYSTEM SET archive_mode = 'on';
ALTER SYSTEM SET archive_command = '/opt/homebrew/bin/pgbackrest --stanza=demo --config=/opt/homebrew/etc/pgbackrest.conf archive-push %p';
ALTER SYSTEM SET max_wal_senders = 3;
```

`archive_mode` and `wal_level` require a **restart** (not just reload); `archive_command` only needs a reload:

```bash
brew services restart postgresql@16
# or: pg_ctl -D /opt/homebrew/var/postgresql@16 restart
```

> **Why the absolute path?** The server runs `archive_command` via `sh -c` with a restricted environment. A bare `pgbackrest` fails with `sh: pgbackrest: command not found` and `archive command failed with exit code 127`, even though it works in your shell. Always use the full path here (same goes for `restore_command`).
>
> `%p` is the path of the WAL segment Postgres hands to the command. `archive-push` copies it into the repo. If the command fails, Postgres retains the WAL and retries — so a broken `archive_command` makes `pg_wal` grow (see [wal-and-checkpoints.md](wal-and-checkpoints.md)).

## 5. Create the stanza

This initializes the repo for your cluster:

```bash
pgbackrest --config=/opt/homebrew/etc/pgbackrest.conf --stanza=demo stanza-create
```

## 6. Verify the configuration

`check` confirms Postgres and pgBackRest agree and that WAL archiving actually works (it forces a segment switch and checks it lands in the repo):

```bash
pgbackrest --config=/opt/homebrew/etc/pgbackrest.conf --stanza=demo check
# ... INFO: check command end: completed successfully
```

If this passes, archiving is wired correctly.

## 7. Take a backup

```bash
# (commands shown with --config; export PGBACKREST_CONFIG to omit it)
# First backup is always promoted to a full backup:
pgbackrest --config=/opt/homebrew/etc/pgbackrest.conf --stanza=demo --type=full backup

# Later backups can be incremental (only changed files since the last backup):
pgbackrest --config=/opt/homebrew/etc/pgbackrest.conf --stanza=demo --type=incr backup

# Differential (changes since the last FULL):
pgbackrest --config=/opt/homebrew/etc/pgbackrest.conf --stanza=demo --type=diff backup
```

## 8. Inspect backups

```bash
pgbackrest --config=/opt/homebrew/etc/pgbackrest.conf --stanza=demo info
```

```
stanza: demo
    status: ok
    db (current)
        full backup: 20260624-160000F
            timestamp start/stop: 2026-06-24 16:00:00 / 2026-06-24 16:00:12
            wal start/stop: 000000010000000000000003 / 000000010000000000000003
            database size: 24.1MB, backup size: 24.1MB
```

You now have a base backup **plus** continuously archived WAL — everything needed to restore to the backup *or* to any later point in time. See **[recovery.md](recovery.md)**.

---

## 9. Automating backups (cron)

A simple local schedule — full weekly, differential daily:

```bash
# crontab -e
30 2 * * 0  PGBACKREST_CONFIG=/opt/homebrew/etc/pgbackrest.conf pgbackrest --stanza=demo --type=full backup
30 2 * * 1-6 PGBACKREST_CONFIG=/opt/homebrew/etc/pgbackrest.conf pgbackrest --stanza=demo --type=diff backup
```

In production this is driven by your scheduler/IaC, with the repo on offsite object storage and retention tuned to your **RPO**.

---

## Troubleshooting

| Symptom | Cause / fix |
|---------|-------------|
| `check` fails: "WAL segment ... was not archived" | `archive_command` wrong or Postgres not restarted after setting `archive_mode`. Verify the exact command and `SHOW archive_mode;`. Check `pg_stat_archiver` and `log-path/demo-archive-push.log`. |
| `sh: pgbackrest: command not found` / "exit code 127" in PG log | `archive_command` uses a bare `pgbackrest`; the server's restricted `PATH` can't find it. Use the **absolute path** (`/opt/homebrew/bin/pgbackrest`), then `SELECT pg_reload_conf();`. |
| `unable to open ... permission denied` | pgBackRest not running as the `PGDATA` owner, or repo dir not owned by your user. |
| `stanza-create` says "primary has been initialized" mismatch | `pg1-path` doesn't match the running cluster's `data_directory`. |
| `pg_wal` filling up | `archive_command` failing — Postgres keeps WAL until it succeeds. Check `pgbackrest` logs in `log-path`. |
| config not found | export `PGBACKREST_CONFIG` or pass `--config=...` on every command. |
| `archive-push` slow / backlog | enable async archiving: `archive-async=y` + `spool-path` in `[global]`. |

---

## Mapping to the interview

- *"Why pgBackRest over `pg_dump`?"* → physical backups + WAL archiving enable **PITR** and fast parallel restore; `pg_dump` is logical, no PITR, slow at scale.
- *"What enables PITR?"* → `archive_mode=on` + an `archive_command` shipping WAL to the repo, plus periodic base backups. Restore = base backup + replay WAL to a target.
- *"Full vs differential vs incremental?"* → full = everything; diff = changes since last full; incr = changes since last backup of any type. Trade restore speed vs backup size/time.
- *"Where should the repo live?"* → separate/offsite storage (object storage). A backup on the same disk as the data protects against nothing. Follow 3-2-1 and **test restores**.
