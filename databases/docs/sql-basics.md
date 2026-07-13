# SQL Basics — Joins, Aggregates, Filtering, Subqueries

A practical reference for core SQL: join types, aggregation, `GROUP BY`/`HAVING`, sorting, subqueries, `EXISTS`/`IN`, set operations, and window functions. The conceptual snippets reference the [EXPLAIN lab](../lab/) schema (`customers`, `subscriptions`, `billing_events`); each **Lab** block uses a tiny self-contained `cust`/`orders` dataset (see [Lab dataset](#lab-dataset)) so you can run it and check the expected output by hand.

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

## Lab dataset

Every **Lab** below runs against these two tiny tables. Create them once in `psql` and follow along — the small size makes the expected output easy to verify by hand.

```sql
CREATE TABLE cust (
    id     int PRIMARY KEY,
    name   text,
    region text
);
INSERT INTO cust VALUES
    (1, 'Alice', 'US'),
    (2, 'Bob',   'US'),
    (3, 'Carol', 'EU'),
    (4, 'Dave',  'EU');      -- Dave has NO orders (useful for outer/anti-joins)

CREATE TABLE orders (
    id      int PRIMARY KEY,
    cust_id int REFERENCES cust(id),
    amount  numeric
);
INSERT INTO orders VALUES
    (101, 1,  50),
    (102, 1,  30),
    (103, 2,  20),
    (104, 3, 100);
```

**cust**

| id | name | region |
|----|------|--------|
| 1 | Alice | US |
| 2 | Bob | US |
| 3 | Carol | EU |
| 4 | Dave | EU |

**orders**

| id | cust_id | amount |
|----|---------|--------|
| 101 | 1 | 50 |
| 102 | 1 | 30 |
| 103 | 2 | 20 |
| 104 | 3 | 100 |

Handy facts to check answers against: total orders = 4, total amount = 200, average = 50. Spend per customer: Alice 80, Bob 20, Carol 100, Dave 0.

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

**Lab:**

```sql
-- INNER: only customers who have orders (Dave drops out)
SELECT c.name, o.amount
FROM cust c JOIN orders o ON o.cust_id = c.id
ORDER BY c.name;
```
| name | amount |
|------|--------|
| Alice | 50 |
| Alice | 30 |
| Bob | 20 |
| Carol | 100 |

```sql
-- LEFT + anti-join: customers with NO orders
SELECT c.name
FROM cust c LEFT JOIN orders o ON o.cust_id = c.id
WHERE o.id IS NULL;
```
| name |
|------|
| Dave |

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

**Lab:**

```sql
SELECT count(*) AS n_orders, sum(amount) AS total,
       avg(amount) AS avg_amount, min(amount) AS min, max(amount) AS max
FROM orders;
```
| n_orders | total | avg_amount | min | max |
|----------|-------|------------|-----|-----|
| 4 | 200 | 50 | 20 | 100 |

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

**Lab — spend per customer, keep big spenders:**

```sql
SELECT c.name, sum(o.amount) AS spend
FROM cust c JOIN orders o ON o.cust_id = c.id
GROUP BY c.name
HAVING sum(o.amount) > 50
ORDER BY spend DESC;
```
| name | spend |
|------|-------|
| Carol | 100 |
| Alice | 80 |

Bob (20) is removed by `HAVING`; Dave never appears (no rows to group).

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

**Lab:**

```sql
SELECT DISTINCT region FROM cust ORDER BY region;
```
| region |
|--------|
| EU |
| US |

```sql
-- top 2 orders by amount
SELECT c.name, o.amount
FROM orders o JOIN cust c ON c.id = o.cust_id
ORDER BY o.amount DESC
LIMIT 2;
```
| name | amount |
|------|--------|
| Carol | 100 |
| Alice | 50 |

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

**Lab — orders above the average amount:**

```sql
SELECT id, amount FROM orders
WHERE amount > (SELECT avg(amount) FROM orders);   -- avg = 50
```
| id | amount |
|----|--------|
| 104 | 100 |

Only the $100 order beats the $50 average (the $50 order is not strictly greater).

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

**Lab — who has ordered, and who hasn't:**

```sql
SELECT name FROM cust c
WHERE EXISTS (SELECT 1 FROM orders o WHERE o.cust_id = c.id);
```
| name |
|------|
| Alice |
| Bob |
| Carol |

```sql
SELECT name FROM cust c
WHERE NOT EXISTS (SELECT 1 FROM orders o WHERE o.cust_id = c.id);
```
| name |
|------|
| Dave |

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

**Lab — set operations:**

```sql
-- US customers who ALSO have an order of $50+
SELECT name FROM cust WHERE region = 'US'
INTERSECT
SELECT c.name FROM cust c JOIN orders o ON o.cust_id = c.id WHERE o.amount >= 50;
```
| name |
|------|
| Alice |

```sql
-- US customers who do NOT have a $50+ order
SELECT name FROM cust WHERE region = 'US'
EXCEPT
SELECT c.name FROM cust c JOIN orders o ON o.cust_id = c.id WHERE o.amount >= 50;
```
| name |
|------|
| Bob |

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

**Lab — bucket orders by size:**

```sql
SELECT id, amount,
       CASE WHEN amount >= 100 THEN 'large'
            WHEN amount >= 50  THEN 'medium'
            ELSE 'small' END AS bucket
FROM orders
ORDER BY amount;
```
| id | amount | bucket |
|----|--------|--------|
| 103 | 20 | small |
| 102 | 30 | small |
| 101 | 50 | medium |
| 104 | 100 | large |

```sql
-- conditional counts (pivot) with FILTER
SELECT count(*) FILTER (WHERE amount >= 50) AS big,
       count(*) FILTER (WHERE amount <  50) AS small
FROM orders;
```
| big | small |
|-----|-------|
| 2 | 2 |

---

## CTEs (Common Table Expressions / `WITH`)

A **CTE** is a named, temporary result set defined with `WITH` that exists only for the duration of the query. Think of it as a query-scoped "view" that makes complex SQL readable by breaking it into named steps.

```sql
WITH plan_revenue AS (
    SELECT plan_code, sum(monthly_price) AS mrr
    FROM subscriptions
    GROUP BY plan_code
)
SELECT * FROM plan_revenue WHERE mrr > 10000 ORDER BY mrr DESC;
```

**Lab — revenue per region via a CTE:**

```sql
WITH per_cust AS (
    SELECT c.region, c.name, sum(o.amount) AS spend
    FROM cust c JOIN orders o ON o.cust_id = c.id
    GROUP BY c.region, c.name
)
SELECT region, sum(spend) AS region_revenue
FROM per_cust                       -- reuse the named step
GROUP BY region
ORDER BY region_revenue DESC, region;
```
| region | region_revenue |
|--------|----------------|
| EU | 100 |
| US | 100 |

US = Alice 80 + Bob 20 = 100; EU = Carol 100 (Dave contributes nothing).

### Why use them
- **Readability** — name intermediate steps instead of deeply nesting subqueries.
- **Reuse** — reference the same CTE multiple times in one query.
- **Chaining** — build a pipeline where each CTE uses the previous one.
- **Recursion** — the only way to walk hierarchies/graphs in SQL.

### Multiple / chained CTEs
Separate definitions with commas; each can reference the ones before it:

```sql
WITH active_subs AS (
    SELECT customer_id, monthly_price
    FROM subscriptions
    WHERE status = 'active'
),
by_customer AS (
    SELECT customer_id, sum(monthly_price) AS spend
    FROM active_subs                     -- references the CTE above
    GROUP BY customer_id
)
SELECT c.email, b.spend
FROM by_customer b
JOIN customers c ON c.id = b.customer_id
WHERE b.spend > 100
ORDER BY b.spend DESC;
```

### Recursive CTEs (`WITH RECURSIVE`)
For hierarchies (org charts, category trees, graph traversal). Structure = an **anchor** (starting rows) `UNION ALL` a **recursive term** that references the CTE itself until no new rows are produced.

```sql
-- Walk an employees table up/down a management chain
WITH RECURSIVE chain AS (
    SELECT id, manager_id, name, 1 AS depth      -- anchor: the top
    FROM employees WHERE manager_id IS NULL
  UNION ALL
    SELECT e.id, e.manager_id, e.name, c.depth + 1
    FROM employees e
    JOIN chain c ON e.manager_id = c.id          -- recursive term
)
SELECT * FROM chain ORDER BY depth;
```
> Always ensure the recursion terminates (each step must make progress toward a stopping point), or add a `depth < N` guard to avoid runaway queries on cyclic data.

**Lab — walk an org chart:**

```sql
CREATE TABLE emp (id int, manager_id int, name text);
INSERT INTO emp VALUES
    (1, NULL, 'CEO'),
    (2, 1,    'VP'),
    (3, 2,    'Lead'),
    (4, 3,    'Eng');

WITH RECURSIVE chain AS (
    SELECT id, manager_id, name, 1 AS depth      -- anchor
    FROM emp WHERE manager_id IS NULL
  UNION ALL
    SELECT e.id, e.manager_id, e.name, c.depth + 1
    FROM emp e JOIN chain c ON e.manager_id = c.id   -- recursive term
)
SELECT depth, name FROM chain ORDER BY depth;
```
| depth | name |
|-------|------|
| 1 | CEO |
| 2 | VP |
| 3 | Lead |
| 4 | Eng |

Each pass adds the next level down until no employee reports to the rows found so far.

### Data-modifying CTEs
In PostgreSQL a CTE can `INSERT`/`UPDATE`/`DELETE` with `RETURNING`, letting you do multi-step writes in one atomic statement — e.g. archive-then-delete:

```sql
WITH moved AS (
    DELETE FROM billing_events
    WHERE created_at < now() - interval '1 year'
    RETURNING *
)
INSERT INTO billing_events_archive
SELECT * FROM moved;
```

### Materialization & performance (important nuance)
- Before **PostgreSQL 12**, CTEs were an **optimization fence** — always materialized (computed once into a temp result), which could block the planner from pushing filters down.
- **PG12+**: a CTE used **once** is **inlined** by default (optimized like a subquery); used multiple times or if recursive/volatile, it's materialized. You can force either way:

```sql
WITH x AS MATERIALIZED     (...)   -- force compute-once (old behavior)
WITH x AS NOT MATERIALIZED (...)   -- force inlining
```
- Rule of thumb: `MATERIALIZED` helps when the CTE is expensive and reused; `NOT MATERIALIZED` (or a plain subquery) helps when you want the planner to push `WHERE`/joins into it. Check with `EXPLAIN`.

**CTE vs subquery:** functionally similar for single use; choose CTEs for readability/reuse/recursion, subqueries for simple one-offs. On older PG versions, remember the CTE fence could hurt performance.

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

**Lab — rank customers by spend within region, plus the region total:**

```sql
WITH per_cust AS (
    SELECT c.region, c.name, sum(o.amount) AS spend
    FROM cust c JOIN orders o ON o.cust_id = c.id
    GROUP BY c.region, c.name
)
SELECT region, name, spend,
       rank()      OVER (PARTITION BY region ORDER BY spend DESC) AS rnk,
       sum(spend)  OVER (PARTITION BY region)                     AS region_total
FROM per_cust
ORDER BY region, rnk;
```
| region | name | spend | rnk | region_total |
|--------|------|-------|-----|--------------|
| EU | Carol | 100 | 1 | 100 |
| US | Alice | 80 | 1 | 100 |
| US | Bob | 20 | 2 | 100 |

Unlike `GROUP BY`, every customer row is kept — `region_total` is repeated on each row of the partition.

---

## Quick interview hits

- **Logical order:** FROM → WHERE → GROUP BY → HAVING → SELECT → ORDER BY → LIMIT.
- **WHERE vs HAVING:** rows-before-grouping vs groups-after-aggregation.
- **LEFT JOIN + WHERE on the right table** accidentally becomes an INNER JOIN — filter in `ON`.
- **Anti-join:** prefer `NOT EXISTS` over `NOT IN` (NULL safety).
- **`UNION` vs `UNION ALL`:** `UNION` dedupes (extra cost); use `ALL` when you can.
- **Window functions** aggregate without collapsing rows.
- **`COUNT(*)` vs `COUNT(col)`:** the latter skips NULLs.
- **CTEs:** named `WITH` steps for readability/reuse/recursion; PG12+ inlines single-use CTEs (use `MATERIALIZED`/`NOT MATERIALIZED` to control it); `WITH RECURSIVE` walks hierarchies.
