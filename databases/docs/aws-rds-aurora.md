# AWS RDS & Aurora (PostgreSQL)

How managed PostgreSQL works on AWS — **RDS** and **Aurora** — what differs from self-managed Postgres, and the operational knobs that matter.

**See also:** [ha-and-dr.md](ha-and-dr.md) · [best-practices.md](best-practices.md) · [pgbouncer.md](pgbouncer.md) · [recovery.md](recovery.md)

---

## The three ways to run PostgreSQL on AWS

| Option | What it is | You manage | AWS manages |
|--------|-----------|------------|-------------|
| **EC2 self-managed** | Postgres you install on a VM | everything (OS, PG, HA, backups) | just the hardware |
| **RDS for PostgreSQL** | Managed community PostgreSQL | schema, queries, params | OS, patching, backups, failover, replication |
| **Aurora PostgreSQL** | AWS's cloud-native, PG-**compatible** engine | schema, queries, params | all of RDS + a re-architected storage layer |

RDS runs the **real community PostgreSQL** binary. Aurora is a **PostgreSQL-compatible** engine that keeps the SQL/wire protocol but replaces the storage engine with a distributed, log-based one.

---

## RDS for PostgreSQL

**Architecture:** a single primary instance with attached EBS storage. Optional:
- **Multi-AZ instance:** a synchronous **standby** in another AZ (EBS-level replication). On failure, RDS fails over via DNS (~60–120s). The standby is **not readable** — it's purely for HA.
- **Multi-AZ DB cluster:** 1 writer + 2 readable standbys (semi-sync), faster failover (~35s).
- **Read replicas:** up to 5, **asynchronous** streaming replication; readable; can be promoted; can live cross-region.

**Backups:**
- **Automated backups** → daily snapshot + continuous WAL to S3 → **PITR** to any second in the retention window (up to 35 days).
- **Manual snapshots** persist until you delete them.

**Storage:** provisioned EBS (gp3/io1/io2); **storage autoscaling** grows it automatically.

**Key limitation:** no OS or true superuser access. You get the **`rds_superuser`** role (elevated but restricted); no `SET` of restricted params, no filesystem, no extensions unless AWS allows them.

---

## Aurora PostgreSQL

**The big idea:** compute and storage are **decoupled**. Aurora replaces WAL-to-datafile with a purpose-built storage service.

- **Shared distributed storage:** one storage volume shared by all cluster instances, auto-growing to 128 TiB.
- **6 copies across 3 AZs**, with quorum writes (4/6) and reads (3/6) — survives an AZ loss with no data loss.
- **Replicas are fast and cheap:** up to **15 Aurora replicas** read the *same* shared storage, so there's no separate copy of data and replica lag is typically **single-digit milliseconds** (they don't replay WAL the traditional way — they read shared storage).
- **Failover:** a replica is promoted in ~**30s or less** because storage is already shared (no data to copy).

**Endpoints (this is a common interview point):**
| Endpoint | Points to | Use for |
|----------|-----------|---------|
| **Cluster (writer) endpoint** | current primary | writes |
| **Reader endpoint** | load-balances across replicas | reads |
| **Instance endpoint** | one specific instance | targeted/admin |
| **Custom endpoint** | a chosen subset | e.g. analytics-only nodes |

**Aurora-specific features:**
- **Backtrack** — rewind the cluster in-place to a past time (no restore) for quick "oops" recovery.
- **Fast clones** — copy-on-write clone of a large DB in minutes for testing.
- **Aurora Serverless v2** — auto-scales compute (ACUs) up/down with load; good for spiky/variable workloads.
- **Global Database** — cross-region replication with typically <1s lag for DR / low-latency global reads (see below).

---

## Aurora Global Database (multi-region)

An **Aurora Global Database** is a single logical database spanning **multiple AWS regions**: one **primary region** that handles all writes, plus up to **five secondary regions** that are read-only and kept in sync.

