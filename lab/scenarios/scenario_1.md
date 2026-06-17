# Scenario 1: Sequential Scan (no index on `region`)

## Query

```sql
EXPLAIN (ANALYZE, BUFFERS, VERBOSE)
SELECT *
FROM customers
WHERE region = 'US-EAST';
```

## Actual output

```
                                                     QUERY PLAN
--------------------------------------------------------------------------------------------------------------------
 Seq Scan on public.customers  (cost=0.00..229.00 rows=2000 width=51) (actual time=0.019..11.749 rows=2000 loops=1)
   Output: id, email, region, status, created_at
   Filter: (customers.region = 'US-EAST'::text)
   Rows Removed by Filter: 8000
   Buffers: shared hit=104
 Planning:
   Buffers: shared hit=72
 Planning Time: 1.076 ms
 Execution Time: 12.082 ms
```

## What the query does

PostgreSQL reads **every row** in `customers` (10,000 total), checks `region = 'US-EAST'`, and keeps 2,000 of them. There is no index on `region` yet, so it uses a **Sequential Scan**.

---

## The plan node (read bottom-up)

```
Seq Scan on public.customers
  (cost=0.00..229.00 rows=2000 width=51)
  (actual time=0.019..11.749 rows=2000 loops=1)
```

| Part | Meaning |
|------|---------|
| **Seq Scan** | Read the whole table page by page |
| **cost=0.00..229.00** | Planner guess: cheap start, ~229 total cost units (not milliseconds) |
| **rows=2000** | Planner **estimated** 2,000 matching rows |
| **width=51** | ~51 bytes per output row |
| **actual time=0.019..11.749** | Real time: 0.019 ms to first row, 11.749 ms total |
| **rows=2000** | Actually returned 2,000 rows — estimate was spot-on |
| **loops=1** | Scan ran once |

Good sign: **estimated rows = actual rows (2000)**. Stats are healthy.

---

## Filter line — the important detail

```
Filter: (customers.region = 'US-EAST'::text)
Rows Removed by Filter: 8000
```

PostgreSQL read **10,000 rows** and threw away **8,000** after the filter.

That means it did work on rows it didn't need. On a small table (10k) that's fine (~12 ms). On millions of rows this would be painful.

**Key point:** *"Seq scan with a high 'Rows Removed by Filter' on a large table usually means we need an index or a more selective predicate."*

---

## Buffers — cache vs disk

```
Buffers: shared hit=104
```

- **shared hit=104** → 104 pages found in PostgreSQL's buffer cache (RAM)
- No **shared read** → nothing had to be read from disk this time

The whole table was already warm in cache, so this was as fast as a seq scan gets.

**Key point:** *"All buffer hits — table was cached. I'd still look at the plan shape, not just speed, because cold cache or production scale changes the story."*

---

## Planning section

```
Planning:
  Buffers: shared hit=72
Planning Time: 1.076 ms
Execution Time: 12.082 ms
```

- **Planning Time** — time to choose the plan (~1 ms)
- **Execution Time** — time to run the query (~12 ms), not including sending results to your terminal

Total wall time ≈ **13 ms**.

---

## Visual summary

```
customers table (10,000 rows, 104 pages in cache)
        │
        ▼
   Seq Scan  ── reads ALL rows
        │
        ▼
   Filter region = 'US-EAST'
        │
        ├── keep:    2,000 rows  ✓
        └── discard: 8,000 rows  ✗
        │
        ▼
   Return 2,000 rows  (12 ms)
```

---

## What to try next (Exercise 2)

```sql
CREATE INDEX idx_customers_region ON customers(region);

EXPLAIN (ANALYZE, BUFFERS)
SELECT id, email
FROM customers
WHERE region = 'US-EAST';
```

You should see something like:

```
Index Scan using idx_customers_region on customers ...
```

Compare:

- **Execution Time** — should drop a lot
- **Buffers** — fewer pages touched
- **No "Rows Removed by Filter: 8000"** — index goes straight to matching rows
