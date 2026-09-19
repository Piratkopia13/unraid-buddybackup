# Pre-Release & Merge-to-Main Checklist

This document is the authoritative release checklist for **ZFS Buddy Backup**. Every step in this checklist must be completed and verified before merging changes from the `dev` branch into `main` and publishing a release tag.

---

## Overview of Release Workflow

```text
 ┌─────────────────────────────────────────────────────────────┐
 │ Phase 1: Code Quality, Hygiene & Security Audit             │
 │  • Dead code & complexity audit  • Static PHP/Shell lint    │
 │  • PII & credential scan         • Line endings & permissions│
 └──────────────────────────────┬──────────────────────────────┘
                                │
 ┌──────────────────────────────▼──────────────────────────────┐
 │ Phase 2: Comprehensive Testing & Verification               │
 │  • Unit test suite (t/*.t)       • Backwards compatibility  │
 │  • Testlab automated gate        • Write result history     │
 │  • Generic & TrueNAS smoke       • WebGUI theme & UI check  │
 └──────────────────────────────┬──────────────────────────────┘
                                │
 ┌──────────────────────────────▼──────────────────────────────┐
 │ Phase 3: Documentation & Changelog                          │
 │  • Update USER_GUIDE.md          • Refresh UI screenshots   │
 │  • Update <CHANGES> in .plg      • Draft GitHub release notes│
 └──────────────────────────────┬──────────────────────────────┘
                                │
 ┌──────────────────────────────▼──────────────────────────────┐
 │ Phase 4: Packaging & Version Bump                           │
 │  • Bump version in plg           • Build txz package        │
 │  • Verify & sync MD5 hash        • Commit & tag prep        │
 └──────────────────────────────┬──────────────────────────────┘
                                │
 ┌──────────────────────────────▼──────────────────────────────┐
 │ Phase 5: Merge, Tag, Release & In-The-Wild Sanity Check     │
 │  • Merge dev to main             • Push git tag             │
 │  • Publish GitHub Release        • Live install validation  │
 └─────────────────────────────────────────────────────────────┘
```

---

## Phase 1: Code Quality, Hygiene & Security Audit

Complete these static audits before running tests or provisioning VMs.

### 1.1 Dead Code & Obsolete Logic
- [ ] **Scan for unused PHP functions & variables**: Ensure all functions declared in `src/usr/local/emhttp/plugins/buddybackup/*.php` are actively used or exported for Unraid emhttp hooks.
- [ ] **Remove debug statements**: Ensure no stray `var_dump()`, `print_r()`, `console.log()`, `error_log()` debugging spam, or commented-out draft blocks exist in `src/`.
- [ ] **Clean up dependencies**: Verify that any binary or script in `deps/` is actively required. Remove orphaned helper scripts or temporary files.

### 1.2 Code Complexity & Quality
- [ ] **Review cyclomatic complexity**: Identify deeply nested conditionals or overly complex loops in `src/` (especially in `common.php`, `Backups.page`, and `BuddysBackupSettings.page`). Refactor into small, single-purpose helper functions where appropriate.
- [ ] **Consistent error handling**: Ensure all shell command invocations check exit codes and report clean, localized errors to the WebGUI instead of dumping raw stack traces or silent failures.
- [ ] **Simulated Dynamix template evaluation**: Confirm all `.page` files evaluate cleanly without warnings:
  ```powershell
  & "C:\Program Files\Git\usr\bin\perl.exe" t/php_syntax_and_eval.t
  ```
- [ ] **No raw unescaped ampersands**: Ensure XML headers in `.page` files do not contain unescaped `&` characters (must use `&amp;` where required by Unraid parser).

### 1.3 Personal Information (PII) & Secret Leak Prevention
- [ ] **No hardcoded credentials**: Verify zero hardcoded private keys, passwords, authentication tokens, or test SSH keys in the repository.
- [ ] **No personal or host paths**: Ensure files do not contain local developer paths (e.g., `C:\Users\...`, `/mnt/user/<user>/...`, `/home/<user>/...`).
- [ ] **No private IP addresses or hostnames**: Verify examples and test fixtures use dummy IPs (e.g., `192.0.2.x`, `127.0.0.1`) or standard RFC documentation addresses instead of real private LAN addresses.
- [ ] **Clean `.gitignore` enforcement**: Confirm that `.testlab/`, `testlab/config/lab.local.json`, and local transient logs are ignored and not staged:
  ```powershell
  git status --ignored
  ```

