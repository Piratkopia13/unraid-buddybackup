# Testlab Architectural Refactoring & Reliability Plan

**Date**: October 18, 2026  
**Target System**: BuddyBackup Testlab (`testlab/`)  
**Status**: Phase 1 Completed & Verified | Handoff-Ready for Phases 2–4  
**Fast Harness Test**: `./testlab/tests/Run-HarnessTests.ps1`  

---

## 1. Executive Summary & Problem Diagnosis

The BuddyBackup testlab is a test automation environment supporting multi-node QEMU virtualization under WSL, fixed Unraid versions, generic OpenZFS targets, bidirectional syncoid replication, and pre-release gate enforcement.

Over multiple iterations, the testlab grew into a collection of tightly coupled, massive monolithic scripts (**over 13,600 lines of PowerShell** across ~20 loose scripts), with the single largest script (`run-matrix.ps1`) exceeding **3,300 lines**.

### The "Complexity Spiral"
When an engineer or AI agent attempted to fix an intermittent failure:
1. **Context Saturation**: Inspecting a failure required reading thousands of lines across multiple files, frequently exceeding context limits or obscuring downstream dependencies.
2. **Hidden Duplication**: Critical logic (SSH transport, bash quoting, plugin installation, retry loops, boot detection) was copy-pasted across 6+ separate files with subtle behavioral divergences. A fix applied in one place did not propagate to others, or introduced conflicting behavior.
3. **No Isolated Execution**: Test scenarios (`post-reboot`, `fresh-install`, `upgrade-preserves-config`) were hardcoded directly into the giant matrix loop. They could not be executed, inspected, or debugged in isolation without running the entire matrix.
4. **Zero Harness Tests**: There were zero automated unit tests for the testlab scripts themselves. Changes to remote command escaping, manifest parsing, or timeout math were tested only through a 15-minute live VM run.

---

## 2. Root Cause Analysis & Phase 1 Hotfixes Applied

The immediate flakiness issues reported have been resolved and verified with automated regression tests:

### Issue A: Remote Shell Syntax Error in Settle Check (RESOLVED)
* **Root Cause**: In `run-matrix.ps1` and `provision-wsl-qemu-lab.ps1`, `Convert-ToRemoteShellCommand` only encoded commands in Base64 if the string contained newline characters (`[`r`n]`). Because the settle check was written as a single-line command with double quotes (`awk "{print int(\$1)}"`), Windows command line argument splitting stripped the double quotes before sending the argument to SSH. Remote bash received unquoted syntax where `(` inside `$(awk {print int($1)} ...)` triggered an immediate syntax error.
* **Fix Applied**:
  1. Updated `Convert-ToRemoteShellCommand` in both `run-matrix.ps1` and `provision-wsl-qemu-lab.ps1` to Base64-encode any command containing shell metacharacters (`[\r\n\"''\$\(\)\{\}\;\|\&\<\>\`\\]`). This guarantees that quotes, subshells, awk scripts, and variables are delivered byte-for-byte without Windows CLI quote mangling.
  2. Simplified the settle command to use `cut -d. -f1 /proc/uptime` instead of awk, removing all quote and parenthesis nesting.

### Issue B: SSH Drop During Settle and Settle Timeout (RESOLVED)
* **Root Cause**: Unraid starts `sshd` early in boot, but shortly afterward `emhttpd` triggers delayed background service reloads (`reload_services`), which can bounce network interfaces and restart daemons. `run-matrix.ps1` contained two duplicate, conflicting settle blocks (lines 1327–1344 and 1354–1368) with an aggressive 60s timeout, causing premature test aborts when SSH bounced during the reload.
* **Fix Applied**:
  1. Deduplicated the settle logic in `Wait-ForRebootCycle`: settle now runs once, deterministically, **before** any `$ReadyCommand` is executed.
  2. Increased the recovery timeout to `[Math]::Max($TimeoutSeconds, 120)` (minimum 120s) to give Unraid adequate time to finish service restarts.
  3. Guarded `run-matrix.ps1` with `if ($MyInvocation.InvocationName -ne '.')` so that helper functions can be imported/tested without unintentionally triggering the full matrix run.

