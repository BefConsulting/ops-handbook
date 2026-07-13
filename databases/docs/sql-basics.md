# SQL Basics — Joins, Aggregates, Filtering, Subqueries

A practical reference for core SQL: join types, aggregation, `GROUP BY`/`HAVING`, sorting, subqueries, `EXISTS`/`IN`, set operations, and window functions. Examples use the [EXPLAIN lab](../lab/) schema: `customers`, `subscriptions`, `billing_events`.

**See also:** [../lab/README.md](../lab/README.md) (reading `EXPLAIN`) · [performance-analysis.md](performance-analysis.md) · [deep-dive.md](deep-dive.md) §2

---

## Logical order of execution (know this cold)

SQL is *written* `SELECT ... FROM ... WHERE ...`, but it's *evaluated* in a different order. This explains many "why can't I use my alias / why doesn't WHERE see my aggregate" questions:

```
1. FROM / JOIN      -> build the working set of rows
2. WHERE            -> filter rows (no aggregates yet)
3. GROUP BY         -> collapse into groups
4. HAVING           -> filter groups (aggregates allowed)
5. SELECT           -> compute columns / expressions / aliases
6. DISTINCT
7. ORDER BY         -> sort (can use SELECT aliases)
8. LIMIT / OFFSET   -> slice
```

Consequences: `WHERE` can't reference a `SELECT` alias or an aggregate; `HAVING` can; `ORDER BY` can use aliases because it runs after `SELECT`.

---

## Join types

Joins combine rows from two tables based on a condition.

| Join | Returns |
|------|---------|
| `INNER JOIN` | only rows with a match in **both** tables |
| `LEFT [OUTER] JOIN` | all left rows + matching right (NULLs where no match) |
| `RIGHT [OUTER] JOIN` | all right rows + matching left |
| `FULL [OUTER] JOIN` | all rows from both; NULLs where either side is missing |
| `CROSS JOIN` | Cartesian product (every left × every right) |
| self-join | a table joined to itself (via aliases) |

```sql
-- INNER: customers who have at least one subscription
SELECT c.email, s.plan_code
FROM customers c
JOIN subscriptions s ON s.customer_id = c.id;

-- LEFT: ALL customers, with their subscriptions if any (NULL if none)
SELECT c.email, s.plan_code
FROM customers c
LEFT JOIN subscriptions s ON s.customer_id = c.id;

-- Find customers with NO subscriptions (anti-join pattern)
SELECT c.email
FROM customers c
LEFT JOIN subscriptions s ON s.customer_id = c.id
WHERE s.id IS NULL;
```

**Gotcha:** filtering an outer-joined table in `WHERE` (e.g. `WHERE s.status = 'active'`) silently turns a LEFT JOIN into an INNER JOIN, because `WHERE` runs after the join and NULLs fail the test. Put that condition in the `ON` clause instead if you want to keep unmatched left rows.

---

## Aggregate functions

Collapse many rows into one value.

| Function | Returns |
|----------|---------|
| `COUNT(*)` | number of rows (incl. NULLs) |
| `COUNT(col)` | non-NULL values in `col` |
| `COUNT(DISTINCT col)` | distinct non-NULL values |
| `SUM`, `AVG` | total / mean (ignore NULLs) |
| `MIN`, `MAX` | extremes |
| `string_agg`, `array_agg` | concatenate/collect values |

```sql
-- Whole-table aggregate (no GROUP BY = one row)
SELECT count(*) AS total_customers, count(DISTINCT region) AS regions
FROM customers;
```

> NULLs are ignored by `SUM`/`AVG`/`COUNT(col)`. `AVG` divides by the count of **non-NULL** values, which can surprise you.

---

## GROUP BY and HAVING

