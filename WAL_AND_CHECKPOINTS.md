# WAL, Dirty Buffers & Checkpoints

How PostgreSQL gets **durability and speed at the same time**: a compact log written at commit (WAL) plus actual data pages flushed lazily later (dirty buffers), reconciled at checkpoints.

**See also:** [POSTGRESQL_DEEP_DIVE.md](POSTGRESQL_DEEP_DIVE.md) §1.2 · [CACHE.md](CACHE.md) · [PERFORMANCE_ANALYSIS.md](PERFORMANCE_ANALYSIS.md)

---

## WAL vs Dirty Buffers — the core distinction

Two representations of the same change, with two different jobs: **WAL makes changes durable; dirty buffers make changes fast.**

| | **WAL record** | **Dirty buffer** |
|---|----------------|------------------|
| **What** | A small log entry describing *what changed* | A full 8KB data page in memory that *has* the change |
| **Where** | `pg_wal/` on disk (written almost immediately) | `shared_buffers` in RAM |
| **Form** | Sequential, append-only log | The actual table/index page |
| **Purpose** | **Durability** + recovery + replication | **Performance** — avoid random disk writes |
| **Write pattern** | Sequential (fast on any disk) | Random (scattered across data files) |
| **When it hits disk** | At/around **COMMIT** (fsync) | **Later**, lazily, at a checkpoint or under memory pressure |

---

## What is a dirty buffer?

PostgreSQL never edits table files directly on disk. It loads an 8KB page into `shared_buffers` (RAM), modifies it there, and marks it **dirty** (changed in memory, not yet written back to the data file).

```
UPDATE customers SET email='x' WHERE id=42;
        |
        v
Load page into shared_buffers (if not already there)
        |
        v
Modify the row in memory  ->  page is now DIRTY
                              (RAM has new data, disk file still has old data)
```

Writing each change straight to the data file would be a **random write** to a scattered location every time — slow. Batching dirty pages and flushing later (coalescing many changes to the same page into one write) is far more efficient.

---

## What is WAL?

Before the change is made to the buffer, PostgreSQL writes a **WAL record** — a compact description of the change — to the write-ahead log. At COMMIT, that record is **fsync'd to disk**.

```
UPDATE customers ...
        |
        v
1. Write WAL record ("on page X, set row 42 email='x'")  -> WAL buffer
2. Modify the data page in shared_buffers                 -> dirty buffer
        |
   COMMIT
        v
3. fsync WAL to disk   <-- THIS is what makes the commit durable
```

The WAL hits disk at commit; the dirty data page does **not**. The commit is safe the instant the WAL is flushed, even though the table page is still only in RAM.

---

## The rule: Write-Ahead (WAL-before-data)

> A dirty buffer may **never** be written to the data file before its corresponding WAL record is on disk.

This is the guarantee that makes the scheme safe. WAL is the source of truth for durability; the data file catches up later.

---

## What happens on a crash

Crash after COMMIT but **before** the dirty buffer was flushed:

```
On disk:  WAL has the change  OK      Data file has OLD data  (stale)
                |
          Server restarts
                |
                v
        Crash recovery / REDO:
        replay WAL records -> re-apply changes to data files
                |
                v
        Data file now has the committed change  OK
```

The dirty buffer was lost (RAM only), but the **WAL survived**, so recovery replays it and reconstructs the change. **No committed data is lost** — the entire point of WAL.

---

## Checkpoints — reconciling the two

A **checkpoint** flushes **all current dirty buffers** to the data files and records "everything up to WAL position X is safely persisted" (the redo point).

```
Checkpoint:
  - flush all dirty buffers -> data files
  - record the WAL redo point
  - WAL before that point is no longer needed for crash recovery (can recycle)
```

After a checkpoint, crash recovery only needs to replay WAL **since the last checkpoint** — so checkpoint frequency bounds recovery time.

```
Timeline:
  COMMIT ──> WAL on disk (durable) ──────────────►
                 |                                 |
           dirty buffer in RAM ───────────► CHECKPOINT flushes it to data file
```

### What triggers a checkpoint
- **Time:** every `checkpoint_timeout` (default 5 min)
- **Volume:** WAL since last checkpoint approaches `max_wal_size` (default 1GB)
- **Manual:** `CHECKPOINT;` command
- **Events:** shutdown, `pg_basebackup`, etc.