### 1.4 Line Endings (CRLF vs LF) & File Permissions
- [ ] **Unix line endings (`LF`)**: Shell scripts on Unraid fail immediately with `\r: command not found` if committed with Windows `CRLF`. Ensure all files in `src/` have Unix `LF` line endings:
  ```powershell
  Get-ChildItem -Path src -Recurse -File | ForEach-Object {
      $content = [System.IO.File]::ReadAllText($_.FullName)
      if ($content.Contains("`r`n")) {
          Write-Warning "CRLF found in $($_.FullName)"
      }
  }
  ```
- [ ] **Executable permissions (`0755`)**: Verify executable bits on shell/perl scripts in `src/usr/local/emhttp/plugins/buddybackup/`:
  - `deps/restrict_zfs`
  - `deps/generic_host_setup.sh`
  - `deps/sanoid`
  - `deps/syncoid`
  - `scripts/rc.buddybackup`

---

## Phase 2: Comprehensive Testing & Verification

### 2.1 Automated Unit & TAP Suite (`t/*.t`)
- [ ] **Run all TAP tests**: Run the complete unit and integration test suite:
  ```powershell
  # Run natively with Windows / Git Perl:
  ./testlab/scripts/run-unit-tests.ps1

  # Or run inside WSL (exercises full PHP evaluation):
  ./testlab/scripts/run-unit-tests.ps1 -UseWsl
  ```
  Verify all of the following test files pass without failures:
  - `t/restrict_zfs.t`: Strict allowlist parsing, command injection defense, and privilege escalation guards.
  - `t/restrict_zfs_scope.t`: Dataset scope boundaries and path traversal rejection.
  - `t/generic_host_setup.t`: Remote host setup script behavior, argument parsing, and state files.
  - `t/generic_host_setup_truenas.t`: TrueNAS SCALE specific sudo and allowlist path behaviors.
  - `t/php_syntax_and_eval.t`: PHP syntax check (`php -l`), `.page` template evaluation, and telemetry keys.
  - `t/multi_buddy.t`: Multi-buddy key handling and configuration parsing.
  - `t/backwards_compat.t`: Protocol and CLI backwards compatibility across versions.
- [ ] **New code test coverage**: Ensure any newly introduced feature or bug fix includes an accompanying test in `t/`.

### 2.2 Automated Testlab Release Gate
- [ ] **Run release gate in Execute mode**:
  ```powershell
  ./testlab/scripts/run-release-gate.ps1 -LabConfig testlab/config/lab.local.json -MatrixProfile release-default -Execute
  ```
- [ ] **Verify preflight checks**:
  - Clean git worktree requirement satisfied (no uncommitted or untracked changes).
  - Version bump requirement satisfied (`buddybackup.plg` version > `previousReleaseVersion`).
- [ ] **Verify matrix scenarios pass**:
  - `base-setup-verify`: Plugin installed, zpool present, encrypted & unencrypted datasets active.
  - `fresh-install`: Clean install succeeds without emhttp warnings.
  - `upgrade-preserves-config`: Upgrading in-place from previous release retains backup jobs, SSH state, receiver mode, and advanced settings.
  - `backup-smoke` & `restore-smoke`: Bidirectional remote and local backups pass; snapshot listing and dataset restoration verified.
  - `post-reboot`: Nodes reboot cleanly; settings, datasets, and WebGUI authentication persist across reboot.
