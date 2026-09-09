# TrueNAS SCALE manual validation checklist

TrueNAS SCALE manages users, SSH keys, sudo grants and its sshd configuration through the
middleware, so its UI-driven setup cannot be fully automated by the testlab. Validate a
TrueNAS SCALE host manually with this checklist before each release that touches the
generic ZFS host support.

Prerequisites for the checklist host:

- TrueNAS SCALE 24.04 (Electric Eel) or newer with a pool that has `feature@encryption` enabled.
- A Unraid server running the BuddyBackup plugin version under test.

## Setup

1. On the Unraid server: open Settings → **ZFS Buddy Backup → Generic ZFS hosts**.
2. Choose role, username (`buddybackup`), parent dataset, port, platform `TrueNAS SCALE`.
3. Copy the generated setup command and the SSH public key.
4. On TrueNAS (shell as root, e.g. web shell + `sudo -i`):
   - Run the setup command (or download the script, review it, then run it).
   - Confirm it prints the SCALE-specific blocks (sudo values + SSH Auxiliary Parameters).
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

## Pull smoke (TrueNAS → Unraid)

1. On TrueNAS: create snapshots of the source dataset (Data Protection → Periodic Snapshot
   Tasks, or one manual snapshot).
2. On Unraid: Backups → add entry, type **Pull from generic ZFS host**, remote host/port/
   username per setup, source dataset, local destination dataset.
3. Click **Test connection** and confirm success plus the encryption status line.
4. Click **Send backup now** (runs the pull preflight and pull) and confirm
   "Successfully pulled backup from <host>!".
5. On TrueNAS: confirm the sender user cannot receive, destroy or snapshot (`zfs allow` shows
   only `send`/`hold` and the allowlist blocks everything else).
6. On Unraid: restore from the pulled dataset via the local restore path.

## Negative checks

1. From the TrueNAS shell as the restricted user, confirm these fail or are blocked:
   - `ssh -i <key> buddybackup@localhost "echo ok && ls"` → no output from `ls` (blocked).
   - `ssh -i <key> buddybackup@localhost "zfs destroy <received dataset>"` → blocked.
   - `ssh -i <key> buddybackup@localhost "sudo -i"` → blocked (no tty, not allowlisted).
2. On Unraid with `AllowUnencryptedRemoteBackups=no`: a pull from an unencrypted dataset
   aborts with "is not encrypted!".

## Pass criteria

- All steps complete without unexpected warnings; the setup script's `--verify` checklist
  reports zero FAIL entries in both roles; no forced-command line is lost after the TrueNAS
  UI key-edit step once the script has been re-run.