### Key checkpoint parameters
| Parameter | Default | Role |
|-----------|---------|------|
| `checkpoint_timeout` | 5min | Max time between checkpoints |
| `max_wal_size` | 1GB | Soft cap on WAL before a checkpoint is forced |
| `min_wal_size` | 80MB | Floor for recycled WAL files |
| `checkpoint_completion_target` | 0.9 | Spread the flush over this fraction of the interval (smooths I/O) |

---

## `max_wal_size` and how it relates to checkpoints

`max_wal_size` is a **soft limit on how much WAL accumulates between checkpoints**. It is *not* a hard disk cap and *not* the size of a single WAL file — it's the budget of WAL allowed to pile up before Postgres says "that's enough, checkpoint now."

### A checkpoint is triggered by whichever comes first:
```
TIME:    checkpoint_timeout elapses (default 5 min)          -> "timed" checkpoint
VOLUME:  WAL written since last checkpoint nears max_wal_size -> "requested" checkpoint
```

- Hit the **timer** first → counts in `checkpoints_timed`.
- Hit the **WAL volume** first → counts in `checkpoints_req` (a *demand/forced* checkpoint).

### Why the relationship matters
A checkpoint must flush all dirty buffers — that's an I/O burst. So you want checkpoints **spaced out and predictable**, ideally driven by the timer, not by WAL filling up:

- **`checkpoints_req` high vs `checkpoints_timed`** → WAL is filling faster than `checkpoint_timeout`, forcing frequent demand checkpoints. Frequent checkpoints = more `full_page_writes` (the first change to a page after a checkpoint writes the whole page to WAL), which generates *even more* WAL → a vicious cycle. **Fix: raise `max_wal_size`.**
- **`max_wal_size` too small** → constant forced checkpoints, I/O spikes, WAL amplification.
- **`max_wal_size` too large** → fewer checkpoints (good for steady-state I/O) but **longer crash recovery** (more WAL to replay) and more disk used by `pg_wal`.

So `max_wal_size` is the main knob to **trade checkpoint frequency against crash-recovery time and disk usage**:

```
small max_wal_size  ->  frequent checkpoints  ->  fast recovery, more I/O churn, WAL amplification
large max_wal_size  ->  rare checkpoints      ->  slow recovery, smoother I/O, more pg_wal disk
```

### Practical tuning
```sql
-- If checkpoints_req is climbing, give WAL more room
ALTER SYSTEM SET max_wal_size = '4GB';
ALTER SYSTEM SET checkpoint_timeout = '15min';
ALTER SYSTEM SET checkpoint_completion_target = 0.9;  -- spread flush, avoid spikes
SELECT pg_reload_conf();
```
Rule of thumb: size `max_wal_size` so that under normal write load, checkpoints are driven by `checkpoint_timeout` (timed), not by volume (requested).

---

## Reading `pg_stat_bgwriter` (interpretation cheat-sheet)

```sql
SELECT * FROM pg_stat_bgwriter;
```

| Field | Meaning | What to watch for |
|-------|---------|-------------------|
| `checkpoints_timed` | Checkpoints fired by `checkpoint_timeout` | Want this to dominate |
| `checkpoints_req` | Checkpoints forced by `max_wal_size` (demand) | **High vs timed → raise `max_wal_size`** |
| `checkpoint_write_time` | Total ms writing during checkpoints | Large is fine — it's spread on purpose |
| `checkpoint_sync_time` | Total ms in `fsync` at checkpoint end | Spikes → slow storage |
| `buffers_checkpoint` | Dirty pages written by checkpointer | Planned writes (good) |
| `buffers_clean` | Dirty pages written by the **background writer** | 0 = bgwriter idle/too conservative |
| `maxwritten_clean` | Times bgwriter stopped early (hit its cap) | High → raise `bgwriter_lru_maxpages` |
| `buffers_backend` | Dirty pages **backends flushed themselves** | High proportion → cache pressure; make bgwriter aggressive / raise `shared_buffers` |
| `buffers_backend_fsync` | Times a backend did its own fsync | **Must be ~0**; >0 = fsync queue overflow (serious) |
| `buffers_alloc` | Buffers allocated | Cache demand gauge |

