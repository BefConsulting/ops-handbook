# WAL, Dirty Buffers & Checkpoints — Tuning & Troubleshooting

Focus: **how to find current settings, pick optimal values, and troubleshoot checkpoint/WAL problems.** Basics are condensed up top for reference.

**See also:** [deep-dive.md](deep-dive.md) §1.2 · [cache.md](cache.md) · [performance-analysis.md](performance-analysis.md)

---

## Basics (condensed)

- **Dirty buffer** — an 8KB data page modified in `shared_buffers` (RAM) but not yet written to the data file. Flushed lazily (batched) to avoid slow random writes.
- **WAL record** — a compact, sequential log of the change, `fsync`'d to disk at **COMMIT**. This is what makes a commit durable.
- **Write-ahead rule** — a dirty buffer is never written to the data file before its WAL record is on disk.
- **Crash recovery (REDO)** — on restart, Postgres replays WAL since the last checkpoint to rebuild dirty buffers lost from RAM → no committed data lost.
- **Checkpoint** — flushes all dirty buffers to data files and advances the *redo point* so older WAL can be recycled. Checkpoint spacing bounds crash-recovery time.

```
COMMIT ──> WAL fsync'd (durable) ─────────────────►
               │                                    │
         dirty buffer in RAM ──────────► CHECKPOINT flushes to data file,
                                          advances redo point, recycles old WAL
```

**Why both:** commit = one fast sequential WAL write (durable) + data files updated lazily in batches (fast). Durability *and* speed.

### What triggers a checkpoint
| Trigger | Parameter | Counter in `pg_stat_bgwriter` |
|---------|-----------|-------------------------------|
| **Time** | `checkpoint_timeout` (default 5min) | `checkpoints_timed` |
| **WAL volume** | `max_wal_size` (default 1GB) | `checkpoints_req` |
| Manual / events | `CHECKPOINT;`, shutdown, basebackup | either |

---

## Find the current settings

```sql
-- All relevant settings with units, source, and how to change them
SELECT name, setting, unit, source, context, pending_restart
FROM pg_settings
WHERE name IN (
  'checkpoint_timeout', 'max_wal_size', 'min_wal_size',
  'checkpoint_completion_target', 'wal_buffers', 'wal_compression',
  'full_page_writes', 'shared_buffers', 'bgwriter_lru_maxpages', 'bgwriter_delay'
)
ORDER BY name;
```

Key columns:
- **`source`** — `default` / `configuration file` / `database` / `session` / `override` (did anything actually change it?)
- **`context`** — `postmaster` = restart, `sighup` = reload, `user` = per-session. `checkpoint_timeout` and `max_wal_size` are both **`sighup` → reload, no restart**.
- **`pending_restart`** — `true` if a restart-only change hasn't taken effect.

```sql
-- Which file/line set a value
SELECT name, setting, sourcefile, sourceline FROM pg_settings WHERE name = 'max_wal_size';
```

---

## The #1 health signal: timed vs requested checkpoints

```sql
SELECT checkpoints_timed, checkpoints_req,
       round(100.0 * checkpoints_req /
             nullif(checkpoints_timed + checkpoints_req, 0), 1) AS pct_forced
FROM pg_stat_bgwriter;
```

> **Golden rule:** checkpoints should be **timed**, almost never **requested**. `pct_forced ≈ 0` = healthy. Rising `checkpoints_req` = WAL is filling faster than `checkpoint_timeout` → **raise `max_wal_size`**.

Why forced checkpoints are bad: each checkpoint resets `full_page_writes`, so frequent checkpoints write more full pages to WAL → *more* WAL → even more forced checkpoints (a vicious cycle) plus I/O spikes.

---

## Optimal settings

### Recommended starting values
| Setting | Default | General production | Write-heavy OLTP |
|---------|---------|--------------------|------------------|
| `checkpoint_timeout` | `5min` | `15min` | `30min` |
| `max_wal_size` | `1GB` | `4GB` | `16GB`+ (size to write rate) |
| `min_wal_size` | `80MB` | `1GB` | `2GB` |
| `checkpoint_completion_target` | `0.9` | `0.9` | `0.9` |

### Size `max_wal_size` from real data (don't guess)
```sql
-- Reading 1
SELECT pg_current_wal_lsn();
-- ...wait ~5 min under normal load...
-- Reading 2 then diff:
SELECT pg_size_pretty(pg_wal_lsn_diff('<reading2>', '<reading1>')) AS wal_in_interval;
```
```
max_wal_size  ≈  (WAL per checkpoint_timeout interval)  ×  2
```
×2 gives margin for bursts and the ~2-cycle budget. E.g. 2 GB per 15 min → `max_wal_size ≈ 4–6 GB`.

### Apply (reloadable, no restart)
```sql
ALTER SYSTEM SET checkpoint_timeout = '15min';
ALTER SYSTEM SET max_wal_size = '4GB';
ALTER SYSTEM SET min_wal_size = '1GB';
ALTER SYSTEM SET checkpoint_completion_target = 0.9;
SELECT pg_reload_conf();

-- undo a change:
-- ALTER SYSTEM RESET max_wal_size;  SELECT pg_reload_conf();
```
(`ALTER SYSTEM` writes `postgresql.auto.conf`, overriding `postgresql.conf`.)

### Verify
```sql
SHOW max_wal_size;
SELECT checkpoints_timed, checkpoints_req FROM pg_stat_bgwriter;  -- req should stop climbing
```

