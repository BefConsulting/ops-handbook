# Patroni HA Lab — on local macOS (PostgreSQL 16)

A hands-on guide to building a 3-node Patroni cluster **on a single Mac** using your Homebrew PostgreSQL 16, with etcd as the DCS and HAProxy for client routing. Then test automatic failover.

**See also:** [ha-and-dr.md](ha-and-dr.md) (concepts: failover, split-brain, DCS) · [deep-dive.md](deep-dive.md) §3

> This runs three Postgres instances on one machine (ports 5432/5433/5434), each managed by its own Patroni agent, all coordinating through one etcd. It's a learning topology — in production each node is a separate host (ideally separate AZ/region).

---

## Architecture

```
                 ┌─────────────── etcd (DCS) :2379 ───────────────┐
                 │     leader election + cluster state             │
                 └───────▲───────────────▲───────────────▲────────┘
                         │               │               │
                   Patroni:8008    Patroni:8009    Patroni:8010
                         │               │               │
                   Postgres:5432   Postgres:5433   Postgres:5434
                     node1            node2            node3
                   (leader)         (replica)        (replica)
                         ▲               ▲               ▲
                         └──────── HAProxy ──────────────┘
                          :5000 -> primary   :5001 -> replicas
```

- **etcd** — the DCS that holds the leader key; only the key holder may be primary (split-brain prevention).
- **Patroni** — one agent per Postgres node; health-checks, elects, promotes, and exposes a REST API (8008–8010).
- **HAProxy** — routes writes to `:5000` (whoever Patroni reports as primary) and reads to `:5001`.

---

## 1. Install the tools

```bash
# PostgreSQL 16 you already have via Homebrew. Add etcd + haproxy:
brew install etcd haproxy

# Patroni (Python). Use a dedicated venv to avoid polluting system Python:
python3 -m venv ~/patroni-lab/venv
source ~/patroni-lab/venv/bin/activate
pip install --upgrade pip
pip install "patroni[etcd3]" psycopg2-binary

patroni --version
etcd --version
haproxy -v
```

Make sure the PG16 binaries are on PATH (Patroni also gets them via `bin_dir` in the config):
```bash
export PATH="/opt/homebrew/opt/postgresql@16/bin:$PATH"
```

---

## 2. Free port 5432 & make lab directories

Patroni runs its **own** Postgres instances (it calls `initdb` itself), so stop the Homebrew-managed server to free port 5432:

```bash
brew services stop postgresql@16

mkdir -p ~/patroni-lab/{node1,node2,node3}
```

> Your existing `pg_lab` data (in `/opt/homebrew/var/postgresql@16`) is untouched — Patroni uses separate data dirs under `~/patroni-lab`. Restart the brew service later to get it back.

---

## 3. Start etcd (the DCS)

In its own terminal (lab single-node etcd):

```bash
etcd \
  --name lab-etcd \
  --data-dir ~/patroni-lab/etcd-data \
  --listen-client-urls http://127.0.0.1:2379 \
  --advertise-client-urls http://127.0.0.1:2379
```

Verify:
```bash
etcdctl --endpoints=127.0.0.1:2379 endpoint health
```

---

## 4. Patroni node configs

Create three YAML files. They differ only in `name`, the two ports (`restapi`, `postgresql.listen/connect_address`), and `data_dir`.

