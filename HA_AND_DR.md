# PostgreSQL High Availability & Disaster Recovery

Focus: **replication, automatic failover, and disaster recovery** — how to keep PostgreSQL available and recoverable at scale. Highly relevant to the Wavelo DBRE role (PostgreSQL at scale, HA, multi-region).

**See also:** [POSTGRESQL_DEEP_DIVE.md](POSTGRESQL_DEEP_DIVE.md) §3 (HA & scaling) · [WAL_AND_CHECKPOINTS.md](WAL_AND_CHECKPOINTS.md) · [PERFORMANCE_ANALYSIS.md](PERFORMANCE_ANALYSIS.md)

---

## Replication basics (condensed)

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

## Failover automation

**Failover** = promoting a standby to primary when the primary fails. Doing it **automatically and safely** is the core of HA. The hard part isn't the promotion — it's *detecting* failure correctly and *preventing split-brain* (two primaries accepting writes).

### Manual vs automatic
- **Manual failover / switchover:** an operator runs `pg_ctl promote` (or `SELECT pg_promote()`) on a chosen standby. Fine for planned maintenance (switchover), too slow for unplanned outages.
- **Automatic failover:** a cluster manager continuously health-checks the primary, elects a new leader, promotes it, and redirects clients — in seconds.

### The anatomy of safe automatic failover
```
1. DETECT     health checks + timeouts decide the primary is really down
2. ELECT      pick the best standby (most caught-up = lowest data loss)
3. FENCE      ensure the old primary can't keep writing (STONITH / demote)
4. PROMOTE    pg_promote() the chosen standby to primary
5. REDIRECT   clients/proxy point at the new primary
6. REPAIR     re-attach old primary as a standby (pg_rewind)
```

### Split-brain & how it's prevented
Split-brain = the old primary comes back (or never fully died) and a second one was promoted → **two writers, diverging data**. Prevention relies on:
- **Consensus / quorum** via a **DCS** (Distributed Configuration Store: etcd, Consul, ZooKeeper). Only the node holding the leader lock in the DCS may be primary.
- **Fencing / STONITH** ("shoot the other node in the head") — forcibly isolate or kill the old primary (kill VM, revoke its network/VIP, demote it).
- **Watchdog** (e.g. Patroni + watchdog) — the old primary self-demotes if it loses the leader key, even if hung.

---

## Failover automation tools

| Tool | Model | Notes |
|------|-------|-------|
| **Patroni** | Template/agent + **DCS** (etcd/Consul/ZooKeeper) | The de-facto standard. Each node runs a Patroni agent; leader election + config live in the DCS; integrates with watchdog for fencing. Most flexible, cloud-friendly. |
| **repmgr** | Daemon (`repmgrd`) | Simpler, no external DCS (uses its own metadata + witness node). Good for smaller setups; weaker split-brain guarantees than quorum DCS. |
| **pg_auto_failover** | Monitor + keeper nodes | Microsoft project; a dedicated **monitor** node arbitrates. Easy 2-node + monitor topology. |
| **Stolon** | Proxy-based + DCS | Kubernetes-friendly; routes all traffic through its own proxy that always points to the current primary. |
| **PAF (PostgreSQL Automatic Failover)** | **Pacemaker/Corosync** resource agent | Linux HA stack; strong fencing (STONITH) but heavier/more complex to operate. |
| **Cloud-managed** | Vendor-managed | RDS/Aurora, Cloud SQL, Azure Postgres do failover for you (Multi-AZ); least control, least effort. |
| **Patroni on Kubernetes operators** | Operator (Zalando, CrunchyData/CPNG) | Patroni under the hood, declarative CRDs; common modern deployment. |

### Client redirection (so apps follow the new primary)
A promoted standby is useless if clients still connect to the dead one. Options:
- **HAProxy** with health checks hitting Patroni's REST API (routes to whoever reports `role=primary`). Common pattern: port 5000 → primary, 5001 → replicas.
- **PgBouncer** (re-pointed on failover) for pooling + redirection.
- **Virtual IP (VIP)** that moves to the new primary.
- **Stolon/operators**: built-in proxy.
- **libpq multi-host** connection strings: `host=a,b,c target_session_attrs=read-write` — the driver finds the writable node (simple, no proxy, but reconnect-based).

---

## Disaster Recovery (DR)

HA handles a node failure within a site; **DR** handles losing the whole site/region or corruption/human error that replication faithfully copies everywhere.

### Backup types
| Type | Tool | Restore granularity |
|------|------|---------------------|
| **Logical** | `pg_dump` / `pg_dumpall` | Per-DB/table; portable across versions; slow restore |
| **Physical base backup** | `pg_basebackup` | Whole cluster snapshot |
| **Physical + WAL archiving → PITR** | `pgBackRest`, `Barman`, `WAL-G` | **Any point in time**; incremental, compressed, parallel, S3 |

