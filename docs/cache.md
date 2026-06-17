# Cold Cache vs Warm Cache

**Cache = data held in fast memory (RAM) instead of slow disk.** "Cold" vs "warm" describes whether the data you need is *already in memory* or *still on disk*.

---

## The two states

| State | Meaning | Speed |
|-------|---------|-------|
| **Cold cache** | Data is **not** in memory yet — must read from disk | Slow (first access) |
| **Warm cache** | Data is **already** in memory from a previous read | Fast (repeat access) |

---

## Why it happens in PostgreSQL

Postgres keeps recently-used table/index pages in a RAM area called **`shared_buffers`** (plus the OS file cache).

```
First time you query a table -> pages on disk -> load into RAM   (COLD)
                                                      |
                                                      v
Next time you query it       -> pages already in RAM -> fast     (WARM)
```

- **Cold:** right after a server restart, or the first time a table/index is touched, or when data was evicted to make room for other data
- **Warm:** the data has been read recently and is still cached

---

## How you see it in EXPLAIN

This is exactly what the `Buffers:` line shows:

```
Buffers: shared hit=104 read=4
                  |          |
                  |          +-- READ from disk  = COLD (4 pages)
                  +------------- HIT in cache    = WARM (104 pages)
```

- **`shared hit`** = found in memory (warm) -> fast
- **`shared read`** = had to fetch from disk (cold) -> slow

Example from **scenario_2.md**: the new index showed `shared read=4` on the Bitmap Index Scan — because the index was **cold** (just created, never read yet). The table was **warm** (`shared hit=104`) from the Scenario 1 seq scan.

---

## Why it matters for performance analysis

**The same query can look fast or slow depending only on cache state:**

```sql
-- First run (cold): 200 ms   -- reading from disk
EXPLAIN (ANALYZE, BUFFERS) SELECT ...;

-- Second run (warm): 5 ms    -- same query, now cached
EXPLAIN (ANALYZE, BUFFERS) SELECT ...;
```

**Common misconception:** *"My query got faster the second time!"* — That's just the cache warming up, not a real optimization. To compare fairly, run a query **2–3 times** and look at the **warm** number, or deliberately test cold performance.

---

## Cold cache red flags (from the health check)

| Symptom | What it suggests |
|---------|------------------|
| `cache_hit_pct` < 95% (health check #2) | Working set bigger than RAM -> constantly cold |
| High `shared read` in EXPLAIN | This query touches cold/uncached data |
| `wait_event_type = IO` (health check #1) | Query stalled waiting on disk reads (cold) |

**Common causes of a persistently cold cache:**

- `shared_buffers` too small for your data
- Table/indexes larger than available RAM
- Server recently restarted (cache empty until traffic warms it)
- A big one-off query evicting the "hot" working set (cache thrashing)

---

## Fixes

| Problem | Fix |
|---------|-----|
| Working set > RAM | More RAM, or `shared_buffers` tuning |
| Reading too many pages | Better/narrower indexes (fewer pages to read) |
| Cold after restart | Pre-warm with `pg_prewarm` extension |
| One query evicts hot data | Isolate analytics from OLTP, partition cold data |

---

## Summary

> *"Cold cache means the data isn't in `shared_buffers` or OS cache yet, so Postgres reads from disk — you see it as `shared read` in EXPLAIN BUFFERS. Warm cache is `shared hit`. I always run a query a few times before judging it, because the first run pays the cold-read cost."*

---

**See also:** [performance-analysis.md](performance-analysis.md) · [../README.md](../README.md) · [scenario_2.md](../lab/scenarios/scenario_2.md)
