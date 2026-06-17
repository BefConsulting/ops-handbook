# PostgreSQL Replication — Basics, Troubleshooting & Best Practices

Focus: **understand the replication types, monitor lag, troubleshoot common failures, and apply best practices.** Highly relevant to the Wavelo DBRE role (PostgreSQL at scale, HA, multi-region).

**See also:** [POSTGRESQL_DEEP_DIVE.md](POSTGRESQL_DEEP_DIVE.md) §3 (HA & scaling) · [WAL_AND_CHECKPOINTS.md](WAL_AND_CHECKPOINTS.md) · [PERFORMANCE_ANALYSIS.md](PERFORMANCE_ANALYSIS.md)

---

## Basics (condensed)

Replication = copying data from a **primary** to one or more **standbys/replicas**, built on shipping **WAL** (the same WAL that drives crash recovery).

### Physical (streaming) replication
- **What:** byte-for-byte WAL streamed to standbys; replays the exact block changes. Whole-cluster copy.
- **Standbys:** read-only (**hot standby** can serve queries), promotable to primary on failover.
- **Sync modes:**
  - **Asynchronous** (default) — primary doesn't wait for standby → low latency, small data-loss window on failover.
  - **Synchronous** — primary waits for standby to confirm WAL → zero data loss (RPO 0), higher commit latency.

### Logical replication
- **What:** decodes WAL into **row-level changes** and publishes selected tables (publish/subscribe).
- **Use for:** major-version upgrades with near-zero downtime, partial/selective replication, replicating into a different schema, CDC.
- **Limits:** doesn't replicate DDL, sequences need care, large transactions can lag, conflicts possible on subscriber.

```
PHYSICAL                              LOGICAL
primary ──WAL stream──► standby       publisher ──decoded rows──► subscriber
(whole cluster, read-only)            (chosen tables, writable target)
```

### Key terms
| Term | Meaning |
|------|---------|
| **LSN** | Log Sequence Number — a byte position in the WAL stream; the unit of replication progress |
| **Replication slot** | Server-side bookmark guaranteeing WAL is retained until the replica consumes it |
| **`sent_lsn` / `write_lsn` / `flush_lsn` / `replay_lsn`** | Stages of WAL progress on the standby (sent → written → fsynced → applied) |
| **WAL sender / receiver** | Processes that ship and receive WAL |
| **RPO / RTO** | Recovery Point (data loss) / Recovery Time objectives |

---

## Monitoring & lag

### On the primary — per-replica state and lag
```sql
SELECT client_addr, application_name, state, sync_state,
       pg_size_pretty(pg_wal_lsn_diff(pg_current_wal_lsn(), sent_lsn))   AS sent_lag,
       pg_size_pretty(pg_wal_lsn_diff(pg_current_wal_lsn(), replay_lsn)) AS replay_lag,
       write_lag, flush_lag, replay_lag AS replay_time_lag
FROM pg_stat_replication;
```
- **`replay_lag` (bytes)** — how far behind the standby is in *applying* WAL. The number that matters most for read-after-write staleness.
- **`state`** — should be `streaming`. `catchup` = still catching up.
- **`sync_state`** — `async`, `sync`, or `potential`.

### On the standby — am I behind, and by how long?
```sql
SELECT pg_is_in_recovery();                       -- true on a standby
SELECT now() - pg_last_xact_replay_timestamp() AS replay_delay;  -- time lag
SELECT pg_last_wal_receive_lsn(), pg_last_wal_replay_lsn();
```

### Replication slots (WAL retention)
```sql
SELECT slot_name, slot_type, active, wal_status,
       pg_size_pretty(pg_wal_lsn_diff(pg_current_wal_lsn(), restart_lsn)) AS retained_wal
FROM pg_replication_slots;
```
- **`active = false`** on a slot = **danger**: it's retaining WAL for a consumer that isn't there → `pg_wal` grows until the disk fills.
- **`wal_status = 'lost'`** = required WAL was already removed; the replica can't catch up.

---

## Troubleshooting