### Point-In-Time Recovery (PITR)
Continuous WAL archiving lets you restore to an **exact moment** — e.g. just before a bad `DELETE`:
```
restore base backup  +  replay archived WAL up to '2026-06-17 09:42:00'
                        (recovery_target_time)
```
This is the key DR capability replication alone can't give you: replication copies the bad `DELETE` to every standby instantly; **only a backup + PITR can rewind it.**

### DR strategy essentials
- **3-2-1 rule:** 3 copies, 2 media types, 1 off-site (different region/provider).
- **Cross-region standby** for fast regional failover (async streaming to another region).
- **Define RPO/RTO** and pick tooling to meet them:
  - Low RPO → synchronous replication + frequent WAL archiving.
  - Low RTO → warm standby ready to promote (HA) rather than restore-from-backup.
- **Test restores regularly** — a backup you've never restored is not a backup. Measure actual restore time against your RTO.

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
- **`replay_lag` (bytes)** — how far behind the standby is in *applying* WAL. Matters most for read-after-write staleness and for choosing a failover target.
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

(Ready-to-run versions in [scripts/replication.sql](scripts/replication.sql).)

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
| **Failover didn't trigger** | DCS quorum lost, health-check thresholds too lax, no eligible standby | Check DCS health (etcd/Consul); tune Patroni `ttl`/`loop_wait`/`retry_timeout`; ensure a caught-up standby exists |
| **Split-brain (two primaries)** | Old primary returned without fencing | Fence/STONITH old node; `pg_rewind` to re-attach as standby; rely on DCS consensus + watchdog |
| **Clients still hit old primary after failover** | No proxy/VIP redirection | HAProxy via Patroni REST, VIP move, or `target_session_attrs=read-write` |
| **Logical: subscriber not receiving changes** | Subscription disabled, slot inactive, or publication missing tables | Check `pg_stat_subscription`, `pg_publication_tables`, slot `active` |
| **Logical: replication conflict / duplicate key** | Target row already exists / local writes clash | Resolve conflict, ensure target is read-only for replicated tables, check `pg_stat_subscription_stats` |

### Key diagnostic queries
```sql
-- Is replication even connected? (run on primary)
SELECT count(*) FROM pg_stat_replication;

-- Lag in seconds on standby
SELECT CASE WHEN pg_is_in_recovery()
            THEN extract(epoch FROM now() - pg_last_xact_replay_timestamp())
       END AS replay_lag_seconds;

-- WAL retained by each slot (sorted worst first)
SELECT slot_name, active,
       pg_size_pretty(pg_wal_lsn_diff(pg_current_wal_lsn(), restart_lsn)) AS retained
FROM pg_replication_slots
ORDER BY pg_wal_lsn_diff(pg_current_wal_lsn(), restart_lsn) DESC;
```

With Patroni, also: `patronictl list` (cluster state/roles/lag) and the Patroni REST API (`/health`, `/primary`, `/replica`).

---

## Best practices

### Replication setup & safety
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

### Failover automation
- Use **Patroni + a DCS** (etcd/Consul) for automatic failover and **split-brain prevention** via consensus; enable the **watchdog** for fencing.
- Keep an **odd number of DCS members** (3 or 5) so quorum survives a node loss.
- Tune detection vs stability: Patroni `ttl` (leader key lifetime), `loop_wait`, `retry_timeout` — too aggressive = false failovers (flapping); too lax = slow detection.
- Route clients through **HAProxy/PgBouncer/VIP** (or `target_session_attrs=read-write`) so they follow the new primary automatically.
- **Rehearse failover** (planned switchover) and `pg_rewind` re-attach regularly — don't discover problems during a real outage.

### DR
- Follow **3-2-1**; keep a **cross-region** copy/standby.
- Use **pgBackRest/Barman/WAL-G** for PITR; **test restores** and measure against RTO.
- Document and version your recovery runbooks.

### Monitoring checklist
1. `pg_stat_replication` on primary: `state='streaming'`, lag within SLO.
2. Inactive replication slots → alert immediately.
3. `max_slot_wal_keep_size` set so a dead replica can't fill `pg_wal`.
4. Standby time lag alert (e.g. > 30s).
5. DCS quorum healthy; Patroni `patronictl list` shows expected roles.
6. Client routing (HAProxy/VIP) tested against an actual failover.
7. Backups succeeding + periodic **test restore**; RPO/RTO validated.

---

## One-liner for the interview

> *"For HA I run streaming replicas managed by **Patroni with an etcd/Consul DCS**: it health-checks the primary, elects the most caught-up standby, fences the old node via watchdog to prevent split-brain, promotes with `pg_promote`, and clients follow via HAProxy hitting Patroni's REST API. I tune `ttl`/`loop_wait` to balance fast detection against flapping, and re-attach the old primary with `pg_rewind`. HA covers node failure, but for DR — region loss or a bad `DELETE` that replication copies everywhere — I rely on pgBackRest/WAL-G WAL archiving for PITR, a cross-region copy under 3-2-1, and regularly tested restores measured against RTO."*
