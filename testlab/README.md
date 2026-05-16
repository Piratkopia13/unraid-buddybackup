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
- Small matrix definition.
- Matrix runner with lifecycle scenario hooks.
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

5. Execute for real:

   powershell
   ./testlab/scripts/run-matrix.ps1 -LabConfig testlab/config/lab.local.json -MatrixConfig testlab/config/matrix.small.json -Execute

## Notes

- Scripts default to dry-run to avoid accidental VM reboot or remote changes.
- SSH key-based access is expected for sender/receiver nodes.
- This phase is report-only and writes artifacts to `.testlab/artifacts`.
