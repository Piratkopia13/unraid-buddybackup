# Release Test History

Successful execute release-gate runs are recorded here when they either use a clean worktree or install published BuddyBackup releases only.
Coverage columns record the version pairs assigned to the two fixed lab slots for each run. The functional smoke still exercises remote backup and restore in both directions within that slot pairing.

## Runs

| Run | Plugin | Commit | Matrix | Plugin Compat | Unraid Compat | BuddyBackup Pair Coverage | Unraid Pair Coverage | Detail |
| --- | --- | --- | --- | --- | --- | --- | --- | --- |
| 20260525-212854-6c41f04 | 2026.05.02 | 6c41f04 | release-mixed-unraid | pass | pass | 2025.09.13 (release-tag) -> 2026.05.02 (release-tag); 2026.05.02 (release-tag) -> 2025.09.13 (release-tag); 2026.05.02 (release-tag) -> 2026.05.02 (release-tag) | 7.2.6 -> 7.3.0 | [detail](runs/20260525-212854-6c41f04.json) |