- [ ] **Write & Verify Result File**:
  - Verify run manifest stored in durable host storage: `%LOCALAPPDATA%\BuddyBackup\TestlabHistory/<run-id>/`
  - Verify public history summary updated in [`testlab/release-history/README.md`](file:///y:/testlab/release-history/README.md) and [`testlab/release-history/index.json`](file:///y:/testlab/release-history/index.json).

### 2.3 Backwards Compatibility
- [ ] **Older Sender → Newer Receiver**: Verify an older BuddyBackup version can push backups to the candidate release without protocol or allowlist rejection.
- [ ] **Newer Sender → Older Receiver**: Verify the candidate release can push backups to an older BuddyBackup receiver.
- [ ] **Configuration Migration**: Verify configuration written by older releases loads seamlessly without loss of settings.

### 2.4 Generic Host & TrueNAS SCALE Verification
- [ ] **Generic OpenZFS host smoke**: Run the generic smoke test against `nodeC`:
  ```powershell
  ./testlab/scripts/run-generic-smoke.ps1 -LabConfig testlab/config/lab.local.json -Execute
  ```
- [ ] **TrueNAS SCALE manual validation**: If changes touch `generic_host_setup.sh`, allowlist scoping, sudo mode, or generic host UI, complete all checks in [`testlab/MANUAL-SCALE-CHECKLIST.md`](file:///y:/testlab/MANUAL-SCALE-CHECKLIST.md):
  - Setup command generation & execution on TrueNAS SCALE.
  - Persistent allowlist location verified (`/mnt/<pool>/.buddybackup/`).
  - TrueNAS UI configuration (SSH service Auxiliary Parameters, user sudo commands).
  - Push smoke: Unraid → TrueNAS.
  - Replication smoke: TrueNAS SCALE native replication task → Unraid (Retention = None, Sudo = Disabled).
  - Teardown & grant change checks (`--revoke`, `--clean`).
  - Negative security checks (blocked commands, non-allowlisted datasets rejected).

### 2.5 WebGUI Theme & Visual Inspection
- [ ] **Theme compatibility**: Inspect the BuddyBackup WebGUI under both Unraid themes:
  - **White (light) theme**: Verify contrast, table borders, status badges, and input text visibility.
  - **Black (dark) theme**: Verify no blinding white boxes, text readability, and icon rendering.
- [ ] **Unraid OS version UI styling**: Verify rendering across Unraid 6.12.x and Unraid 7.x Dynamix layouts.
- [ ] **Browser console**: Open browser developer tools; confirm zero JavaScript errors or 404 missing asset warnings.
- [ ] **Interactive form actions**:
  - Test connection button on newly entered (unsaved) entries vs existing saved entries.
  - Snapshot creation and manual "Send backup now" button flows.
  - Restore wizard modal navigation and dataset selector dropdowns.

---

## Phase 3: Documentation & Changelog

### 3.1 User Guide & Screenshots
- [ ] **Update [`docs/USER_GUIDE.md`](file:///y:/docs/USER_GUIDE.md)**: Document any new features, configuration options, changed UI labels, or revised operational recommendations.
- [ ] **Refresh screenshots**: If UI layouts or tabs were modified, capture new screenshots from the live testlab nodes and update images in `docs/` or embedded media.
- [ ] **Update [`README.md`](file:///y:/README.md)**: Keep feature summaries, requirements, and compatibility tables up to date.

### 3.2 Changelog Authoring
- [ ] **Update `<CHANGES>` in [`buddybackup.plg`](file:///y:/buddybackup.plg)**: Unraid's Plugin Manager displays this XML block directly to users when checking for updates. Add a new section at the top with the release version:
  ```xml
  ###YYYY.MM.DD
  - Concise bullet points of user-facing features, enhancements, and bug fixes
  - Mention any breaking changes or required manual actions
  ```
- [ ] **Draft GitHub Release notes**: Prepare release highlights, detailed changelog, and thank-yous for community issue reporters.

---

## Phase 4: Packaging & Release Preparation

### 4.1 Version Bump
- [ ] **Set release version**: Update the `version` entity in [`buddybackup.plg`](file:///y:/buddybackup.plg):
  ```xml
  <!ENTITY version      "YYYY.MM.DD">
  ```
  *(If releasing multiple builds in a single day, append a letter suffix, e.g. `2026.09.19a`).*

### 4.2 Build Package & Synchronize MD5
- [ ] **Package `buddybackup.txz`**: Build the release archive from `src/`. Ensure owner is `root:root` and file permissions are preserved.
- [ ] **Calculate & update MD5**: Calculate the MD5 hash of `buddybackup.txz` and update `pkgMD5` in [`buddybackup.plg`](file:///y:/buddybackup.plg):
  ```xml
  <!ENTITY pkgMD5        "<calculated-md5-hash>">
  ```
- [ ] **Verify checksum match**:
  ```powershell
  $actualMd5 = (Get-FileHash -Path "buddybackup.txz" -Algorithm MD5).Hash.ToLower()
  Write-Host "Package MD5: $actualMd5"
  ```
  Confirm that `buddybackup.plg` contains this exact hash string.

### 4.3 Git State Verification
- [ ] **Review git diff**: Ensure only intended files are modified.
  ```powershell
  git status
  git diff
  ```
- [ ] **Commit release preparation**: Commit the version bump, changelog, and plg updates:
  ```bash
  git commit -am "Prepare YYYY.MM.DD release"
  ```

---

## Phase 5: Merge, Tag, Release & In-The-Wild Sanity Check

### 5.1 Merge `dev` to `main`
- [ ] **Rebase or merge `dev` into `main`**:
  ```bash
  git checkout main
  git pull origin main
  git merge dev --ff-only   # or clean merge commit
  git push origin main
  ```

### 5.2 Git Tag Creation & Push
- [ ] **Tag the release**:
  ```bash
  git tag -a YYYY.MM.DD -m "Release YYYY.MM.DD"
  git push origin YYYY.MM.DD
  ```

### 5.3 GitHub Release Publishing
- [ ] **Trigger workflow**: The tag push triggers [`.github/workflows/create_release.yml`](file:///y:/.github/workflows/create_release.yml), which drafts a release with `buddybackup.plg`.
- [ ] **Upload `buddybackup.txz`**: Attach the built `buddybackup.txz` archive to the GitHub release draft.
- [ ] **Publish release**: Paste the changelog into the release description and publish the release.

### 5.4 Live In-The-Wild Sanity Check
- [ ] **Test install from public URL**: On a clean test Unraid server or testlab node, run:
  ```bash
  plugin install https://raw.githubusercontent.com/Piratkopia13/unraid-buddybackup/refs/heads/main/buddybackup.plg
  ```
- [ ] **Verify live installation**:
  - Confirm `buddybackup.plg` downloads without SSL or HTTP errors.
  - Confirm `buddybackup.txz` downloads and matches the MD5 hash.
  - Confirm package extracts cleanly with zero emhttp warnings or errors.
  - Confirm BuddyBackup appears immediately in Unraid's **Settings** menu and the dashboard panel loads.

---

## Release Sign-Off Checklist Summary

| Step | Area | Responsible / Tool | Status |
| :--- | :--- | :--- | :---: |
| 1 | Dead code, complexity & secret check | Static analysis / code review | [ ] |
| 2 | Line endings (LF) & permissions (0755) | `Get-ChildItem` check | [ ] |
| 3 | TAP Unit Test Suite (`t/*.t`) | `run-unit-tests.ps1` | [ ] |
| 4 | Testlab Automated Gate & History | `run-release-gate.ps1 -Execute` | [ ] |
| 5 | TrueNAS manual validation | `MANUAL-SCALE-CHECKLIST.md` | [ ] |
| 6 | WebGUI Light & Dark theme review | Browser / DevTools inspection | [ ] |
| 7 | User guide & screenshots updated | `docs/USER_GUIDE.md` | [ ] |
| 8 | Changelog written in `.plg` & GitHub | `buddybackup.plg` `<CHANGES>` | [ ] |
| 9 | Version bumped & MD5 synchronized | `buddybackup.plg` & `txz` | [ ] |
| 10 | Merged to `main` and tagged | `git tag YYYY.MM.DD` | [ ] |
| 11 | GitHub release published with `.txz` | GitHub Releases | [ ] |
| 12 | Live test install from GitHub URL | `plugin install <url>` on Unraid | [ ] |
