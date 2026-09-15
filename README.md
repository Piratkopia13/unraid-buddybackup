# ZFS Buddy Backup

A plugin for Unraid that aims to simplify ZFS snapshot replication: back up to a buddy that is also running Unraid, or replicate to and from any ZFS-enabled system such as TrueNAS SCALE or Proxmox VE.

BuddyBackup supports backing up **to** and **from** any OpenZFS system (TrueNAS SCALE, Proxmox VE, generic Debian/Ubuntu Linux). It sets up authentication and syncs raw encrypted ZFS snapshots. Your backup buddy will not have access to read any of your backed-up data, and can not access your server for anything other than sending and receiving their backups.

Backups are offsite-ready ZFS snapshot replications: raw sends (`zfs send -w`) keep your data encrypted end to end, the remote end never gets a shell, and the SSH user is restricted to an allowlist of the exact commands replication needs.

This plugin is fully open source, and I encourage you to review the source to ensure you understand how it operates and verify its security.

### [User guide here](https://forums.unraid.net/topic/186256-zfs-buddybackup-plugin-guide/)

### Compatibility

- **Unraid → Unraid**: the classic buddy setup (push backups to a buddy, restore back).
- **Unraid → TrueNAS SCALE / Proxmox VE / generic Linux (OpenZFS 2.2+)**: push backups to any ZFS-enabled host. A one-time setup command (generated on the plugin's *Generic ZFS hosts* page) configures the remote host with a restricted user, a forced-command allowlist scoped to the configured dataset tree and the minimal `zfs allow` delegations.
- **TrueNAS SCALE / Proxmox VE / generic Linux → Unraid**: push backups directly to Unraid from TrueNAS SCALE (via native GUI Replication Tasks) or Proxmox/Debian (via Sanoid/Syncoid). Unraid receives backups with an immutable allowlist that strictly rejects destructive commands like `zfs destroy`, keeping backups safe against ransomware.

### Generic ZFS hosts

- **Pushing from Unraid to a generic host**: The plugin's *Generic ZFS hosts* page provides a one-time setup command (`generic_host_setup.sh`) to run as root on the remote host (TrueNAS SCALE, Proxmox VE, Debian/Ubuntu). This script creates a dedicated restricted SSH user, installs a fine-grained forced-command allowlist scoped strictly to the configured parent dataset, grants minimal `zfs allow` delegations (`create,mount,receive` and raw `send`), and ensures received datasets are never mounted on the remote host (`mountpoint=none`).
- **Replicating from TrueNAS SCALE or Proxmox VE to Unraid**: Generic hosts replicate directly into Unraid's buddy SSH user:
  - **TrueNAS SCALE**: In TrueNAS, create a Replication Task pointing to Unraid with **Snapshot Retention Policy = None** (since Unraid's allowlist protects backups by strictly denying `zfs destroy`). Set snapshot naming schema to Sanoid format (`autosnap_%Y-%m-%d_%H:%M:%S_daily`) so Unraid manages retention automatically with Sanoid.
  - **Proxmox VE / Generic Linux**: Run Sanoid/Syncoid on the remote host pushing to Unraid.

### Testing lab bootstrap

Initial reproducible test-lab scaffolding is in `testlab/`; see `testlab/README.md` for the test catalog, default matrix behavior, and scenario coverage.

![Logo](src/usr/local/emhttp/plugins/buddybackup/images/buddybackup.png)

---

Total downloads

![GitHub all releases](https://img.shields.io/github/downloads/Piratkopia13/unraid-buddybackup/total)

Latest release

![GitHub release (latest by date)](https://img.shields.io/github/v/release/Piratkopia13/unraid-buddybackup)
![GitHub release (latest by date)](https://img.shields.io/github/downloads/Piratkopia13/unraid-buddybackup/latest/total)
