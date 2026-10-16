# Security Audit & Remediation Plan: `dev` Branch

**Target**: Changes between `main` and `dev` (`git log main..dev`)  
**Scope**: BuddyBackup plugin source files (`rc.buddybackup`, `rc.buddybackup.php`, WebGUI `.page` files, allowlists, and helper scripts)  
**Security Standard**: Least Privilege, Safe File Handling (CWE-59/377), Injection Prevention (CWE-78), Concurrency Control (CWE-362)

---

## Executive Summary

A comprehensive security audit was conducted on all commits introduced on the `dev` branch since diverging from `main` (commits `7bcd41f` through `75e310d`). While the new features (custom SSH ports, snapshot schedule configurability, multi-dataset authorization, baseline child dataset snapshots, and receiver reboot self-healing) significantly expand plugin capabilities, the audit identified **7 security findings** ranging from **Critical** to **Low/Defense-in-Depth**.

| ID | Title | Severity | CWE | Status |
|---|---|---|---|---|
| **SEC-01** | Local Privilege Escalation via Wildcard `chown`/`chmod` and Symlinks in `/tmp` | **CRITICAL** | CWE-59 / CWE-377 / CWE-269 | Needs Resolution |
| **SEC-02** | Concurrency Race Condition & Missing File Lock on Snapshot-Triggered Backups | **HIGH** | CWE-362 | Needs Resolution |
| **SEC-03** | Shell Metacharacter Injection & Quote Fragility in `update_sanoid_conf` | **HIGH** | CWE-78 | Needs Resolution |
| **SEC-04** | Information Disclosure of Cross-Buddy Destination Datasets in `probe_zfs` | **MEDIUM** | CWE-200 | Needs Resolution |
| **SEC-05** | Non-POSIX Bashisms in Sanoid Pre/Post Hook Filter Causing Snapshot Failures | **MEDIUM** | CWE-758 | Needs Resolution |
| **SEC-06** | World-Readable Incoming Buddy Metadata in Public `/tmp` Directory | **LOW** | CWE-276 / CWE-732 | Needs Resolution |
| **SEC-07** | Telemetry Attribution Desynchronization on Shared Keys | **LOW** | CWE-703 | Needs Resolution |

---

## Detailed Vulnerability Analysis & Remediation Plan

---

### Finding SEC-01 (CRITICAL): Local Privilege Escalation via Wildcard `chown`/`chmod` and Symlinks in `/tmp`

#### Vulnerability Description
In `src/usr/local/emhttp/plugins/buddybackup/scripts/rc.buddybackup.php`, commit `75e310d` added logic to update telemetry file permissions and store incoming buddy metadata in `/tmp/`:

```php
// rc.buddybackup.php: lines 728-735
$tmp_buddy_files = glob("/tmp/buddybackup-buddy*");
if (is_array($tmp_buddy_files)) {
    foreach ($tmp_buddy_files as $f) {
        @chown($f, 'buddybackup');
        @chgrp($f, 'buddybackup');
        @chmod($f, 0666);
    }
}
```

And in `mark_received_backup`:
```php
file_put_contents("/tmp/buddybackup-buddy-$matched_uid", $info);
@chmod("/tmp/buddybackup-buddy-$matched_uid", 0666);
```

#### Attack Scenario & Risk
1. `/tmp` on Linux is a sticky-bit world-writable directory (`drwxrwxrwt`). Any local user (including a compromised Docker container sharing `/tmp` or the restricted `buddybackup` user who has local command execution permissions) can create symlinks in `/tmp/`.
2. An unprivileged attacker creates a symlink:  
   `ln -s /etc/shadow /tmp/buddybackup-buddy-exploit`
3. When the Unraid administrator applies or saves incoming buddy settings in the WebGUI, `sync_incoming_buddies()` runs as `root`.
4. `glob("/tmp/buddybackup-buddy*")` matches `/tmp/buddybackup-buddy-exploit`.
5. In PHP, `chown()` and `chmod()` **follow symlinks** by default. Root executes:
   - `chown('/etc/shadow', 'buddybackup')`
   - `chmod('/etc/shadow', 0666)`
6. `/etc/shadow` is now world-writable (`0666`). The attacker can modify `/etc/shadow` to assign themselves a blank password or root password hash, achieving **Full Root Compromise**.
7. In addition, `/tmp/buddybackup-incoming.json` is written directly into `/tmp`. If an attacker creates a pre-existing symlink `/tmp/buddybackup-incoming.json -> /boot/config/passwd`, root's `file_put_contents` overwrites critical system files.

