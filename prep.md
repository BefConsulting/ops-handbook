# Interview Prep — Senior Database / Reliability Engineer

Maps each required Knowledge/Skill/Ability to **what they're testing**, **key points to hit**, **likely questions with crisp answers**, and **where to study** in this handbook.

> How to use: read each section's "key points" out loud until you can deliver them without notes, then drill the questions. Deep references live in [databases/docs/](databases/docs/).

**Quick links:** [deep-dive](databases/docs/deep-dive.md) · [performance-analysis](databases/docs/performance-analysis.md) · [wal-and-checkpoints](databases/docs/wal-and-checkpoints.md) · [ha-and-dr](databases/docs/ha-and-dr.md) · [patroni](databases/docs/patroni.md) · [best-practices](databases/docs/best-practices.md) · [cache](databases/docs/cache.md) · [scripts](databases/scripts/)

---

## 1. PostgreSQL internals — MVCC, WAL, vacuum, locking, query planning
**Testing:** Do you understand *why* Postgres behaves the way it does, not just commands.

**Key points:**
- **MVCC:** every row version carries `xmin`/`xmax`. Readers never block writers; each tuple is visible if its `xmin` committed ≤ your snapshot and `xmax` is empty/uncommitted. Updates/deletes don't remove rows — they mark them dead, which is why **bloat** and **vacuum** exist.
- **WAL:** write-ahead logging — changes hit the WAL (sequential, durable) *before* the data files. Commit = WAL flushed. Dirty buffers are written later by checkpoints. Gives durability + crash recovery + the basis for replication/PITR.
- **Vacuum:** reclaims dead tuples, updates the visibility map, refreshes stats (ANALYZE), and **freezes** old XIDs to prevent transaction-ID **wraparound**.
- **Locking:** row locks live in the tuple (`xmax`), not a lock table; table-level locks are in `pg_locks`. MVCC means most reads need no locks.
- **Query planning:** cost-based optimizer using table statistics → picks scan/join/aggregate methods by estimated cost.

**Likely questions:**
- *"What is bloat and how do you fix it?"* → Dead tuples left by updates/deletes; monitor `n_dead_tup`/dead_pct; fix with autovacuum tuning, `VACUUM`, or `VACUUM FULL`/`pg_repack` for severe cases.
- *"What is XID wraparound and how do you prevent it?"* → XIDs are 32-bit; un-frozen old rows could appear "in the future." Autovacuum freezes before `autovacuum_freeze_max_age`. Monitor `age(datfrozenxid)`.
- *"Why did my UPDATE not block a SELECT?"* → MVCC: the reader sees the old version until the writer commits.

**Study:** [deep-dive §1](databases/docs/deep-dive.md) · [wal-and-checkpoints](databases/docs/wal-and-checkpoints.md) · scripts: [vacuum_bloat.sql](databases/scripts/vacuum_bloat.sql), [activity.sql](databases/scripts/activity.sql)

---

## 2. Highly available clusters with automated failover
**Testing:** Can you design HA that survives a node loss without split-brain or data loss.

**Key points:**
- **Streaming replication** (physical): primary ships WAL to standbys; sync (zero data loss, latency cost) vs async (fast, small RPO).
- **Automated failover** needs three things: **failure detection**, **leader election**, and **fencing** of the old primary. A tool (Patroni) + a **DCS** (etcd/Consul) provides this. Only the holder of the leader key in the DCS may be primary → prevents split-brain.
- **Client redirection:** HAProxy (routes via Patroni REST `/primary` & `/replica`), VIP/keepalived, or `libpq` multi-host `target_session_attrs=read-write`.
- **`pg_rewind`** re-attaches a failed old primary without a full rebuild.
- **RPO/RTO:** define them up front; they drive sync vs async and backup cadence.

**Likely questions:**
- *"How do you prevent split-brain?"* → Consensus leader key in the DCS + quorum (3/5 nodes) + fencing/watchdog so a partitioned old primary demotes itself.
- *"Sync vs async replication trade-off?"* → Sync = RPO 0 but commit waits on the standby; async = lower latency but you can lose the last transactions on failover.
- *"Walk me through a failover."* → Detection (TTL expires) → election of most-caught-up replica → promote (new timeline) → reroute clients → rejoin old node via pg_rewind.

**Study:** [ha-and-dr](databases/docs/ha-and-dr.md) · [patroni](databases/docs/patroni.md) · [replication.sql](databases/scripts/replication.sql)

