# WAL & Checkpoints

How PostgreSQL keeps data durable without writing every change to disk twice immediately — the **write-ahead log (WAL)**, how **checkpoints** flush dirty data, how the **`pg_wal` directory size** is bounded, how **segment recycling** avoids filesystem churn, and **how long WAL is kept for physical and logical replication**.

**See also:** [best-practices.md](best-practices.md) (the WAL/checkpoint config table) · [ha-and-dr.md](ha-and-dr.md) (replication setup and slot monitoring) · [linux.md](linux.md) (dirty-page writeback, fsync) · [monitoring.md](monitoring.md) (checkpoint & WAL metrics)

> **The one-line model:** changes are written to the **sequential WAL first** (cheap, durable); the actual data pages are dirtied in memory and flushed **later** by checkpoints. WAL is what makes that safe — on a crash, Postgres replays WAL to recover anything not yet flushed.

---

## 1. WAL vs dirty buffers — the write path

When a transaction modifies data, two things happen, in order:

1. **WAL record** describing the change is appended to the **write-ahead log** — a *sequential* write to `pg_wal`. On `COMMIT`, the WAL up to that point is **flushed** (`fsync`'d) to disk. This is what makes the commit durable.
2. The actual **data page** in `shared_buffers` is modified in memory and marked **dirty**. It is *not* written to the data files yet.

```
   change ─▶ WAL record ─▶ pg_wal (sequential, fsync on commit)   ← durability lives here
            └▶ data page in shared_buffers marked "dirty"          ← flushed later
```

**Why this design is fast:** sequential WAL writes are far cheaper than random writes scattered across the data files. By making only the WAL durable at commit time and deferring the random data-file writes, Postgres turns many random writes into one sequential stream + a batched flush later. The dirty pages get written out by **checkpoints** (and the background writer) in the background.

So at any moment, the data files on disk are *behind* the logical state of the database; the gap is exactly "the changes recorded in WAL since the last checkpoint." Crash recovery closes that gap by replaying WAL.

---

## 2. Checkpoints — flushing dirty pages

A **checkpoint** writes all currently-dirty pages out to the data files and records a marker in the WAL saying "everything before this point is safely on disk." Its two jobs:

- **Bound crash-recovery time** — recovery only has to replay WAL *from the last checkpoint forward*, not from the beginning of time.
- **Allow WAL cleanup** — once a checkpoint has flushed the pages a WAL segment described, that segment is no longer needed for crash recovery and becomes eligible for recycling/removal (§4).

**What triggers a checkpoint:**

| Trigger | Cause | Config |
|---------|-------|--------|
| **Timed** | `checkpoint_timeout` elapsed since the last one | `checkpoint_timeout` (e.g. `15min`) |
| **Requested** (WAL-driven) | WAL written since last checkpoint approached `max_wal_size` | `max_wal_size` |
| Manual / forced | `CHECKPOINT;`, shutdown, base backup, etc. | — |

> **Health signal:** you want checkpoints to be mostly **timed**, not **requested**. Lots of *requested* checkpoints means WAL is filling `max_wal_size` faster than `checkpoint_timeout` — so raise `max_wal_size`. Check the ratio with `pg_stat_checkpointer` (PG17+) / `pg_stat_bgwriter` (`num_timed` vs `num_requested`) or `log_checkpoints = on`.

**`checkpoint_completion_target`** (default `0.9`) spreads a checkpoint's writes across 90% of the interval to the next one, instead of dumping them all at once — this smooths the I/O spike. Pair it with the kernel's dirty-page writeback tuning ([linux.md](linux.md)) so the flush is a gentle trickle, not a storm.

---

## 3. WAL segment files — what's actually in `pg_wal`

WAL is stored as a sequence of fixed-size **segment files**, **16MB each** by default, named as 24-hex-character files (e.g. `0000000100000A2B000000FE` = timeline + log sequence). New WAL records append to the current segment; when it fills, Postgres advances to the next file.

```
WAL directory size  ≈  (number of segment files) × 16MB
```

So bounding the `pg_wal` directory size is really about controlling **how many segment files exist** — which is what `min_wal_size`, `max_wal_size`, and recycling decide.

### Why 16MB? (and when to change it)

16MB is just the **default** — a balance between two opposing costs, not a magic number:

| Smaller segments | Larger segments |
|------------------|-----------------|
| Finer archiving granularity (`archive_command` runs per segment) | Fewer files → less filesystem metadata, fewer recycle/rename ops |
| Less waste on forced switches (`archive_timeout` ships a whole, possibly-empty segment) | Less per-segment switch overhead; smoother archiving at high write rates |

16MB sits in the middle: small enough that forced switches don't waste much, large enough that `pg_wal` doesn't explode into too many files at normal write rates.

**Tunable at `initdb` only** (powers of two, 1MB–1GB; can't change on a running cluster):
```bash
initdb --wal-segsize=64 -D /path/to/pgdata     # 64MB segments
#   postgres=# SHOW wal_segment_size;
```
**When to raise it:** very high write throughput (thousands of segments churning) → `64`–`256MB` to cut file churn and `archive_command` invocations.

---

## 4. Segment recycling — rename instead of delete

When a segment is no longer needed, Postgres can either **delete** it or **recycle** it. Recycling is the clever part.

**When is a segment "no longer needed"?** All of these must be true:
- a **checkpoint** has completed past it (not needed for crash recovery), **and**
- it has been **archived** if `archive_mode=on` (`archive_command` succeeded), **and**
- no **replication slot** still requires it (up to the `max_slot_wal_keep_size` cap), **and**
- it's older than the most recent **`wal_keep_size`** worth of WAL.

(Full rule and the replication guarantees in [§7](#7-wal-retention-for-replication--wal_keep_size-and-max_slot_wal_keep_size).)

**Recycling = rename to a future name.** At checkpoint time, instead of `unlink()`-ing every freed segment, Postgres **renames** some of them to the filenames that will come *after* the current write position — so they're already allocated and ready to be overwritten:

```
Freed after checkpoint:  [..FC] [..FD]              (16MB files, no longer needed)
Current write position:  [..FE current]

Recycle (rename, don't delete):
                         [..FE current] [..FF ready] [..00 ready] ...
                                         └─ same 16MB file, renamed to a future segment, ready to reuse
```

**Why recycle instead of delete + create?** Creating a fresh WAL segment means allocating and **zero-filling 16MB** — real I/O and filesystem metadata work, right in the write path. Recycling **reuses an already-allocated file** via a cheap rename, so when Postgres needs the next segment it's already sitting there. This keeps WAL writes smooth and avoids allocation stalls during write bursts.

---

## 5. How `min_wal_size` and `max_wal_size` bound the directory

These two (PG 9.5+, replacing the old `checkpoint_segments`) decide **how many freed segments to keep recycled vs. delete**:

| Setting | Role | Effect on `pg_wal` size |
|---------|------|--------------------------|
| **`max_wal_size`** | **Soft** target for WAL accumulated *between* checkpoints. As WAL since the last checkpoint nears it, a **checkpoint is triggered** so segments can be freed. | Upper steer — checkpoints fire to pull size back down. **Not a hard cap.** |
| **`min_wal_size`** | **Floor.** Postgres keeps **at least this much** WAL recycled and ready at all times rather than deleting to nothing. | Below it, freed segments are always **recycled** (kept ready); above it, the excess is **removed** (deleted). |

The checkpoint-time decision, roughly:

```
target = estimate of segments the next cycle will need
         (moving average of recent WAL usage, steered by max_wal_size,
          but never fewer than min_wal_size)

for each freed segment:
    if segments_kept < target:  recycle it   (rename to a future name, keep)
    else:                       remove it     (delete)
```

So Postgres adapts: it keeps roughly as many recycled segments as recent activity suggests it'll need next cycle, with `min_wal_size` as the guaranteed floor and `max_wal_size` steering the ceiling.

### Behavior over time

```
disk used by pg_wal
   ▲
max_wal_size ┄┄┄┄┄┄┄┄┄┄┄┄┄┄  ← checkpoints trigger near here (soft cap)
             │      ╱╲      ╱╲
             │    ╱    ╲  ╱    ╲      ← rises on write bursts, falls after checkpoints free/recycle
min_wal_size ┄┄╱┄┄┄┄┄┄┄╲╱┄┄┄┄┄┄╲┄┄   ← never shrinks below this; segments stay recycled & ready
             │
           0 └──────────────────────▶ time
```

- **Steady state:** `pg_wal` hovers between `min_wal_size` and `max_wal_size`, depending on write rate.
- **`min_wal_size` is a pre-allocation cushion:** raise it to keep more 16MB files always ready, smoothing **bursty** write workloads (no scramble to create files mid-burst) — at the cost of always using that much disk. Lower it to reclaim disk faster after spikes, at the cost of more create/recycle churn if bursts recur.
- **After a sustained high-WAL period ends,** Postgres gradually shrinks the kept set back toward `min_wal_size` (removing the excess instead of recycling it).

---

## 6. The important caveat — `max_wal_size` is *not* a hard limit

`pg_wal` can and will exceed `max_wal_size` when something prevents segments from being freed:

- **Write bursts** outpacing checkpoint completion (temporary, self-corrects).
- **Archiving falling behind / `archive_command` failing** — segments can't be removed until archived.
- **Replication slots retaining WAL** — especially an **inactive** slot; bound it with `max_slot_wal_keep_size`.
- **`wal_keep_size`** set high — keeps extra segments for standbys regardless (see [§7](#7-wal-retention-for-replication--wal_keep_size-and-max_slot_wal_keep_size)).

> This is the classic **"`pg_wal` is filling the disk"** incident. Usual suspect: an **inactive replication slot**. Diagnose with `pg_replication_slots` (look for `active = false` and large `restart_lsn` lag) and a failing `archive_command` in the logs.

**Sizing the volume:** budget the `pg_wal` filesystem *above* `max_wal_size` plus whatever your slots/archiving could plausibly retain — never size it exactly to `max_wal_size`.

---

## 7. WAL retention for replication — `wal_keep_size` and `max_slot_wal_keep_size`

Three parameters with similar names do three different jobs:

| Parameter | Kind | Applies to | What it does | Default |
|-----------|------|------------|--------------|---------|
| **`wal_keep_size`** (PG13+; was `wal_keep_segments`) | **Floor** | Standbys streaming **without** a slot | Always keep at least this much recent WAL in `pg_wal`, whether anyone needs it or not | `0` |
| **`max_wal_size`** | **Checkpoint trigger** | Nothing to do with replication | Start a checkpoint once this much WAL has been written since the last one (soft, see §5–6) | `1GB` |
| **`max_slot_wal_keep_size`** (PG13+) | **Cap** | **Every slot, physical *and* logical** | The most WAL a single slot may force the primary to keep. Past it, the slot is invalidated (`wal_status = 'lost'`) | `-1` (no cap) |

> **Common mix-up:** there is no `max_wal_keep_size`. And `max_slot_wal_keep_size` is **not** physical-only: it is the one setting that **can** remove WAL a logical subscriber still needs.

### When WAL is actually removed

**Only at the end of a checkpoint** (a *restartpoint* on a standby). Nothing else deletes WAL. Postgres finds the oldest segment still needed, which is the **earliest** of:

1. the **redo point** of the checkpoint that just finished (crash recovery needs it; always kept);
2. the oldest **`restart_lsn`** of any replication slot, but no more than `max_slot_wal_keep_size` back;
3. the current WAL position minus **`wal_keep_size`**;
4. the oldest segment **not yet archived** (`.ready` in `pg_wal/archive_status/`), when `archive_mode = on`.

Everything older is recycled or removed (§4–5). A checkpoint runs every `checkpoint_timeout`, when `max_wal_size` is reached, or on `CHECKPOINT` / shutdown / base backup, so a slot that becomes invalid is only acted on at the next one.

### Physical replication: is the WAL guaranteed?

A physical standby **can stream without a slot**; slots are optional (`primary_slot_name` on the standby).

| | Without a slot | With a slot |
|---|---|---|
| Does the primary know what the standby needs? | No | Yes, via the slot's `restart_lsn` |
| WAL guaranteed? | Only the last `wal_keep_size` | **Yes**, all of it, until `max_slot_wal_keep_size` is reached (no limit if `-1`) |
| Standby falls further behind than that | The WAL is removed: `requested WAL segment ... has already been removed` | The slot is marked `lost` and the WAL is removed |
| Risk | The standby breaks | With no cap, the **primary's disk fills** |
| `hot_standby_feedback` | Only while connected | The `xmin` is kept in the slot even while disconnected |

**The safety net for physical standbys is the archive.** When streaming can't provide a segment, the standby runs `restore_command` to fetch it from the WAL archive, catches up, then switches back to streaming by itself. That only works if `restore_command` is correct (for pgBackRest it's `archive-get`, never `archive-push`) and the archive still has the segment. Without a working archive, a standby that has lost its WAL has to be rebuilt (`pg_basebackup` or a restore).

### Logical replication: is the WAL guaranteed?

Logical replication **always** uses a slot (`CREATE SUBSCRIPTION` creates one on the publisher by default). The slot keeps:
- **`restart_lsn`**: all WAL from here on, until the subscriber confirms it (`confirmed_flush_lsn`);
- **`catalog_xmin`**: system-catalog rows decoding may still need, which holds back catalog vacuum.

So **yes, all WAL the subscriber needs is kept, as long as the slot exists and is still valid.** `wal_keep_size` plays no part. The guarantee breaks when:

| Case | Result |
|------|--------|
| `max_slot_wal_keep_size` exceeded | The slot is invalidated (`wal_status = 'lost'`) |
| `idle_replication_slot_timeout` (PG18+, off by default) | An inactive slot is invalidated after the timeout |
| Failover to a physical standby on PG ≤ 16 | Logical slots aren't copied to standbys, so the slot doesn't exist on the new primary. PG17+ has failover slots (`failover = true` + `sync_replication_slots = on`); Patroni has *permanent slots* |
| The slot is dropped (often to free disk) | Retention stops at once |
| `wal_level` lowered below `logical` | Logical slots are invalidated at restart |

**Logical has no archive fallback.** The walsender only decodes WAL from the publisher's own `pg_wal`; it can't fetch from the archive. A lost logical slot always means dropping and recreating the subscription and a **full resync** of the tables (`copy_data = true`), or a new snapshot for CDC tools.

**A stuck subscriber is a disk problem on the publisher.** If the subscriber is down, or keeps failing on an apply error (unique violation, missing table, permissions), the slot doesn't advance and WAL piles up. With an apply error the slot can still show `active = true`, so alert on **retained WAL growing**, not only on `active = false`. PG15+ `disable_on_error` at least makes the failure visible.

### Summary

| | WAL guaranteed until… | When the guarantee runs out | Recovery |
|---|---|---|---|
| Physical, no slot | `wal_keep_size` is exceeded | Segment removed | Archive (`restore_command`), else rebuild |
| Physical, slot | `max_slot_wal_keep_size` (or the disk fills, if `-1`) | Slot `lost` | Archive (`restore_command`), else rebuild |
| Logical (always a slot) | `max_slot_wal_keep_size` / slot dropped / failover (PG ≤ 16) | Slot `lost` or missing | **Full resync only** |

### Worked example: worst-case `pg_wal` size

With `wal_keep_size = 16GB`, `max_wal_size = 16GB`, `max_slot_wal_keep_size = 32GB`:

| Situation | Approximate `pg_wal` |
|---|---|
| Everything healthy, all slots caught up | About **16GB** (`wal_keep_size`) plus the current checkpoint cycle's segments, e.g. ~18GB |
| A standby or subscriber stops | Grows until its slot holds 32GB, plus up to ~16GB written before the next checkpoint enforces the cap: **~45–50GB peak**, then the slot is `lost` |
| `archive_command` failing | **No limit** until the disk is full |

Takeaways:
- **With slots, a large `wal_keep_size` mostly just costs disk.** It's always in use even when every standby is caught up. It is still the only protection for a standby whose slot was dropped or invalidated, or for a base backup taken without a slot, so lower it only once the archive fallback is known to work.
- **Set `max_slot_wal_keep_size` below the free space on the `pg_wal` volume**, so a dead consumer costs a resync or a fetch from the archive instead of a full disk on the primary.
- **A failing `archive_command` fills the disk the same way**, and no setting caps it. Monitor `pg_stat_archiver`.

### What is holding WAL right now?

```sql
-- Slots holding WAL back (physical and logical)
SELECT slot_name, slot_type, active, wal_status, safe_wal_size,
       pg_size_pretty(pg_wal_lsn_diff(pg_current_wal_lsn(), restart_lsn)) AS held
FROM pg_replication_slots ORDER BY restart_lsn;

-- Is each physical standby actually using a slot? (empty slot_name = no slot)
SELECT r.application_name, r.client_addr, s.slot_name, s.active, s.wal_status
FROM pg_stat_replication r
LEFT JOIN pg_replication_slots s ON s.active_pid = r.pid;

-- Archiving stuck?
SELECT archived_count, failed_count, last_failed_wal, last_failed_time, stats_reset FROM pg_stat_archiver;
SELECT count(*) AS not_archived FROM pg_ls_dir('pg_wal/archive_status') f WHERE f LIKE '%.ready';

-- Settings in force, and where they come from (postgresql.conf vs postgresql.auto.conf)
SELECT name, setting, unit, sourcefile FROM pg_settings
WHERE name IN ('wal_keep_size','max_slot_wal_keep_size','max_wal_size','min_wal_size','checkpoint_timeout','restore_command');

-- Size of pg_wal
SELECT pg_size_pretty(sum(size)) FROM pg_ls_waldir();
```

**Alert on:** a slot with `active = false` for more than a few minutes; `wal_status` other than `reserved` (`extended` and `unreserved` are warnings, `lost` means broken); retained WAL growing past a threshold sized for the volume; and any increase in `pg_stat_archiver.failed_count`.

---

## 8. Crash recovery (why all this is safe)

On restart after a crash, Postgres:
1. Finds the **last checkpoint** record in the WAL.
2. **Replays** (REDO) every WAL record from that checkpoint forward, re-applying changes to data pages that hadn't been flushed yet.
3. Opens the database once WAL is exhausted — now the data files match the last durably-committed state.

This is also the foundation of **streaming replication** (standbys replay the primary's WAL) and **PITR** (replay archived WAL to a chosen point in time). Two durability guards make replay correct:
- **`full_page_writes = on`** — writes a full image of a page the first time it changes after a checkpoint, protecting against **torn pages** (partial 8KB writes during a crash).
- **`fsync = on`** + **`synchronous_commit = on`** — ensure WAL is truly on disk at commit. (See [best-practices.md](best-practices.md) → Durability. Never disable these in production.)

---

## 9. Monitoring & key settings

**Watch:**
- **Checkpoint cause ratio** — `num_timed` vs `num_requested` in `pg_stat_checkpointer` (PG17+) / `pg_stat_bgwriter`. Mostly requested → raise `max_wal_size`.
- **`log_checkpoints = on`** — logs each checkpoint's timing and buffers written.
- **`pg_wal` size** — `SELECT pg_size_pretty(sum(size)) FROM pg_ls_waldir();`
- **Replication slot lag** — `pg_replication_slots` (inactive slots retaining WAL).

**Relevant config** (full table in [best-practices.md](best-practices.md)):

| Parameter | Typical | Purpose |
|-----------|---------|---------|
| `max_wal_size` | large enough that checkpoints are mostly *timed* | soft WAL ceiling between checkpoints |
| `min_wal_size` | `1`–`2GB` | floor of recycled segments kept ready |
| `checkpoint_timeout` | `15min` (`30min` write-heavy) | max time between checkpoints |
| `checkpoint_completion_target` | `0.9` | spread checkpoint writes to smooth I/O |
| `wal_compression` | `on` | smaller full-page images → less WAL |
| `wal_keep_size` | small (or `0`) when slots are used | floor of WAL always kept for slot-less standbys (§7) |
| `max_slot_wal_keep_size` | below free space on the `pg_wal` volume | cap WAL any slot (physical or logical) can pin (§7) |

---

## Mapping to the interview

- *"How does Postgres stay durable without writing data files on every commit?"* → WAL-first: sequential WAL is fsync'd at commit; dirty data pages flush later via checkpoints; crash recovery replays WAL from the last checkpoint.
- *"What do `min_wal_size` / `max_wal_size` do?"* → `max` is a soft target that triggers checkpoints; `min` is the floor of recycled segments kept ready. Together they bound `pg_wal` and adapt to write rate.
- *"What is WAL recycling?"* → renaming freed 16MB segments to future names instead of deleting + re-creating, avoiding zero-fill/metadata cost in the write path.
- *"`pg_wal` is filling the disk — why?"* → inactive replication slot (most common), failing `archive_command`, big write burst, or high `wal_keep_size`. `max_wal_size` is a *soft* limit.
- *"Timed vs requested checkpoints?"* → mostly requested means WAL hits `max_wal_size` before `checkpoint_timeout` — raise `max_wal_size`.
- *"`wal_keep_size` vs `max_slot_wal_keep_size` vs `max_wal_size`?"* → floor kept for slot-less standbys / cap on what any slot may pin / checkpoint trigger. Only the cap can invalidate a slot.
- *"When is WAL deleted on the primary?"* → only at the end of a checkpoint, and only segments older than all of: the redo point, the oldest slot `restart_lsn` (up to the cap), `wal_keep_size`, and the oldest unarchived segment.
- *"Can a physical standby replicate without a slot?"* → yes; it's then protected only by `wal_keep_size`, and falls back to the archive via `restore_command` once the primary has removed its WAL.
- *"Is all WAL a logical subscriber needs retained?"* → yes, by its slot, unless the slot is invalidated by `max_slot_wal_keep_size`, dropped, or lost on failover (PG ≤ 16). There's no archive fallback, so a lost logical slot means a full resync.
