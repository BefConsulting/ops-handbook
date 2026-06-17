# Scenario 2: Bitmap Index Scan (after adding index on `region`)

## Query

```sql
CREATE INDEX idx_customers_region ON customers(region);

EXPLAIN (ANALYZE, BUFFERS)
SELECT id, email
FROM customers
WHERE region = 'US-EAST';
```

## Actual output

```
                                                             QUERY PLAN
------------------------------------------------------------------------------------------------------------------------------------
 Bitmap Heap Scan on customers  (cost=27.79..156.78 rows=2000 width=28) (actual time=0.089..0.560 rows=2000 loops=1)
   Recheck Cond: (region = 'US-EAST'::text)
   Heap Blocks: exact=104
   Buffers: shared hit=104 read=4
   ->  Bitmap Index Scan on idx_customers_region  (cost=0.00..27.29 rows=2000 width=0) (actual time=0.069..0.069 rows=2000 loops=1)
         Index Cond: (region = 'US-EAST'::text)
         Buffers: shared read=4
 Planning:
   Buffers: shared hit=16 read=1
 Planning Time: 0.304 ms
 Execution Time: 0.635 ms
```

## Headline: 19× faster than Scenario 1

| Metric | Scenario 1 (Seq Scan) | Scenario 2 (Bitmap) |
|--------|----------------------|---------------------|
| Execution Time | 12.082 ms | **0.635 ms** |
| Planning Time | 1.076 ms | 0.304 ms |
| Plan type | Seq Scan | Bitmap Index Scan → Bitmap Heap Scan |
| Rows returned | 2,000 | 2,000 |

---

## What is Bitmap Scan? (brief)

A **bitmap scan** is two steps working together:

1. **Bitmap Index Scan** — walk the index, build a bitmap (map of heap page IDs with matching rows). Does not fetch table rows yet.
2. **Bitmap Heap Scan** — visit those heap pages **in order**, read rows, apply **Recheck Cond** filter.

**Why use it?** Plain **Index Scan** = one random heap jump per row (bad for many matches). **Seq Scan** = read the whole table (bad for moderate selectivity). Bitmap batches heap reads and reduces random I/O.

| Selectivity | Typical plan |
|-------------|--------------|
| Few rows (< ~5%) | **Index Scan** |
| Moderate (~5–20%) | **Bitmap Scan** |
| Most of table (> ~20%) | **Seq Scan** |

- **Exact bitmap** (`Heap Blocks: exact=N`) — knows precise rows
- **Lossy bitmap** — page-level only; must recheck every row on those pages

```
Index Scan:  index → row → index → row → index → row  (random hops)
Bitmap Scan: index → {pages 3,7,12…} → read 3, 7, 12 in order
```

---

## Why Bitmap Scan instead of Index Scan?

You might expect a plain **Index Scan**. PostgreSQL chose **Bitmap Index Scan** instead because:

- You're returning **2,000 of 10,000 rows** (~20% of the table)
- At moderate selectivity, bitmap is often cheaper than row-by-row index lookups
- Bitmap collects matching row locations first, then visits heap pages in order (fewer random I/O trips)

**Rule of thumb:**

| Selectivity | Typical plan |
|-------------|--------------|
| Very selective (< ~5%) | **Index Scan** |
| Moderate (~5–15%) | **Bitmap Index Scan** |
| Low (> ~15–20%) | **Seq Scan** or **Bitmap** |

With 5 regions evenly distributed, `US-EAST` ≈ 20% — right in bitmap territory.

**Key point:** *"The planner didn't pick a simple Index Scan because we're fetching a large fraction of the table. Bitmap batching reduces random heap access."*

---

## Read the plan bottom-up

### Step 1 — Bitmap Index Scan (inner node, runs first)

```
Bitmap Index Scan on idx_customers_region
  Index Cond: (region = 'US-EAST'::text)
  Buffers: shared read=4
```

- Walks `idx_customers_region` to find all entries where `region = 'US-EAST'`
- Builds an in-memory **bitmap** of matching heap page locations
- **shared read=4** — 4 index pages read from disk (index was just created, not yet cached)

### Step 2 — Bitmap Heap Scan (outer node)

```
Bitmap Heap Scan on customers
  Recheck Cond: (region = 'US-EAST'::text)
  Heap Blocks: exact=104
  Buffers: shared hit=104 read=4
```

- Uses the bitmap to visit heap pages that contain matching rows
- **Heap Blocks: exact=104** — bitmap is *exact* (not lossy); knows precisely which rows to fetch
- **Recheck Cond** — still listed; PostgreSQL re-checks the filter when reading each row (normal)
- **shared hit=104** — all 104 table pages were already in cache from Scenario 1

Even with an index, it still touched all 104 heap pages because 2,000 rows are spread across the whole table. The win is **less CPU per row** and **ordered page access**, not fewer pages this time.

---

## Comparison to Scenario 1

```
Scenario 1 — Seq Scan                    Scenario 2 — Bitmap Index Scan
─────────────────────                    ────────────────────────────────
Read every row                           Read index → build bitmap
Check filter on all 10,000 rows          Visit only matching pages/rows
Rows Removed by Filter: 8000             No rows-discarded line
12 ms                                    0.6 ms
```

The big difference at this scale is **time**, not pages touched. On a much larger table with a selective filter, you'd also see far fewer buffer hits.

---

## Buffers breakdown

| Node | Buffers | Meaning |
|------|---------|---------|
| Bitmap Index Scan | `shared read=4` | Index pages from disk (cold index) |
| Bitmap Heap Scan | `shared hit=104` | Table pages from RAM (warm from Scenario 1) |
| Bitmap Heap Scan | `shared read=4` | A few heap pages not yet cached |

**Key point:** *"Index was cold (shared read on index scan). Heap was warm from the prior seq scan. In production I'd look at both plan shape and buffer hits vs reads under realistic cache conditions."*

---

## Visual summary

```
idx_customers_region (index)
        │
        ▼
 Bitmap Index Scan ── find all 'US-EAST' entries
        │              build bitmap of heap page IDs
        ▼
 Bitmap Heap Scan ── visit pages in order
        │              recheck region = 'US-EAST'
        │              fetch id, email
        ▼
   Return 2,000 rows  (0.6 ms)
```

---

## Try this to see a plain Index Scan

A highly selective query returns fewer rows — planner may switch to Index Scan:

```sql
EXPLAIN (ANALYZE, BUFFERS)
SELECT id, email
FROM customers
WHERE region = 'US-EAST' AND id = 42;
```

Or:

```sql
EXPLAIN (ANALYZE, BUFFERS)
SELECT id, email
FROM customers
WHERE region = 'CA-EAST' AND status = 'churned';
```

Look for `Index Scan using idx_customers_region` instead of Bitmap.

---

## Key takeaways

1. **Adding an index doesn't always mean Index Scan** — Bitmap and Seq Scan are still valid choices
2. **Compare estimated vs actual rows** — here both say 2,000 ✓
3. **Execution time dropped 12 ms → 0.6 ms** — index helped even though buffer count looks similar
4. **`Rows Removed by Filter` disappeared** — index/bitmap path avoids scanning irrelevant rows at the filter stage
5. **Selectivity drives plan choice** — always consider what fraction of the table you're fetching