---

## 3. Performance tuning — query optimization, indexing, workload tuning
**Testing:** Can you make a real workload faster, methodically.

**Key points:**
- **Read the plan:** `EXPLAIN (ANALYZE, BUFFERS)`. Compare **estimated vs actual rows** (off = stale stats), watch **shared hit vs read** (cache), **loops** (nested loop blowups), and **Sort Method: external merge** (raise `work_mem`).
- **Indexing:** B-tree for equality/range; **composite** (column order matters), **covering** (`INCLUDE`) for index-only scans, **partial** for hot subsets, **expression** indexes for `lower(col)` etc. Every index costs write throughput.
- **Workload tuning:** `shared_buffers` ~25% RAM, `effective_cache_size` 50–75%, `work_mem` per-node/per-conn, `random_page_cost`≈1.1 on SSD, partitioning for huge tables, PgBouncer for connection storms.

**Likely questions:**
- *"A query suddenly got slow — what do you do?"* → Reproduce, `EXPLAIN ANALYZE`, check plan change/stats, indexes, parameter sniffing, recent data growth; fix root cause and verify.
- *"When is a seq scan correct?"* → Small tables or low-selectivity predicates returning much of the table — the planner is right to skip the index.
- *"Index exists but isn't used — why?"* → Low selectivity, stale stats, type mismatch, function on the column, or `random_page_cost` too high.

**Study:** [performance-analysis](databases/docs/performance-analysis.md) · [cache](databases/docs/cache.md) · [lab scenarios](databases/lab/scenarios/) · [indexes.sql](databases/scripts/indexes.sql), [slow_queries.sql](databases/scripts/slow_queries.sql)

---

## 4. Diagnosing issues — query plans, I/O, memory, WAL growth, bloat
**Testing:** A structured triage method under pressure.

**Key points (the funnel):**
1. **Scope** — CPU, I/O, locks, connections, or one bad query?
2. **`pg_stat_activity`** — long-running/active queries, `idle in transaction`, blocking (`pg_blocking_pids`).
3. **`pg_stat_statements`** — top queries by total/mean time.
4. **`EXPLAIN (ANALYZE, BUFFERS)`** — on the worst offender.
5. **Cache** — DB hit ratio (want >99% OLTP), per-table/index in `pg_statio_*`.
6. **WAL growth** — usually an **inactive replication slot** or stuck archiving; check `pg_replication_slots`, `pg_ls_waldir()`.
7. **Bloat/wraparound** — `n_dead_tup`, `age(relfrozenxid)`.

**Likely questions:**
- *"`pg_wal` is filling the disk — why?"* → Inactive/orphaned replication slot retaining WAL, failing `archive_command`, or `max_wal_size` huge. Drop the dead slot, fix archiving, bound `max_slot_wal_keep_size`.
- *"How do you find what's blocking a query?"* → `pg_stat_activity` + `pg_blocking_pids()`; identify holder, decide to wait or `pg_terminate_backend()`.
- *"Memory pressure signs?"* → Low cache hit ratio, temp files from `work_mem` spills (`log_temp_files`), OOM events.

**Study:** [performance-analysis](databases/docs/performance-analysis.md) · all of [databases/scripts/](databases/scripts/) (each has `look:` hints), run [all.sql](databases/scripts/all.sql)

---

## 5. Backup & recovery — PITR, durability planning
**Testing:** Can you guarantee recoverability to a point in time.

**Key points:**
- **Logical** (`pg_dump`) vs **physical** (`pg_basebackup`, file-level). Physical + WAL archiving enables **PITR**.
- **PITR** = base backup + continuous WAL archive → restore base, replay WAL to a target time/LSN (`recovery_target_time`). Needs `archive_mode=on` + an `archive_command`.
- **Tools:** **pgBackRest** / **Barman** / **WAL-G** — incremental backups, compression, retention, parallelism.
- **Durability planning:** define **RPO** (max data loss) and **RTO** (max downtime); follow **3-2-1** (3 copies, 2 media, 1 offsite). **Test restores** regularly — an untested backup isn't a backup.

**Likely questions:**
- *"How does PITR work?"* → Restore the base backup, then replay archived WAL up to `recovery_target_time`/LSN; Postgres stops there and opens.
- *"How do you pick backup frequency?"* → From the RPO; WAL archiving gives near-continuous recovery between base backups.
- *"Difference between a replica and a backup?"* → A replica protects against node failure but faithfully replicates mistakes (a `DROP TABLE` propagates); backups/PITR protect against logical errors.

