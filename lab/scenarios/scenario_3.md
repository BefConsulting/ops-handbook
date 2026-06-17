# Scenario 3: Nested Loop Join (single customer lookup)

## Query

```sql
EXPLAIN (ANALYZE, BUFFERS)
SELECT c.email, s.plan_code, s.monthly_price
FROM customers c
JOIN subscriptions s ON s.customer_id = c.id
WHERE c.id = 42;
```

## Actual output

```
                                                                 QUERY PLAN
--------------------------------------------------------------------------------------------------------------------------------------------
 Nested Loop  (cost=4.60..23.68 rows=3 width=37) (actual time=0.105..0.127 rows=3 loops=1)
   Buffers: shared hit=11
   ->  Index Scan using customers_pkey on customers c  (cost=0.29..8.30 rows=1 width=28) (actual time=0.054..0.056 rows=1 loops=1)
         Index Cond: (id = 42)
         Buffers: shared hit=6
   ->  Bitmap Heap Scan on subscriptions s  (cost=4.31..15.35 rows=3 width=25) (actual time=0.041..0.060 rows=3 loops=1)
         Recheck Cond: (customer_id = 42)
         Heap Blocks: exact=3
         Buffers: shared hit=5
         ->  Bitmap Index Scan on idx_subscriptions_customer_id  (cost=0.00..4.31 rows=3 width=0) (actual time=0.033..0.033 rows=3 loops=1)
               Index Cond: (customer_id = 42)
               Buffers: shared hit=2
 Planning:
   Buffers: shared hit=50 dirtied=1
 Planning Time: 1.583 ms
 Execution Time: 0.168 ms
```

## Headline: ideal join for a tiny outer side

| Metric | Value |
|--------|-------|
| Join type | **Nested Loop** |
| Customer rows | 1 |
| Subscription rows | 3 |
| Execution Time | **0.168 ms** |
| Total buffer hits | 11 pages |

---

## What is a Nested Loop Join?

For **each row** from the outer table, look up matching rows in the inner table.

```
FOR each row in outer (customers):
    find matching rows in inner (subscriptions)
```

Best when the outer side is **tiny** (1 row here) and the inner side has an **index** on the join key (`customer_id`).

**Key point:** *"Nested loop is perfect when outer cardinality is 1 and inner is index-backed — O(1) probe per outer row."*

---

## Read the plan (bottom-up, then top)

### Step 1 — Outer: Index Scan on `customers` (runs first)

```
Index Scan using customers_pkey on customers c
  Index Cond: (id = 42)
  rows=1
```

- Primary key lookup → exactly **1 customer**
- `customers_pkey` makes this instant

### Step 2 — Inner: Bitmap scan on `subscriptions` (runs per outer row)

```
Bitmap Index Scan on idx_subscriptions_customer_id
  Index Cond: (customer_id = 42)
        │
        ▼
Bitmap Heap Scan on subscriptions s
  Recheck Cond: (customer_id = 42)
  Heap Blocks: exact=3
  rows=3
```

- Uses `idx_subscriptions_customer_id` to find subscriptions for customer 42
- Returns **3 subscriptions** across **3 heap pages**
- Bitmap again (not plain Index Scan) — 3 rows is a small set but planner still chose bitmap for the inner lookup

### Step 3 — Nested Loop (parent, ties them together)

```
Nested Loop  rows=3  loops=1
```

- Outer ran **1 time** → inner ran **1 time** (`loops=1` on both children)
- 1 customer × 3 subscriptions = **3 result rows**
- If outer had 1,000 rows and inner had no index → inner `loops=1000` = disaster

---

## The `loops=` column — critical for Nested Loop

| Node | loops | Meaning |
|------|-------|---------|
| Nested Loop | 1 | Join executed once |
| Index Scan (customers) | 1 | Fetched 1 customer |
| Bitmap Heap Scan (subscriptions) | 1 | Probed subscriptions once |

**Red flag in production:** `loops=500000` on the inner node = inner index probed 500k times. Fix: better selectivity, different join order, or Hash Join.

---

## Visual summary

```
WHERE c.id = 42
        │
        ▼
 Index Scan on customers_pkey ── 1 row (customer 42)
        │
        ▼
 Nested Loop ────────────────── for that 1 customer...
        │
        ▼
 Bitmap Index Scan on idx_subscriptions_customer_id
        │  customer_id = 42
        ▼
 Bitmap Heap Scan on subscriptions ── 3 rows
        │
        ▼
 Return: email, plan_code, monthly_price  (3 rows, 0.17 ms)
```

---

## Buffers breakdown

| Node | Buffers | Meaning |
|------|---------|---------|
| customers Index Scan | shared hit=6 | PK lookup (table + index pages) |
| subscriptions Bitmap Index | shared hit=2 | Index pages for customer_id=42 |
| subscriptions Bitmap Heap | shared hit=5 | 3 heap pages + overhead |
| **Total** | **shared hit=11** | All from cache, no disk reads |

Everything cached — expected for a point query after warm-up.

---

## Nested Loop vs Hash Join (when to expect each)

| Situation | Typical join |
|-----------|--------------|
| Outer is tiny, inner indexed | **Nested Loop** ← this query |
| Both sides large, no selective filter | **Hash Join** (see Exercise 4) |
| Both sides pre-sorted on join key | **Merge Join** |

This query filters `c.id = 42` → outer = 1 row → Nested Loop is the obvious winner.

---

## Compare to a bad plan (what to watch for)

If someone wrote the query without `WHERE c.id = 42`:

```sql
SELECT c.email, s.plan_code
FROM customers c
JOIN subscriptions s ON s.customer_id = c.id;
```

You'd likely see **Hash Join** or **Nested Loop with loops=10000** — joining all 10k customers to 25k subscriptions. Always check whether the outer side is selective.

---

## Key takeaways

1. **Nested Loop = for each outer row, probe inner** — great when outer is small
2. **`loops=` on inner node** — multiply by outer rows to gauge cost
3. **Both sides used indexes** — PK on customers, `idx_subscriptions_customer_id` on subscriptions
4. **0.17 ms, 11 buffer hits** — textbook efficient point lookup + join
5. **Join order matters** — planner picked customers as outer (1 row) because of `WHERE c.id = 42`
