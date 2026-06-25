# Restore & Point-In-Time Recovery (PITR) — pgBackRest

How to recover a PostgreSQL cluster from a pgBackRest backup — both a **plain restore** (back to the latest state in the archive) and **Point-In-Time Recovery** (stop at a chosen moment, e.g. just before a bad `DROP TABLE`). These share the **same command**; PITR just adds a *target*.

**See also:** [pgbackrest.md](pgbackrest.md) (set up the backups first) · [wal-and-checkpoints.md](wal-and-checkpoints.md) (how WAL replay works) · [best-practices.md](best-practices.md) → Durability

> **Prerequisite:** a working pgBackRest stanza with at least one backup and archived WAL — see [pgbackrest.md](pgbackrest.md). Examples use stanza `demo`, `PGDATA` = `/opt/homebrew/var/postgresql@16`, and `PGBACKREST_CONFIG=/opt/homebrew/etc/pgbackrest.conf`.

---

## 1. The mental model — restore = base backup + WAL replay

A physical backup is a copy of the data files at some moment. WAL archived *after* that moment records every subsequent change. Recovery is always:

```
   restore base backup (data files as of backup time)
        │
        ▼
   replay archived WAL forward ───▶ stop point
        │                              ├─ end of archive   → "latest" (plain restore)
        │                              └─ a chosen target  → PITR (time / LSN / xid / named point)
        ▼
   open the database
```

- **Plain restore** replays WAL to the **end of the archive** — the most recent recoverable state. Use it for "the server/disk died, bring it back."
- **PITR** replays WAL only up to a **target** and stops. Use it for "someone ran a bad migration at 14:32 — bring us back to 14:31."

Same restore command, same replay engine — the only difference is whether you specify a target.

---

## 2. Plain restore (recover to the latest state)

> ⚠️ Restore **overwrites `PGDATA`**. Stop Postgres first, and on a real system preserve the old data dir if there's any chance you'll need it.

```bash
export PATH="/opt/homebrew/opt/postgresql@16/bin:$PATH"
export PGBACKREST_CONFIG=/opt/homebrew/etc/pgbackrest.conf

# 1. Stop PostgreSQL
brew services stop postgresql@16
# or: pg_ctl -D /opt/homebrew/var/postgresql@16 stop

# 2. (Safety) keep the current data dir aside instead of deleting
mv /opt/homebrew/var/postgresql@16 /opt/homebrew/var/postgresql@16.broken

# 3. Restore the latest backup into PGDATA
pgbackrest --stanza=demo restore

# 4. Start PostgreSQL — it replays WAL to the end of the archive, then opens
brew services start postgresql@16
```

pgBackRest writes the recovery settings for you (into `postgresql.auto.conf`, and creates a `recovery.signal` file), so you don't hand-edit a `restore_command`. Postgres comes up in recovery, replays WAL, and opens at the latest state.

**`--delta` (faster restore):** if `PGDATA` still exists, `--delta` restores only the files that differ (using checksums) instead of recopying everything — much faster for large clusters:

```bash
pgbackrest --stanza=demo --delta restore
```

---

## 3. Point-In-Time Recovery (stop at a target)

Add a **target** to stop replay at a precise point. pgBackRest sets the corresponding `recovery_target*` in `postgresql.auto.conf`.

### Target types

| `--type` | Stops at | `--target` value |
|----------|----------|------------------|
| `time` | a timestamp (most common) | `"2026-06-24 14:31:00"` |
| `lsn` | a WAL log position | `0/3000150` |
| `xid` | a transaction ID | `573921` |
| `name` | a named restore point you created earlier | `before_migration` |
| `immediate` | as soon as the backup is consistent (earliest safe point) | — |
| `default` | end of the archive (= plain restore) | — |

### Example: recover to just before a bad change at 14:32

```bash
brew services stop postgresql@16
mv /opt/homebrew/var/postgresql@16 /opt/homebrew/var/postgresql@16.broken

pgbackrest --stanza=demo \
  --type=time --target="2026-06-24 14:31:00" \
  --target-action=promote \
  restore

brew services start postgresql@16
```