**Study:** [ha-and-dr — Disaster Recovery](databases/docs/ha-and-dr.md)

---

## 6. Observability & monitoring — metrics, alerting, Grafana
**Testing:** Can you operate proactively, not just react.

**Key points:**
- **Exporter → TSDB → dashboard:** `postgres_exporter` → **Prometheus** → **Grafana**; node_exporter for host metrics.
- **Key metrics:** connections vs `max_connections`, cache hit ratio, replication lag (bytes & seconds), checkpoint frequency (timed vs requested), dead tuples / XID age, slow queries (`pg_stat_statements`), TPS, lock waits, `pg_wal` size, disk/CPU/IO.
- **Alerting (symptoms, not noise):** replication lag/broken, inactive replication slot, XID age approaching wraparound, disk %, connections near max, checkpoints mostly requested, long `idle in transaction`.
- Internals are exposed via `pg_stat_*` views — the same ones in [databases/scripts/](databases/scripts/).

**Likely questions:**
- *"What would you put on a Postgres dashboard?"* → The key metrics above, grouped: availability/replication, throughput/latency, resource saturation, maintenance (vacuum/bloat/XID).
- *"What alerts are must-haves?"* → Wraparound risk, replication broken/lagging, inactive slot, disk full, connection exhaustion.

**Study:** map [scripts/](databases/scripts/) queries → metrics; [performance-analysis](databases/docs/performance-analysis.md)

---

## 7. Distributed systems — service discovery, consensus (Consul)
**Testing:** Do you understand the theory behind HA tooling.

**Key points:**
- **Consensus** (Raft, used by etcd/Consul) keeps a replicated, agreed-upon state across nodes; needs a **quorum** (majority) → run **odd numbers (3/5)**. This is what makes a leader key trustworthy.
- **Service discovery:** components find each other dynamically (Consul DNS/KV, registered health-checked services) instead of hard-coded IPs — e.g. clients resolve "the current primary."
- **DCS in HA:** Patroni stores cluster state + leader key in etcd **or Consul**; the consensus guarantee is precisely what prevents two primaries.
- **CAP / split-brain:** during a partition you trade availability for consistency; quorum + fencing keeps the minority side from acting as primary.

**Likely questions:**
- *"Why an odd number of consensus nodes?"* → Majority quorum; 3 tolerates 1 failure, 5 tolerates 2; even numbers add cost without extra fault tolerance.
- *"How does Consul fit a Postgres HA setup?"* → As the DCS for Patroni (leader election + KV state) and/or service discovery so apps/HAProxy find the current primary.

**Study:** [patroni — DCS section](databases/docs/patroni.md) · [ha-and-dr](databases/docs/ha-and-dr.md)

---

## 8. Linux systems knowledge — performance tuning, resource management
**Testing:** You can tune the box under the database, not just the database.

**Key points:**
- **Memory:** disable **THP**; `vm.swappiness=1`; `vm.overcommit_memory=2` to protect the postmaster from the OOM killer; huge pages for `shared_buffers`.
- **I/O:** `vm.dirty_*` writeback tuning to avoid checkpoint write storms; `noatime`; NVMe scheduler `none`; separate volumes for data/WAL; reliable `fsync`.
- **Resources:** high `LimitNOFILE`; CPU governor `performance`; NUMA awareness; `somaxconn`.
- **Tools:** `top`/`htop`, `vmstat`, `iostat`, `pidstat`, `sar`, `dstat`, `ss`, `perf` — know what each tells you (CPU vs IO wait vs memory vs network).

**Likely questions:**
- *"Server is slow — is it CPU, IO, or memory?"* → `vmstat`/`iostat` for run queue, IO wait, swap; correlate with `pg_stat_activity` wait events.
- *"Why disable THP for Postgres?"* → defrag stalls cause latency spikes; PG explicitly recommends against it.

**Study:** [best-practices — Part 1 (Linux host)](databases/docs/best-practices.md)

---

## 9. Scripting & infrastructure-as-code automation
**Testing:** You automate repeatable, reviewable operations.

**Key points:**
- **Scripting:** Bash + SQL for ops (the [scripts/](databases/scripts/) suite); Python for heavier tooling.
- **IaC:** **Terraform** to provision DB infra (instances, storage, networking, replicas) declaratively with versioned state; **Ansible** for configuration management (install/configure Postgres, apply `postgresql.conf`, manage `pg_hba.conf`); **Jenkins** to gate plan/apply and run migrations in CI/CD.
- **Principles:** idempotency, version control, peer review (PR), least-privilege credentials, no manual snowflake changes.

