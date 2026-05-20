# BuddyBackup Test Lab

This folder contains the first implementation of a reproducible, script-first test environment for BuddyBackup.

## Goals

- Reproducible setup on a new host with minimal manual work.
- Matrix testing for sender/receiver plugin compatibility across Unraid versions.
- Explicit lifecycle scenarios for fresh install and post-reboot validation.
- Report-only execution initially.

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

## Quick start

1. Create and enter a dedicated branch.
2. Copy `testlab/config/lab.example.json` to `testlab/config/lab.local.json` and fill host/provider values.
3. Run bootstrap:

   powershell
   ./testlab/scripts/bootstrap-host.ps1

4. Run matrix in dry-run mode (default):

   powershell
   ./testlab/scripts/run-matrix.ps1 -LabConfig testlab/config/lab.local.json -MatrixConfig testlab/config/matrix.small.json

5. Validate node readiness with provisioning probe:

   powershell
   ./testlab/scripts/provision-lab.ps1 -LabConfig testlab/config/lab.local.json

   If `provider` is set to `windows-local`, the provision step boots local Unraid nodes through WSL/QEMU and verifies SSH on the configured localhost ports.
   After SSH is ready, it can also apply base guest setup actions from `setup` in the lab config.

6. Execute for real:

   powershell
   ./testlab/scripts/run-matrix.ps1 -LabConfig testlab/config/lab.local.json -MatrixConfig testlab/config/matrix.small.json -Execute

7. Tear down the local WSL/QEMU nodes when you are done:

   powershell
   ./testlab/scripts/teardown-wsl-qemu-lab.ps1 -LabConfig testlab/config/lab.local.json -Execute

## Notes

- Scripts default to dry-run to avoid accidental VM reboot or remote changes.
- SSH key-based access is expected for sender/receiver nodes.
- This phase is report-only and writes artifacts to `.testlab/artifacts` and provisioning reports to `.testlab/logs`.
- The `windows-local` provider now targets WSL2 plus QEMU/KVM rather than Hyper-V.
- For the local provider, keep `lab.nodes.sender.host` and `lab.nodes.receiver.host` on `127.0.0.1` with distinct SSH-forwarded ports.
- If automatic Unraid zip download fails, place `unraid-<version>.zip` manually under `.testlab/cache`; the local provider will extract the payload from there.
- `wslQemu.dataDiskSizeGB` controls the dedicated non-array data disk used for base ZFS setup.
- Base setup (`setup`) runs after SSH readiness and records testable action outputs in `.testlab/logs/local-provider-*.json`.
- BuddyBackup plugin install is validated by both install exit status and `plugin list`; by default, install output containing `warning` or `error` fails setup.
- ZFS base setup creates a standalone pool and two datasets per node: one unencrypted and one encrypted.
- The lab intentionally does not try to register that disk as an Unraid-managed named pool on Main. Unraid's documented workflow is GUI-driven, and the internal emhttp update path behind it is not treated here as a stable automation surface across Unraid releases.
- `setup.verifyBaseConfigInMatrix` controls a `base-setup-verify` check that runs before each matrix cell scenario and writes `scenario-base-setup-verify.json` in the cell artifact directory.
