# BuddyBackup Test Lab

This folder contains the first implementation of a reproducible, script-first test environment for BuddyBackup.

## Goals

- Reproducible setup on a new host with minimal manual work.
- Matrix testing for sender/receiver plugin compatibility across Unraid versions.
- Explicit lifecycle scenarios for fresh install and post-reboot validation.
- Dry-run-first execution with explicit `-Execute` paths for live provisioning and test actions.

## Current status

This initial implementation provides:

- Host bootstrap script.
- Lab config templates.
- Windows-local WSL/QEMU provisioning path with artifact-backed SSH readiness checks.
- Post-SSH base guest setup for the local provider (BuddyBackup plugin install verification, and ZFS pool + datasets).
- Matrix-time base setup verification checks for plugin install health and ZFS baseline.
- Manual-provider provisioning probe with JSON readiness report.
- Small matrix definition.
- Matrix runner with lifecycle scenario hooks and per-cell artifacts.
- Scenario scripts for fresh install and reboot checks.
- Dedicated functional smoke runner for reciprocal backup and restore checks against the live local lab.

## Quick start

1. Optional: if you plan to edit the repo, create and switch to a separate Git branch for this testlab work.
2. Copy `testlab/config/lab.example.json` to `testlab/config/lab.local.json` and fill host/provider values.
3. Run bootstrap:

   ```powershell
   ./testlab/scripts/bootstrap-host.ps1
   ```

4. Optional: run provisioning in dry-run mode to verify config without starting any nodes:

   ```powershell
   ./testlab/scripts/provision-lab.ps1 -LabConfig testlab/config/lab.local.json
   ```

   This writes reports only. Without `-Execute`, the local WSL/QEMU nodes are not started, so any WebGUI URLs in reports are not live.

5. Start the local lab for real:

   ```powershell
   ./testlab/scripts/provision-lab.ps1 -LabConfig testlab/config/lab.local.json -Execute
   ```

   For the current `windows-local` provider, this starts two Unraid nodes named `sender` and `receiver`.

   During a real run, provisioning prints lines like these for each node:

   ```text
   [testlab] sender WebGUI HTTP: http://127.0.0.1:8080
   [testlab] sender WebGUI HTTPS: https://127.0.0.1:8443
   [testlab] sender WebGUI user: root (password from setup.manualAccess.rootPassword)
   ```

   The wrapper report at `.testlab/logs/provision-*.json` only records `providerReportPath`. The per-node WebGUI URLs and login user are stored in the provider report at `.testlab/logs/local-provider-*.json`; the password is not echoed or written to the report.

6. Optional: inspect the latest local-provider report to get the actual WebGUI URLs and login user that were used for that run:

   ```powershell
   $report = Get-ChildItem .testlab/logs/local-provider-*.json |
     Sort-Object LastWriteTime -Descending |
     Select-Object -First 1 |
     Get-Content -Raw |
     ConvertFrom-Json

   $report.nodes | Select-Object node, webGuiHttpUrl, webGuiHttpsUrl,
     @{Name='webGuiUser';Expression={$_.manualAccess.webGuiUser}},
       @{Name='passwordConfigured';Expression={$_.manualAccess.passwordConfigured}},
       @{Name='passwordSource';Expression={$_.manualAccess.passwordSource}}
   ```

    The actual password is the value of `setup.manualAccess.rootPassword` in the lab config used for the run.

7. Run matrix in dry-run mode (default):

   ```powershell
   ./testlab/scripts/run-matrix.ps1 -LabConfig testlab/config/lab.local.json -MatrixConfig testlab/config/matrix.small.json
   ```

8. Execute for real:

   ```powershell
   ./testlab/scripts/run-matrix.ps1 -LabConfig testlab/config/lab.local.json -MatrixConfig testlab/config/matrix.small.json -Execute
   ```

9. Tear down the local WSL/QEMU nodes when you are done:

   ```powershell
   ./testlab/scripts/teardown-wsl-qemu-lab.ps1 -LabConfig testlab/config/lab.local.json -Execute
   ```

   To stop only one node, pass `-NodeNames sender` or `-NodeNames receiver`.

## Default behavior

- `provision-lab.ps1`, `run-matrix.ps1`, `run-functional-smoke.ps1`, and `teardown-wsl-qemu-lab.ps1` default to dry-run. Pass `-Execute` to make changes on live nodes.
- `run-matrix.ps1` defaults to `-LabConfig testlab/config/lab.local.json` and `-MatrixConfig testlab/config/matrix.small.json`.
- `run-functional-smoke.ps1` defaults to `-LabConfig testlab/config/lab.local.json` and operates against the already provisioned `sender` and `receiver` nodes from that lab config.
- In the example lab config, `setup.applyBaseConfigAfterSsh` and `setup.verifyBaseConfigInMatrix` are both `true`, so local provisioning applies BuddyBackup and ZFS base setup by default and each matrix cell runs `base-setup-verify` before its listed scenarios.
- Matrix artifact collection is enabled by default. Pass `-SkipArtifacts` to `run-matrix.ps1` to suppress per-cell artifact capture.

## Test catalog