**Likely questions:**
- *"How would you automate provisioning a new replica?"* → Terraform for the instance/storage/network, Ansible to install/configure and bootstrap from the primary (or let Patroni clone), all in version control behind CI.
- *"Terraform state — why does it matter?"* → It's the source of truth mapping config to real resources; use a remote backend with locking to avoid corruption/races.

**Study:** [terraform/](terraform/) · [ansible/](ansible/) · [jenkins/](jenkins/) (scaffolded for your notes)

---

## 10. Troubleshooting & problem-solving in production
**Testing:** Calm, structured incident handling.

**Key points / framework:** **Observe → orient → hypothesize → test → fix → verify → write it up.**
- Stop the bleeding first (restore service), then root-cause.
- Use evidence (metrics, logs, plans) — don't guess-and-restart.
- Change one thing at a time; keep a timeline; do a blameless postmortem.

**Likely question:** *"Tell me about a production incident."* → Use **STAR**: Situation, Task, Action, Result + what you changed afterward (alert added, runbook written).

**Have ready:** 2–3 STAR stories (a perf fire, a failover/HA event, a near-miss like wraparound or a filling disk).

---

## 11. Security, compliance, encryption, auditing, access control
**Testing:** You treat the DB as a protected asset.

**Key points:**
- **AuthN:** `pg_hba.conf` with `scram-sha-256`; never `trust` over a network; `listen_addresses` minimal.
- **AuthZ:** least privilege — roles, `GRANT`/`REVOKE`, `ALTER DEFAULT PRIVILEGES`, **Row-Level Security** for multi-tenant isolation.
- **Encryption:** **in transit** (`ssl=on`, TLS), **at rest** (filesystem/volume encryption or TDE-style at storage layer).
- **Auditing:** **pgAudit** for who-did-what; log connections/DDL; ship logs centrally.
- **Compliance:** retention, access reviews, separation of duties, encrypted backups.

**Likely questions:**
- *"Isolate tenants in one database?"* → RLS policies keyed on tenant + a current-tenant setting, plus schema/role separation.
- *"Encrypt at rest in Postgres?"* → No built-in full TDE; use filesystem/volume encryption (LUKS/cloud KMS) and encrypted backups.

**Study:** [deep-dive §4](databases/docs/deep-dive.md) · [best-practices — Security](databases/docs/best-practices.md)

---

## 12. Working independently in HA, production-critical systems
**Testing:** Judgment and ownership.

**Key points:** runbooks for common ops, change management/maintenance windows, test in staging, prefer reversible changes, automate the routine, communicate proactively, and know when escalation is the responsible call. Bias toward protecting availability and data integrity over speed.

---

## 13. AI-assisted tools (Claude, Windsurf, GitHub Copilot)
**Testing:** You use AI effectively *and* responsibly in an ops context.

**Key points:** use AI to draft scripts/IaC/SQL, explain plans, and write runbooks/postmortems faster — but **always review** generated SQL/migrations/IaC before running in production; never paste secrets/PII; treat output as a draft, not authority. Mention concrete use (e.g. building this handbook, generating monitoring queries, explaining EXPLAIN output).

---

## Rapid-fire cheat sheet
- **MVCC visibility:** `xmin` committed ≤ snapshot AND `xmax` empty/uncommitted.
- **Bloat metric:** `n_dead_tup` / dead_pct (`pg_stat_user_tables`).
- **Wraparound watch:** `age(datfrozenxid)` toward ~2.1B; freeze before `autovacuum_freeze_max_age`.
- **Cache hit target:** >99% OLTP (`pg_stat_database`).
- **Checkpoint health:** `checkpoints_req` ≈ 0 (else raise `max_wal_size`).
- **Replication lag:** `pg_stat_replication` (bytes) + `pg_last_xact_replay_timestamp()` (time).
- **WAL filling disk:** suspect an inactive replication slot first.
- **SSD planner:** `random_page_cost ≈ 1.1`.
- **Split-brain prevention:** DCS leader key + odd-quorum + fencing.
- **RPO/RTO:** drive sync-vs-async and backup cadence; test restores.
- **Don't disable:** `fsync`, `full_page_writes`, `autovacuum` in production.
