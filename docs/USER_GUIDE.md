# ZFS BuddyBackup — Comprehensive Plugin & User Guide

> **Official Forum Guide Thread**: [Unraid Community Forums - ZFS BuddyBackup Plugin Guide](https://forums.unraid.net/topic/186256-zfs-buddybackup-plugin-guide/)  
> **Source Code**: [GitHub - Piratkopia13/unraid-buddybackup](https://github.com/Piratkopia13/unraid-buddybackup)  
> **Compatibility**: Unraid 6.12.0 or newer with ZFS  

---

## Overview

**ZFS BuddyBackup** is an Unraid plugin designed to make ZFS snapshot maintenance, local pool replication, and offsite backups between two Unraid servers (or between Unraid and generic OpenZFS systems) simple, automated, and secure:
- **Raw Encrypted Transfers**: Remote transfers use raw ZFS send (`zfs send -w`). Data remains encrypted in transit and at rest on the remote server without requiring the destination host to possess your encryption keys (zero-knowledge backup destination).
- **Least-Privilege Security**: Remote connections run as a restricted non-root `buddybackup` user locked to an SSH forced-command allowlist (`restrict_zfs`). Interactive shell access and arbitrary commands are blocked.
- **Remote Immutability**: Destructive commands (`zfs destroy`, `zfs rollback`) are strictly blocked on the receiver to protect against remote compromises and ransomware.

> [!CAUTION]
> **Disclaimer**: I take no responsibility for data loss or damage caused by using this plugin. Please review the open-source code and report any bugs or suggestions on GitHub or the Unraid forum.

---

## Prerequisites & Installation

1. **Unraid Version**: Unraid 6.12.0 or newer with OpenZFS.
2. **Installation**: Install **ZFS BuddyBackup** via the Unraid **Community Applications (Apps)** tab.
3. **Encryption**: By default, remote backups require an encrypted source ZFS dataset. If you must back up unencrypted datasets remotely over a trusted private network, enable **Allow unencrypted remote** in **Advanced Settings**.
4. **Network Connection**: Connect remote servers over a secure network (e.g. Tailscale, WireGuard, or private LAN). Avoid exposing SSH directly to the public internet.

---

## Interface Walkthrough

In the Unraid WebGUI, access the plugin under **Tools → ZFS Buddy Backup**.

The interface is organized into five tabs:
1. [Backup and restore](#1-backup-and-restore)
2. [Snapshot creation and pruning](#2-snapshot-creation-and-pruning)
3. [Buddy's Backups](#3-buddys-backups-receiving-backups)
4. [Advanced Settings](#4-advanced-settings)
5. [Log](#5-log)

*(A live status panel is also available on the main Unraid [Dashboard](#6-unraid-dashboard-integration)).*

---

### 1. Backup and restore

The main command center for configuring, monitoring, and restoring backups.

![Backup and restore Overview](images/screenshot_01_backups_overview.png)

#### Your SSH Public Key
Send your SSH public key to your buddy to add under their **Buddy's Backups** page (or use it when running the setup helper on a generic receiver).

#### Backup Tasks
Each configured backup task displays:
- **Status**: Status indicators for `Healthy`, `Triggered by snapshot`, `Warning` (overdue), `Alert` (critical overdue), `Failed` (last run error), or `Disabled`.
- **Route & Telemetry**: Source dataset `pool/dataset` → destination, last run timestamp, destination size, cron schedule, and snapshot trigger badges.
- **Alert Banners**: Displays failure date, error details, and log link if a task is overdue or failed.

![Backup Task Details](images/screenshot_02_backup_card_expanded.png)

#### Source Settings
- **Enable on cron schedule**: Enables scheduled automated runs.
- **ZFS dataset to backup**: Local dataset to replicate (encrypted datasets by default).
- **Backup child datasets**: Recursively replicate child datasets and snapshots.
- **Skip parent dataset**: Replicate only child datasets, skipping the root parent dataset (useful when replicating container datasets or pools without duplicating the parent).
- **Cron schedule**: Cron expression defining when the backup runs (default: `0 0 * * *` for midnight).

#### Destination Settings

1. **Remote (BuddyBackup)** (Unraid → Unraid):
   - **Buddy's hostname or IP**: Remote Unraid VPN/LAN IP.
   - **Test connection**: Verifies SSH connectivity and command restriction (`restrict_zfs`).
   - **Destination dataset**: Must start with your buddy's configured parent dataset, followed by a child dataset name (e.g. `tank/backups/buddy/my-data`).

2. **Remote (generic ZFS host)** (Unraid → TrueNAS SCALE / Proxmox VE / Linux):
   - **Buddy's hostname or IP**: Remote host IP or hostname.
   - **Remote username** & **SSH port**: SSH user (default: `buddybackup`) and port (default: `22`).
   - **Destination dataset**: Target dataset path on remote host (e.g. `tank/backups/unraid/appdata`).
   - **Remote host one-time setup**: Generates the root command to configure the remote host.
   - **Test connection**: Verifies SSH connectivity, ZFS version, dataset existence, encryption support, resume tokens, and delegated permissions.

![Generic ZFS Host Setup Helper](images/screenshot_03_generic_host_helper.png)

3. **Local** (Pool-to-Pool on the same Unraid server):
   - **Destination dataset**: Local target dataset (autocomplete provided).
   - **Write Protection**: Local destination datasets are automatically set to `readonly=on` upon sync to prevent accidental tampering and ransomware corruption.

#### Task Actions
- **Send backup now**: Runs preflight checks (verifying source dataset, encryption, and snapshots). If no snapshots exist yet, prompts you to create one and send immediately.
- **Create fresh snapshot and send now**: Takes an immediate local snapshot (`autosnap_YYYY-MM-DD_HH:MM:SS_hourly`) and starts replication.
- **Restore data from destination**: Opens the **Restore Snapshot Wizard**.

#### Restore Snapshot Wizard

![Restore Snapshot Wizard](images/screenshot_04_restore_wizard.png)

1. Select a snapshot from the dropdown (grouped by dataset).
2. Choose a restore mode:
   - **Restore selected snapshot**: Restores the single selected snapshot.
   - **Restore all snapshots in selected dataset**: Restores the complete snapshot history for that dataset.
3. Choose the destination:
   - **New dataset**: Restores to a new local dataset name.
   - **Restore to selected**: Restores into an existing local dataset (requires at least one common snapshot).
4. Live progress streams in a terminal; restores continue in the background if closed.

---

### 2. Snapshot creation and pruning

Automated snapshot creation and retention policies powered by **Sanoid**.

![Snapshot Creation and Pruning](images/screenshot_05_snapshots_page.png)

- **Dataset** & **Recursive**: Dataset to snapshot, with optional recursion.
- **Create snapshots automatically** (`autosnap`) & **Prune snapshots automatically** (`autoprune`): Toggle automated snapshot creation and retention pruning.
- **Snapshot retention**: Number of snapshots to retain for Hourly, Daily, Weekly, Monthly, and Yearly intervals.
- **Trigger backup after snapshot**: Select a backup task to run immediately whenever Sanoid creates a new snapshot of this dataset.

> [!NOTE]
> Sanoid runs automatically every 15 minutes (`*/15 * * * *`) via cron whenever snapshot or incoming buddy tasks are enabled.

---

### 3. Buddy's Backups (Receiving Backups)

Configures your Unraid server to receive incoming backups from buddies or external systems. You can add multiple buddies with independent public keys, datasets, and retention policies.

![Buddy's Backups Receiver Configuration](images/screenshot_06_buddys_backups.png)

- **Buddy Name**: Friendly label to identify this buddy (e.g. `Alex (Offsite)`, `Bob (TrueNAS)`).
- **Enable**: Allow incoming connections for this buddy.
- **Buddy's SSH public key**: Paste buddy's public SSH key (restricted to `restrict_zfs` in `authorized_keys`).
- **Destination parent dataset**: Dedicated sub-dataset where your buddy's backups live (e.g. `disk1/buddy_backups`).
  - Must be a dedicated sub-dataset (contains a `/`), not a bare root disk or pool. Overlapping datasets across buddies are disallowed for isolation.
  - Automatically configured with `readonly=on`, `mountpoint=none`, `setuid=off`, and `exec=off` to keep incoming backups immutable and isolated from Unraid's VFS tree.
  - Restoring via the Restore Wizard creates writable datasets. For an emergency in-place failover:
    ```bash
    zfs set readonly=off <pool/dataset>
    zfs inherit mountpoint <pool/dataset>
    ```
- **Snapshot retention**: Local Sanoid policy for how long to keep your buddy's snapshots (Hourly, Daily, Weekly, Monthly, Yearly).

> [!NOTE]
> **Receiving from TrueNAS SCALE or Proxmox VE?**  
> Sudo mode is not supported on Unraid (`restrict_zfs` blocks `sudo`). In TrueNAS, keep **Use Sudo For ZFS Commands** unchecked and **Snapshot Retention Policy** set to **None** (destructive `zfs destroy` is rejected on Unraid; Unraid Sanoid manages retention locally).

---

### 4. Advanced Settings

Fine-tune daemon settings, alert thresholds, and security overrides.

![Advanced Settings](images/screenshot_07_advanced_settings.png)

#### General
- **Use UTC timezone** (default: `No`): Uses UTC timestamps (`TZ=UTC`) for snapshot creation, Sanoid cron, and manual snapshot naming. Useful to align timestamps between servers in different timezones.

#### Dashboard Panel & Alert Thresholds
Configure when status indicators turn warning or alert on the dashboard and task cards (leave empty or `0` to disable):
- **Backup warning** (days, default: `7`): Mark outgoing backup as warning if inactive for this many days.
- **Backup alert** (days, default: `30`): Mark outgoing backup as alert if inactive for this many days.
- **Buddy's backup warning** (days, default: `7`): Mark incoming backup as warning if inactive for this many days.
- **Buddy's backup alert** (days, default: `30`): Mark incoming backup as alert if inactive for this many days.

#### Security Overrides (Danger Zone)
- **Allow unencrypted remote** (default: `No`): Overrides the requirement for remote datasets to be encrypted (`zfs send -w`). Enables sending unencrypted datasets over trusted networks.

> [!WARNING]
> Only enable **Allow unencrypted remote** over trusted private networks (e.g. WireGuard/Tailscale) if you understand the risks. Data is transferred and stored without native ZFS encryption.

---

### 5. Log

Displays live output from `/var/log/buddybackup.log`, streaming updates every 2 seconds. Useful for monitoring active replications and diagnosing connection or delegation issues.

![Replication Log Viewer](images/screenshot_08_log_viewer.png)

---

### 6. Unraid Dashboard Integration

A dashboard widget summarizing your backup health at a glance:

![Unraid Dashboard Integration](images/screenshot_09_dashboard_tile.png)

- **Header**: Live aggregate counts (`X backup(s), Y autosnap, Z autoprune, Incoming active`).
- **Table Columns**:
  - **Source**: Source dataset or buddy label.
  - **Destination**: Target host and dataset path.
  - **Status**: Status indicator with schedule and trigger badges.
  - **Last run**: Human-readable relative timestamp (e.g. `Today, 06:00`).
  - **Size**: Used storage on the destination.

---

## Generic ZFS Hosts Deep-Dive

BuddyBackup replicates with non-Unraid OpenZFS hosts like **TrueNAS SCALE**, **Proxmox VE**, or standard **Debian/Ubuntu** servers.

### Scenario A: Unraid Pushes Backups to Generic Host

1. In Unraid (**Tools → ZFS Buddy Backup → Backup and restore**), add a backup with **Type: Remote (generic ZFS host)**.
2. Enter the remote host IP, username (`buddybackup`), SSH port (`22`), and destination dataset (e.g. `tank/backups/unraid/appdata`).
3. Run the generated **Remote host one-time setup** command as root on the remote host:
   ```bash
   curl -fsSL https://raw.githubusercontent.com/Piratkopia13/unraid-buddybackup/refs/heads/main/src/usr/local/emhttp/plugins/buddybackup/deps/generic_host_setup.sh | bash -s -- --dataset 'tank/backups/unraid' --user 'buddybackup' --port '22' --pubkey 'ssh-ed25519 AAAAC3...'
   ```

#### Script Options
The `generic_host_setup.sh` script is idempotent and self-verifying:
- `--dataset NAME`: Target parent dataset (creates with `mountpoint=none` and `readonly=on` if missing). Repeatable.
- `--user NAME`: Restricted user account (default: `buddybackup`; UID 0/root refused).
- `--port N`: SSH port (default: `22`).
- `--pubkey KEY`: Unraid SSH public key.
- `--sudo-mode auto|yes|no`: Allows running validated commands via sudo when `zfs` is not directly executable.
- `--allowlist-dir PATH`: Script location (default: `/usr/local/sbin`; TrueNAS SCALE defaults to `/mnt/<pool>/.buddybackup`).
- `--verify`: Run validation checks without changes.
- `--revoke NAME`: Revoke delegations on a dataset.
- `--clean`: Completely uninstall delegations, allowlist files, and SSH entries.

#### Platform-Specific Notes:
- **Proxmox VE / Debian / Ubuntu**: Run directly as root. Creates user, applies ZFS delegations (`create,mount,receive` and raw `send`), installs the allowlist script to `/usr/local/sbin/`, and adds an SSH drop-in to `/etc/ssh/sshd_config.d/`.
- **TrueNAS SCALE**:
  1. *Persistent Directory*: The setup script places the allowlist in `/mnt/<pool>/.buddybackup/` to survive reboots on SCALE 24.04+'s read-only root filesystem.
  2. *Create User*: In *Credentials → Users*, create user `buddybackup`, shell `/usr/bin/bash`, disable password login, and paste Unraid's public key.
  3. *Run Script*: Run the setup command in the TrueNAS root shell (`sudo -i`).
  4. *Sudo Command Grant*: In TrueNAS UI (*Credentials → Users*), add `/usr/bin/bash -c *` to *Allowed sudo commands with no password* (the allowlist script remains the strict fine-grained gate).
  5. *SSH Parameters*: Paste the printed `Match User buddybackup` block into *System Settings → Services → SSH → Auxiliary Parameters* and restart SSH.
4. In Unraid, use **Test connection** on the backup entry to verify access.

---

### Scenario B: Generic Host Pushes Backups to Unraid

Your Unraid server acts as the secure receiver.

> [!IMPORTANT]
> **Sudo mode is not supported on Unraid**: Unraid grants dataset permissions via native OpenZFS delegation (`zfs allow`). The `buddybackup` user has no sudo privileges, and `restrict_zfs` strictly blocks any `sudo` commands.

#### 1. Prepare Unraid (Receiver)
Under **Tools → ZFS Buddy Backup → Buddy's Backups**, configure a buddy with a **Destination parent dataset** (e.g. `disk1/buddy_backups`) and your desired **Snapshot retention** policy.

#### 2. Configure TrueNAS SCALE (WebGUI Sender)
1. **SSH Connection**: In **Credentials → Backup Credentials → SSH Connections**, create a connection (Host: Unraid IP, Port: `22`, User: `buddybackup`). Paste the public key into Unraid's **Buddy's Backups**.
2. **Periodic Snapshot Task**: In **Data Protection → Periodic Snapshot Tasks**, set the naming schema to:
   ```
   autosnap_%Y-%m-%d_%H:%M:%S_daily
   ```
   *(Use `_hourly`, `_daily`, `_weekly`, or `_monthly` to match your schedule. Sanoid requires the `autosnap_` prefix and frequency suffix to manage retention).*
3. **Replication Task**: In **Data Protection → Replication Tasks**:
   - Destination: Unraid SSH connection and target dataset (e.g. `tank/backups/buddy/truenas-appdata`).
   - ⚠️ **Use Sudo For ZFS Commands**: Must be **DISABLED** (Unraid blocks sudo).
   - ⚠️ **Snapshot Retention Policy**: Set to **"None"** (TrueNAS must not execute `zfs destroy` on Unraid; Unraid Sanoid manages retention).
   - **Read-Only**: Leave set to **"Set"** or **"Ignore"**.

#### 3. Configure Proxmox VE / Debian (CLI Sender)
1. Generate an SSH keypair on the Linux host:
   ```bash
   ssh-keygen -t ed25519 -f /root/.ssh/id_buddybackup -N ""
   ```
2. Paste `/root/.ssh/id_buddybackup.pub` into Unraid's **Buddy's Backups**.
3. Push snapshots with `syncoid`:
   ```bash
   syncoid --no-privilege-elevation --sshkey=/root/.ssh/id_buddybackup pool/dataset buddybackup@<unraid-ip>:tank/backups/buddy/dataset
   ```
   *(Always pass `--no-privilege-elevation`. Sudo is blocked on Unraid).*
4. Schedule the command via cron or systemd. Older snapshots named `autosnap_*` will be automatically pruned on Unraid according to your retention policy.
