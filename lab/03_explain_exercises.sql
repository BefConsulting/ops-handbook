-- EXPLAIN (ANALYZE, BUFFERS) exercises
-- Run from the lab/ folder: psql -d pg_lab -f 03_explain_exercises.sql
-- Or open in psql and run one block at a time.

\c pg_lab

-- ============================================================
-- EXERCISE 1: Sequential Scan (no useful index)
-- Look for: Seq Scan, actual rows vs estimated rows, shared hit/read
-- ============================================================
EXPLAIN (ANALYZE, BUFFERS, VERBOSE)
SELECT *
FROM customers
WHERE region = 'US-EAST';


-- ============================================================
-- EXERCISE 2: Index Scan (after we add an index)
-- Compare cost, rows, and buffers to Exercise 1
-- ============================================================
CREATE INDEX idx_customers_region ON customers(region);

EXPLAIN (ANALYZE, BUFFERS)
SELECT id, email
FROM customers
WHERE region = 'US-EAST';


-- ============================================================
-- EXERCISE 3: Nested Loop Join (small outer + indexed inner)
-- Look for: Nested Loop, loops=, rows per loop
-- ============================================================
EXPLAIN (ANALYZE, BUFFERS)
SELECT c.email, s.plan_code, s.monthly_price
FROM customers c
JOIN subscriptions s ON s.customer_id = c.id
WHERE c.id = 42;


-- ============================================================
-- EXERCISE 4: Hash Join (larger sets, no selective filter)
-- Look for: Hash, Hash Join, buckets, batches
-- ============================================================
EXPLAIN (ANALYZE, BUFFERS)
SELECT c.region, count(*) AS sub_count
FROM customers c
JOIN subscriptions s ON s.customer_id = c.id
GROUP BY c.region;


-- ============================================================
-- EXERCISE 5: Sort + Aggregate (expensive without index)
-- Look for: Sort, Sort Method, memory vs external (disk)
-- ============================================================
EXPLAIN (ANALYZE, BUFFERS)
SELECT subscription_id, sum(amount) AS total_billed
FROM billing_events
WHERE event_type = 'charge'
GROUP BY subscription_id
ORDER BY total_billed DESC
LIMIT 20;


-- ============================================================
-- EXERCISE 6: Fix Exercise 5 with a partial index
-- Compare planning time, execution time, buffers
-- ============================================================
CREATE INDEX idx_billing_charge_sub_amount
ON billing_events(subscription_id, amount)
WHERE event_type = 'charge';

EXPLAIN (ANALYZE, BUFFERS)
SELECT subscription_id, sum(amount) AS total_billed
FROM billing_events
WHERE event_type = 'charge'
GROUP BY subscription_id
ORDER BY total_billed DESC
LIMIT 20;


-- ============================================================
-- EXERCISE 7: Bad pattern — function on indexed column
-- Index won't be used; planner falls back to Seq Scan
-- ============================================================
EXPLAIN (ANALYZE, BUFFERS)
SELECT *
FROM customers
WHERE lower(email) = 'user500@example.com';


-- ============================================================
-- EXERCISE 8: Bitmap Index Scan (moderate selectivity)
-- Look for: Bitmap Index Scan -> Bitmap Heap Scan -> Recheck Cond
-- ============================================================
EXPLAIN (ANALYZE, BUFFERS)
SELECT *
FROM subscriptions
WHERE plan_code = 'fiber-1g' AND status = 'active';