**How it works (why it's fast):** replication happens at the **storage layer**, not by shipping/replaying WAL over a normal connection. The primary's storage service streams changes directly to each secondary region's storage, so:
- **Lag is typically under 1 second** (often ~tens of ms) even cross-continent.
- It uses **dedicated infrastructure**, so replication doesn't steal CPU/IO from the primary's database engine.
- Each secondary region can have up to **16 read replicas** for local low-latency reads.

**Why use it:**
- **Disaster recovery** — survive a full **region** outage (RDS Multi-AZ only survives an *AZ* outage). Low **RPO** (≈1s of data) and low **RTO** (promote a secondary in typically **<1 minute**).
- **Low-latency global reads** — serve users near a secondary region from local replicas.
- **Cross-region scaling** — offload read traffic to other regions.

**Failover options:**
- **Managed planned failover** — for drills/maintenance; keeps the topology intact and loses no data (it syncs first).
- **Unplanned (detach & promote)** — during a real regional outage you promote a secondary to be a standalone primary.

### Headless secondary regions

A **headless secondary** is a secondary region that has **storage but no DB instances (no compute)** — just the replicated Aurora storage volume kept in sync from the primary.

- **Why:** it dramatically **cuts cost** for a DR standby. You pay for storage + replication (and replicated I/O) but **not for idle compute** sitting there waiting for a disaster.
- **How it behaves:** the region stays continuously up to date at the storage layer. Because there are no readers, you **can't serve reads** from it while it's headless.
- **At failover:** you **add compute instances** to that region (or promote it), then it starts serving traffic. There's a short delay to spin up instances versus a "hot" secondary that already has replicas running — a classic **cost vs. RTO trade-off**.
- **Setup:** create the Global Database secondary region and simply don't provision any DB instances in it (0 instances) — the storage-only volume is the headless secondary.

> Trade-off summary: **hot secondary** (has replicas) = faster failover + serves reads, higher cost. **Headless secondary** (no compute) = cheapest DR, but you add instances at failover so RTO is a bit higher.

---

## RDS vs Aurora — how to choose

| Dimension | RDS PostgreSQL | Aurora PostgreSQL |
|-----------|----------------|-------------------|
| Engine | community PostgreSQL | PG-compatible (custom storage) |
| Read replicas | up to 5, async (own storage) | up to 15, ~ms lag (shared storage) |
| Failover | ~60–120s (single-AZ standby) | ~30s (shared storage) |
| Storage | provisioned EBS, autoscaling | auto-grow shared, 6× 3-AZ |
| Extra features | simpler, cheaper baseline | Backtrack, clones, Serverless v2, Global DB |
| Cost | lower for small/steady | higher, but scales & performs better |
| Best for | standard workloads, cost-sensitive | high-throughput, many replicas, HA-critical, scale |

**Rule of thumb:** RDS for straightforward/cost-sensitive workloads; Aurora when you need many low-lag read replicas, faster failover, big scale, or its differentiators.

---

## Operating both — the knobs that matter

- **Parameter groups** = managed `postgresql.conf`. You change settings here, not by editing a file. Static params need a **reboot**; dynamic ones apply on save. (`context = postmaster` still means reboot.)
- **Option/DB cluster parameter groups** for cluster-wide (Aurora) settings.
- **Monitoring:**
  - **CloudWatch** — CPU, IOPS, connections, freeable memory, replica lag, storage.
  - **Enhanced Monitoring** — OS-level metrics (per-process).
  - **Performance Insights** — the killer feature: visualizes DB load by **wait event** and top SQL (the managed equivalent of `pg_stat_activity` + `pg_stat_statements`).
- **Connection management:** **RDS Proxy** = managed connection pooling/multiplexing (the AWS PgBouncer), also smooths failover by holding client connections.
- **Security:** run in a **VPC** (private subnets), **security groups** as the firewall, **KMS** encryption at rest, **TLS** in transit, and **IAM database authentication** (token-based, no stored passwords). Audit with `pgaudit` + CloudTrail.
- **Maintenance windows:** AWS patches minor versions in your chosen window; major upgrades are initiated by you.

---

## What you give up vs self-managed

- No OS/shell access, no true `superuser` (only `rds_superuser`).
- Only **AWS-approved extensions**; some `postgresql.conf` params are locked.
- You rely on AWS's failover/replication implementation rather than Patroni/repmgr.
- Aurora's internals differ from community PG — a few extensions/tools that assume standard WAL don't apply.

**The trade-off:** you trade low-level control for AWS handling patching, backups, HA, and storage durability — less toil, faster to operate, at higher cost.

---

## Interview quick hits

- *"RDS vs Aurora?"* → RDS = managed community PG on EBS; Aurora = PG-compatible with distributed 6-copy/3-AZ shared storage, up to 15 near-zero-lag replicas, ~30s failover, plus Backtrack/clones/Serverless.
- *"How does Aurora get such fast replicas/failover?"* → Replicas share one storage volume, so there's no data copy — promotion and reads are near-instant.
- *"PITR on RDS?"* → Automated backups (daily snapshot + continuous WAL to S3) let you restore to any second within the retention window (≤35 days).
- *"How do you pool connections?"* → RDS Proxy (managed), or PgBouncer on the app side.
- *"How do you monitor?"* → Performance Insights (load by wait event + top SQL) + CloudWatch + Enhanced Monitoring.
- *"Superuser?"* → No true superuser on RDS/Aurora — you get `rds_superuser`.
- *"How do you survive a whole region going down?"* → Aurora **Global Database**: storage-layer replication to secondary regions with <1s lag, promote a secondary in <1 min (region-level DR, unlike Multi-AZ which is AZ-level).
- *"What's a headless secondary?"* → A Global Database secondary region with **storage but no compute** — cheap DR standby; you add instances at failover (cost vs. RTO trade-off).
