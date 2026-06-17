-- Sample SaaS schema (customers / subscriptions / billing) for EXPLAIN practice
-- Run from the lab/ folder: psql -f 01_schema.sql

DROP DATABASE IF EXISTS pg_lab;
CREATE DATABASE pg_lab;

\c pg_lab

CREATE TABLE customers (
    id          BIGSERIAL PRIMARY KEY,
    email       TEXT NOT NULL,
    region      TEXT NOT NULL,          -- 'US-EAST', 'US-WEST', 'CA', etc.
    status      TEXT NOT NULL DEFAULT 'active',
    created_at  TIMESTAMPTZ NOT NULL DEFAULT now()
);

CREATE TABLE subscriptions (
    id              BIGSERIAL PRIMARY KEY,
    customer_id     BIGINT NOT NULL REFERENCES customers(id),
    plan_code       TEXT NOT NULL,      -- 'fiber-1g', 'fiber-500', 'mobile-unlimited'
    monthly_price   NUMERIC(10,2) NOT NULL,
    status          TEXT NOT NULL DEFAULT 'active',
    started_at      TIMESTAMPTZ NOT NULL,
    cancelled_at    TIMESTAMPTZ
);

CREATE TABLE billing_events (
    id              BIGSERIAL PRIMARY KEY,
    subscription_id BIGINT NOT NULL REFERENCES subscriptions(id),
    event_type      TEXT NOT NULL,      -- 'charge', 'refund', 'adjustment'
    amount          NUMERIC(10,2) NOT NULL,
    event_at        TIMESTAMPTZ NOT NULL,
    metadata        JSONB
);

-- Only a few indexes on purpose — we'll add more during exercises
CREATE INDEX idx_subscriptions_customer_id ON subscriptions(customer_id);
CREATE INDEX idx_billing_events_subscription_id ON billing_events(subscription_id);

CREATE EXTENSION IF NOT EXISTS pg_stat_statements;