### Issue C: SMB / Network Share Path Sensitivity (RESOLVED)
* **Root Cause**: The workspace is hosted on an SMB network share (`Y:\ -> \\192.168.0.40\sonic\buddybackup_plugin`). In Windows PowerShell 5.1, `Get-Content -Raw -Path ...` on network shares can trigger Win32 Error 87 (`ERROR_INVALID_PARAMETER`) due to opportunistic lock conflicts or memory-mapped file stream caching.
* **Fix Applied**:
  1. Updated `Get-TestLabPluginDisplayVersion` in `testlab/scripts/testlab-plugin-source.ps1` to use `Resolve-Path -LiteralPath` and `.NET` `[System.IO.File]::ReadAllText(..., [System.Text.Encoding]::UTF8)`.
  2. Verified manifest parsing returns valid display versions (`2026.10.18`) consistently.

### Issue D: Absence of Harness Unit Tests (RESOLVED)
* **Fix Applied**: Created `testlab/tests/Run-HarnessTests.ps1`.
* It runs in **< 2 seconds** and validates:
  - Manifest reading on SMB shares.
  - Base64 encoding of shell metacharacters and nested quotes.
  - Remote bash syntax validation inside WSL.
  - JSON parsing of lab and matrix configuration files.
* **Result**: `5 Total | 5 Passed | 0 Failed`.

---

## 3. Target Modular Architecture (5 Layers)

```mermaid
flowchart TD
    subgraph Layer5["Layer 5: Orchestrators & Entrypoints (Lean Scripts < 350 lines)"]
        RG[run-release-gate.ps1]
        RM[run-matrix.ps1]
        PL[provision-lab.ps1]
        TL[teardown-lab.ps1]
    end

    subgraph Layer4["Layer 4: Standalone Test Scenarios (Independently Runnable CLI)"]
        S_Fresh[Scenario-FreshInstall.ps1]
        S_Reboot[Scenario-PostReboot.ps1]
        S_Upgrade[Scenario-UpgradePreservesConfig.ps1]
        S_Multi[Scenario-MultiDataset.ps1]
        S_Smoke[Scenario-FunctionalSmoke.ps1]
        S_Generic[Scenario-GenericSmoke.ps1]
    end

    subgraph Layer3["Layer 3: Guest & Domain Management Modules"]
        M_Unraid[TestLab.Unraid<br/>Reboot protocol, settle, emhttp readiness]
        M_Plugin[TestLab.Plugin<br/>Package .txz, install, verify, manifest parser]
        M_Zfs[TestLab.Zfs<br/>Pool & dataset management, encryption, snapshots]
    end

    subgraph Layer2["Layer 2: Transport & Remote Shell (Single Canonical Source)"]
        M_Transport[TestLab.Transport<br/>Invoke-RemoteBash (100% Base64 safe)<br/>SCP file transfer, Wait-Until polling, connection pool]
    end

    subgraph Layer1["Layer 1: Core Foundation & Platform"]
        M_Core[TestLab.Core<br/>Logging, SMB-safe File I/O, Config parser & validation]
        M_Platform[TestLab.Platform<br/>WSL root execution, QEMU VM manager, NAT & port router]
    end

    Layer5 --> Layer4
    Layer5 --> Layer3
    Layer4 --> Layer3
    Layer3 --> Layer2
    Layer4 --> Layer2
    Layer2 --> Layer1
```

---

## 4. Architectural Separation of Concerns

### Layer 1: Core Foundation & Platform
* **`testlab/modules/TestLab.Core/`**:
  * `Logging.ps1`: Standardized timestamps, color coding, heartbeat tickers (`Write-TestLabHeartbeat`).
  * `FileSystem.ps1`: `Read-TestLabTextFile`, `Write-TestLabTextFile` with `[System.IO.File]::ReadAllText/WriteAllText` and `FileShare.ReadWrite`.
  * `Config.ps1`: `Get-TestLabConfig`, `Resolve-TestLabPath`, JSON schema validation, node naming normalization (`nodeA` $\leftrightarrow$ `buddybackup-node-a`).