### Core trade-off (bound by your RTO)
```
bigger max_wal_size + longer checkpoint_timeout
   + fewer checkpoints, less I/O, less WAL amplification
   - longer crash recovery, more pg_wal disk

smaller / shorter
   + faster crash recovery, less WAL disk
   - frequent checkpoints, I/O spikes, more full_page_writes
```
Provision **`pg_wal` disk well above `max_wal_size`** — it's a soft limit and can be exceeded under load or with inactive replication slots.

---

## Troubleshooting

### `pg_stat_bgwriter` field reference
| Field | Meaning | Watch for |
|-------|---------|-----------|
| `checkpoints_timed` | Timed checkpoints | Want this to dominate |
| `checkpoints_req` | Forced by `max_wal_size` | **High vs timed → raise `max_wal_size`** |
| `checkpoint_write_time` | ms writing during checkpoints | Large is fine (spread on purpose) |
| `checkpoint_sync_time` | ms in `fsync` at checkpoint end | Spikes → slow storage |
| `buffers_checkpoint` | Pages written by checkpointer | Planned writes (good) |
| `buffers_clean` | Pages written by background writer | 0 = bgwriter idle/too conservative |
| `maxwritten_clean` | Times bgwriter hit its write cap | High → raise `bgwriter_lru_maxpages` |
| `buffers_backend` | Pages backends flushed themselves | High share → cache pressure |
| `buffers_backend_fsync` | Backends doing own fsync | **Must be ~0**; >0 = fsync queue overflow (serious) |
| `buffers_alloc` | Buffers allocated | Cache demand gauge |

### Symptom → cause → fix
| Symptom | Likely cause | Fix |
|---------|--------------|-----|
| `checkpoints_req` rising / high `pct_forced` | `max_wal_size` too small for write rate | Raise `max_wal_size`; raise `checkpoint_timeout` |
| Periodic **latency/IO spikes** every few min | Checkpoint flush bursts | `checkpoint_completion_target=0.9`; raise `checkpoint_timeout`; raise `max_wal_size` |
| **WAL fills the disk** (`pg_wal` grows unbounded) | Inactive replication slot, failing `archive_command`, or orphaned slot | Drop/fix slot (`pg_drop_replication_slot`); fix archiving; check `pg_replication_slots` |
| **Slow commits** | `fsync` latency on WAL storage | Put `pg_wal` on fast/low-latency disk; check `checkpoint_sync_time` |
| **Long crash recovery / startup** | Checkpoints too far apart (too much WAL to replay) | Lower `checkpoint_timeout` / `max_wal_size` (trades steady-state I/O for faster recovery) |
| `buffers_backend` large share + `buffers_clean=0` | bgwriter too passive, cache pressure | `bgwriter_lru_maxpages`↑, `bgwriter_delay`↓; raise `shared_buffers` |
| `buffers_backend_fsync > 0` | fsync request queue overflow | Investigate I/O subsystem; raise `shared_buffers` |
| `maxwritten_clean` high | bgwriter stopping early | Raise `bgwriter_lru_maxpages` |

> A high `buffers_backend` share is **normal during one-off bulk loads** (a burst fills `shared_buffers` faster than the gentle bgwriter reacts). Only a concern if it persists under steady OLTP load.

### Diagnostic queries
```sql
-- WAL position & last checkpoint location
SELECT pg_current_wal_lsn();
SELECT redo_lsn, checkpoint_lsn FROM pg_control_checkpoint();

-- WAL generated since a known LSN
SELECT pg_size_pretty(pg_wal_lsn_diff(pg_current_wal_lsn(), '0/0')) AS wal_total;

-- Replication slots retaining WAL (a classic "disk full" cause)
SELECT slot_name, active, wal_status,
       pg_size_pretty(pg_wal_lsn_diff(pg_current_wal_lsn(), restart_lsn)) AS retained_wal
FROM pg_replication_slots;

-- Total pg_wal size on disk
SELECT pg_size_pretty(sum(size)) FROM pg_ls_waldir();
```

**Version note:** on **PG16** these counters live in `pg_stat_bgwriter`. In **PG17+**, `buffers_backend`/`buffers_backend_fsync` moved to `pg_stat_io`, and checkpoint counters to `pg_stat_checkpointer`.

---

## Checklist

1. Raise `checkpoint_timeout` to ~15 min (or align to your RTO).
2. Measure WAL/interval (`pg_wal_lsn_diff`), set `max_wal_size` ≈ 2× that.
3. Leave `checkpoint_completion_target = 0.9`.
4. Set `min_wal_size` ~1–2 GB to reduce file churn.
5. `SELECT pg_reload_conf();` then confirm with `SHOW`.
6. Watch `checkpoints_req` / `pct_forced` stay near 0; re-tune if not.
7. Keep `pg_wal` disk headroom over `max_wal_size`; monitor inactive replication slots.

---

## Summary

> *"I size `max_wal_size` to ~2× the WAL generated per `checkpoint_timeout` interval (measured with `pg_wal_lsn_diff`) and set `checkpoint_timeout` to ~15 min with `checkpoint_completion_target=0.9`. The goal is timer-driven checkpoints — I verify `checkpoints_req` stays near zero in `pg_stat_bgwriter`. It's a trade-off between checkpoint I/O and crash-recovery time, bounded by RTO and `pg_wal` disk headroom. For 'WAL filling the disk' I check inactive replication slots and archiving first."*