#### Remediation Instructions
1. **Never store plugin IPC or telemetry files directly in `/tmp`**. Use a dedicated, access-controlled directory under `/var/run/buddybackup` (or `/var/tmp/buddybackup`).
2. Have `setup_buddy_user` or plugin init create `/var/run/buddybackup` owned by `root:buddybackup` with restrictive permissions `0750` or `0770`:
   ```bash
   mkdir -p /var/run/buddybackup
   chown root:buddybackup /var/run/buddybackup
   chmod 0750 /var/run/buddybackup
   ```
3. Store `incoming.json` as `/var/run/buddybackup/incoming.json` and telemetry files as `/var/run/buddybackup/buddy-$uid`.
4. Delete the dangerous `glob("/tmp/buddybackup-buddy*")` loop entirely.
5. In PHP, verify that any destination file is not a symlink (`is_link($path)`) before operating on it.

---

### Finding SEC-02 (HIGH): Concurrency Race Condition & Missing File Lock on Snapshot-Triggered Backups

#### Vulnerability Description
In `src/usr/local/emhttp/plugins/buddybackup/scripts/rc.buddybackup` (added in commit `dcd0e85`):

```bash
# rc.buddybackup: line 425
# b. If trigger is set and not empty, invoke rc.buddybackup.php send_backup "<trigger_backup_uid>" in the background.
if [[ -n "${trigger_uid}" && "${trigger_uid}" != "no" ]]; then
    logger "Triggering backup task '${trigger_uid}' after snapshot of '${dataset}'" -t"${plugin}"
    ( "${empath}/scripts/rc.buddybackup.php" send_backup "${trigger_uid}" 2>&1 | "${empath}/scripts/log.sh" ) >/dev/null 2>&1 &
fi
```

#### Attack Scenario & Risk
1. In `rc.buddybackup.php`, cron-scheduled backups explicitly use `flock -n "/var/lock/buddybackup-$uid"`.
2. In contrast, `run_snapshot_post_hook_and_trigger` launches `send_backup` asynchronously without `flock`.
3. If a snapshot completes and triggers a backup at the same time a scheduled cron backup runs, or if two snapshot datasets trigger the same backup task, **multiple instances of Syncoid run concurrently** against the same ZFS datasets.
4. Concurrent `zfs send | zfs receive` streams targeting the same filesystem cause ZFS dataset lock collisions, broken replication streams (`cannot receive incremental stream: destination has been modified`), corrupted transfer state, and error alert spam on Unraid.

#### Remediation Instructions
1. Wrap the background triggered backup command in `flock -n "/var/lock/buddybackup-${trigger_uid}"`:
   ```bash
   if [[ -n "${trigger_uid}" && "${trigger_uid}" != "no" ]]; then
       logger "Triggering backup task '${trigger_uid}' after snapshot of '${dataset}'" -t"${plugin}"
       ( flock -n "/var/lock/buddybackup-${trigger_uid}" "${empath}/scripts/rc.buddybackup.php" send_backup "${trigger_uid}" 2>&1 | "${empath}/scripts/log.sh" ) >/dev/null 2>&1 &
   fi
   ```
2. Validate that `${trigger_uid}` contains only safe alphanumeric/hyphen characters (`^[A-Za-z0-9_-]+$`) before interpolation.

> [!NOTE]
> **Preserving Issue #25 Decoupling & Snapshot Timing**: The `flock -n` check is executed **inside the already-detached background subshell** `( flock -n ... ) &`.
> - It uses the non-blocking `-n` flag on an independent per-job lock file (`/var/lock/buddybackup-${trigger_uid}`).
> - It does **not** touch Sanoid's cron lock (`/var/lock/buddybackup-sanoid-cron`).
> - Because stdout/stderr are redirected to `/dev/null` and spawned in the background, Sanoid and `run_snapshot_post_hook_and_trigger` return within milliseconds, guaranteeing zero delay or missed windows for Sanoid's 1-minute ticker.

---

### Finding SEC-03 (HIGH): Shell Metacharacter Injection & Quote Fragility in `update_sanoid_conf`

#### Vulnerability Description
In `src/usr/local/emhttp/plugins/buddybackup/scripts/rc.buddybackup.php` (commit `dcd0e85`):

```php
// rc.buddybackup.php: lines 936-941
if ($post_hook !== '' && $trigger !== '') {
    $sanoid_conf_content .= "    force_post_snapshot_script = 1\n";
    $escaped_post_hook = addcslashes($post_hook, "\\\"$");
    $post_cmd = "$rc run_snapshot_post_hook_and_trigger \"$dataset\" \"$escaped_post_hook\" \"$hook_timeout\" \"$trigger\"";
    if ($hook_scope === 'daily') {
        $post_cmd .= " \"daily\"";
    }
    $sanoid_conf_content .= "    post_snapshot_script = $post_cmd\n";
}
```