`GROUP BY` splits rows into groups; aggregates then apply **per group**. `HAVING` filters groups (it's `WHERE` for aggregates).

```sql
-- Revenue per plan, only plans billing more than $10k, richest first
SELECT s.plan_code,
       count(*)            AS subs,
       sum(s.monthly_price) AS mrr
FROM subscriptions s
GROUP BY s.plan_code
HAVING sum(s.monthly_price) > 10000
ORDER BY mrr DESC;
```

- Every non-aggregated column in `SELECT` must appear in `GROUP BY`.
- **`WHERE` vs `HAVING`:** `WHERE` filters **rows before** grouping (and is index-friendly, so prefer it when possible); `HAVING` filters **groups after** aggregation. Use `WHERE` for row conditions, `HAVING` only for conditions on aggregates.

---

## DISTINCT, ORDER BY, LIMIT

```sql
SELECT DISTINCT region FROM customers;          -- unique values

SELECT email FROM customers
ORDER BY created_at DESC NULLS LAST             -- sort; control NULL placement
LIMIT 20 OFFSET 40;                              -- pagination (page 3 of 20)
```

- `ORDER BY` can reference `SELECT` aliases or column positions (`ORDER BY 2`).
- `DISTINCT ON (col)` (PostgreSQL) keeps the first row per `col` given an `ORDER BY`.

---

## Subqueries

A query nested inside another.

```sql
-- Scalar subquery (returns one value)
SELECT email FROM customers
WHERE created_at > (SELECT min(created_at) FROM customers WHERE region = 'US-EAST');

-- Subquery as a derived table (must be aliased)
SELECT region, avg_price
FROM (SELECT region, avg(monthly_price) AS avg_price
      FROM subscriptions s JOIN customers c ON c.id = s.customer_id
      GROUP BY region) t
WHERE avg_price > 50;
```

- **Correlated subquery:** references the outer query, so it runs per outer row (can be slow) — often rewritable as a join.

---

## EXISTS vs IN vs ANY (a classic question)

All three test membership, but behave differently — especially with NULLs.

```sql
-- EXISTS: true as soon as the subquery returns any row; great for "has a match"
SELECT c.email FROM customers c
WHERE EXISTS (SELECT 1 FROM subscriptions s WHERE s.customer_id = c.id);

-- IN: value matches any in a list/subquery
SELECT c.email FROM customers c
WHERE c.id IN (SELECT customer_id FROM subscriptions);

-- NOT EXISTS: customers with no subscription (NULL-safe)
SELECT c.email FROM customers c
WHERE NOT EXISTS (SELECT 1 FROM subscriptions s WHERE s.customer_id = c.id);
```

| | Behavior / notes |
|--|------------------|
| `EXISTS` | Stops at the first match; correlated; **NULL-safe**; usually best for "does a related row exist" |
| `IN` | Fine for small/static lists; with a subquery the planner often treats it like a semi-join |
| **`NOT IN`** | **Danger:** if the subquery returns **any NULL**, `NOT IN` yields no rows (three-valued logic). Prefer **`NOT EXISTS`** for anti-joins. |
| `ANY`/`ALL` | `= ANY(...)` ≡ `IN`; `<> ALL(...)` ≡ `NOT IN`; also work with operators like `> ANY` |

Performance-wise, modern PostgreSQL optimizes `EXISTS` and `IN`-subqueries into semi-joins, so pick the one that's **correct and readable** first.

---

## Set operations

Combine the results of two queries (same column count/types).

| Operator | Returns |
|----------|---------|
| `UNION` | rows from both, **duplicates removed** |
| `UNION ALL` | rows from both, **duplicates kept** (faster — no dedupe) |
| `INTERSECT` | rows in **both** |
| `EXCEPT` | rows in the first but **not** the second |

```sql
SELECT email FROM customers WHERE region = 'US-EAST'
UNION ALL
SELECT email FROM customers WHERE status = 'active';
```

> Use `UNION ALL` unless you actually need duplicate removal — `UNION` adds a sort/hash to dedupe.

---

## CASE (conditional expressions)

```sql
SELECT email,
       CASE
         WHEN monthly_price >= 100 THEN 'premium'
         WHEN monthly_price >= 20  THEN 'standard'
         ELSE 'basic'
       END AS tier
FROM subscriptions s JOIN customers c ON c.id = s.customer_id;

-- CASE inside an aggregate = conditional counting ("pivot")
SELECT count(*) FILTER (WHERE status = 'active')   AS active,
       count(*) FILTER (WHERE status = 'canceled') AS canceled
FROM subscriptions;                                 -- FILTER is the clean PG way
```

---

## CTEs (WITH) — readable multi-step queries

```sql
WITH plan_revenue AS (
    SELECT plan_code, sum(monthly_price) AS mrr
    FROM subscriptions
    GROUP BY plan_code
)
SELECT * FROM plan_revenue WHERE mrr > 10000 ORDER BY mrr DESC;
```

CTEs name intermediate results for readability; **recursive CTEs** (`WITH RECURSIVE`) handle hierarchies/graphs (org charts, trees).

---

## Window functions (aggregate without collapsing rows)

Unlike `GROUP BY`, window functions compute across a set of rows **while keeping each row**.

```sql
SELECT c.region, c.email, s.monthly_price,
       rank()       OVER (PARTITION BY c.region ORDER BY s.monthly_price DESC) AS price_rank,
       sum(s.monthly_price) OVER (PARTITION BY c.region)                       AS region_mrr
FROM customers c JOIN subscriptions s ON s.customer_id = c.id;
```

- `PARTITION BY` = groups; `ORDER BY` = ordering within the window.
- Common functions: `row_number`, `rank`, `dense_rank`, `lag`, `lead`, `sum/avg OVER`, `ntile`.
- Great for "top N per group," running totals, and comparisons to the previous row.

---

## Quick interview hits

- **Logical order:** FROM → WHERE → GROUP BY → HAVING → SELECT → ORDER BY → LIMIT.
- **WHERE vs HAVING:** rows-before-grouping vs groups-after-aggregation.
- **LEFT JOIN + WHERE on the right table** accidentally becomes an INNER JOIN — filter in `ON`.
- **Anti-join:** prefer `NOT EXISTS` over `NOT IN` (NULL safety).
- **`UNION` vs `UNION ALL`:** `UNION` dedupes (extra cost); use `ALL` when you can.
- **Window functions** aggregate without collapsing rows.
- **`COUNT(*)` vs `COUNT(col)`:** the latter skips NULLs.