### Symptom → cause → fix
| Symptom | Likely cause | Fix |
|---------|--------------|-----|
| **Replication lag growing** | Standby can't keep up: slow disk/CPU, heavy read queries, single-threaded replay bottleneck, large transactions | Faster standby storage; offload heavy queries; check `recovery_min_apply_delay`; consider fewer big transactions |
| **`pg_wal` filling on primary** | Inactive replication slot or failed `archive_command` retaining WAL | Find inactive slots (`pg_replication_slots`); drop orphaned slot (`pg_drop_replication_slot`); fix archiving |
| **Standby fell too far behind, can't catch up** | Required WAL recycled before sent (`wal_status='lost'`, no slot) | Use a **replication slot** to retain WAL; or re-sync standby (`pg_basebackup` / `pg_rewind`) |
| **Standby queries canceled** (`ERROR: canceling statement due to conflict with recovery`) | Long read query on standby conflicts with WAL replay (vacuum cleanup) | Raise `max_standby_streaming_delay`; or `hot_standby_feedback = on` (trades bloat on primary) |
| **Sync replication stalls all commits** | The only sync standby is down → primary waits forever | Configure multiple sync candidates (`synchronous_standby_names`), or use quorum `ANY n (...)` |
| **Logical: subscriber not receiving changes** | Subscription disabled, slot inactive, or publication missing tables | Check `pg_stat_subscription`, `pg_publication_tables`, slot `active` |
| **Logical: replication conflict / duplicate key** | Target row already exists / local writes clash | Resolve conflict, ensure target is effectively read-only for replicated tables, check `pg_stat_subscription_stats` |
| **After failover: split-brain risk** | Old primary comes back as a second writer | Fence old primary; use `pg_rewind` to re-attach as standby; rely on Patroni/DCS consensus |

### Key diagnostic queries
```sql
-- Is replication even connected? (run on primary)
SELECT count(*) FROM pg_stat_replication;

-- Lag in seconds on standby
SELECT CASE WHEN pg_is_in_recovery()
            THEN extract(epoch FROM now() - pg_last_xact_replay_timestamp())
       END AS replay_lag_seconds;

-- Logical replication subscriber status
SELECT subname, received_lsn, latest_end_lsn,
       last_msg_receipt_time FROM pg_stat_subscription;

-- WAL retained by each slot (sorted worst first)
SELECT slot_name, active,
       pg_size_pretty(pg_wal_lsn_diff(pg_current_wal_lsn(), restart_lsn)) AS retained
FROM pg_replication_slots
ORDER BY pg_wal_lsn_diff(pg_current_wal_lsn(), restart_lsn) DESC;
```

---

## Best practices

### Setup & safety
- **Always use replication slots** so the primary retains WAL until the standby consumes it — but **monitor for inactive slots** (the #1 disk-fill cause). Set `max_slot_wal_keep_size` (PG13+) to cap how much WAL a slot may retain, so a dead replica can't fill the disk.
- **Use `pg_basebackup`** (or pgBackRest/WAL-G) to seed standbys; **`pg_rewind`** to re-attach a former primary after failover without a full rebuild.
- **Enable `hot_standby = on`** for read replicas; understand the query-cancellation vs primary-bloat trade-off of `hot_standby_feedback`.

### Synchronous replication
- Use **quorum-based** sync to avoid a single down standby stalling commits:
  ```
  synchronous_standby_names = 'ANY 1 (standby1, standby2, standby3)'
  ```
- Reserve `synchronous_commit = remote_apply` for true zero-loss-read needs; it's the strictest/slowest. `remote_write` / `on` are lighter.
- Never run with a **single** sync standby and no fallback — that's an availability landmine.

### Lag management
- Alert on **both** byte lag (`replay_lag` bytes) and **time lag** (`now() - pg_last_xact_replay_timestamp()`).
- Keep standby hardware ≥ primary (replay is largely single-threaded; a weak standby lags).
- Route only **lag-tolerant** reads to async replicas; send read-after-write traffic to the primary or a sync standby.

### HA & failover (see deep dive §3.3)
- Use **Patroni + a DCS** (etcd/Consul) for automatic failover and **split-brain prevention** via consensus.
- Route clients through **HAProxy/PgBouncer/VIP** so they follow the new primary automatically.
- Define and **test** RPO/RTO; rehearse failover and `pg_rewind` re-attach regularly.

### Monitoring checklist
1. `pg_stat_replication` on primary: `state='streaming'`, lag within SLO.
2. Inactive replication slots → alert immediately.
3. `max_slot_wal_keep_size` set so a dead replica can't fill `pg_wal`.
4. Standby time lag alert (e.g. > 30s).
5. For logical: `pg_stat_subscription` progressing, no conflicts.
6. Failover path (Patroni/DCS) healthy; client routing tested.

---

## One-liner for the interview

> *"Physical replication streams raw WAL to read-only standbys for HA; logical replication decodes WAL into row changes for selective/cross-version use like near-zero-downtime upgrades. I monitor `pg_stat_replication` for `replay_lag` and watch for inactive replication slots, which are the classic cause of `pg_wal` filling the disk — I cap them with `max_slot_wal_keep_size`. For zero data loss I use quorum synchronous replication so one down standby can't stall commits, and for HA I rely on Patroni with a DCS for consensus-based failover and split-brain prevention, plus `pg_rewind` to re-attach an old primary."*
