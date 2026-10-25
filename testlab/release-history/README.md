# Release Test History

Successful execute release-gate runs are recorded here when they either use a clean worktree or install published BuddyBackup releases only.
Coverage columns record the version pairs assigned to the two fixed lab slots for each run. The functional smoke still exercises remote backup and restore in both directions within that slot pairing. The Generic Host column records the release-gate generic OpenZFS smoke stage.

## Runs

| Run | Plugin | Commit | Matrix | Plugin Compat | Unraid Compat | Generic Host | BuddyBackup Pair Coverage | Unraid Pair Coverage | Detail |
| --- | --- | --- | --- | --- | --- | --- | --- | --- | --- |
| 20261024-141032-94797e0 | 2026.10.18 | 94797e0 | release-default | pass | pass | pass | 2026.05.02 (release-tag) -> 2026.10.18 (workspace-build); 2026.10.18 (workspace-build) -> 2026.05.02 (release-tag); 2026.10.18 (workspace-build) -> 2026.10.18 (workspace-build) | 7.2.6 -> 7.3.0 | [detail](runs/20261024-141032-94797e0.json) |
| 20261016-212928-136fe9a | 2026.10.16 | 136fe9a | release-default | pass | pass | pass | 2026.05.02 (release-tag) -> 2026.10.16 (workspace-build); 2026.10.16 (workspace-build) -> 2026.05.02 (release-tag); 2026.10.16 (workspace-build) -> 2026.10.16 (workspace-build) | 7.2.6 -> 7.3.0 | [detail](runs/20261016-212928-136fe9a.json) |
| 20261004-174140-55b97f0 | 2026.10.04 | 55b97f0 | release-default | pass | pass | - | 2026.05.02 (release-tag) -> 2026.10.04 (workspace-build); 2026.10.04 (workspace-build) -> 2026.05.02 (release-tag); 2026.10.04 (workspace-build) -> 2026.10.04 (workspace-build) | 7.2.6 -> 7.3.0 | [detail](runs/20261004-174140-55b97f0.json) |
| 20260927-122114-1adc975 | 2026.09.27 | 1adc975 | release-default | pass | pass | - | 2026.05.02 (release-tag) -> 2026.09.27 (workspace-build); 2026.09.27 (workspace-build) -> 2026.05.02 (release-tag); 2026.09.27 (workspace-build) -> 2026.09.27 (workspace-build) | 7.2.6 -> 7.3.0 | [detail](runs/20260927-122114-1adc975.json) |
| 20260920-101804-c39017d | 2026.09.23 | c39017d | release-default | pass | pass | - | 2026.05.02 (release-tag) -> 2026.09.23 (workspace-build); 2026.09.23 (workspace-build) -> 2026.05.02 (release-tag); 2026.09.23 (workspace-build) -> 2026.09.23 (workspace-build) | 7.2.6 -> 7.3.0 | [detail](runs/20260920-101804-c39017d.json) |
| 20260528-202529-28b6c9a | 2026.05.29 | 28b6c9a | release-default | pass | pass | - | 2026.05.02 (release-tag) -> 2026.05.29 (workspace-build); 2026.05.29 (workspace-build) -> 2026.05.02 (release-tag); 2026.05.29 (workspace-build) -> 2026.05.29 (workspace-build) | 7.2.6 -> 7.3.0 | [detail](runs/20260528-202529-28b6c9a.json) |
| 20260525-212854-6c41f04 | 2026.05.02 | 6c41f04 | release-mixed-unraid | pass | pass | - | 2025.09.13 (release-tag) -> 2026.05.02 (release-tag); 2026.05.02 (release-tag) -> 2025.09.13 (release-tag); 2026.05.02 (release-tag) -> 2026.05.02 (release-tag) | 7.2.6 -> 7.3.0 | [detail](runs/20260525-212854-6c41f04.json) |
| 20260524-214246-3317e40 | 2026.05.02 | 3317e40 | release-default | pass | pass | - | 2025.09.13 (release-tag) -> 2026.05.02 (release-tag); 2026.05.02 (release-tag) -> 2025.09.13 (release-tag); 2026.05.02 (release-tag) -> 2026.05.02 (release-tag) | 7.2.6 -> 7.2.6 | [detail](runs/20260524-214246-3317e40.json) |