* **`testlab/modules/TestLab.Platform/`**:
  * `WslProvider.ps1`: WSL execution, distro resolution, path conversion (`Convert-WindowsPathToWslPath`).
  * `QemuVmManager.ps1`: QEMU process startup, pid tracking, shutdown, health probes.
  * `NetworkManager.ps1`: Port availability probes, port forwards, host DNAT rules.

### Layer 2: Transport & Remote Execution (`TestLab.Transport`)
* **Single Source of Truth for SSH**:
  * Retire the 6 duplicate SSH runners in favor of:
    ```powershell
    Invoke-RemoteBash -NodeConnection $node -BashScript $script [-Arguments $args] [-DoExecute]
    Invoke-RemoteUpload -NodeConnection $node -LocalPath $path -RemotePath $remotePath [-DoExecute]
    Wait-UntilReady -ProbeScriptBlock { ... } -TimeoutSeconds 120 -IntervalSeconds 3
    ```
  * All multi-character commands and scripts are delivered Base64-encoded to prevent Windows CLI quote stripping.

### Layer 3: Guest & Domain Management (`TestLab.Guest`)
* **`UnraidLifecycle.ps1`**:
  * Encapsulates `Wait-ForRebootCycle`:
    1. Wait for host to drop (`Wait-SshUnavailable`).
    2. Wait for host to reconnect and verify `boot_id` has changed.
    3. Settle phase: Poll until `reload_services` is NOT running, `emhttpd` is alive, and the zpool is accessible.
    4. Verify SSH stability with consecutive pings across a recovery window (min 120s).
* **`PluginManager.ps1`**:
  * Local package compilation: `New-TestLabWorkspacePackage` (`buddybackup.txz`).
  * Remote staging and installation: `Install-TestLabPlugin`.
  * Manifest reading: `Get-TestLabPluginDisplayVersion`.
* **`ZfsManager.ps1`**:
  * Dataset creation (plain and encrypted), pool verification, snapshot listing, syncoid receiver delegation.

### Layer 4: Independent Test Scenarios (`testlab/scenarios/`)
Every test scenario is an independently executable script taking standard parameters:
* `Scenario-FreshInstall.ps1 -LabConfig <path> [-Execute]`
* `Scenario-PostReboot.ps1 -LabConfig <path> [-Execute]`
* `Scenario-UpgradePreservesConfig.ps1 -LabConfig <path> [-UpgradeFrom <version>] [-Execute]`
* `Scenario-MultiDataset.ps1 -LabConfig <path> [-Execute]`
* `Scenario-FunctionalSmoke.ps1 -LabConfig <path> [-Execute]`
* `Scenario-GenericSmoke.ps1 -LabConfig <path> [-Execute]`

**Key Benefit**: A developer or agent diagnosing a reboot issue can execute `Scenario-PostReboot.ps1` directly in **45 seconds** without running the 15-minute matrix.

### Layer 5: Orchestrators (`testlab/runners/` or root `testlab/scripts/`)
* **`run-matrix.ps1`**:
  * Reduced from **3,305 lines to ~350 lines**.
  * Only handles: loading matrix config $\to$ iterating cells $\to$ calling Layer 4 scenarios $\to$ collecting artifacts $\to$ generating `results.json`.
* **`run-release-gate.ps1`**:
  * Reduced from **1,259 lines to ~400 lines**.
  * Handles: preflight cleanliness checks $\to$ matrix profile generation $\to$ invoking matrix runner $\to$ publishing durable release history.

---

## 5. Implementation Roadmap & Handoff Guide