- **`--target-action`** controls what happens when the target is reached:
  - `pause` (default) — recovery stops and **waits** so you can inspect before committing. Resume/finish with `SELECT pg_wal_replay_resume();` (opens read-write) once you're happy.
  - `promote` — finish recovery and open read-write immediately (used above).
  - `shutdown` — stop the server at the target (lets you copy data out, then decide).
- **`--exclusive` vs `--target-inclusive`:** by default the target *is* included; use `--target-exclusive` to stop *just before* it (handy for `xid`/`lsn`).

### Named restore points (plan-ahead PITR)

Before a risky operation, drop a marker you can recover to by name:

```sql
SELECT pg_create_restore_point('before_migration');
```
```bash
pgbackrest --stanza=demo --type=name --target=before_migration --target-action=promote restore
```

---

## 4. Timelines (what happens after PITR)

When recovery stops at a target and **promotes**, PostgreSQL starts a **new timeline** — a fork of history from that point. WAL on the new timeline gets a new ID, so the abandoned "future" (the changes after your target, including the mistake) doesn't collide with new activity. This is why you can PITR more than once and why pgBackRest tracks timelines. If a restore seems to "not find" expected WAL, a timeline mismatch is a common cause — `--type=time` with the right target usually resolves it.

---

## 5. Verify the recovery

```bash
psql -d pg_lab -c "SELECT now() AS recovered_at;"
psql -d pg_lab -c "\dt"                         # tables present as expected?
psql -d pg_lab -c "SELECT count(*) FROM orders;" # data at the expected point?

# Confirm it's out of recovery and accepting writes:
psql -d postgres -tAc "SELECT pg_is_in_recovery();"   # 'f' = open read-write
```

If you used `--target-action=pause`, the DB is read-only until you run `SELECT pg_wal_replay_resume();`.

Once you've confirmed the recovery is good, remove the preserved `*.broken` directory.

---

## 6. The golden rules of recovery

- **An untested backup is not a backup.** Practise this restore drill regularly — it's the only proof your backups + WAL archive actually work and that you can hit your **RTO**.
- **Replica ≠ backup.** A streaming replica faithfully replays a `DROP TABLE`; only PITR can rewind *before* a logical mistake.
- **Know your RPO/RTO.** WAL archiving gives near-continuous recoverability (small RPO); restore + replay time is your RTO — `--delta` and parallelism shrink it.
- **Preserve, don't delete.** Move the old `PGDATA` aside during a real recovery; don't destroy your only evidence/fallback until the restore is verified.

---

## Quick reference

```bash
# Latest-state restore
pgbackrest --stanza=demo restore
pgbackrest --stanza=demo --delta restore                 # faster, in-place

# PITR to a time, then open read-write
pgbackrest --stanza=demo --type=time \
  --target="2026-06-24 14:31:00" --target-action=promote restore

# PITR to a named point / lsn / xid
pgbackrest --stanza=demo --type=name --target=before_migration restore
pgbackrest --stanza=demo --type=lsn  --target=0/3000150 --target-exclusive restore

# After a 'pause' recovery, finish and open read-write:
#   psql -c "SELECT pg_wal_replay_resume();"
```

---

## Mapping to the interview

- *"How does PITR work?"* → restore a base backup, then replay archived WAL up to a `recovery_target` (time/LSN/xid/name); Postgres stops there, promotes onto a new timeline, and opens.
- *"Difference between restoring a backup and PITR?"* → same restore process; plain restore replays to the **end** of the archive (latest), PITR stops at a **target**. With pgBackRest it's the same command plus `--type/--target`.
- *"How would you recover from an accidental `DROP TABLE` at 14:32?"* → PITR with `--type=time --target="14:31:..." --target-action=pause`, verify, then resume/promote — recovering everything up to just before the mistake.
- *"Why test restores?"* → it's the only way to validate backups and prove you can meet RTO; a replica won't save you from a logical error.