#### Attack Scenario & Risk
1. Sanoid executes `post_snapshot_script` via Perl `system($script)`, which passes the string to `/bin/sh -c`.
2. `addcslashes($post_hook, "\\\"$")` escapes quotes, dollar signs, and backslashes, but **does not escape backticks** (`` ` ``). In `/bin/sh`, backticks inside double quotes `"echo `command`"` are still evaluated.
3. `$trigger` is directly interpolated without sanitization or validation. If an attacker controls or injects values into `snapshots.cfg`, commands can break out of the double quotes.
4. Furthermore, `run_snapshot_post_hook_and_trigger` in `rc.buddybackup` already has fallback logic to load `post_hook`, `hook_timeout`, and `hook_scope` from `snapshots.cfg` if they are not passed on the CLI. Passing raw hook command lines through `sanoid.conf` creates unnecessary shell-escaping risk.

#### Remediation Instructions
1. Validate `$trigger`:
   ```php
   if (!preg_match('/^[A-Za-z0-9_-]+$/', $trigger)) {
       $trigger = '';
   }
   ```
2. Use `build_shell_command()` or `escapeshellarg()` to safely quote all arguments placed into `post_cmd`, ensuring backticks and special shell characters cannot be interpreted:
   ```php
   $post_args = array($rc, 'run_snapshot_post_hook_and_trigger', $dataset, '', $hook_timeout, $trigger);
   if ($hook_scope === 'daily') {
       $post_args[] = 'daily';
   }
   $post_cmd = build_shell_command($post_args);
   ```
3. Allow `run_snapshot_post_hook_and_trigger` in `rc.buddybackup` to read the actual hook command directly from `snapshots.cfg` rather than passing raw shell script strings on the command line.

---

### Finding SEC-04 (MEDIUM): Cross-Buddy Destination Dataset Exposure in `probe_zfs`

#### Vulnerability Description
In `src/usr/local/emhttp/plugins/buddybackup/scripts/rc.buddybackup.php` (commit `df9482a` / `75e310d`):

```php
// rc.buddybackup.php: lines 247-268
if (is_array($incoming_cfg)) {
    $env_uid = getenv('BUDDY_UID') ?: ($_ENV['BUDDY_UID'] ?? '');
    if ($env_uid !== '' && isset($incoming_cfg[$env_uid]['destination_dataset'])) {
        $ds = trim($incoming_cfg[$env_uid]['destination_dataset']);
        if (is_valid_zfs_dataset_name($ds) && !in_array($ds, $datasets, true)) {
            $datasets[] = $ds;
        }
    }
    foreach ($incoming_cfg as $uid => $buddy) {
        if (($buddy['enable'] ?? '') === 'yes' && !empty($buddy['destination_dataset'])) {
            $ds = trim($buddy['destination_dataset']);
            if (is_valid_zfs_dataset_name($ds) && !in_array($ds, $datasets, true)) {
                $datasets[] = $ds;
            }
        }
    }
```

#### Attack Scenario & Risk
1. If `BUDDY_DATASET` is unset in the environment (e.g. unscoped incoming connections or direct probe calls), the code checks `$env_uid`.
2. However, there is no `return` statement or `else` branch after checking `$env_uid`. The code immediately proceeds to iterate through **all** configured buddies in `incoming_cfg` and appends their datasets to `$datasets`.
3. `probe_zfs` outputs:
   `{"status":"ok", "dataset":"...", "datasets":["disk1/alice", "disk1/bob_private", "disk1/charlie_vault"]}`
4. A connecting buddy calling `probe_zfs` over SSH receives a JSON array containing the private destination dataset names of every other buddy on the receiver (CWE-200 Information Disclosure).

#### Remediation Instructions
1. If `$env_uid` is provided and found, immediately return only that buddy's dataset(s):
   ```php
   if ($env_uid !== '' && isset($incoming_cfg[$env_uid]['destination_dataset'])) {
       $ds = trim($incoming_cfg[$env_uid]['destination_dataset']);
       if (is_valid_zfs_dataset_name($ds)) {
           return array($ds);
       }
   }
   ```
2. When `probe_zfs` returns an error (e.g. dataset outside allowed list), do NOT echo back `$all_datasets` to the remote caller.

---

### Finding SEC-05 (MEDIUM): Non-POSIX Bashisms in Sanoid Pre/Post Hook Filter Causing Snapshot Failures

#### Vulnerability Description
In `src/usr/local/emhttp/plugins/buddybackup/scripts/rc.buddybackup.php` (commit `dcd0e85`):

```php
// rc.buddybackup.php: lines 922 & 945
$pre_hook = '[ -n "${SANOID_TYPES:-}" ] && [[ "${SANOID_TYPES}" != *"daily"* ]] && exit 0; ' . $pre_hook;
...
$post_hook = '[ -n "${SANOID_TYPES:-}" ] && [[ "${SANOID_TYPES}" != *"daily"* ]] && exit 0; ' . $post_hook;
```

#### Attack Scenario & Risk
1. Sanoid executes `pre_snapshot_script` via Perl's `system()`, which runs through `/bin/sh -c`.
2. On generic hosts (Debian, Ubuntu, Proxmox, etc.) or systems where `/bin/sh` is `dash`, `[[ ... ]]` is unsupported syntax and produces `sh: 1: [[: not found` (exit code 127).
3. When `hook_failure_mode` is set to `'abort'` (`no_inconsistent_snapshot = 1`), Sanoid treats this syntax error as a hook failure and **aborts the snapshot**, halting all backups on the host.

#### Remediation Instructions
Replace the non-POSIX bashism with standard POSIX shell syntax:
```php
$daily_filter = '[ -n "${SANOID_TYPES:-}" ] && case "${SANOID_TYPES}" in *daily*) ;; *) exit 0;; esac; ';
```

---

### Finding SEC-06 (LOW): World-Readable Incoming Buddy Metadata in Public `/tmp`

#### Vulnerability Description
In `src/usr/local/emhttp/plugins/buddybackup/scripts/rc.buddybackup.php`:
```php
file_put_contents($tmp_incoming_json_path, json_encode($incoming_map, JSON_PRETTY_PRINT));
@chmod($tmp_incoming_json_path, 0644);
```
File is created world-readable (`0644`) in `/tmp/buddybackup-incoming.json`.

#### Remediation Instructions
Relocate to `/var/run/buddybackup/incoming.json` with permissions `0640` or `0600` owned by `root:buddybackup`.

---

### Finding SEC-07 (LOW): Telemetry Attribution Desynchronization on Shared Keys

#### Vulnerability Description
When multiple buddy configs share the same public key, `sync_incoming_buddies()` groups them into one `authorized_keys` line with `--uid $primary_uid`. If a received backup command cannot have its destination dataset matched from the command string, telemetry falls back to `$primary_uid`, leaving other jobs stale on the dashboard.

#### Remediation Instructions
Ensure dataset parsing in `restrict_zfs` is robust and matches against both full and sub-dataset patterns, falling back to all associated UIDs if necessary.

---

## Step-by-Step Implementation Plan

### Step 1: Secure Runtime Directory Setup
- Create `/var/run/buddybackup` directory in `setup_buddy_user` and `rc.buddybackup.php`.
- Set owner `root:buddybackup` and mode `0750`.
- Update `$tmp_recv_dataset_path`, `$tmp_incoming_json_path`, and telemetry paths from `/tmp/` to `/var/run/buddybackup/`.

### Step 2: Remove Wildcard Chown/Chmod
- In `rc.buddybackup.php::sync_incoming_buddies()`, remove `glob("/tmp/buddybackup-buddy*")` with `chown`/`chmod`.
- In `mark_received_backup()`, write telemetry files to `/var/run/buddybackup/buddy-$matched_uid` with mode `0660`.

### Step 3: Implement Locking for Async Triggered Backups
- In `rc.buddybackup::run_snapshot_post_hook_and_trigger()`, wrap background call in:
  `flock -n "/var/lock/buddybackup-${trigger_uid}"`

### Step 4: Fix Sanoid Hook Generation & Quoting
- In `rc.buddybackup.php::update_sanoid_conf()`:
  - Replace `[[ "${SANOID_TYPES}" != *"daily"* ]]` with POSIX `case "${SANOID_TYPES}" in *daily*) ;; *) exit 0;; esac;`.
  - Validate `$trigger` with `/^[A-Za-z0-9_-]+$/`.
  - Safely construct `$post_cmd` using `build_shell_command()` instead of string concatenation.

### Step 5: Fix Scoping & Cross-Buddy Leak in `read_receive_destination_datasets`
- In `rc.buddybackup.php::read_receive_destination_datasets()`:
  - Return immediately if `$env_uid` matches an incoming config entry.
  - In `probe_zfs()`, do not expose other buddies' datasets in error messages.

---

## Verification Plan

### Automated Tests
1. Run existing test suite: `prove -I deps t/` (must remain 100% passing).
2. Add new security regression tests in `t/security_audit_fixes.t`:
   - Test symlink attack resistance: create symlink in temp dir and verify `sync_incoming_buddies` does not follow or chmod target.
   - Test POSIX compliance of hook filtering under `sh`.
   - Test `probe_zfs` does not leak third-party datasets when querying with a specific UID.
   - Test concurrency locking on background triggers.

### Manual Verification
1. Run `testlab/scripts/scenario-multi-dataset.ps1` in testlab environment.
2. Verify telemetry attribution on Unraid dashboard.
3. Verify snapshot hooks execute properly during daily vs hourly snapshot cycles.
