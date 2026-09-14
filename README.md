# ZFS Buddy Backup

A plugin for Unraid that aims to simplify ZFS snapshot replication: back up to a buddy that is also running Unraid, or to any ZFS-enabled system such as TrueNAS SCALE or Proxmox VE — and pull backups from those hosts too.

BuddyBackup supports backing up **to** and **from** any OpenZFS system (TrueNAS SCALE, Proxmox VE, generic Debian/Ubuntu Linux). It sets up authentication and syncs raw encrypted ZFS snapshots. Your backup buddy will not have access to read any of your backed-up data, and can not access your server for anything other than sending and receiving their backups.

Backups are offsite-ready ZFS snapshot replications: raw sends (`zfs send -w`) keep your data encrypted end to end, the remote end never gets a shell, and the SSH user is restricted to an allowlist of the exact commands replication needs.

This plugin is fully open source, and I encourage you to review the source to ensure you understand how it operates and verify its security.

### [User guide here](https://forums.unraid.net/topic/186256-zfs-buddybackup-plugin-guide/)

### Compatibility

- **Unraid → Unraid**: the classic buddy setup (push backups to a buddy, restore back).
- **Unraid → TrueNAS SCALE / Proxmox VE / generic Linux (OpenZFS 2.2+)**: push backups to any ZFS-enabled host. A one-time setup command (generated on the plugin's *Generic ZFS hosts* page) configures the remote host with a restricted user, a forced-command allowlist scoped to the configured dataset tree and the minimal `zfs allow` delegations.
- **TrueNAS SCALE / Proxmox VE / generic Linux → Unraid**: pull backups on a cron schedule from any OpenZFS host (OpenZFS 2.4+ hosts can be locked down further so Unraid can only ever request raw encrypted streams).

### Pull backups and snapshot pruning

Pulled snapshots arrive on your Unraid server with the **source host's** snapshot names, and no
pruning is configured for pull destinations by default. Two things are needed for old pulled
snapshots to be cleaned up:

- **Enable pruning for the destination dataset**: add the local destination dataset on the
  *Snapshot creation and pruning* page with *Prune snapshots automatically* = **Yes** plus the
  desired retention (*Create snapshots automatically* is optional). Set *Recursive* = **Yes** if the
  backup entry pulls recursively. Without this entry, pulled snapshots accumulate forever.
- **The source snapshots must use the sanoid naming convention**: only snapshots whose names start
  with `autosnap` and end with `_hourly` / `_daily` / `_weekly` / `_monthly` / `_yearly` are
  recognized and pruned on Unraid. Sources running sanoid natively match. For TrueNAS SCALE, the
  default periodic snapshot task naming schema (`auto-%Y-%m-%d_%H-%M`) does **not** match and those
  snapshots are replicated but **never pruned** — set each task's Naming Schema to a
  sanoid-compatible pattern matching its schedule instead (for example `autosnap_%Y-%m-%d_%H:%M:%S_hourly`
  for an hourly task, `..._daily` for a daily task; TrueNAS requires `%Y`, `%m`, `%d`, `%H` and `%M`
  in the schema). Snapshots created by other tools are also replicated but never pruned, notably:
  - **Proxmox VE's default `zfs-auto-snapshot` cron** (names like `zfs-auto-snap_hourly-2026-01-01_1200`).
    Run [sanoid](https://github.com/jimsalterjrs/sanoid) on the Proxmox host instead if you want
    Unraid-side pruning.
  - TrueNAS **"frequently"** (sub-hourly) snapshot tasks: the plugin's retention fields cover hourly
    and above only, so those snapshots are not pruned.

  Note that the source's own pruning (e.g. TrueNAS Snapshot Lifetime) only removes snapshots on the
  source — pulled copies on Unraid keep accumulating until they are pruned there.

### Restoring pulled backups

For pull backups the *Restore* button is labeled **Restore pulled data to a local dataset**, and that
is exactly what it does: pulled snapshots are stored in the entry's local destination dataset, and the
restore wizard materializes snapshots from there into another — or brand new — local dataset on your
Unraid server. The whole operation is local: Unraid never connects to the pull source, and it could
not write there anyway. The pull source user only holds `send` (raw-only on OpenZFS 2.4+) and `hold`
delegations, so the credential that reads the backup is physically unable to modify the source. This
is deliberate: malware on your Unraid server must not be able to destroy the original data the backup
protects, on either side of the connection.

Snapshot objects are not browsable, so this local restore is also the first step of every recovery:
it turns the pulled snapshot history into a dataset you can read over SMB/NFS.

#### Putting pulled data back on the source host

If the source host (e.g. a TrueNAS box) loses its data, you have two ways to get it back — neither
of which requires giving your pull entry write access to the source:

- **File-level copy back**: restore to a local dataset (above), then copy the files back over
  SMB/NFS/rsync using normal user credentials. Simplest option, but not ZFS-native and does not
  recreate snapshot history.
- **Dual-role setup (ZFS-native)**: run the *Generic ZFS hosts* setup on the source host a second
  time with the **receiver** role and a dedicated restore parent dataset, then add a normal push
  backup entry (type *Remote (generic ZFS host)*) with the pull destination dataset as its source.
  The pulled snapshots kept their original names, so syncoid will resume from the newest common
  snapshot — or send a full stream from the oldest if the source was wiped. This stays within the
  security model: the receiver role grants only `create,mount,receive` (never `destroy`, `rollback`
  or `snapshot`), so a compromised Unraid server can at worst create junk datasets on the source
  host, not destroy the original data. Keep the restore parent dataset in a separate subtree from
  the original data.

  Note: if the source dataset was unencrypted, the pulled copy is unencrypted too, and the push
  entry will refuse to list it as a source unless *Allow unencrypted remote backups* is enabled in
  the plugin settings.

### Testing lab bootstrap

Initial reproducible test-lab scaffolding is in `testlab/`; see `testlab/README.md` for the test catalog, default matrix behavior, and scenario coverage.

![Logo](src/usr/local/emhttp/plugins/buddybackup/images/buddybackup.png)

---

Total downloads

![GitHub all releases](https://img.shields.io/github/downloads/Piratkopia13/unraid-buddybackup/total)

Latest release

![GitHub release (latest by date)](https://img.shields.io/github/v/release/Piratkopia13/unraid-buddybackup)
![GitHub release (latest by date)](https://img.shields.io/github/downloads/Piratkopia13/unraid-buddybackup/latest/total)