### Healthy picture (the ideal)
- `checkpoints_req = 0` (or ≪ `checkpoints_timed`) → WAL not outpacing the timer; `max_wal_size` sized fine.
- `buffers_backend_fsync = 0` → no fsync-queue pressure.
- Most writes come from `buffers_checkpoint` (planned), not `buffers_backend`.

### Pressure signals & fixes
| Signal | Likely fix |
|--------|------------|
| `checkpoints_req` rising | Raise `max_wal_size`, raise `checkpoint_timeout` |
| `buffers_backend` large share + `buffers_clean=0` | Make bgwriter aggressive (`bgwriter_lru_maxpages`↑, `bgwriter_delay`↓); raise `shared_buffers` |
| `buffers_backend_fsync > 0` | Investigate I/O subsystem; increase `shared_buffers`; check storage |
| `maxwritten_clean` high | Raise `bgwriter_lru_maxpages` |

> Note: a high `buffers_backend` share is **normal during one-off bulk loads** (a big insert burst fills `shared_buffers` faster than the gentle bgwriter reacts). It's only a concern if it persists under steady OLTP load.

**Version note:** on **PG16** these all live in `pg_stat_bgwriter`. In **PG17+**, `buffers_backend` / `buffers_backend_fsync` moved to `pg_stat_io`, and checkpoint counters moved to `pg_stat_checkpointer`.

---

## Analogy

A busy kitchen:

- **WAL** = the **order ticket** written immediately and pinned up. Compact, sequential, never lost. If the kitchen burns down, the tickets tell you exactly what to remake.
- **Dirty buffer** = the **half-plated dish** on the counter. The real food, but rebuildable from the ticket if lost.
- **Checkpoint** = periodically **delivering all finished plates** to tables and clearing tickets you no longer need.

---

## Why both exist

| If you only had... | Problem |
|--------------------|---------|
| Only dirty buffers (no WAL) | A crash loses everything in RAM → committed data lost → no durability |
| Only WAL, flush data every commit | Every commit = slow random writes to data files → terrible performance |

Together: **commit = one fast sequential WAL write (durable)** + **data files updated lazily in batches (fast)**. Durability *and* speed.

---

## Operational issues (DBRE relevance)

| Symptom | Cause / fix |
|---------|-------------|
| **WAL fills the disk** | Inactive replication slot or failing `archive_command` prevents WAL recycling → see deep dive §1.2 |
| **Checkpoint I/O spikes / latency** | Too many dirty buffers flushed at once → raise `max_wal_size`, set `checkpoint_completion_target=0.9` |
| **Slow commits** | `fsync` storage latency on WAL → put `pg_wal` on fast disk |
| **Long crash recovery** | Checkpoints too far apart → lower `checkpoint_timeout` / `max_wal_size` (trades steady-state I/O for faster recovery) |
| **`shared_buffers` too small** | Pages evicted while still dirty → extra I/O churn |

Monitor:
```sql
-- Checkpoint & dirty-buffer activity (PG16: pg_stat_checkpointer; older: pg_stat_bgwriter)
SELECT * FROM pg_stat_bgwriter;
-- buffers_checkpoint  = pages written by checkpoints
-- buffers_clean       = pages written by background writer
-- buffers_backend     = pages a backend had to write itself (pressure signal)

SELECT pg_current_wal_lsn();           -- current WAL write position
SELECT checkpoint_lsn FROM pg_control_checkpoint();  -- last checkpoint location
```

Tip: frequent `buffers_backend` writes mean backends are flushing dirty pages themselves because the bgwriter/checkpointer can't keep up — a sign to tune checkpoint/bgwriter settings.

---

## One-liner for the interview

> *"A dirty buffer is the actual 8KB data page modified in RAM but not yet written to the data file; the WAL record is a compact, sequential log of that change flushed to disk at commit. WAL is written before the data page (write-ahead rule) and gives durability — on crash it's replayed to recover changes whose dirty buffers were lost. Checkpoints flush all dirty buffers to data files and advance the redo point, turning slow random writes into fast sequential WAL plus batched flushing. Checkpoint frequency trades steady-state I/O against crash-recovery time."*
