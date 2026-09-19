# TrueNAS SCALE manual validation checklist

TrueNAS SCALE manages users, SSH keys, sudo grants and its sshd configuration through the
middleware, so its UI-driven setup cannot be fully automated by the testlab. Validate a
TrueNAS SCALE host manually with this checklist before each release that touches the
generic ZFS host support.

Prerequisites for the checklist host:

- TrueNAS SCALE 24.04 (Dragonfish) or newer with a pool that has `feature@encryption` enabled.
- A Unraid server running the BuddyBackup plugin version under test.

## Setup

1. On the Unraid server: open Settings → **ZFS Buddy Backup → Backup and restore**.
2. Add a backup entry, choose type **Remote (generic ZFS host)**, and configure username,
   SSH port, and destination dataset.
3. In the **Remote host one-time setup** helper, copy the generated setup command.
   (The sender SSH public key is also at the top of the *Backup and restore* page).
4. On TrueNAS (shell as root, e.g. web shell + `sudo -i`):
   - Run the setup command (or download the script, review it, then run it).
   - Confirm it prints the SCALE-specific blocks (sudo values + SSH Auxiliary Parameters).
   - Confirm the allowlist was installed on persistent storage: TrueNAS 24.04+ mounts its
     root filesystem read-only, so the script places the allowlist in a hidden root-owned
     `.buddybackup` directory on the dataset's pool (e.g. `/mnt/<pool>/.buddybackup/`), or
     wherever `--allowlist-dir` pointed. Confirm the script prints that path and that the
     directory is root-owned 0755.
   - Confirm a sibling `<allowlist>.datasets` scope file exists next to the allowlist and
     lists exactly the datasets passed with `--dataset`.
5. In the TrueNAS UI:
   - System Settings → Services → SSH: enable, set the TCP port used above.
   - Credentials → Users: create the user (no password login, shell `/usr/bin/bash`), paste
     the public key into "SSH Public Key".
   - If the script reported the zfs binary is not executable for the user: paste the printed
     value (`/usr/bin/bash -c *`) into the user's "Allowed sudo commands with no password"
     field and re-run the setup script.
   - Paste the printed `Match User` block into the SSH service's "Auxiliary Parameters".
6. Re-run the setup script with `--verify` and confirm all checks pass.

## Push smoke (Unraid → TrueNAS)

1. On Unraid: Backups → add entry, type **Remote (generic ZFS host)**, host/port/username per
   setup, destination dataset under the configured parent (child dataset name).
2. Click **Test connection** and confirm: SSH success, `zfs version` reported, dataset state
   correct (created on first backup or already present), encryption status reported, resume
   support line, and "Security validation passed".
3. Click **Send backup now** and confirm the backup completes ("Successfully synced backup
   to buddy!") and that no plaintext mounts appear on TrueNAS (`mountpoint=none` tree).
4. On TrueNAS: confirm `zfs get -H compression`-style read access is impossible for the
   buddybackup user (raw stream was received; data unreadable without keys).
5. On Unraid: use **Restore data from destination** for the entry, restore the newest pushed
   snapshot to a new local dataset, and confirm the restore succeeds (validates the
   receiver's `send` delegation).
6. In the TrueNAS UI, edit the user's SSH key (or remove and re-add it), then confirm the
   forced-command line is gone from `~buddybackup/.ssh/authorized_keys`; re-run the setup
   script and confirm `--verify` passes again.

## Push smoke (TrueNAS SCALE Replication Task → Unraid)

1. On TrueNAS: Data Protection → Periodic Snapshot Tasks:
   - Configure a periodic snapshot task with Naming Schema formatted to Sanoid conventions,
     e.g. `autosnap_%Y-%m-%d_%H:%M:%S_daily` (or `_hourly`). TrueNAS requires `%Y`, `%m`, `%d`, `%H`, `%M` in the schema.
2. On TrueNAS: Data Protection → Replication Tasks → Add:
   - Source Location: On this System, select the source dataset.
   - Destination Location: On a Different System.
   - SSH Connection: Create/select the SSH connection to Unraid's buddy user (port 22 or Unraid SSH port, buddy user, private key matching public key added to Unraid's BuddyBackup buddy list).
   - Target Dataset: Set to a child of Unraid's configured Receive parent dataset (e.g. `disk1/backups/truenas`).
   - **Snapshot Retention Policy**: Must be set to **None** (Unraid's `restrict_zfs` allowlist strictly rejects `zfs destroy` to keep received backups immutable).
   - **Use Sudo For ZFS Commands**: Must be **unchecked / disabled** (sudo mode is not supported; Unraid uses native OpenZFS delegation and BuddyBackup's restricted shell strictly blocks `sudo`).
3. Run the replication task manually and verify it succeeds.
4. On Unraid:
   - Verify received dataset exists under the receive parent dataset.
   - On *Snapshot creation and pruning*, verify or configure pruning retention on the receive parent dataset (with Recursive = Yes).
   - Verify that Sanoid automatically prunes old snapshots matching `autosnap_*_<frequency>` according to configured retention.

## Teardown / grant changes

- Changing the served datasets: re-run the setup script with the new `--dataset` list (repeat
  the option for each dataset). The run converges: grants for previously set-up datasets that
  are no longer listed are revoked automatically (tracked in the root-owned
  `buddybackup-<user>-zfs-grants.txt` state file next to the allowlist), and the allowlist's
  `<allowlist>.datasets` scope file is rewritten to the same list so the forced command can no
  longer reach the removed datasets.
- Removing a single dataset's access: `--revoke <dataset>` (can be combined with a normal
  setup run or used alone).
- Full uninstall: `--clean` revokes every recorded and discovered delegation, removes the
  allowlist script(s), sudo flag files, sudoers entry, sshd drop-in and the forced-command
  line from authorized_keys; add `--delete-user` to also delete the user. Datasets and their
  data are never touched. If a custom `--allowlist-dir` was used, pass it to `--clean` so its
  files are found. Confirm the TrueNAS UI leftovers (Auxiliary Parameters block, SSH key /
  user) are removed manually as printed by the script.

## Negative checks

1. From the TrueNAS shell as the restricted user, confirm these fail or are blocked:
   - `ssh -i <key> buddybackup@localhost "echo ok && ls"` → no output from `ls` (blocked).
   - `ssh -i <key> buddybackup@localhost "zfs destroy <received dataset>"` → blocked.
   - `ssh -i <key> buddybackup@localhost "sudo -i"` → blocked (no tty, not allowlisted).
   - Writing to the allowlist location fails: `touch /mnt/<pool>/.buddybackup/test` →
     permission denied (the user must never be able to replace the forced-command script).
2. **Datasets outside the configured scope must never pass the connection test** (this is
   the sudo-mode regression check: on TrueNAS the validated commands run as root, so only
   the allowlist scope can stop them):
   - For a push entry pointing outside the receiver's configured parent: it must
     report "Neither dataset ... nor its parent exists" and must **never** print
     "ZFS receive permissions verified".
3. From the TrueNAS shell as root, remove one dataset line from the receiver's
   `<allowlist>.datasets` scope file; the push connection test above must still reject that
   dataset (a missing or drifted scope file is reported by `--verify` so it can be restored
   by re-running the setup script).

## Pass criteria

- All steps complete without unexpected warnings; the setup script's `--verify` checklist
  reports zero FAIL entries; no forced-command line is lost after the TrueNAS
  UI key-edit step once the script has been re-run.
- Received snapshots beyond retention on Unraid are pruned by sanoid; snapshots with non-Sanoid naming conventions are preserved.