- `base-setup-verify`: runs before each matrix cell when `setup.verifyBaseConfigInMatrix` is enabled. It verifies BuddyBackup is installed on both nodes, verifies the configured zpool exists, verifies the unencrypted dataset exists, and verifies the encrypted dataset exists with encryption enabled. On live local-provider runs it also cross-checks the latest local-provider report. Results are written to `scenario-base-setup-verify.json` in the cell artifact directory.
- `fresh-install`: installs the matrix-selected BuddyBackup plugin version on both sender and receiver for that cell.
- `post-reboot`: reboots both nodes one at a time, waits for SSH to drop and return, confirms a new `boot_id`, verifies the manual WebGUI password persisted, re-verifies BuddyBackup installation, and re-verifies the configured ZFS datasets.
- `backup-smoke`: delegates to the functional smoke workflow and reports whether the backup-oriented actions succeeded.
- `restore-smoke`: also delegates to the functional smoke workflow and reports whether the restore-oriented actions succeeded. If `backup-smoke` already ran in the same cell, the runner reuses the cached functional smoke result instead of re-running the full smoke workflow.
- `run-functional-smoke.ps1`: can also be run directly against a live provisioned lab. It validates connectivity on both nodes, creates source snapshots on both nodes, runs remote and local backup flows on both nodes, lists available snapshots, restores selected snapshots, and verifies the restored datasets.

## Default matrix

- `testlab/config/matrix.small.json` is the default matrix file used by `run-matrix.ps1`.
- It currently defines these cells:
1. `cell-01`: sender and receiver both run Unraid `7.1.0` with BuddyBackup `2026.05.02`; scenarios are `fresh-install`, `backup-smoke`, and `restore-smoke`.
2. `cell-02`: sender runs Unraid `7.1.0` with BuddyBackup `2026.05.02`, receiver runs Unraid `7.1.0` with BuddyBackup `2025.09.13`; scenarios are `fresh-install` and `backup-smoke`.
3. `cell-03`: sender runs Unraid `7.0.0` with BuddyBackup `2025.09.13`, receiver runs Unraid `7.1.0` with BuddyBackup `2026.05.02`; scenarios are `post-reboot` and `backup-smoke`.
- Because `setup.verifyBaseConfigInMatrix` defaults to `true` in the example lab config, each of those cells also runs `base-setup-verify` before the listed scenarios.

## Backup direction coverage

- Remote backup coverage is bidirectional in the functional smoke run.
- The sender performs a remote backup to a dataset received on the receiver.
- The receiver performs a remote backup to a dataset received on the sender.
- After those remote sends, the smoke test verifies inbound remote datasets on both nodes, so each node is tested as both a remote sender and a remote receiver.
- Connectivity checks are also bidirectional: `test_connection` is executed from both nodes against the opposite node before backups begin.
- Local backup coverage is symmetric as well: both nodes run local backup, snapshot listing, and local restore flows.
- Remote restore coverage is also symmetric: both nodes list remote snapshots and restore a selected remote snapshot into node-specific restore datasets.

## Notes

- Scripts default to dry-run to avoid accidental VM reboot or remote changes.
- `provision-lab.ps1` without `-Execute` does not boot the local Unraid nodes. It only writes reports and dry-run actions.
- `teardown-wsl-qemu-lab.ps1` also defaults to dry-run; keep `-Execute` when you actually want to stop the local nodes.
- SSH key-based access is expected for sender/receiver nodes.
- The current local provider boots two Unraid guests (`sender` and `receiver`) through WSL/QEMU.
- Artifacts are written to `.testlab/artifacts`, and provisioning reports are written to `.testlab/logs`.
- The `windows-local` provider targets WSL2 plus QEMU/KVM.
- For the local provider, keep `lab.nodes.sender.host` and `lab.nodes.receiver.host` on `127.0.0.1` with distinct SSH-forwarded ports.
- Default forwarded ports are sender `2222` / `8080` / `8443` and receiver `2223` / `8081` / `8444` for SSH / HTTP / HTTPS. You can override the WebGUI ports with `nodes.sender.webGuiHttpPort`, `nodes.sender.webGuiHttpsPort`, `nodes.receiver.webGuiHttpPort`, and `nodes.receiver.webGuiHttpsPort`.
- If a preferred WebGUI port is already busy, the probe can fall back to another localhost port for that run. Use the console output or the latest `local-provider-*.json` report instead of assuming the default ports were used.
- If automatic Unraid zip download fails, place `unraid-<version>.zip` manually under `.testlab/cache`; the local provider will extract the payload from there.
- `wslQemu.dataDiskSizeGB` controls the dedicated non-array data disk used for base ZFS setup.
- Base setup (`setup`) runs after SSH readiness and records testable action outputs in `.testlab/logs/local-provider-*.json`.
- The local provider forwards each guest WebGUI to localhost and prints the HTTP/HTTPS URLs after real provisioning for manual checks.
- Manual WebGUI login defaults to `root` with the password from `setup.manualAccess.rootPassword`, but that password is not echoed or written to testlab reports.
- If you open both WebGUIs at the same time in the same browser profile, Unraid session cookies can collide because both are served from `127.0.0.1` on different ports. Use separate browser profiles or a private window if you need both open simultaneously.
- BuddyBackup plugin install is validated by both install exit status and `plugin list`; by default, install output containing `warning` or `error` fails setup.
- ZFS base setup creates a standalone pool and two datasets per node: one unencrypted and one encrypted.
- The lab intentionally does not try to register that disk as an Unraid-managed named pool on Main. Unraid's documented workflow is GUI-driven, and the internal emhttp update path behind it is not treated here as a stable automation surface across Unraid releases.
- `setup.verifyBaseConfigInMatrix` controls a `base-setup-verify` check that runs before each matrix cell scenario and writes `scenario-base-setup-verify.json` in the cell artifact directory.
