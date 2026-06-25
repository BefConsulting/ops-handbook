# WAL & Checkpoints

How PostgreSQL keeps data durable without writing every change to disk twice immediately — the **write-ahead log (WAL)**, how **checkpoints** flush dirty data, how the **`pg_wal` directory size** is bounded, and how **segment recycling** avoids filesystem churn.

**See also:** [best-practices.md](best-practices.md) (the WAL/checkpoint config table) · [linux.md](linux.md) (dirty-page writeback, fsync) · [monitoring.md](monitoring.md) (checkpoint & WAL metrics)

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
- no **replication slot** still requires it.

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
- **`wal_keep_size`** set high — keeps extra segments for standbys regardless.

> This is the classic **"`pg_wal` is filling the disk"** incident. Usual suspect: an **inactive replication slot**. Diagnose with `pg_replication_slots` (look for `active = false` and large `restart_lsn` lag) and a failing `archive_command` in the logs.

**Sizing the volume:** budget the `pg_wal` filesystem *above* `max_wal_size` plus whatever your slots/archiving could plausibly retain — never size it exactly to `max_wal_size`.

---

## 7. Crash recovery (why all this is safe)

On restart after a crash, Postgres:
1. Finds the **last checkpoint** record in the WAL.
2. **Replays** (REDO) every WAL record from that checkpoint forward, re-applying changes to data pages that hadn't been flushed yet.
3. Opens the database once WAL is exhausted — now the data files match the last durably-committed state.

This is also the foundation of **streaming replication** (standbys replay the primary's WAL) and **PITR** (replay archived WAL to a chosen point in time). Two durability guards make replay correct:
- **`full_page_writes = on`** — writes a full image of a page the first time it changes after a checkpoint, protecting against **torn pages** (partial 8KB writes during a crash).
- **`fsync = on`** + **`synchronous_commit = on`** — ensure WAL is truly on disk at commit. (See [best-practices.md](best-practices.md) → Durability. Never disable these in production.)

---

## 8. Monitoring & key settings

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
| `max_slot_wal_keep_size` | bound it | cap WAL an inactive slot can pin |

---

## Mapping to the interview

- *"How does Postgres stay durable without writing data files on every commit?"* → WAL-first: sequential WAL is fsync'd at commit; dirty data pages flush later via checkpoints; crash recovery replays WAL from the last checkpoint.
- *"What do `min_wal_size` / `max_wal_size` do?"* → `max` is a soft target that triggers checkpoints; `min` is the floor of recycled segments kept ready. Together they bound `pg_wal` and adapt to write rate.
- *"What is WAL recycling?"* → renaming freed 16MB segments to future names instead of deleting + re-creating, avoiding zero-fill/metadata cost in the write path.
- *"`pg_wal` is filling the disk — why?"* → inactive replication slot (most common), failing `archive_command`, big write burst, or high `wal_keep_size`. `max_wal_size` is a *soft* limit.
- *"Timed vs requested checkpoints?"* → mostly requested means WAL hits `max_wal_size` before `checkpoint_timeout` — raise `max_wal_size`.
