-- Populate with enough rows to make query plans interesting
-- Run from the lab/ folder: psql -d pg_lab -f 02_seed.sql

\c pg_lab

-- ~10k customers
INSERT INTO customers (email, region, status, created_at)
SELECT
    'user' || g || '@example.com',
    (ARRAY['US-EAST','US-WEST','US-CENTRAL','CA-EAST','CA-WEST'])[1 + (g % 5)],
    CASE WHEN g % 17 = 0 THEN 'churned' ELSE 'active' END,
    now() - (g || ' days')::interval
FROM generate_series(1, 10000) g;

-- ~25k subscriptions (some customers have multiple)
INSERT INTO subscriptions (customer_id, plan_code, monthly_price, status, started_at, cancelled_at)
SELECT
    1 + (g % 10000),
    (ARRAY['fiber-1g','fiber-500','fiber-250','mobile-unlimited'])[1 + (g % 4)],
    (ARRAY[89.99, 69.99, 49.99, 45.00])[1 + (g % 4)],
    CASE WHEN g % 23 = 0 THEN 'cancelled' ELSE 'active' END,
    now() - ((g * 3) || ' days')::interval,
    CASE WHEN g % 23 = 0 THEN now() - ((g % 30) || ' days')::interval ELSE NULL END
FROM generate_series(1, 25000) g;

-- ~200k billing events (event-driven billing stream)
INSERT INTO billing_events (subscription_id, event_type, amount, event_at, metadata)
SELECT
    1 + (g % 25000),
    (ARRAY['charge','charge','charge','refund','adjustment'])[1 + (g % 5)],
    round((random() * 120 + 5)::numeric, 2),
    now() - ((g % 365) || ' days')::interval - ((g % 24) || ' hours')::interval,
    jsonb_build_object('source', 'billing-api', 'batch', g / 1000)
FROM generate_series(1, 200000) g;

ANALYZE customers;
ANALYZE subscriptions;
ANALYZE billing_events;

SELECT 'customers' AS tbl, count(*) FROM customers
UNION ALL SELECT 'subscriptions', count(*) FROM subscriptions
UNION ALL SELECT 'billing_events', count(*) FROM billing_events;
