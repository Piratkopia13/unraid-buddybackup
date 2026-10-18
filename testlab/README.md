# BuddyBackup Test Lab

This folder contains the first implementation of a reproducible, script-first test environment for BuddyBackup.

## Goals

- Reproducible setup on a new host with minimal manual work.
- Matrix testing for fixed-node plugin compatibility across Unraid versions.
- Explicit lifecycle scenarios for fresh install and post-reboot validation.
- Dry-run-first execution with explicit `-Execute` paths for live provisioning and test actions.

## Architecture & Modular Design

The testlab is structured into a clean, 5-layer modular architecture designed for maintainability, independent testability, and fast iteration:

```text
┌─────────────────────────────────────────────────────────┐
│ Layer 5: Orchestrators (scripts/run-matrix.ps1, etc.)    │
└───────────────────────────┬─────────────────────────────┘
                            │ delegates cells to
┌───────────────────────────▼─────────────────────────────┐
│ Layer 4: Standalone Scenarios (scenarios/Scenario-*.ps1) │
└───────────────────────────┬─────────────────────────────┘
                            │ imports
┌───────────────────────────▼─────────────────────────────┐
│ Layer 3: Guest Management (modules/TestLab.Guest)       │
├─────────────────────────────────────────────────────────┤
│ Layer 2: Transport & Platform (TestLab.Transport/Platform)│
├─────────────────────────────────────────────────────────┤
│ Layer 1: Core Foundation (modules/TestLab.Core)         │
└─────────────────────────────────────────────────────────┘
```

### Module Hierarchy (`testlab/modules/`)
1. **`TestLab.Core`**:
   - `FileSystem.ps1`: Safe workspace resolution (`Get-TestLabWorkspaceRoot`), path normalization, directory creation.
   - `Logging.ps1`: Structured logging, timestamped formatters, execution wrappers.
   - `Config.ps1`: JSON configuration loading, object accessors (`Get-ObjectValue`), node connection resolvers.
2. **`TestLab.Platform`**:
   - `WslProvider.ps1`: WSL command invocation, Windows-to-WSL path translations, root bash runners.
   - `NetworkManager.ps1`: Port availability testing, free port allocation, gateway IP resolution.
   - `QemuVmManager.ps1`: QEMU VM process management, disk creation, VM teardown.
3. **`TestLab.Transport`**:
   - `Connection.ps1`: Node connection representation, SSH parameter resolution.
   - `RemoteBash.ps1`: Safe script block quoting, remote execution with retry logic (`Invoke-RemoteBash`).
   - `RemoteUpload.ps1`: Multi-file transfer with WSL `wslpath` caching (`Send-RemoteFiles`).
   - `WaitProbes.ps1`: Polling probes with bounded timeouts (`Wait-ForRemoteSuccess`).
4. **`TestLab.Guest`**:
   - `UnraidLifecycle.ps1`: WebGUI readiness, manual access verification, boot ID detection, reboot cycling.
   - `PluginManager.ps1`: Display version parsing, `.txz` workspace compilation, remote staging, plugin install runner.
   - `ZfsManager.ps1`: Pool and dataset creation, encryption key handling, dataset destroy/scrub.
   - `UpgradeStateManager.ps1`: Pre/post upgrade state snapshots, JSON normalization, state diffing.

### Standalone Scenarios (`testlab/scenarios/`)
All test scenarios are self-contained CLI scripts that can be executed directly or dispatched by matrix orchestrators:
- **`Scenario-FreshInstall.ps1`**: Installs BuddyBackup on `nodeA` and `nodeB`, verifying plugin health and binaries.
- **`Scenario-PostReboot.ps1`**: Snapshots state, triggers guest reboot, waits for SSH/boot ID transition, and verifies state persistence across reboot.
- **`Scenario-UpgradePreservesConfig.ps1`**: Installs a baseline version, seeds realistic configuration, upgrades in-place, and verifies configuration integrity.
- **`Scenario-FunctionalSmoke.ps1`**: Bidirectional reciprocal backup and restore validation between `nodeA` and `nodeB`.
- **`Scenario-MultiDataset.ps1`**: Multi-dataset hot-standby replication and telemetry isolation.
- **`Scenario-GenericSmoke.ps1`**: Remote replication push and snapshot restore with a non-Unraid OpenZFS host (`nodeC`).

