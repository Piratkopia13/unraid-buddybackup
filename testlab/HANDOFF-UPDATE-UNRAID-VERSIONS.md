# Handoff: Updating Testlab Unraid Versions (Tracking Latest Unraid Release)

## Purpose & Goal
Update the BuddyBackup testlab environment (`testlab/`) so that at least one local QEMU/WSL test node runs the latest available Unraid release (e.g., Unraid 7.3.4+) while preserving backwards-compatibility testing against earlier supported versions (e.g., 7.2.6).

---

## Background & Incident Context (Why This Is Needed)

### The Issue That Slipped Through
After upgrading to **Unraid 7.3.4**, receiver nodes running BuddyBackup failed incoming SSH replications from buddies (such as TrueNAS or remote Unraid instances) with:
```text
failed: Authentication failed..
```
Unraid syslog reported:
```text
sshd-session[3464523]: User buddybackup not allowed because account is locked
```

### Technical Root Cause
1. **OpenSSH 9.8+ Strict Account Validation**:
   Unraid 7 upgraded to OpenSSH 9.8+ (introducing the `sshd-session` binary split). In `auth.c`, OpenSSH evaluates `platform_locked_account()` against `/etc/shadow`. If the password field begins with `!` or `*`, OpenSSH immediately denies the connection during preauth—even when valid SSH public keys are configured in `authorized_keys`.
2. **Ephemeral Rootfs Account Restoration**:
   On reboot, Unraid's `/etc/rc.d/rc.S.cont` restores user accounts from `/boot/config/passwd` and `/boot/config/shadow`, invoking `/usr/sbin/pwconv`. Non-root accounts without Linux shell passwords receive `!` or `!!` in `/etc/shadow`.
3. **Silent Failure in `usermod -U`**:
   BuddyBackup's post-reboot repair logic ([`setup_buddy_user`](file:///y/src/usr/local/emhttp/plugins/buddybackup/scripts/rc.buddybackup#L816-L860)) ran `usermod -U buddybackup` to unlock the account. However, standard Linux shadow utilities **refuse** to unlock an account whose password is `!` or `!!` without an existing hash (`usermod: unlocking the user's password would result in a passwordless account. You should set a password with usermod -p...`). With stderr redirected to `/dev/null`, the account remained locked in `/etc/shadow`.
4. **Resolution in Commit `0cf6117`**:
   [`src/usr/local/emhttp/plugins/buddybackup/scripts/rc.buddybackup`](file:///y/src/usr/local/emhttp/plugins/buddybackup/scripts/rc.buddybackup#L838-L856) now explicitly sets an unguessable password string via `usermod -p` during post-reboot repair, clearing the `!` lock marker and syncing the entry to `/boot/config/shadow`.

### Why the Testlab Missed It
- The testlab had `nodeA` pinned to `7.2.6` and `nodeB` to `7.3.0`.
- In `Scenario-PostReboot.ps1` and `UnraidLifecycle.ps1`, the receiver readiness check only verified `grep -q '^buddybackup:' /etc/shadow` without attempting an actual SSH public-key login as user `buddybackup` post-reboot.

---

## Action Items for the Testlab Update Agent

### 1. Update Testlab Configuration & Version Inventory
- In [`testlab/config/lab.example.json`](file:///y/testlab/config/lab.example.json) and [`testlab/config/lab.local.json`](file:///y/testlab/config/lab.local.json):
  - Add download URL mapping for Unraid 7.3.4 (or latest stable) under `downloadUrls`.
  - Update `nodes.nodeB.unraidVersion` to `7.3.4` (or latest).
  - Update `releaseGate.latestSupportedUnraidVersion` to `7.3.4`.
  - Maintain `nodes.nodeA.unraidVersion` at `7.2.6` (or `previousCertifiedUnraidVersion`) for mixed-version pair testing.

### 2. Verify Extraction & WSL/QEMU Caching
- Ensure the image downloader and extraction pipeline (`testlab/scripts/provision-wsl-qemu-lab.ps1` / `UnraidLifecycle.ps1`) cleanly downloads, extracts, and caches `bzimage`, `bzroot`, `bzmodules`, and `bzfirmware` for the new release.
- Verify that ZFS kernel modules packaged with the new Unraid version load cleanly in the QEMU guest.

### 3. Strengthen Post-Reboot Verification in Scenarios
- In [`testlab/scenarios/Scenario-PostReboot.ps1`](file:///y/testlab/scenarios/Scenario-PostReboot.ps1) and [`testlab/modules/TestLab.Guest/UnraidLifecycle.ps1`](file:///y/testlab/modules/TestLab.Guest/UnraidLifecycle.ps1):
  - Ensure receiver validation doesn't just check if `buddybackup` exists in `/etc/shadow`, but verifies that the password field does **not** begin with `!` or `*`:
    ```bash
    awk -F: '$1=="buddybackup" { exit ($2 ~ /^!|^\*/) ? 1 : 0 }' /etc/shadow
    ```
  - Ideally execute a real SSH probe using the sender's identity against `buddybackup@nodeB`.

### 4. Run Test Suite & Release Gate Validation
- Execute unit and lifecycle tests:
  ```powershell
  Invoke-Pester -Path testlab/tests/Core.Tests.ps1
  Invoke-Pester -Path testlab/tests/Guest.Tests.ps1
  ```
- Run a targeted testlab probe or smoke run against the upgraded node:
  ```powershell
  .\testlab\scripts\probe-wsl-qemu-unraid.ps1 -InstanceName probe -PayloadPath .testlab/cache/unraid-7.3.4-extracted
  ```

---

## Key Files Reference
- `testlab/config/lab.example.json` & `testlab/config/lab.local.json`
- `testlab/scripts/provision-wsl-qemu-lab.ps1`
- `testlab/modules/TestLab.Guest/UnraidLifecycle.ps1`
- `testlab/scenarios/Scenario-PostReboot.ps1`
- `src/usr/local/emhttp/plugins/buddybackup/scripts/rc.buddybackup` (Commit `0cf6117`)
- `t/reboot_receiver_user_repair.t`