### Phase 1: Immediate Flakiness Hotfixes & Harness Tests (COMPLETED)
- [x] Fix single-line bash quoting bug in `run-matrix.ps1` and `provision-wsl-qemu-lab.ps1`.
- [x] Replace `Get-Content` with SMB-safe `[System.IO.File]::ReadAllText` in `testlab-plugin-source.ps1`.
- [x] Deduplicate settle logic in `run-matrix.ps1`, simplify to `cut -d. -f1 /proc/uptime`, and bump timeout to 120s.
- [x] Guard `run-matrix.ps1` entrypoint against dot-sourcing.
- [x] Create and verify `testlab/tests/Run-HarnessTests.ps1` (5/5 tests passing).
- [x] Verify `run-release-gate.ps1 -MatrixProfile release-default -AllowDirtyWorktree` dry-run passes cleanly.

### Phase 2: Transport & Core Module Extraction (NEXT STEP)
1. **Create `testlab/modules/TestLab.Core/`**:
   - Extract `FileSystem.ps1` (SMB-safe `Read-TestLabTextFile`, `Write-TestLabTextFile`).
   - Extract `Config.ps1` (`Get-TestLabConfig`, node canonical/legacy resolution).
   - Extract `Logging.ps1` (`Write-TestLabHostLine`, `Write-TestLabHeartbeat`).
2. **Create `testlab/modules/TestLab.Transport/`**:
   - Extract `Invoke-RemoteBash` (Base64-encapsulated execution).
   - Extract `Invoke-RemoteUpload` (SCP with retry).
   - Extract `Wait-SshReady`, `Wait-SshUnavailable`, `Wait-SshStable`.
3. **Verify with Harness Tests**:
   - Add unit tests in `testlab/tests/Transport.Tests.ps1`.
   - Update `run-matrix.ps1` and `provision-wsl-qemu-lab.ps1` to import `TestLab.Transport`.
   - Run `Run-HarnessTests.ps1` to confirm zero regressions.

### Phase 3: Guest Management & Standalone Scenarios
1. **Create `testlab/modules/TestLab.Guest/`**:
   - Extract `UnraidLifecycle.ps1` (`Wait-ForRebootCycle`, settle protocol).
   - Extract `PluginManager.ps1` (build `.txz`, install, verify, read display version).
   - Extract `ZfsManager.ps1` (pool & dataset verification and creation).
2. **Decouple Scenarios into `testlab/scenarios/`**:
   - Extract `Scenario-PostReboot.ps1` as a standalone CLI runner.
   - Extract `Scenario-FreshInstall.ps1` as a standalone CLI runner.
   - Extract `Scenario-UpgradePreservesConfig.ps1` as a standalone CLI runner.
3. **Test Scenarios Individually**:
   - Verify each scenario can be invoked directly from PowerShell against live nodes.

### Phase 4: Orchestrator Slimdown & Final Polish
1. **Refactor `run-matrix.ps1`**:
   - Replace embedded scenario implementations with dispatches to `testlab/scenarios/`.
   - Reduce file size to ~350 lines.
2. **Refactor `run-release-gate.ps1`**:
   - Use `TestLab.Core` and `TestLab.Reporting` modules.
3. **Documentation & Cleanup**:
   - Update `testlab/README.md` with instructions for running individual scenarios.
   - Remove deprecated, orphaned scripts (`scenario-fresh-install.ps1`, `scenario-post-reboot.ps1`).

---

## 6. Handoff Verification Checklist

Any engineer or agent continuing this work should verify the baseline using these commands:

```powershell
# 1. Run the fast harness test suite (< 2 seconds, no VMs required)
./testlab/tests/Run-HarnessTests.ps1

# 2. Run the release gate preflight and matrix dry-run (< 30 seconds)
./testlab/scripts/run-release-gate.ps1 -LabConfig testlab/config/lab.local.json -MatrixProfile release-default -AllowDirtyWorktree

# 3. If live VMs are running, test individual reboot validation:
# (Once Phase 3 is implemented):
./testlab/scenarios/Scenario-PostReboot.ps1 -LabConfig testlab/config/lab.local.json -Execute
```