### Running Scenarios Standalone
Any scenario can be executed directly in dry-run or live execution mode:
```powershell
# Run fresh install scenario dry-run
./testlab/scenarios/Scenario-FreshInstall.ps1 -LabConfig testlab/config/lab.local.json

# Run post-reboot verification against live nodes
./testlab/scenarios/Scenario-PostReboot.ps1 -LabConfig testlab/config/lab.local.json -Execute

# Run upgrade preservation test
./testlab/scenarios/Scenario-UpgradePreservesConfig.ps1 -LabConfig testlab/config/lab.local.json -UpgradeFrom 2026.05.02 -UpgradeTo workspace-build -Execute
```

### Running Test Suites (`testlab/tests/`)
The testlab includes a fast unit and regression test runner (< 3 seconds execution):
```powershell
# Run core, transport, guest module tests and regression checks
./testlab/tests/Run-HarnessTests.ps1

# Include scenario dry-run tests
./testlab/tests/Run-HarnessTests.ps1 -IncludeScenarios
```

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

   For the current `windows-local` provider, this starts two Unraid nodes named `nodeA` and `nodeB`.

   During a real run, provisioning prints lines like these for each node:

   ```text
   [testlab] nodeA WebGUI HTTP: http://127.0.0.1:8080
   [testlab] nodeA WebGUI HTTPS: https://127.0.0.1:8443
   [testlab] nodeA WebGUI user: root (password from setup.manualAccess.rootPassword)
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

9. Run the pre-release gate wrapper when you want one command that enforces repo-state policy, runs provisioning plus matrix execution, and stores a durable summary outside `.testlab`:

   ```powershell
   ./testlab/scripts/run-release-gate.ps1 -LabConfig testlab/config/lab.local.json -MatrixConfig testlab/config/matrix.small.json
   ```

   By default this runs in dry-run mode, just like the underlying scripts.

   For release-oriented runs, you can use a named generated profile instead of a hand-written matrix file:

   ```powershell
   ./testlab/scripts/run-release-gate.ps1 -LabConfig testlab/config/lab.local.json -MatrixProfile release-default
   ```

10. Execute the release gate for real:

   ```powershell
   ./testlab/scripts/run-release-gate.ps1 -LabConfig testlab/config/lab.local.json -MatrixConfig testlab/config/matrix.small.json -Execute
   ```

   The release gate refuses to start if the git worktree is dirty. It records the tested commit SHA, branch, matrix profile, and copied run summaries under `%LOCALAPPDATA%\BuddyBackup\TestlabHistory` unless you override `releaseGate.historyRoot` in the lab config or pass `-HistoryRoot`.

   On successful execute runs, the wrapper also publishes a sanitized public summary into `testlab/release-history` when the run either uses a clean worktree or installs published BuddyBackup releases only.

11. To run a generated release profile against a published BuddyBackup release instead of the current workspace build, pass the BuddyBackup release overrides on the command line:

    ```powershell
    ./testlab/scripts/run-release-gate.ps1 \
       -LabConfig testlab/config/lab.local.json \
       -MatrixProfile release-default \
       -CurrentCandidatePlugin 2026.05.02 \
       -PreviousReleaseVersion 2025.09.13 \
       -Execute
    ```

    Any non-`workspace-build` plugin value is treated as a published release tag. Use this when you want the generated profile to validate a public release-to-release window instead of the current checkout. Unraid baselines for generated profiles come from `lab.releaseGate.previousCertifiedUnraidVersion` and `lab.releaseGate.latestSupportedUnraidVersion` in the lab config.

11. Tear down the local WSL/QEMU nodes when you are done:

   ```powershell
   ./testlab/scripts/teardown-wsl-qemu-lab.ps1 -LabConfig testlab/config/lab.local.json -Execute
   ```

   To stop only one node, pass `-NodeNames nodeA` or `-NodeNames nodeB`.

## Default behavior

- `provision-lab.ps1`, `run-matrix.ps1`, `run-functional-smoke.ps1`, and `teardown-wsl-qemu-lab.ps1` default to dry-run. Pass `-Execute` to make changes on live nodes.
- `run-release-gate.ps1` also defaults to dry-run. It runs the existing provision and matrix flows, then copies the resulting `provision-*.json` and `results.json` into the durable history root together with a `manifest.json`, `index.json`, and `latest.json` summary.
- `run-matrix.ps1` defaults to `-LabConfig testlab/config/lab.local.json` and `-MatrixConfig testlab/config/matrix.small.json`.
- `run-functional-smoke.ps1` defaults to `-LabConfig testlab/config/lab.local.json` and operates against the already provisioned `nodeA` and `nodeB` nodes from that lab config.
- In the example lab config, `setup.applyBaseConfigAfterSsh` and `setup.verifyBaseConfigInMatrix` are both `true`, so local provisioning applies BuddyBackup and ZFS base setup by default and each matrix cell runs `base-setup-verify` before its listed scenarios.
- Matrix artifact collection is enabled by default. Pass `-SkipArtifacts` to `run-matrix.ps1` to suppress per-cell artifact capture.
- `run-release-gate.ps1` still fails immediately on any uncommitted or untracked git changes when the selected matrix includes a `workspace-build` candidate, because the tested BuddyBackup artifact comes from the current checkout in that mode.
- For release-tag-only matrices, dirty worktrees now warn instead of blocking because the installed BuddyBackup artifacts come from published release URLs. Successful execute runs in that mode still publish repository history. `-AllowDirtyWorktree` remains available as an explicit override when you want to suppress the workspace-build cleanliness guard during harness development.
- `run-release-gate.ps1` only publishes repository history for successful execute runs that do not use `-AllowDirtyWorktree` and either have a clean worktree or install published BuddyBackup releases only. Dry-runs and dirty-worktree override runs still write local durable manifests, but they do not update `testlab/release-history`.
- Release-gate manifests now include `categoryRollups`, and published repository history shows per-category pass/fail columns such as `pluginCompatibility` and `unraidCompatibility` when the selected matrix defines categories.
- `run-release-gate.ps1` also runs the generic host smoke as a stage after the matrix, recorded as `summary.genericSmoke` and a `genericHost` category rollup. For `windows-local` labs it auto-provisions the local `nodeC` VM first when `nodes.nodeC.host` is `127.0.0.1`. Pass `-SkipGenericSmoke` to skip the stage, or configure `releaseGate.genericSmoke` (`enabled`, `required`, `autoProvisionNodeC`).

## Test catalog

- `base-setup-verify`: runs before each matrix cell when `setup.verifyBaseConfigInMatrix` is enabled. It verifies BuddyBackup is installed on both nodes, verifies the configured zpool exists, verifies the unencrypted dataset exists, and verifies the encrypted dataset exists with encryption enabled. On live local-provider runs it also cross-checks the latest local-provider report. Results are written to `scenario-base-setup-verify.json` in the cell artifact directory.
- `fresh-install`: installs the matrix-selected BuddyBackup plugin version on both fixed lab nodes for that cell.
- `post-reboot`: captures BuddyBackup state on both nodes, reboots both nodes one at a time, waits for SSH to drop and return, confirms a new `boot_id`, verifies the manual WebGUI password persisted, re-verifies BuddyBackup installation, re-verifies the configured ZFS datasets, and fails if any captured BuddyBackup state changed across the reboot.
- `upgrade-preserves-config`: installs the configured `upgradeFromPlugin` version on both nodes, seeds realistic BuddyBackup state (backup jobs, snapshot job, advanced settings, receive mode, SSH state), upgrades both nodes in place to the matrix-selected plugin version, captures normalized before/after state summaries, and fails if any preserved state changed unexpectedly.
- `backup-smoke`: delegates to the functional smoke workflow and reports whether the backup-oriented actions succeeded.
- `restore-smoke`: also delegates to the functional smoke workflow and reports whether the restore-oriented actions succeeded. If `backup-smoke` already ran in the same cell, the runner reuses the cached functional smoke result instead of re-running the full smoke workflow.
- `run-functional-smoke.ps1`: can also be run directly against a live provisioned lab. It validates connectivity on both nodes, creates source snapshots on both nodes, runs remote and local backup flows on both nodes, lists available snapshots, restores selected snapshots, and verifies the restored datasets.
- `run-generic-smoke.ps1`: standalone push smoke against a generic OpenZFS host (Debian-based, same path as Proxmox). It prepares a dataset on the generic node, runs `generic_host_setup.sh` as receiver plus its `--verify` checklist, seeds a `remote_generic` entry on nodeA, runs the connection test (verifying `ZFS receive permissions verified`), pushes real syncoid replication flows through the allowlist, verifies the pushed dataset on the generic node, lists snapshots through the remote_generic path, and restores a pushed snapshot back to nodeA. It also runs negative checks: a dataset that exists on the generic node but was never passed to `--dataset` is rejected by the connection test ("Neither dataset ... nor its parent exists" and no `ZFS receive permissions verified`).
- `scenario-multi-dataset.ps1` (`multi-dataset`): validates multi-dataset hot-standby replication where the sender replicates child datasets under parent container destinations (e.g. `bbpool/domains/MintCinnamon` under `bbpool/domains`), verifies single consolidated `authorized_keys` emission with multiple `--dataset` options for shared sender keys, verifies OpenZFS permission delegation, and confirms telemetry is accurately attributed to the specific target card while keeping sibling cards isolated.

## Default matrix

- `testlab/config/matrix.small.json` is the default matrix file used by `run-matrix.ps1`.
- It currently defines these cells:
1. `cell-01`: nodeA and nodeB both run Unraid `7.1.0` with BuddyBackup `2026.05.02`; scenarios are `fresh-install`, `backup-smoke`, and `restore-smoke`.
2. `cell-02`: nodeA runs Unraid `7.1.0` with BuddyBackup `2026.05.02`, nodeB runs Unraid `7.1.0` with BuddyBackup `2025.09.13`; scenarios are `fresh-install` and `backup-smoke`.
3. `cell-03`: nodeA and nodeB both run the current `workspace-build`; scenarios are `post-reboot` and `backup-smoke`, so the default matrix now exercises reboot persistence on the current checkout.
4. `cell-04`: nodeA and nodeB both run Unraid `7.1.0` with BuddyBackup `2026.05.02`, but each upgrades in place from `2025.09.13`; scenarios are `upgrade-preserves-config`, `backup-smoke`, and `restore-smoke`.
- Because `setup.verifyBaseConfigInMatrix` defaults to `true` in the example lab config, each of those cells also runs `base-setup-verify` before the listed scenarios.

## Release matrix profiles

- `run-release-gate.ps1` accepts `-MatrixProfile` for release-oriented generated matrices.
- `release-default`: the required release gate. It covers the previous certified Unraid version and the latest supported Unraid version, with previous-release versus current-candidate BuddyBackup across both fixed lab nodes, one in-place `upgrade-preserves-config` cell on each Unraid baseline, and one current/current `post-reboot` cell on the latest supported Unraid version.
- `release-mixed-unraid`: an optional mixed-version profile. It keeps the previous certified Unraid version on nodeA and the latest supported Unraid version on nodeB, then runs previous/current BuddyBackup interoperability plus mixed-pair `upgrade-preserves-config` coverage within that fixed node pairing.
- `release-latest-unraid-isolation`: an optional current/current isolation run on the latest supported Unraid version with restore coverage.
- `release-post-reboot`: an optional reboot-persistence run for the current candidate on the latest supported Unraid version.
- `release-extended`: the required `release-default` cells plus the isolation profile.
- The matrix schema now names the two fixed lab slots `nodeA` and `nodeB`.
- Current limitation: the existing providers provision one fixed nodeA slot and one fixed nodeB slot from the lab config before the matrix starts. That means one execution cannot truly switch Unraid versions per cell.
- `run-matrix.ps1` now resolves runtime `nodeA.unraid` and `nodeB.unraid` values from `lab.nodes.nodeA.unraidVersion` and `lab.nodes.nodeB.unraidVersion`, so matrix execution uses whatever Unraid pair is already provisioned on the lab nodes.
- Generated release-gate profiles do the same before they are written under `.testlab/generated-matrices`, so their saved JSON reflects the provisioned node versions used for that run.
- If you want a different Unraid pair, change `lab.nodes.nodeA.unraidVersion` and `lab.nodes.nodeB.unraidVersion` and reprovision the lab before running the matrix.
- Generated profiles still read their BuddyBackup version pairings from `lab.releaseGate.previousReleaseVersion` and `lab.releaseGate.currentCandidatePlugin`. The `previousCertifiedUnraidVersion` and `latestSupportedUnraidVersion` settings still describe the intended release-gate baselines, but the runtime matrix written under `.testlab/generated-matrices` records the actual provisioned node versions used for that run.
- Generated matrix JSON files are written under `.testlab/generated-matrices` so the exact release matrix used for a run is still inspectable after the wrapper starts.

## Version bump policy

- `run-release-gate.ps1` evaluates the current `buddybackup.plg` display version against `lab.releaseGate.previousReleaseVersion` whenever the selected matrix includes a `workspace-build` candidate.
- The default policy is `lab.releaseGate.versionPolicy.mode = require`.
- In `require` mode, clean execute release-gate runs are blocked if the current candidate still reports the same display version as the previous release.
- Dry-runs still continue in `require` mode, but they emit a warning so you can validate the rest of the flow before deciding to cut a release.
- Alternative modes are `warn` and `ignore` if you need to relax the policy for a special case.

## Workspace-build source

- Set a node or matrix plugin value to `workspace-build` when you want the testlab to install the BuddyBackup code from the currently checked out workspace instead of a published GitHub release tag.
- The testlab builds `buddybackup.txz` locally from `src/` into `.testlab/build-cache/workspace-<shortSha>/buddybackup.txz`, uploads that package plus the local dependency packages from `deps/`, installs them on the guest, and then runs `rc.buddybackup.php update`.
- The active install source is written on the guest to `/boot/config/plugins/buddybackup/testlab-plugin-source.json`. Matrix artifact collection captures that file as `plugin-source.txt` so release and workspace-build provenance can be reviewed after a run.
- `workspace-build` is intended for release-candidate validation. Because the current display version in `buddybackup.plg` can still match the last published release, use the recorded commit SHA and plugin-source metadata to distinguish a workspace candidate from a published tag.
- Any other plugin string such as `2026.05.02` is treated as a published release tag and installed from `lab.plugin.plgUrlTemplate`.

## Generic node and TrueNAS SCALE coverage

- The lab config defines a third slot `nodes.nodeC` for a generic OpenZFS host (Debian-based; the same path Proxmox uses). Unlike nodeA/nodeB, the local WSL/QEMU provider does not provision nodeC automatically - point it at any SSH-reachable host that already has OpenZFS installed and a pool created. The release gate runs the generic smoke as a stage after the matrix (auto-provisioning the local nodeC VM when `nodes.nodeC.host` is `127.0.0.1`); to run the generic smoke directly instead:
  - Dry-run: `./testlab/scripts/run-generic-smoke.ps1 -LabConfig testlab/config/lab.local.json`
  - Execute: `./testlab/scripts/run-generic-smoke.ps1 -LabConfig testlab/config/lab.local.json -Execute`
- For local runs, `provision-nodec-wsl-qemu.ps1` provisions a reusable throwaway generic host inside WSL/QEMU instead of pointing at an external machine:
  - Provision or health-check: `./testlab/scripts/provision-nodec-wsl-qemu.ps1 -LabConfig testlab/config/lab.local.json -Execute`
  - Stop the VM: add `-Teardown -Execute`; also delete its disks: add `-RemoveDisks`; rebuild from scratch on the next provision: add `-Recreate`.
  - It boots an Ubuntu 24.04 cloud image (`-ImageUrl` accepts Debian cloud images too), forwards SSH to `127.0.0.1:2224` (`-SshPort`), installs OpenZFS, creates the pool (`bbpool` by default) on a dedicated data disk, and injects the lab public key for root. VM state lives in `/var/lib/buddybackup-nodec` inside the WSL distro (`-VmRoot`), and reports are written to `.testlab/logs/nodec-*.json`.
  - The `nodes.nodeC` block below matches these defaults, so no extra values are needed for the local path.
- Before this smoke can run, `nodes.nodeC` must exist in the lab config; if it is missing, the script stops with `Missing lab.nodes.nodeC.host`. Minimum requirements for the host you point it at:
  - Debian-based OpenZFS host (Proxmox, Debian, or Ubuntu) reachable over SSH, with `zfs`/`zpool` working and a pool already created. The smoke does not create the pool.
  - SSH login as `root` with the lab identity file (`lab.ssh.identityFile`, default `.testlab/lab_key`), or set `nodes.nodeC.user` / `nodes.nodeC.identityFile` for a different account or key.
  - A config block like this (inserted into `nodes`):
    ```json
    "nodeC": {
      "name": "buddybackup-node-c-generic",
      "host": "127.0.0.1",
      "port": 2224,
      "platform": "generic-debian",
      "zfsPool": "bbpool",
      "datasetRoot": "buddybackup"
    }
    ```
    `zfsPool` defaults to `setup.zfs.poolName` and `datasetRoot` defaults to `buddybackup`; the values above match the local lab defaults.
  - A non-22 SSH port forwarded from the WSL/QEMU host (the example uses `127.0.0.1:2224`). nodeA cannot reach nodeC's SSH directly, so the smoke installs a `nodeCAliasIp:22 -> hostGatewayIp:<port>` DNAT rule on nodeA; that rule is skipped when the configured port is 22, which means port 22 does not work for the local WSL/QEMU lab. For a remote host on the LAN, terminate the forward on the WSL side (for example `socat` or `ssh -L 127.0.0.1:2224:<nodeC>:22`).
  - Dry-runs only validate config parsing; SSH reachability is exercised when you pass `-Execute`.
- The generic smoke reaches nodeC from nodeA through the same host-gateway DNAT pattern the functional smoke uses, so the Unraid backup entries connect to `setup.functionalTests.nodeCAliasIp` on port 22.
- The smoke runs `generic_host_setup.sh` as receiver plus its `--verify` checklist on nodeC itself, so no manual setup-script run is required up front.
- TrueNAS SCALE is validated manually; `testlab/MANUAL-SCALE-CHECKLIST.md` documents the full setup, Unraid push to TrueNAS, TrueNAS replication to Unraid, negative checks and pass criteria.

## Backup direction coverage

- The matrix and reports label the two fixed lab slots as `nodeA` and `nodeB`, but those names do not mean only one node sends backups and only one node receives them.
- Remote backup coverage is bidirectional in the functional smoke run.
- nodeA performs a remote backup to a dataset received on nodeB.
- nodeB performs a remote backup to a dataset received on nodeA.
- After those remote sends, the smoke test verifies inbound remote datasets on both nodes, so each fixed node is tested as both a remote sender and a remote receiver.
- Connectivity checks are also bidirectional: `test_connection` is executed from both nodes against the opposite node before backups begin.
- Local backup coverage is symmetric as well: both nodes run local backup, snapshot listing, and local restore flows.
- Remote restore coverage is also symmetric: both nodes list remote snapshots and restore a selected remote snapshot into node-specific restore datasets.

## Notes

- Scripts default to dry-run to avoid accidental VM reboot or remote changes.
- `provision-lab.ps1` without `-Execute` does not boot the local Unraid nodes. It only writes reports and dry-run actions.
- `teardown-wsl-qemu-lab.ps1` also defaults to dry-run; keep `-Execute` when you actually want to stop the local nodes.
- `run-release-gate.ps1` is the intended entrypoint for pre-release runs. It is strict about git cleanliness by default because release evidence should always map to one exact commit.
- SSH key-based access is expected for both lab nodes.
- The current local provider boots two Unraid guests in fixed `nodeA` and `nodeB` lab slots through WSL/QEMU.
- Artifacts are written to `.testlab/artifacts`, and provisioning reports are written to `.testlab/logs`.
- Release-gate history is written outside the workspace by default under `%LOCALAPPDATA%\BuddyBackup\TestlabHistory`, so results can persist across multiple release cycles even if `.testlab` is cleaned.
- Public release history is written inside the repository under `testlab/release-history` only after successful execute release-gate runs that either have a clean worktree or install published BuddyBackup releases only.
- Public release history includes category-level compatibility status columns plus BuddyBackup and Unraid pair-coverage columns when the release matrix annotates cells with categories.
- The `windows-local` provider targets WSL2 plus QEMU/KVM.
- For the local provider, keep `lab.nodes.nodeA.host` and `lab.nodes.nodeB.host` on `127.0.0.1` with distinct SSH-forwarded ports.
- Default forwarded ports are nodeA `2222` / `8080` / `8443` and nodeB `2223` / `8081` / `8444` for SSH / HTTP / HTTPS. You can override the WebGUI ports with `nodes.nodeA.webGuiHttpPort`, `nodes.nodeA.webGuiHttpsPort`, `nodes.nodeB.webGuiHttpPort`, and `nodes.nodeB.webGuiHttpsPort`.
- If a preferred WebGUI port is already busy, the probe can fall back to another localhost port for that run. Use the console output or the latest `local-provider-*.json` report instead of assuming the default ports were used.
- `wslQemu.unraidDownloadUrlTemplate` still works when Unraid exposes a predictable versioned URL pattern.
- If a newer release uses a hashed direct zip URL instead, set `wslQemu.unraidDownloadUrls.<version>` for that exact version.
- If automatic Unraid zip download still fails, place `unraid-<version>.zip` manually under `.testlab/cache`; the local provider will extract the payload from there.
- `wslQemu.dataDiskSizeGB` controls the dedicated non-array data disk used for base ZFS setup.
- `wslQemu.networkDeviceModel` controls the QEMU guest NIC model for the local WSL/QEMU provider. It now defaults to `virtio-net-pci`, and the probe/report records the chosen NIC model and stable MAC address for each guest.
- Base setup (`setup`) runs after SSH readiness and records testable action outputs in `.testlab/logs/local-provider-*.json`.
- The local provider forwards each guest WebGUI to localhost and prints the HTTP/HTTPS URLs after real provisioning for manual checks.
- Manual WebGUI login defaults to `root` with the password from `setup.manualAccess.rootPassword`, but that password is not echoed or written to testlab reports.
- If you open both WebGUIs at the same time in the same browser profile, Unraid session cookies can collide because both are served from `127.0.0.1` on different ports. Use separate browser profiles or a private window if you need both open simultaneously.
- BuddyBackup plugin install is validated by both install exit status and `plugin list`; by default, install output containing `warning` or `error` fails setup.
- ZFS base setup creates a standalone pool and two datasets per node: one unencrypted and one encrypted.
- The lab intentionally does not try to register that disk as an Unraid-managed named pool on Main. Unraid's documented workflow is GUI-driven, and the internal emhttp update path behind it is not treated here as a stable automation surface across Unraid releases.
- `setup.verifyBaseConfigInMatrix` controls a `base-setup-verify` check that runs before each matrix cell scenario and writes `scenario-base-setup-verify.json` in the cell artifact directory.
