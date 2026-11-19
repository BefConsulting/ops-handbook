# Postgres Encryption at Rest

The options for encrypting the OpenStack Cinder volumes behind our Postgres clusters, their trade-offs, and a recommendation.

> **Note:** Site, cluster, host, project and repository names in this document are generic placeholders (`site-a`, `db-a`, `<db-repo>`, and so on). Sizes and timings come from a real environment and are kept as a sizing reference.

## Summary

- Security has asked for encryption at rest on the Postgres data volumes. Today they are **not encrypted**: every volume uses the default Cinder type `NVMe_SSD` and reports `encrypted = False`.
- There are three places encryption can happen: the **storage backend** (layer 1), **OpenStack Cinder, on the hypervisor** (layer 2), or **inside the VM with LUKS** (layer 3).
- **Recommendation: layer 2**, an encrypted Cinder volume type with keys in Barbican. Barbican is already available in `site-a`. It needs **no changes inside the VMs**: Salt, cloud-init, mount points and monitoring all stay as they are.
- **Every option needs the data copied** to new volumes, because no layer can encrypt a volume in place without long downtime. We do the copy as a rolling replica rebuild, about 72 TB in `site-a` prod alone.
- Choose layer 3 only if security requires that **cloud operators cannot read the data**. It conflicts with our Salt volume states and monitoring filters, so it needs significant engineering (see [section 7](#7-challenges-with-layer-3-in-our-environment)).

## Contents

1. [Our environment](#1-our-environment)
2. [The three layers](#2-the-three-layers)
3. [Side-by-side comparison](#3-side-by-side-comparison)
4. [Pros and cons](#4-pros-and-cons)
5. [Migration (needed for every layer)](#5-migration-needed-for-every-layer)
6. [Database sizes and time estimates](#6-database-sizes-and-time-estimates)
7. [Challenges with layer 3](#7-challenges-with-layer-3-in-our-environment)
8. [Review of another team's LUKS procedure](#8-review-of-another-teams-luks-procedure)
9. [Recommended plan and open questions](#9-recommended-plan-and-open-questions)
10. [Appendix: commands](#10-appendix-commands)

---

## 1. Our environment

| Item | Current state |
|---|---|
| OpenStack sites | **site-a** (`openstack.site-a.example.com`, region `RegionOne`) and **site-b** (`openstack.site-b.example.com`, regions `site-b1`/`site-b2`) |
| Volume types (site-a) | Only `NVMe_SSD`, the default. It has no encryption, as volumes report `encrypted = False` |
| Barbican (key manager) | **Available in site-a**: it's in the service catalog and `openstack secret list` works for our project. site-b2 still to be checked |
| Who creates volumes | Terraform (Atlantis). `openstack_blockstorage_volume_v3` in the `<db-repo>` modules `postgres-primary` and `postgres-standby`, one data volume per VM, with **no `volume_type` set** (so the cloud default is used) |
| site-a prod volume total | About **72 TB** across 26 volumes. Largest is **8.75 TB** (`db-a`). See [section 6](#6-database-sizes-and-time-estimates) |

### Two Postgres setups, which matter for the migration

**A. Streaming replication (`<db-repo>`)**

- Separate `*-primary-01` / `*-standby-01` VMs. Salt decides the role from the **hostname** (`'primary' in host`), and `primary_ip` is hard-coded in pillar.
- Salt highstate runs **every 10 minutes**. A standby is (re)built by `pg_basebackup` when `/tmp/firstrun` exists.
- **cloud-init** formats `/dev/vdb` as XFS and mounts it at `/data`. Salt never touches the disk.
- Clients connect through an **Octavia LB** whose only member is the primary (TCP health check).
- **Cascaded replication** in site-b2 (`db-a`, `db-d`): a manual state (`postgres.cascading-replication`, PG13) builds a downstream replica with slot `cascade_1`.
- `db-c` has **no standby**.

**B. Patroni + Consul (`<salt-repo>`)**

- Clusters: `patroni-a`, `patroni-b`, `patroni-c`, `patroni-d`, `patroni-e` (site-b).
- Patroni manages automatic failover. Clients use the Consul endpoints `<cluster>-primary.service.consul`, so a switchover needs **no LB or DNS changes**.
- **Salt formats and mounts the disks on every highstate** (`state/postgres/volume.sls`): `blockdev.formatted` and `mount.mounted` on the raw devices from the `attached_volumes` grain, giving `/pg_data` and an optional `/pg_wal`.
- Separate data and WAL volumes, so **two volumes per node** need encrypting.

---

## 2. The three layers

Each layer encrypts at a different point between Postgres and the physical disk. The difference that matters is **where data is still in plaintext** and **who holds the keys**.

Legend: `plain` = plaintext at this point, `cipher` = encrypted at this point, 🔒 = where encryption/decryption happens.

| Tier (top to bottom) | Layer 1: Storage backend | Layer 2: Cinder encrypted volume type | Layer 3: LUKS inside the VM |
|---|---|---|---|
| VM / Postgres | `plain`: sees `/dev/vdb` | `plain`: sees an ordinary `/dev/vdb`, unaware of encryption | 🔒 `/dev/vdb` → LUKS → `/dev/mapper/pgdata` → `/data` |
| Compute host (hypervisor) | `plain`: passes data through | 🔒 Nova / os-brick LUKS encrypts and decrypts here | `cipher` |
| Storage network | `plain` | `cipher` | `cipher` |
| Storage cluster (Ceph / array) | `plain`: Ceph daemons see plaintext | `cipher`: only ever sees ciphertext | `cipher` |
| Physical disks | 🔒 dm-crypt OSDs or self-encrypting drives | `cipher` | `cipher` |
| **Keys held by** | Storage system / KMS (cloud team) | Barbican, one per volume, fetched on attach | Us (OpenBao / Clevis-Tang) |

**Layers 2 and 3 both use LUKS / dm-crypt.** The only differences are *where* it runs (the hypervisor or the VM) and *who owns the keys* (Barbican or us). Layer 1 is the storage team's responsibility and can't be seen from inside the VM.

### What LUKS is

- LUKS (Linux Unified Key Setup) is the standard Linux disk-encryption format, built on the kernel's `dm-crypt`. Data is encrypted with AES-XTS using a random **master key**.
- The master key is stored only in wrapped form, in **keyslots** (8 in LUKS1, 32 in LUKS2). Each keyslot is unlocked by a passphrase or keyfile. Unlock keys can be added or revoked without re-encrypting the data. Rotating the master key does require re-encryption.
- The overhead with AES-NI (present on modern CPUs) is typically a few percent of I/O throughput.

---

## 3. Side-by-side comparison

| | Layer 1: Storage | Layer 2: Cinder + Barbican | Layer 3: LUKS in the VM |
|---|---|---|---|
| Where encryption happens | Storage disks | Hypervisor | Inside the VM |
| Who controls the keys | Storage / cloud team | Cloud team (Barbican) | **Us** (OpenBao) |
| Stolen or decommissioned disks | ✅ Protected | ✅ Protected | ✅ Protected |
| Storage admin or raw Ceph access | ❌ Not protected | ✅ Protected | ✅ Protected |
| Data on the storage network | ❌ Plaintext | ✅ Encrypted | ✅ Encrypted |
| Cloud / hypervisor operators | ❌ Can read | ❌ Can read | ⚠️ Can't read disks (memory dumps still possible) |
| Changes inside the VM | None | **None** | LUKS Salt state, crypttab, boot unlock, monitoring fixes |
| Salt / cloud-init | Unchanged | Unchanged | ❌ Conflicts with existing states (see section 7) |
| Mount points and device names | Unchanged | Unchanged (`/dev/vdb` → `/data`) | Mount point can stay; device becomes `/dev/mapper/*` |
| Monitoring | Unchanged | Unchanged | ❌ Vector filter `/dev/vd*` drops `/data`; Datadog device tags change |
| CPU cost | Storage system | Hypervisor | The VM's own vCPUs |
| Extending a volume | Unchanged | Cinder extend (online support depends on the release, so to be confirmed) | Cinder extend + `cryptsetup resize` + `xfs_growfs` |
| What can stop the DB from starting | Storage | Barbican unavailable when a volume is attached | OpenBao unavailable at boot, or a crypttab mistake |
| Data copy needed | No, if already enabled | ⚠️ Yes, onto new volumes | ⚠️ Yes, onto new volumes |
| Who does the work | Cloud / storage team | Cloud team creates the type; we change Terraform and run the migration | Us: Salt, Terraform, OpenBao, runbooks, migration |

---

## 4. Pros and cons

### Layer 1: Storage-backend encryption

**Pros**
- ✔ May **already be in place**. If so, we only need a written statement from the storage team.
- ✔ No work, migration or performance impact for us.
- ✔ Covers every volume, root disks included.

**Cons**
- ✘ Only protects against stolen or decommissioned physical disks.
- ✘ Ceph and storage admins, and anything with raw access to the storage, see plaintext.
- ✘ Can't be verified from our side, so we rely on the cloud team's statement.
- ✘ May not satisfy a stricter interpretation of "encryption at rest".

### Layer 2: Cinder encrypted volume type (recommended)

**Pros**
- ✔ **Nothing changes inside the VM.** Salt `volume.sls`, cloud-init `mkfs`, `/data` and `/pg_data`, and Vector, Datadog and Alloy all keep working.
- ✔ Keys are managed per volume by Barbican, **separately from the storage**. Snapshots and backups stay encrypted, and deleting a volume deletes its key.
- ✔ Data is encrypted on the storage network as well.
- ✔ Terraform change is small: an optional `volume_type`, applied one node at a time.
- ✔ Verifiable: `openstack volume show` reports `encrypted = True`, which gives auditors evidence.
- ✔ Barbican already works in site-a.

**Cons**
- ✘ Cloud and hypervisor operators can still read the data.
- ✘ Depends on the cloud team: they create the type (admin only), and we rely on their Barbican's availability, backups and master-key protection. **Losing a Barbican key means losing that volume's data.**
- ✘ Online extend of encrypted volumes may not be supported on the current OpenStack release.
- ✘ Changing `volume_type` forces Terraform to replace the volume, so it has to be done per node and planned carefully.
- ✘ Root disks are ephemeral, not Cinder volumes, so they aren't covered.

### Layer 3: LUKS inside the VM

**Pros**
- ✔ Strongest separation: **we own the keys**, and the cloud and storage only ever see ciphertext.
- ✔ Independent of OpenStack features, so it works on any cloud or on Proxmox.
- ✔ Fits our existing OpenBao.

**Cons**
- ✘ **Conflicts with the Patroni Salt `volume.sls`**, which formats and mounts raw devices on every highstate (see section 7).
- ✘ cloud-init in the `<db-repo>` Terraform formats `/dev/vdb` on first boot, which conflicts with LUKS.
- ✘ Needs a reliable boot-time unlock. Postgres won't start if OpenBao is down.
- ✘ Monitoring filters need updating, otherwise `/data` disk-full alerts stop silently.
- ✘ Ongoing work: key rotation, recovery keys, runbooks, and two LUKS devices per Patroni node.
- ✘ Encryption uses the VM's own vCPUs.
- ✘ If the key is stored on the root disk for convenience, the protection is **weaker than layer 2**.

---

## 5. Migration (needed for every layer)

> ⚠️ **No layer encrypts existing data in place without downtime.**
> `openstack volume retype` to an encrypted type does a full block copy with the volume *detached*. `cryptsetup reencrypt` needs the filesystem unmounted. On a multi-TB volume, both mean hours of downtime and a risk if interrupted.
> So for every layer we **create new encrypted volumes and copy the data** with a rolling replica rebuild (`pg_basebackup`). The database work is the same for layers 2 and 3; only the setup inside the VM differs.

### General rolling rebuild (per cluster)

1. **Standby:** stop Postgres, unmount, replace the volume with an encrypted one (Terraform).
2. **Re-sync:** `pg_basebackup` from the primary. About 10 h for 8.75 TB.
3. **Switchover** *(downtime: minutes)*: promote the encrypted standby; clients follow.
4. **Old primary:** replace its volume and rebuild it as a replica.
5. **Clean up:** delete the old volumes and snapshots, and verify `encrypted = True`.

### A. Patroni clusters (`<salt-repo>`): the simplest

1. On a replica: `systemctl stop patroni`, `umount /pg_data /pg_wal`.
2. Terraform: set `volume_type` on that node's data and WAL volumes; apply.
3. Highstate: `volume.sls` formats and mounts the new blank volumes (layer 2 only).
4. Start Patroni. It re-clones from the leader (or run `patronictl reinit`).
5. *(Downtime: minutes)* `patronictl switchover`. Consul endpoints follow automatically, then repeat on the old leader.

- No LB or DNS changes, and no hostname-based roles. One switchover per cluster.
- **Watch WAL retention:** while a replica rebuilds, its replication slot on the leader holds back WAL. On large clusters, check the leader's `/pg_wal` space, or check whether `max_slot_wal_keep_size` is set.

### B. Streaming-replication clusters (`<db-repo>`): needs care

1. **Standby:** `salt-call schedule.disable`, stop PG, `umount /data`.
2. tfvars PR: `volume_type` on `prod-X-standby`. The plan must show only that node's volume and attachment.
3. `/home/debian/mount.sh` (mkfs + mount), `touch /tmp/firstrun`, highstate → `pg_basebackup`.
4. **Switchover #1** *(downtime)*: pause Salt on both hosts, promote the standby, swap the LB member.
5. **Primary:** targeted plan for its volume, `mount.sh`, manual `pg_basebackup -R` from the standby.
6. **Switchover #2** *(downtime)*: promote `primary-01` again, `standby.signal` on the standby, restore the LB, re-enable Salt.

- **Two switchovers are needed** because Salt decides the role from the hostname and `primary_ip` is in pillar. Leaving `standby-01` as the primary would make Salt misconfigure both hosts.
- **Pause the 10-minute highstate schedule** while roles are swapped.
- **The LB member is managed by Terraform**, so use `-target` plans for the volume during the window. Otherwise Terraform will undo the manual LB change.
- **cloud-init doesn't re-run** on an existing VM, so the new volume has to be formatted with the existing `/home/debian/mount.sh`.
- **`db-c` has no standby:** first add a `prod-db-c-standby` entry with the encrypted type. It builds itself via cloud-init and `/tmp/firstrun`. Then do the primary.

### C. Cascaded replicas (site-b2 `db-a` / `db-d`)

1. **Leaf first:** rebuild the downstream replica on an encrypted volume.
2. **Slot:** drop the old `cascade_1` on the upstream before re-running the state (`-C -S cascade_1` fails if the slot exists).
3. **Middle tier:** rebuild the upstream node. The leaf loses its source, so it has to be re-pointed or re-cloned.
4. **Top** *(downtime)*: primary via a switchover, as in B.

- **Order matters:** rebuilding a middle node breaks everything downstream of it. Rebuild from the bottom up, and plan for the leaf to need a second resync.
- **Slot WAL retention:** while the leaf is offline (hours), slot `cascade_1` makes the upstream keep WAL and fill `/data`. Drop the slot during the rebuild or monitor closely.
- The cascading state is **manual and hard-coded to PG13** (`postgresql@13-main`). Check the PG version on these hosts before re-running it.
- If any hop crosses data centres (site-a → site-b2), `pg_basebackup` runs over the WAN and takes much longer.

---

## 6. Database sizes and time estimates

Data volumes in **site-a prod** (from `openstack volume list`). Copy time assumes about 250 MB/s for `pg_basebackup`, so it's a rough estimate; measure on the pilot. Every cluster needs **two** copies, one for the standby and one for the old primary. site-b2 and the Patroni clusters still need to be listed.

| Cluster | Primary (GB) | Standby (GB) | Est. copy per node | Notes |
|---|---:|---:|---:|---|
| db-a | 8,650 | 8,750 | ~10 h | Largest. Also a 500 GB WAL volume |
| db-b | 7,400 | 7,400 | ~8 h | Also a 2,500 GB WAL volume |
| db-c | 6,950 | – | ~8 h | **No standby**: add one first |
| db-d | 6,000 | 6,000 | ~7 h | Also a 500 GB WAL volume |
| db-e | 4,350 | 4,350 | ~5 h | Also a 1,021 GB WAL volume |
| db-f | 320 | 320 | ~20 min | |
| db-g | 35 | 35 | minutes | Pilot candidate |
| db-h | 15 | 15 | minutes | Pilot candidate |
| db-i | 10 | 10 | minutes | **First pilot** |
| **Postgres data total** | **~60.6 TB** (both columns) | | | |

| Other volumes | Size | Approach |
|---|---:|---|
| WAL volumes (`*-for-pg-wal`, 4 volumes) | ~4.5 TB | Not in the postgres modules: find where they're defined, then new encrypted volume + copy |
| `backup-01` (pgBackRest repository) | 6.8 TB | New encrypted repo + fresh full backup, keeping the old one until retention expires (or rsync, which is safe here because these are static files) |
| syslog, saltmaster, misc | ~0.2 TB | Swap the volume during a quiet period |
| **Grand total (site-a prod)** | **~72 TB** | |

> ⚠️ **Quota:** rebuilding a standby next to the old one (to keep HA) temporarily needs extra Cinder quota equal to that node's size, up to about 9 TB if clusters are done one at a time. Check with `openstack limits show --absolute` (`maxTotalVolumeGigabytes` against `totalGigabytesUsed`). Replacing a volume in place needs no extra quota, but the primary has no standby during the copy.

---

## 7. Challenges with layer 3 in our environment

> ❌ **Biggest risk: Patroni `volume.sls`.** On every highstate, Salt runs `blockdev.formatted` (XFS) and `mount.mounted` on `grains['attached_volumes'][0]` / `[1]`, which are the **raw** `/dev/vdb` / `/dev/vdc`.
> Once the raw device holds a LUKS header, Salt sees the filesystem type `crypto_LUKS` instead of `xfs`. It will try to reformat (failing, or wiping the volume if forced) and to mount the raw device.
> The state has to be rewritten to work on `/dev/mapper/*` before any Patroni node gets layer 3.

| Area | Problem | Work needed |
|---|---|---|
| **Salt: Patroni** (`<salt-repo>/state/postgres/volume.sls`) | Formats and mounts raw devices on every highstate. Conflicts with LUKS and risks data loss | New LUKS-aware state: open → format the mapper device → mount. Order it before `postgres_install` and the Patroni service |
| **cloud-init** (`<db-repo>` `config.tmpl`) | `fs_setup` and `mount.sh` run `mkfs.xfs` directly on `/dev/vdb` on a new VM's first boot | Change the Terraform template so new VMs leave `/dev/vdb` for LUKS |
| **Boot-time unlock** | Nothing does this today. The disk has to be unlocked before Postgres or Patroni starts, without anyone at the console | systemd unit or Salt state that fetches the key from OpenBao (AppRole), plus crypttab. Or Clevis+Tang, which means running HA Tang servers |
| **Unlock failure + `nofail`** | The VM boots without `/data`. The highstate 10 minutes later creates `/data/postgresql/...` on the root disk, and Postgres may start against an empty directory | Make the states check first (`unless: mountpoint -q /data`) and make Postgres and Patroni require the mount |
| **Monitoring: Vector** (`vector.toml.j2`) | `filesystem.devices.includes = ["/dev/vd*"]` drops `/dev/mapper/*`, so **`/data` disk-usage alerts silently stop** | Add `/dev/mapper/*` |
| **Monitoring: Datadog** (primary hosts) | `use_mount: false` tags metrics by device, so the tag changes from `/dev/vdb` to `/dev/mapper/...` | Update the monitors, or set `use_mount: true` |
| **Monitoring: Grafana Alloy / Agent** | The mapper device is collected, but the `device` label changes | Check dashboards and alerts that filter on the device |
| **Key management** | Per-volume keys for about 30+ volumes and two sites, plus recovery keys, rotation and access control | OpenBao paths and policies per host, an escrow passphrase in a second keyslot, and a rotation runbook |
| **Dependency on OpenBao** | If OpenBao is unreachable at boot, the database doesn't start | OpenBao HA, a cached-key strategy or break-glass procedure, and DR testing |
| **Patroni WAL volume** | Two LUKS devices per node (`/pg_data` and `/pg_wal`), and `move_pg_wal.sh` assumes a plain mount | Extend the state and the script |
| **Resizing** | Volumes grow regularly (e.g. `db-a` at 8,650 vs 8,750 GB) | Every extend becomes `cryptsetup resize` followed by `xfs_growfs`; update the runbooks |
| **Performance** | AES runs on the VM's vCPUs, competing with Postgres | Benchmark on the pilot (check `grep -c aes /proc/cpuinfo`) |

---

## 8. Review of another team's LUKS procedure

Another team's runbook (*Postgres: Encryption at Rest*, internal wiki) uses **layer 3**. It's workable for a 600 GB database, but it shouldn't be copied as-is for our clusters:

- **Keyfile on the root disk** (`/etc/data_keytab`) for automatic unlock. The root disk is on the same unencrypted storage, so anyone who can read the storage gets the key with the data. In practice this is **weaker than layer 2**.
- **rsync of a live data directory:** the default size and modification-time check can miss files changed within the same second, giving **silent corruption**. A safe final pass needs `--checksum`, which takes hours on 8 TB. At `--bwlimit=30m`, one pass over 8.75 TB takes about 3.4 days. Use `pg_basebackup` instead.
- **Primary done in place** during a maintenance window. With a replica available, a switchover avoids that downtime.
- **`shred` on the raw volume** forces Ceph to allocate the full volume (about 72 TB) and causes days of I/O on shared storage. It doesn't protect against side-channel attacks either. Skip it, or write zeros through the opened LUKS device instead.
- **Key handling:** the same passphrase and keyfile on both servers, keys kept in both a secrets vault and a password manager, the keyfile deleted with `rm` (which doesn't erase it), no rotation procedure, and no `/etc/crypttab` step (so a mistake leaves the VM hanging at boot).
- Manual and not in Salt or Terraform, so rebuilds won't reproduce it.

---

## 9. Recommended plan and open questions

### Questions to resolve first

| For | Question | Why it matters |
|---|---|---|
| Security team | Is "encrypted on the storage, keys held by the cloud platform" enough, or must **cloud operators be unable to read the data**? | Decides between layer 2 and layer 3 |
| Cloud / storage team | Is the `NVMe_SSD` backend already encrypted at rest (dm-crypt OSDs or self-encrypting drives)? | Layer 1 might already exist, or provide extra protection |
| Cloud team | Can you create an encrypted volume type (LUKS, `aes-xts-plain64`, 256-bit, front-end) in site-a and site-b2? | Required for layer 2 |
| Cloud team | Does **online extend** of encrypted volumes work on our release? | We rely on `enable_online_resize` |
| Cloud team | How is Barbican backed up, and how is its master key protected? Are ephemeral root disks encrypted? | Losing a key means losing the data. The answer also tells us whether root disks are covered |

### Rollout (layer 2)

1. **Cloud team:** creates `NVMe_SSD_LUKS` (name is our suggestion; the cloud team picks it).
2. **Validate:** 1 GB test volume: `encrypted = True`, attach, extend.
3. **Terraform PR:** optional `volume_type` in the modules. The plan must show **no changes**.
4. **Pilot:** `db-i`, then `db-h` and `db-g`, plus one small Patroni cluster.
5. **Large clusters:** `db-e` → `db-d` → `db-b` → `db-a` → `db-c`, one at a time, each after a verified backup.
6. **The rest:** WAL, `backup-01`, syslog, then site-b2 including the cascades.
7. **Evidence:** delete old volumes and snapshots; report `encrypted = True` for every volume.

### Terraform change (`<db-repo>`)

```diff
# modules/postgres-standby/variables.tf  (same for postgres-primary)
    volume_region     = string
    security_groups   = list(string)
+   volume_type       = optional(string)      # null = cloud default (NVMe_SSD)

# modules/postgres-standby/main.tf  (same for postgres-primary)
+     volume_type       = db.volume_type        # in locals.servers_list
  resource "openstack_blockstorage_volume_v3" "data_volume" {
    ...
+   volume_type          = each.value.volume_type
  }

# tfvars: opt in one node at a time (forces replacement of THAT volume only)
  prod-db-i-standby = {
    ...
+   volume_type = "NVMe_SSD_LUKS"
  }
```

---

## 10. Appendix: commands

### Cloud team (admin): create the encrypted type

```bash
openstack volume type show NVMe_SSD -c properties     # copy volume_backend_name
openstack volume type create NVMe_SSD_LUKS \
  --description "NVMe SSD, LUKS encrypted (Barbican)" \
  --property volume_backend_name=<same as NVMe_SSD> \
  --encryption-provider luks \
  --encryption-cipher aes-xts-plain64 \
  --encryption-key-size 256 \
  --encryption-control-location front-end
```

### Validate (non-admin)

```bash
openstack volume create --type NVMe_SSD_LUKS --size 1 luks-test
openstack volume show luks-test -c encrypted -c volume_type   # encrypted = True
openstack secret list                                         # Cinder's key appears here
openstack server add volume <maint-vm> luks-test              # mkfs, mount, write a file
openstack --os-volume-api-version 3.42 volume set --size 2 luks-test   # online extend test
openstack server remove volume <maint-vm> luks-test
openstack volume delete luks-test
```

### Evidence for the security team

```bash
for v in $(openstack volume list -f value -c ID); do
  openstack volume show "$v" -f value -c name -c encrypted -c volume_type | paste - - -
done
# every line should end in: True  NVMe_SSD_LUKS
```

---

*Sources: `openstack` CLI output (site-a prod project), the streaming-replication repo (Terraform modules, cloud-init `config.tmpl`, Salt `postgres`/`vector`/`datadog` states), the Patroni Salt repo (`state/postgres/volume.sls`, Patroni README, `_grains/openstack.py`), and another team's encryption runbook. Time estimates are approximate; measure on the pilot.*
