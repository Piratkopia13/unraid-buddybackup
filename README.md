# ZFS Buddy Backup

A plugin for Unraid that aims to simplify ZFS snapshot replication: back up to a buddy that is also running Unraid, or to any ZFS-enabled system such as TrueNAS SCALE or Proxmox VE — and pull backups from those hosts too.

BuddyBackup supports backing up **to** and **from** any OpenZFS system (TrueNAS SCALE, Proxmox VE, generic Debian/Ubuntu Linux). It sets up authentication and syncs raw encrypted ZFS snapshots. Your backup buddy will not have access to read any of your backed-up data, and can not access your server for anything other than sending and receiving their backups.

Backups are offsite-ready ZFS snapshot replications: raw sends (`zfs send -w`) keep your data encrypted end to end, the remote end never gets a shell, and the SSH user is restricted to an allowlist of the exact commands replication needs.

This plugin is fully open source, and I encourage you to review the source to ensure you understand how it operates and verify its security.

### [User guide here](https://forums.unraid.net/topic/186256-zfs-buddybackup-plugin-guide/)

### Compatibility

- **Unraid → Unraid**: the classic buddy setup (push backups to a buddy, restore back).
- **Unraid → TrueNAS SCALE / Proxmox VE / generic Linux (OpenZFS 2.2+)**: push backups to any ZFS-enabled host. A one-time setup command (generated on the plugin's *Generic ZFS hosts* page) configures the remote host with a restricted user, a forced-command allowlist and the minimal `zfs allow` delegations.
- **TrueNAS SCALE / Proxmox VE / generic Linux → Unraid**: pull backups on a cron schedule from any OpenZFS host (OpenZFS 2.4+ hosts can be locked down further so Unraid can only ever request raw encrypted streams).

### Testing lab bootstrap

Initial reproducible test-lab scaffolding is in `testlab/`; see `testlab/README.md` for the test catalog, default matrix behavior, and scenario coverage.

![Logo](src/usr/local/emhttp/plugins/buddybackup/images/buddybackup.png)

---

Total downloads

![GitHub all releases](https://img.shields.io/github/downloads/Piratkopia13/unraid-buddybackup/total)

Latest release

![GitHub release (latest by date)](https://img.shields.io/github/v/release/Piratkopia13/unraid-buddybackup)
![GitHub release (latest by date)](https://img.shields.io/github/downloads/Piratkopia13/unraid-buddybackup/latest/total)