### `~/patroni-lab/node1.yml`
```yaml
scope: pg_ha
namespace: /service/
name: node1

restapi:
  listen: 127.0.0.1:8008
  connect_address: 127.0.0.1:8008

etcd3:
  host: 127.0.0.1:2379

bootstrap:
  dcs:
    ttl: 30
    loop_wait: 10
    retry_timeout: 10
    maximum_lag_on_failover: 1048576
    postgresql:
      use_pg_rewind: true
      parameters:
        wal_level: replica
        hot_standby: "on"
        max_wal_senders: 10
        max_replication_slots: 10
        wal_log_hints: "on"
  initdb:
    - encoding: UTF8
    - data-checksums
  pg_hba:
    - host replication replicator 127.0.0.1/32 scram-sha-256
    - host all all 127.0.0.1/32 scram-sha-256
  users:
    admin:
      password: admin
      options:
        - createrole
        - createdb

postgresql:
  listen: 127.0.0.1:5432
  connect_address: 127.0.0.1:5432
  data_dir: /Users/befman/patroni-lab/node1/data
  bin_dir: /opt/homebrew/opt/postgresql@16/bin
  authentication:
    replication:
      username: replicator
      password: replicator
    superuser:
      username: postgres
      password: postgres
  parameters:
    unix_socket_directories: /tmp

watchdog:
  mode: off    # macOS has no /dev/watchdog; off for the lab

tags:
  nofailover: false
  noloadbalance: false
  clonefrom: false
  nosync: false
```

### `~/patroni-lab/node2.yml`
Same as node1 with these changes:
```yaml
name: node2
restapi:
  listen: 127.0.0.1:8009
  connect_address: 127.0.0.1:8009
postgresql:
  listen: 127.0.0.1:5433
  connect_address: 127.0.0.1:5433
  data_dir: /Users/befman/patroni-lab/node2/data
```

### `~/patroni-lab/node3.yml`
```yaml
name: node3
restapi:
  listen: 127.0.0.1:8010
  connect_address: 127.0.0.1:8010
postgresql:
  listen: 127.0.0.1:5434
  connect_address: 127.0.0.1:5434
  data_dir: /Users/befman/patroni-lab/node3/data
```

> Keep the rest (scope, etcd3, bootstrap, bin_dir, authentication, watchdog) identical across all three. The `bootstrap` block is only used by the **first** node that initializes the cluster; the others clone from the leader.

---

## 5. Start the three Patroni nodes

Each in its own terminal (with the venv active):

```bash
source ~/patroni-lab/venv/bin/activate
export PATH="/opt/homebrew/opt/postgresql@16/bin:$PATH"

patroni ~/patroni-lab/node1.yml     # terminal A — bootstraps, becomes leader
patroni ~/patroni-lab/node2.yml     # terminal B — clones from leader (replica)
patroni ~/patroni-lab/node3.yml     # terminal C — clones from leader (replica)
```

What happens: node1 runs `initdb`, creates users, becomes **leader** and grabs the etcd leader key. node2/node3 `pg_basebackup` from the leader and come up as streaming **replicas**.

---

## 6. Inspect the cluster

```bash
patronictl -c ~/patroni-lab/node1.yml list
```
```
+ Cluster: pg_ha --------+---------+---------+----+-----------+
| Member | Host           | Role    | State   | TL | Lag in MB |
+--------+----------------+---------+---------+----+-----------+
| node1  | 127.0.0.1:5432 | Leader  | running |  1 |           |
| node2  | 127.0.0.1:5433 | Replica | running |  1 |         0 |
| node3  | 127.0.0.1:5434 | Replica | running |  1 |         0 |
+--------+----------------+---------+---------+----+-----------+
```

Connect to the leader and write something:
```bash
psql "host=127.0.0.1 port=5432 user=postgres dbname=postgres"   # password: postgres
# CREATE TABLE t(id int); INSERT INTO t VALUES (1);
```
Read it on a replica (read-only):
```bash
psql "host=127.0.0.1 port=5433 user=postgres dbname=postgres" -c "SELECT * FROM t;"
```

---

## 7. Test automatic failover

### Unplanned (kill the leader)
In **terminal A**, press `Ctrl-C` (or `kill` the node1 patroni process). Watch:
```bash
watch -n1 'patronictl -c ~/patroni-lab/node1.yml list'
```
Within ~`ttl` seconds, Patroni elects the most caught-up replica as the new **Leader** and bumps the timeline (TL). That's automatic failover + split-brain-safe promotion via the etcd leader key.

### Planned (switchover — no data loss)
```bash
patronictl -c ~/patroni-lab/node1.yml switchover
# pick the target; Patroni demotes the old leader and promotes cleanly
```

