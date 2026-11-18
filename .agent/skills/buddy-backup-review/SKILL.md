---
name: buddy-backup-review
description: >-
  Reviews and fixes up code changes in BuddyBackup—whether local uncommitted changes, staged changes,
  the last commit, a specific commit or commit range, a branch diff, or specific files. Use when the
  user asks to review, audit, clean up, or verify changes in this repository, ensuring simplicity,
  correctness, backward compatibility, and strict backup data safety and security.
---

# BuddyBackup Change Review & Fix-Up

> [!IMPORTANT]
> **Safety & Data Integrity First**
> BuddyBackup runs with root privileges, manages ZFS datasets and snapshots, handles SSH keys, and executes remote shell commands. Preventing accidental data loss, unintended dataset/snapshot destruction, privilege escalation, and command injection is the highest priority.

This skill defines how to review any requested set of changes in the BuddyBackup repository, directly fix clear issues, preserve existing functionality, and escalate non-obvious decisions to the user.

---

## 1. Resolve Target Change Scope

Determine what the user wants reviewed before inspecting files:

| User Request | Commands to Inspect Scope |
| :--- | :--- |
| **Local changes** *(default if unspecified)* | `git status --short`, `git diff`, `git diff --cached` (also read any untracked files). If the worktree is clean, fall back to the last commit (`git show HEAD`). |
| **Last commit** | `git show HEAD` / `git diff HEAD~1..HEAD` |
| **Specific commit or range** | `git show <sha>` or `git diff <base>..<head>` |
| **Specific branch** | `git diff <base-branch>...<target-branch>` (e.g., `main...dev` or `dev...HEAD`) |
| **Specific files or paths** | Scope `git diff` / `git show` and file reads to the named paths |

Always read the surrounding functions, callers, and state flow in each modified file—never review diff hunks in isolation.

---

## 2. Review Pillars

Evaluate every change against these four pillars:

### 2.1 Simplicity & Correctness
- **Simplest correct solution**: Check whether the change is as simple and direct as possible without sacrificing correctness. Simplify over-engineered abstractions, redundant conditionals, duplicated logic, dead code, or leftover debug statements (`var_dump`, `print_r`, `console.log`, stray `error_log`).
- **Edge cases & failure handling**: Check handling of empty/missing configuration keys, spaces or special characters in dataset/snapshot names, subprocess non-zero exit codes, timeouts, and partial failures.
- **External Vendor Dependencies Policy (`AGENTS.md`)**: Verify zero modifications were made inside upstream vendor files:
  - `src/usr/local/emhttp/plugins/buddybackup/deps/sanoid`
  - `src/usr/local/emhttp/plugins/buddybackup/deps/syncoid`
  - `src/usr/local/emhttp/plugins/buddybackup/deps/sanoid.defaults.conf`
  - `deps/*`
  Any customizations or fixes must live in BuddyBackup's own scripts, wrappers, `.php`, or `.page` files.

### 2.2 Safety & Security (Highest Priority)
- **Data Loss Prevention & Destructive Operations**:
  - Scrutinize any `zfs destroy`, `zfs rollback`, `syncoid --force-delete`, dataset mount/unmount, snapshot pruning, or file deletion paths.
  - Ensure strict dataset scope checks, non-destructive defaults, and fail-safe abort behavior on errors so user backup data can never be unintentionally destroyed or overwritten.
- **Command Injection & Shell Escaping**:
  - Verify all untrusted or dynamic values passed to shell execution (`exec`, `shell_exec`, `passthru`, `proc_open`, SSH remote commands, bash/perl scripts) use `escapeshellarg()`, strict regex whitelisting, or argument arrays.
- **Privilege & Boundary Enforcement**:
  - Check `deps/restrict_zfs` allowlist rules and `deps/generic_host_setup.sh` scoping (including TrueNAS SCALE paths).
  - Verify path traversal guards (rejecting `..` or out-of-scope datasets), SSH private key permissions (`0600`), and ensure private keys/secrets never leak into logs or WebGUI markup.
- **WebGUI Security**:
  - Verify HTML output escaping (`htmlspecialchars`) and input validation/sanitization across `.page`, `api.php`, `common.php`, and `restore_wizard.php`.

### 2.3 Existing Functionality & Backward Compatibility
- **No regressions**: Verify existing WebGUI workflows, CLI actions, cron schedules, Sanoid/Syncoid hooks, and error reporting remain intact.
- **Cross-version interoperability**:
  - **Older sender -> newer receiver**: Receiver `restrict_zfs` allowlists must keep accepting legacy command patterns.
  - **Newer sender -> older receiver**: New remote commands or flags must have graceful fallback paths.
- **In-place config upgrades**: Existing INI/JSON config files written by older versions must load without losing jobs, buddies, or settings, applying safe defaults when new keys are absent.

### 2.4 Platform & Repository Hygiene
- **Line endings**: All files under `src/` and `t/` must use Unix `LF` line endings (never Windows `CRLF`, which breaks scripts on Unraid with `\r: command not found`).
- **Unraid `.page` validity**: XML/INI headers in `.page` files must not contain raw unescaped `&` characters and must evaluate cleanly under the Dynamix parser test.
- **No PII or local paths**: No hardcoded credentials, personal host paths, or real private LAN IPs.

---

## 3. Action Policy: Fix Directly vs. Ask the User

- **Fix directly in the working tree**:
  - Clear bugs, logic flaws, edge-case failures, or broken error handling.
  - Safety or security gaps (missing `escapeshellarg`, missing validation, overly broad destructive paths, unescaped UI output).
  - Needless complexity, dead/debug code, or duplicated logic introduced by the change.
  - `CRLF` line endings in `src/` or `t/`, or missing test coverage for bug fixes/security guards.
  - *Never commit, push, or open a PR unless the user explicitly asks.*
- **Ask the user instead of guessing**:
  - Ambiguous intent or unclear requirements.
  - Decisions affecting user-visible UI/CLI behavior, defaults, or retention/destruction policies where multiple valid designs exist.
  - Architectural trade-offs or changes that might intentionally alter backward compatibility.
  - Use `ask_question` for discrete choices or concise direct questions for open-ended decisions.

---

## 4. Verification & Testing

After reviewing and applying any fixes, run the relevant automated checks against the actual files:

1. **Targeted TAP tests** (run matching tests in `t/`):
   ```powershell
   & "C:\Program Files\Git\usr\bin\perl.exe" t/php_syntax_and_eval.t
   ```
   Run security/compatibility/feature-specific tests as applicable (`t/restrict_zfs.t`, `t/restrict_zfs_scope.t`, `t/generic_host_setup.t`, `t/generic_host_setup_truenas.t`, `t/backwards_compat.t`, `t/security_audit_fixes.t`, `t/multi_buddy.t`, etc.).
2. **Full unit test suite** (when changes span core scripts, hooks, or multiple modules):
   ```powershell
   powershell -ExecutionPolicy Bypass -File ./testlab/scripts/run-unit-tests.ps1
   ```
   *(Add `-UseWsl` when full PHP evaluation inside WSL is needed and available.)*
3. **Regression tests**: Whenever you uncover and fix a bug or security gap, add or update a test in `t/*.t` to prevent regressions.

---

## 5. Review Output Structure

Keep the final report concise and factual (citing only observed files, symbols, and command results):
1. **Scope Reviewed**: Commit, branch diff, or local files inspected.
2. **Findings & Fixes Applied**: Issues identified and fixed (with file links) and any simplifications made.
3. **Verification**: Exact test commands run and their results.
4. **Decisions Needed** *(if any)*: Non-obvious questions or trade-offs awaiting user direction.
