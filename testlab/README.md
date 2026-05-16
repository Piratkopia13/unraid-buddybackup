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
- Windows-local VM planning scaffold with backend auto-detection.
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

   If `provider` is set to `windows-local`, the provision step writes a VM plan and detects Hyper-V or VirtualBox when available.

6. Execute for real:

   powershell
   ./testlab/scripts/run-matrix.ps1 -LabConfig testlab/config/lab.local.json -MatrixConfig testlab/config/matrix.small.json -Execute

## Notes

- Scripts default to dry-run to avoid accidental VM reboot or remote changes.
- SSH key-based access is expected for sender/receiver nodes.
- This phase is report-only and writes artifacts to `.testlab/artifacts` and provisioning reports to `.testlab/logs`.
- For Windows-local VM work, copy `testlab/config/vm-blueprint.example.json` to `testlab/config/vm-blueprint.local.json` and adjust host-specific paths if needed.