### Re-attach the old leader (pg_rewind)
Restart node1:
```bash
patroni ~/patroni-lab/node1.yml
```
Because `use_pg_rewind: true` and `wal_log_hints: on`, Patroni runs **`pg_rewind`** to rewind node1 to the new timeline and rejoin as a **replica** — no full rebuild.

---

## 8. HAProxy — route clients automatically

### What HAProxy is for (and what it is *not*)

HAProxy is a **load balancer / proxy** — the single, stable entry point for the cluster. It is **not** a dashboard (it has a small stats page, but that's a side feature; its real job is routing traffic).

**The problem it solves:** in a Patroni cluster the primary moves around — node1 is primary today, but after a failover it might be node2. Without a proxy, every app would have a connection string pointing at the old primary and would need reconfiguring/restarting on each failover, defeating the point of automatic HA.

```
                        ┌──────────────┐
   app connects to      │   HAProxy    │
   ONE stable address   │  :5000 write │──► whichever node is PRIMARY right now
                        │  :5001 read  │──► whichever nodes are REPLICAS
                        └──────────────┘
```

**How it knows where to send traffic:** HAProxy continuously calls each node's **Patroni REST API** (ports 8008–8010), which it trusts as the source of truth:
- `/primary` returns HTTP 200 **only** on the current leader → the `primary` backend keeps only the leader UP.
- `/replica` returns HTTP 200 **only** on replicas → the `replicas` backend keeps only replicas UP.

So when a failover happens, the `/primary` check moves to the new leader and HAProxy **automatically** sends writes there — no app changes, no restarts. (This is also why you'll see `... is DOWN ... code: 503` warnings on startup: HAProxy is correctly excluding each node from the pool where it doesn't belong — replicas are "DOWN" in the `primary` backend, the leader is "DOWN" in the `replicas` backend. That's healthy, not an error.)

**Two stable endpoints you get:**

| Endpoint | Routes to | Use for |
|----------|-----------|---------|
| `127.0.0.1:5000` | current primary | writes (INSERT/UPDATE/DELETE) |
| `127.0.0.1:5001` | replicas (round-robin) | reads (SELECT), to spread load |

**The stats page** (`http://127.0.0.1:7000/`) is just a monitoring convenience showing UP/DOWN per pool — routing works whether or not you open it.

**Alternatives to HAProxy** (worth knowing): PgBouncer (adds pooling), a floating Virtual IP (VIP) + keepalived, or `libpq` multi-host strings with `target_session_attrs=read-write` (client picks the writable host, no proxy). HAProxy itself is a single point of failure, so production runs **two HAProxy instances** behind a VIP.

### `~/patroni-lab/haproxy.cfg`
```
global
    maxconn 100

defaults
    mode tcp
    retries 2
    timeout client 30m
    timeout connect 4s
    timeout server 30m
    timeout check 5s

listen stats
    mode http
    bind 127.0.0.1:7000
    stats enable
    stats uri /

# Writes -> current primary (Patroni REST /primary returns 200 only on the leader)
listen primary
    bind 127.0.0.1:5000
    option httpchk OPTIONS /primary
    http-check expect status 200
    default-server inter 3s fall 3 rise 2 on-marked-down shutdown-sessions
    server node1 127.0.0.1:5432 maxconn 100 check port 8008
    server node2 127.0.0.1:5433 maxconn 100 check port 8009
    server node3 127.0.0.1:5434 maxconn 100 check port 8010

# Reads -> replicas (/replica returns 200 on replicas)
listen replicas
    bind 127.0.0.1:5001
    option httpchk OPTIONS /replica
    http-check expect status 200
    balance roundrobin
    default-server inter 3s fall 3 rise 2 on-marked-down shutdown-sessions
    server node1 127.0.0.1:5432 maxconn 100 check port 8008
    server node2 127.0.0.1:5433 maxconn 100 check port 8009
    server node3 127.0.0.1:5434 maxconn 100 check port 8010
```

Run it:
```bash
haproxy -f ~/patroni-lab/haproxy.cfg
```

Now apps use **stable endpoints** regardless of who's primary:
```bash
psql "host=127.0.0.1 port=5000 user=postgres dbname=postgres" -c "SELECT pg_is_in_recovery();"  # f (primary)
psql "host=127.0.0.1 port=5001 user=postgres dbname=postgres" -c "SELECT pg_is_in_recovery();"  # t (replica)
```
HAProxy stats dashboard: http://127.0.0.1:7000/. After a failover, HAProxy follows the new primary on `:5000` automatically (because Patroni's `/primary` health check moves).

---

## 9. Useful patronictl commands

```bash
patronictl -c ~/patroni-lab/node1.yml list                 # cluster state
patronictl -c ~/patroni-lab/node1.yml switchover           # planned role swap
patronictl -c ~/patroni-lab/node1.yml failover             # force failover
patronictl -c ~/patroni-lab/node1.yml restart pg_ha node2
patronictl -c ~/patroni-lab/node1.yml reinit  pg_ha node2   # rebuild a replica
patronictl -c ~/patroni-lab/node1.yml edit-config          # change DCS-managed params
patronictl -c ~/patroni-lab/node1.yml pause                # stop automatic failover (maintenance)
patronictl -c ~/patroni-lab/node1.yml resume
```

---

## 10. Teardown / restore your normal setup

```bash
# Stop patroni nodes (Ctrl-C in each terminal), haproxy, etcd
etcdctl --endpoints=127.0.0.1:2379 del --prefix /service/   # clear cluster state
rm -rf ~/patroni-lab/node1/data ~/patroni-lab/node2/data ~/patroni-lab/node3/data ~/patroni-lab/etcd-data

# Bring back your original single-instance lab on 5432
brew services start postgresql@16
```

---

## Troubleshooting (local lab)

| Problem | Fix |
|---------|-----|
| `bin_dir` errors / initdb not found | Confirm `bin_dir: /opt/homebrew/opt/postgresql@16/bin` and that PG16 is installed |
| Port 5432 already in use | `brew services stop postgresql@16` (Patroni needs the port) |
| Node won't join / `pg_rewind` fails | Ensure `wal_log_hints: on` and `use_pg_rewind: true`; `reinit` the replica to rebuild |
| etcd connection refused | Start etcd first; check `etcdctl endpoint health` |
| Replica shows large lag / `start failed` | Check that terminal's Patroni log; `patronictl reinit` to re-clone |
| Watchdog errors | Keep `watchdog: { mode: off }` on macOS |
| Auth failures | Passwords in `authentication:` must match what initdb set; or `reinit` after changing |

---

## Concept mapping

| Concept | Where it shows up here |
|---------|------------------------|
| DCS / consensus / leader key | etcd holds `/service/pg_ha/...`; only key holder is primary |
| Automatic failover | Kill leader → Patroni promotes most caught-up replica |
| Split-brain prevention | etcd leader key + `ttl`; (prod: add watchdog/STONITH) |
| `pg_rewind` re-attach | Old leader rejoins on new timeline without full rebuild |
| Client routing | HAProxy `/primary` & `/replica` health checks |
| Detection vs flapping | `ttl`, `loop_wait`, `retry_timeout` in the `dcs` block |

> **Lab caveat to say out loud:** a single etcd node and `watchdog: off` are fine for learning but not production. Real HA needs an **odd-sized etcd quorum (3/5)** across failure domains and a **watchdog/STONITH** for true fencing.

---

## Summary

> *"I set up Patroni with etcd as the DCS and HAProxy for routing: each Postgres node runs a Patroni agent that registers in etcd, and only the holder of the etcd leader key can be primary. On leader failure Patroni promotes the most caught-up replica, bumps the timeline, and HAProxy follows via the `/primary` REST health check; the old node rejoins with `pg_rewind`. I tune `ttl`/`loop_wait` to balance fast detection against flapping, and in production I'd use a 3- or 5-node etcd quorum plus a watchdog for fencing."*
