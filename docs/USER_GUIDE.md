# ZFS BuddyBackup — Comprehensive Plugin & User Guide

> **Official Forum Guide Thread**: [Unraid Community Forums - ZFS BuddyBackup Plugin Guide](https://forums.unraid.net/topic/186256-zfs-buddybackup-plugin-guide/)  
> **Source Code**: [GitHub - Piratkopia13/unraid-buddybackup](https://github.com/Piratkopia13/unraid-buddybackup)  
> **Compatibility**: Unraid 6.12.0 or newer with ZFS  

---

## Overview

**ZFS BuddyBackup** is an Unraid plugin designed to make ZFS snapshot maintenance, local replication, and remote backups between two Unraid servers (or between Unraid and any generic OpenZFS system) simple, automated, and secure.

Whether you are backing up to a trusted buddy running Unraid, pushing backups to an offsite TrueNAS SCALE / Proxmox VE system, or replicating locally between pools, BuddyBackup ensures:
- **Raw Encrypted Transfers**: Remote transfers use raw ZFS send (`zfs send -w`). Data remains encrypted in transit and at rest on the remote server without requiring the destination host to possess your encryption keys (zero-knowledge backup destination).
- **Least-Privilege Security**: Remote connections run as a restricted non-root `buddybackup` user locked to an SSH forced-command allowlist (`restrict_zfs`). No interactive shell access or arbitrary command execution is permitted.
- **Remote Immutability**: Destructive commands (such as `zfs destroy` and `zfs rollback`) are strictly blocked on the receiver. Even if a sender system is compromised, existing snapshots on the receiver cannot be deleted remotely.

> [!CAUTION]
> **Disclaimer**: I take no responsibility for data loss or damage caused by using this plugin. Please review the open-source code and report any bugs or suggestions on GitHub or the Unraid forum.

---

## Prerequisites & Installation

1. **Unraid Version**: Unraid 6.12.0 or newer with OpenZFS.
2. **Installation**: Install **ZFS BuddyBackup** directly via the Unraid **Community Applications (Apps)** tab.
3. **Encryption**: By default, remote backups require an encrypted source ZFS dataset. If you must back up unencrypted datasets remotely, you can explicitly enable this under **Advanced Settings**.
4. **Network Connection**: For remote backups, connect over a secure network such as a VPN (Tailscale, WireGuard) or direct private network. Avoid exposing SSH directly to the public internet.

---

## Interface Walkthrough

The plugin settings are organized into five clean sections under **Settings → ZFS Buddy Backup**:
1. [Backup and restore](#1-backup-and-restore)
2. [Snapshot creation and pruning](#2-snapshot-creation-and-pruning)
3. [Buddy's Backups](#3-buddys-backups-receiving-backups)
4. [Advanced Settings](#4-advanced-settings)
5. [Log](#5-log)

*(A live status panel is also available on the main Unraid **Dashboard**).*

---

### 1. Backup and restore

This is your main command center for creating, scheduling, monitoring, and restoring backups.

<!-- [SCREENSHOT NEEDED: screenshot_01_backups_overview.png]
Description: Overview of the "Backup and restore" tab showing the "Your SSH public key" banner at the top (with the Copy button), the "Add Backup" and "Collapse All" buttons, and 2-3 configured backup cards in various states (e.g. one active Remote BuddyBackup, one Remote Generic host, one Local).
-->

#### Your SSH Public Key Banner
At the top of the page, you'll see **Your SSH public key**.
- Click the **Copy** button (or click the field to select all) to copy your public key.
- Send this key to your buddy so they can add it to their **Buddy's Backups** page (or use it when preparing a generic receiver).

#### Backup Task Cards
Each backup task is contained in a collapsible card. The header summarizes:
- **Status Indicator**: Healthy (green dot), Warning/Error (red dot), Running (pulsing blue dot), or Disabled (grey dot).
- **Route Summary**: Source dataset `pool/dataset` → Destination `host:target` or `local:target`.
- **Telemetry Indicators**: Timestamp of last run, destination size, cron schedule, and snapshot trigger badges.
- **Quick Action**: A **Send backup now** button right on the header for quick manual execution.

Clicking the card header expands the configuration form:

<!-- [SCREENSHOT NEEDED: screenshot_02_backup_card_expanded.png]
Description: A single backup card expanded showing the 2-column layout ("Source" on left, "Destination" on right), the telemetry banner, form fields, and bottom action buttons (Apply, Send backup now, Create fresh snapshot and send now, Restore data from destination, Remove).
-->

#### Source Settings (Left Column)
- **Enable on cron schedule**: Toggle automated execution (`Yes` / `No`).
- **ZFS dataset to backup**: Select the local dataset to replicate (encrypted datasets by default).
- **Backup child datasets**: Set to `Yes` to recursively include child datasets and snapshots.
- **Cron schedule**: Standard cron expression defining when the backup runs (default: `0 0 * * *` for midnight).

#### Destination Settings (Right Column)
Select one of three destination types:

1. **Remote (BuddyBackup)** (Unraid → Unraid):
   - **Buddy's hostname or IP**: Your buddy's VPN or LAN IP.
   - **Test connection**: Verifies SSH connectivity and dataset permissions on your buddy's server.
   - **Destination dataset**: The dataset on your buddy's server that will receive your backups. Must begin with your buddy's designated parent dataset, followed by a child dataset name (e.g. `tank/backups/buddy/my-server-data`).

2. **Remote (generic ZFS host)** (Unraid → TrueNAS SCALE / Proxmox VE / Linux):
   - **Buddy's hostname or IP**: Remote host IP or hostname.
   - **Remote username**: Restricted SSH user on the remote host (default: `buddybackup`).
   - **SSH port**: SSH port on the remote host (default: `22`).
   - **Destination dataset**: Remote destination dataset (e.g. `tank/backups/unraid/appdata`).
   - **Remote host one-time setup helper**: A built-in command generator! It dynamically crafts the one-time root setup command using the exact username, port, parent dataset, and your Unraid public key. Click **Copy** to copy the command and run it once on the remote machine.
   - **Test connection**: Tests SSH connectivity and verifies ZFS permissions on the generic host.

<!-- [SCREENSHOT NEEDED: screenshot_03_generic_host_helper.png]
Description: Close-up of the Destination column with "Remote (generic ZFS host)" selected, highlighting the "Remote host one-time setup" box with the generated curl command, Copy button, and forum guide link.
-->

3. **Local** (Pool-to-Pool on the same Unraid server):
   - **Destination dataset**: The local dataset to receive the backup (must differ from source; autocomplete datalist provided). Can replicate unencrypted datasets locally.

#### Card Action Buttons
- **Apply**: Saves the backup configuration.
- **Send backup now**: Runs the replication task immediately in the background with a live progress console.
- **Create fresh snapshot and send now**: Creates a brand-new snapshot on the source and immediately pushes it to the destination.
- **Restore data from destination**: Launches the interactive **Restore Snapshot Wizard**.
- **Remove**: Deletes the backup task.

#### Restore Snapshot Wizard
Clicking **Restore data from destination** opens an interactive wizard:
- Queries the destination host for available datasets and snapshots.
- Allows you to browse, select an exact snapshot or full dataset to restore, and choose the target local destination.

<!-- [SCREENSHOT NEEDED: screenshot_04_restore_wizard.png]
Description: The modal dialog of the Restore Snapshot Wizard showing the snapshot selector dropdown, destination picker, and restore options.
-->

---

### 2. Snapshot creation and pruning

BuddyBackup includes built-in automated snapshot creation and pruning powered by **Sanoid**. If you don't use another tool for snapshots, configure your policies here.

<!-- [SCREENSHOT NEEDED: screenshot_05_snapshots_page.png]
Description: The "Snapshot creation and pruning" tab showing a dataset entry with retention inputs (Hourly, Daily, Weekly, Monthly, Yearly), the "Recursive" toggle, and the "Trigger backup after snapshot creation" dropdown.
-->

#### Configuration Options
- **Dataset**: Select which local dataset to snapshot.
- **Recursive**: Apply the snapshot policy recursively to all child datasets.
- **Create snapshots automatically**: Automatically generate snapshots according to the retention schedule.
- **Prune snapshots automatically**: Automatically prune older snapshots when retention thresholds are met.
- **Snapshot retention**: Specify how many snapshots to retain across intervals:
  - Hourly (e.g. keep 24)
  - Daily (e.g. keep 7)
  - Weekly (e.g. keep 4)
  - Monthly (e.g. keep 3)
  - Yearly (e.g. keep 0)
- **Trigger backup after snapshot creation**: Seamlessly link snapshots to backups! When Sanoid takes a new snapshot of this dataset, it can automatically trigger one of your configured backup tasks to replicate immediately.

---

### 3. Buddy's Backups (Receiving Backups)

This tab configures your Unraid server to receive incoming backups from your buddy (or from a remote TrueNAS/Proxmox server).

<!-- [SCREENSHOT NEEDED: screenshot_06_buddys_backups.png]
Description: The "Buddy's Backups" tab showing incoming buddy cards, telemetry banner ("Storage used by buddy", "Last received backup"), Enable toggle, Buddy's SSH public key input, Destination parent dataset selector with live example note, retention inputs, and the generic sender callout box at the bottom.
-->

#### Configuration Options
- **Enable**: Set to `Yes` to allow incoming backup connections.
- **Buddy's SSH public key**: Paste your buddy's public SSH key here (one key per buddy entry). If you receive backups from multiple buddies or secondary systems, use **Add Buddy** to create dedicated entries for each.
- **Destination parent dataset**: Select the parent dataset on your server where your buddy's data will live (e.g. `tank/backups/buddy`).
  - *Important*: Raw encrypted sends preserve the source properties, so local compression or encryption settings on your parent dataset will not alter incoming raw datasets.
- **Snapshot retention**: Your local Sanoid retention policy for your buddy's snapshots. Set this in agreement with your buddy to balance disk usage with recovery depth.
- **Telemetry Banner**: Displays the health status, date of the last received backup, and the current total storage occupied by your buddy's backups.

> [!NOTE]
> **Receiving from TrueNAS SCALE or Proxmox VE?**  
> See the [Generic ZFS Hosts Deep-Dive](#generic-zfs-hosts-deep-dive) below for instructions on TrueNAS replication tasks and snapshot naming conventions.

---

### 4. Advanced Settings

Fine-tune plugin behavior and safety policies:

<!-- [SCREENSHOT NEEDED: screenshot_07_advanced_settings.png]
Description: The "Advanced Settings" tab showing options such as "Bandwidth rate limit", "Allow unencrypted remote backups", and "Log level".
-->

- **Bandwidth rate limit**: Restrict transfer speeds (in KB/s or MB/s) to prevent backup replication from saturating your internet upload bandwidth.
- **Allow unencrypted remote backups**: By default, BuddyBackup requires remote datasets to be encrypted. If you are operating over a private, trusted VPN and want to back up unencrypted datasets, toggle this setting to `Yes`.
- **Custom snapshot prefixes**: Configure custom snapshot prefix matching if needed.

---

### 5. Log

Displays the live system log from `/var/log/buddybackup.log`.
- Automatically streams new log entries as backups and replication tasks run.
- Useful for diagnosing SSH connectivity issues, syncoid output, or permission delegation checks.

<!-- [SCREENSHOT NEEDED: screenshot_08_log_viewer.png]
Description: The "Log" tab showing real-time log entries of a backup run or connection test.
-->

---

### 6. Unraid Dashboard Integration

ZFS BuddyBackup includes a dashboard panel directly on Unraid's main **Dashboard**:
- Provides an at-a-glance summary of all configured backups, their health status, last run timestamps, and storage consumed.
- Includes quick-launch buttons to trigger backups directly from your dashboard.

<!-- [SCREENSHOT NEEDED: screenshot_09_dashboard_tile.png]
Description: Unraid Dashboard showing the BuddyBackup tile/card with task statuses, destination usage, and quick action buttons.
-->

---

## Generic ZFS Hosts Deep-Dive

BuddyBackup works seamlessly with non-Unraid OpenZFS systems like **TrueNAS SCALE**, **Proxmox VE**, or standard **Debian/Ubuntu** servers.

### Scenario A: Unraid Pushes Backups to Generic Host

#### How It Works
1. In Unraid, go to **Backup and restore** and add a backup entry with **Type: Remote (generic ZFS host)**.
2. Fill in the remote host IP, remote user (e.g. `buddybackup`), SSH port (e.g. `22`), and destination dataset (e.g. `tank/backups/unraid/mydata`).
3. In the **Remote host one-time setup** box inside the card, click **Copy** to grab the generated setup command.
4. On the remote host, run the setup command as root:
   ```bash
   curl -fsSL https://raw.githubusercontent.com/Piratkopia13/unraid-buddybackup/refs/heads/main/src/usr/local/emhttp/plugins/buddybackup/deps/generic_host_setup.sh | bash -s -- --dataset 'tank/backups/unraid' --user 'buddybackup' --port '22' --pubkey 'ssh-ed25519 AAAAC3...'
   ```

#### Platform-Specific Notes:
- **Proxmox VE / Debian / Ubuntu**: Run the command directly in a root console or SSH session. The script creates the user, applies ZFS delegations, writes the SSH forced command line, and adds an SSH drop-in automatically.
- **TrueNAS SCALE**:
  1. **SSH Service**: Ensure SSH is enabled under *System Settings → Services → SSH*.
  2. **Create User**: In *Credentials → Users → Add*, create user `buddybackup`, set shell to `/usr/bin/bash`, disable password login, and paste your Unraid public key into the user's *SSH Public Key* field.
  3. **Run Script**: Open the TrueNAS web shell (`sudo -i`) and run the setup command. If prompted, paste the printed sudo commands into the user's *Allowed sudo commands with no password* field in the UI and re-run.
  4. **SSH Auxiliary Parameters**: Paste the printed `Match User buddybackup` block into *System Settings → Services → SSH → Auxiliary Parameters* and restart SSH.
5. In Unraid, click **Test connection** on the backup entry to verify access.

---

### Scenario B: Generic Host Pushes Backups to Unraid

When a generic host pushes backups to Unraid, your Unraid server acts as the secure receiver.

#### 1. Prepare Unraid (Receiver)
1. In Unraid, go to **Buddy's Backups**.
2. Set **Enable** to **Yes**.
3. Choose a **Destination parent dataset** (e.g. `tank/backups/buddy`).
4. Set your desired **Snapshot retention** policy (Hourly, Daily, Weekly, Monthly, Yearly).

#### 2. Configure TrueNAS SCALE (WebGUI Sender)
1. **SSH Connection**:
   - Go to **Credentials → Backup Credentials → SSH Connections → Add**.
   - Set Host to your Unraid IP, Port to `22`, Username to `buddybackup`.
   - Generate a new keypair (or pick an existing one).
   - Copy the public key, paste it into Unraid's **Buddy's Backups → Buddy's SSH public key**, and click **Apply** on Unraid.
2. **Periodic Snapshot Task**:
   - Go to **Data Protection → Periodic Snapshot Tasks → Add**.
   - Select your source dataset and schedule.
   - ⚠️ **Naming Schema**: Change the default naming schema to:
     ```
     autosnap_%Y-%m-%d_%H:%M:%S_daily
     ```
     *(Use `_hourly`, `_daily`, `_weekly`, or `_monthly` matching your schedule. Sanoid on Unraid requires the `autosnap_` prefix and frequency suffix to manage snapshot pruning).*
3. **Replication Task**:
   - Go to **Data Protection → Replication Tasks → Add**.
   - Select your source dataset and snapshot task.
   - Set destination to the Unraid SSH connection and specify the target dataset (e.g. `tank/backups/buddy/truenas-appdata`).
   - ⚠️ **Critical - Snapshot Retention Policy**: Set to **"None"**!
     *Do NOT let TrueNAS manage retention on Unraid. TrueNAS will attempt to execute `zfs destroy` on Unraid, which BuddyBackup strictly rejects to keep your backups immutable. Unraid's local Sanoid service manages retention automatically.*

<!-- [SCREENSHOT NEEDED: screenshot_10_truenas_replication_task.png]
Description: TrueNAS SCALE Replication Task configuration screen showing the destination dataset, SSH connection, and the Snapshot Retention Policy highlighted and set to "None".
-->

#### 3. Configure Proxmox VE / Debian (CLI Sender)
1. Generate an SSH keypair on the Linux host:
   ```bash
   ssh-keygen -t ed25519 -f /root/.ssh/id_buddybackup -N ""
   ```
2. Copy `/root/.ssh/id_buddybackup.pub` and paste it into Unraid's **Buddy's Backups → Buddy's SSH public key**.
3. Push snapshots using `syncoid`:
   ```bash
   syncoid --no-privilege-elevation --sshkey=/root/.ssh/id_buddybackup pool/dataset buddybackup@<unraid-ip>:tank/backups/buddy/dataset
   ```
4. Schedule the command via cron or systemd timer. Older snapshots named with `autosnap_*` will be automatically pruned on Unraid.

---

## Screenshot Inventory & Capture Checklist

When taking screenshots for the forum update, ensure clean test/demo dataset names (e.g. `pool/appdata`, `tank/backups/buddy`) and remove any private IP addresses or sensitive tokens.

| Screenshot ID | Location / Page | State / Description to Capture | Status |
|:---|:---|:---|:---|
| `screenshot_01_backups_overview.png` | **Backup and restore** | Top SSH key banner with Copy button, action toolbar, and 2-3 collapsed cards with status dots and telemetry badges. | **Needs re-capture** (replaces old forum image) |
| `screenshot_02_backup_card_expanded.png` | **Backup and restore** | Expanded backup card showing 2-column layout (Source on left, Destination on right), telemetry banner, and bottom actions. | **Needs re-capture** (replaces old forum image) |
| `screenshot_03_generic_host_helper.png` | **Backup and restore** | Close-up of Destination column with `Remote (generic ZFS host)` selected, showing username, port, and the inline setup helper with curl command & Copy button. | **New screenshot needed** |
| `screenshot_04_restore_wizard.png` | **Backup and restore** | Modal popup of the Restore Snapshot Wizard showing the dataset/snapshot list and destination selection. | **Needs re-capture** (replaces old forum image) |
| `screenshot_05_snapshots_page.png` | **Snapshot creation and pruning** | Sanoid configuration card showing hourly/daily/weekly retention inputs and the trigger backup dropdown. | **Needs re-capture** (replaces old forum image) |
| `screenshot_06_buddys_backups.png` | **Buddy's Backups** | Incoming settings showing telemetry banner, multi-key textarea, destination parent dataset example, retention fields, and generic sender note. | **Needs re-capture** (replaces old forum image) |
| `screenshot_07_advanced_settings.png` | **Advanced Settings** | Settings page showing bandwidth rate limit and unencrypted remote backup toggle. | **New screenshot needed** |
| `screenshot_08_log_viewer.png` | **Log** | Live log viewer streaming recent replication and connection test entries. | **New screenshot needed** |
| `screenshot_09_dashboard_tile.png` | **Unraid Dashboard** | BuddyBackup tile on the main Unraid dashboard showing task statuses and storage metrics. | **New screenshot needed** |
| `screenshot_10_truenas_replication_task.png` | **TrueNAS SCALE WebGUI** | Data Protection → Replication Task showing `Snapshot Retention Policy: None` and destination dataset path. | **New screenshot needed** |
