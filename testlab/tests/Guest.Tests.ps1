<#
.SYNOPSIS
    Unit tests for TestLab.Guest module.
.DESCRIPTION
    Validates manifest version parsing, plugin request resolution, verify command generation,
    ZFS config resolution, upgrade state parsing, and state comparison without running VMs.
#>

param(
    [switch]$VerboseOutput
)

$ErrorActionPreference = "Stop"

$workspaceRoot = [System.IO.Path]::GetFullPath((Join-Path $PSScriptRoot "..\.."))
$modulePath = Join-Path $workspaceRoot "testlab\modules\TestLab.Guest\TestLab.Guest.psm1"

Import-Module -Name (Resolve-Path -LiteralPath $modulePath).ProviderPath -Force -DisableNameChecking

$testsRun = 0
$testsPassed = 0
$testsFailed = 0

function Assert-Test {
    param(
        [string]$Name,
        [scriptblock]$TestBlock
    )

    $script:testsRun++
    try {
        & $TestBlock
        $script:testsPassed++
        Write-Host "  [PASS] $Name" -ForegroundColor Green
    } catch {
        $script:testsFailed++
        Write-Host "  [FAIL] $Name" -ForegroundColor Red
        Write-Host "         $($_.Exception.Message)" -ForegroundColor DarkRed
        if ($VerboseOutput) {
            Write-Host "$($_.ScriptStackTrace)" -ForegroundColor DarkGray
        }
    }
}

Write-Host "=== Running TestLab.Guest Unit Tests ===" -ForegroundColor Cyan

# ---------------------------------------------------------------------------
# Test 1: Get-TestLabPluginDisplayVersion using SMB-safe reader
# ---------------------------------------------------------------------------
Assert-Test "Get-TestLabPluginDisplayVersion parses manifest version safely" {
    $version = Get-TestLabPluginDisplayVersion -WorkspaceRoot $workspaceRoot
    if ([string]::IsNullOrWhiteSpace($version)) {
        throw "Parsed version is empty"
    }

    if ($version -notmatch '^\d{4}\.\d{2}\.\d{2}$') {
        throw "Version '$version' does not match expected format YYYY.MM.DD"
    }

    # Test missing manifest handling
    $fakeDir = Join-Path $workspaceRoot "testlab\.testlab\tmp_missing_manifest"
    $threw = $false
    try {
        Get-TestLabPluginDisplayVersion -WorkspaceRoot $fakeDir | Out-Null
    } catch {
        $threw = $true
    }
    if (-not $threw) {
        throw "Expected Get-TestLabPluginDisplayVersion to throw on missing manifest"
    }
}

# ---------------------------------------------------------------------------
# Test 2: Resolve-TestLabPluginRequest with release-tag vs workspace-build
# ---------------------------------------------------------------------------
Assert-Test "Resolve-TestLabPluginRequest handles release-tag requests" {
    $resolvedTag = Resolve-TestLabPluginRequest -RequestedValue "2026.04.15" -WorkspaceRoot $workspaceRoot
    if ($resolvedTag.sourceType -ne "release-tag") {
        throw "Expected sourceType 'release-tag', got '$($resolvedTag.sourceType)'"
    }
    if ($resolvedTag.requestedValue -ne "2026.04.15") {
        throw "Expected requestedValue '2026.04.15', got '$($resolvedTag.requestedValue)'"
    }
    if ($resolvedTag.displayVersion -ne "2026.04.15") {
        throw "Expected displayVersion '2026.04.15', got '$($resolvedTag.displayVersion)'"
    }
    if ($null -ne $resolvedTag.buildInfo) {
        throw "Expected buildInfo to be null for release-tag"
    }
}

Assert-Test "Resolve-TestLabPluginRequest handles workspace-build requests" {
    $resolvedWs = Resolve-TestLabPluginRequest -RequestedValue "workspace-build" -WorkspaceRoot $workspaceRoot
    if ($resolvedWs.sourceType -ne "workspace-build") {
        throw "Expected sourceType 'workspace-build', got '$($resolvedWs.sourceType)'"
    }
    if ($resolvedWs.label -ne "workspace-build") {
        throw "Expected label 'workspace-build', got '$($resolvedWs.label)'"
    }
    if ($null -eq $resolvedWs.buildInfo) {
        throw "Expected buildInfo to be populated for workspace-build"
    }
    if ([string]::IsNullOrWhiteSpace($resolvedWs.buildInfo.commitSha)) {
        throw "Expected commitSha to be populated"
    }
    if ([string]::IsNullOrWhiteSpace($resolvedWs.buildInfo.displayVersion)) {
        throw "Expected displayVersion in buildInfo"
    }
    if (-not (Test-Path -LiteralPath $resolvedWs.buildInfo.packagePath)) {
        throw "Expected packagePath '$($resolvedWs.buildInfo.packagePath)' to exist"
    }
}

# ---------------------------------------------------------------------------
# Test 3: Get-BuddyBackupPluginVerifyCommand bash script generation
# ---------------------------------------------------------------------------
Assert-Test "Get-BuddyBackupPluginVerifyCommand generates valid verification script" {
    $verifyCmd = Get-BuddyBackupPluginVerifyCommand
    if ([string]::IsNullOrWhiteSpace($verifyCmd)) {
        throw "Verify command was empty"
    }

    if ($verifyCmd -notmatch 'set -eu') {
        throw "Missing 'set -eu' in verify command"
    }

    if ($verifyCmd -notmatch 'plugin list \| grep -i buddybackup') {
        throw "Missing plugin list grep in verify command"
    }

    if ($verifyCmd -notmatch '/boot/config/plugins/buddybackup/buddybackup\.txz') {
        throw "Missing buddybackup.txz check in verify command"
    }

    if ($verifyCmd -notmatch '/usr/local/emhttp/plugins/buddybackup/scripts/rc\.buddybackup\.php') {
        throw "Missing rc.buddybackup.php check in verify command"
    }

    # Verify bash syntax if wsl is present
    $wsl = Get-Command wsl.exe -ErrorAction SilentlyContinue
    if ($wsl) {
        $b64 = [Convert]::ToBase64String([System.Text.Encoding]::UTF8.GetBytes($verifyCmd))
        $proc = Start-Process -FilePath "wsl.exe" -ArgumentList @("--", "bash", "-c", "echo $b64 | base64 -d | bash -n") -NoNewWindow -Wait -PassThru
        if ($proc.ExitCode -ne 0) {
            throw "Bash syntax error in Get-BuddyBackupPluginVerifyCommand (ExitCode: $($proc.ExitCode))"
        }
    }
}

# ---------------------------------------------------------------------------
# Test 4: Get-SetupZfsValues default and custom configs
# ---------------------------------------------------------------------------
Assert-Test "Get-SetupZfsValues returns standard defaults when unconfigured" {
    $defaults = Get-SetupZfsValues -Lab $null
    if ($defaults.PoolName -ne "bbpool") {
        throw "Expected default PoolName 'bbpool', got '$($defaults.PoolName)'"
    }
    if ($defaults.DatasetRoot -ne "bbpool/buddybackup") {
        throw "Expected default DatasetRoot 'bbpool/buddybackup', got '$($defaults.DatasetRoot)'"
    }
    if ($defaults.UnencryptedDataset -ne "bbpool/buddybackup/plain") {
        throw "Expected default UnencryptedDataset 'bbpool/buddybackup/plain', got '$($defaults.UnencryptedDataset)'"
    }
    if ($defaults.EncryptedDataset -ne "bbpool/buddybackup/secure") {
        throw "Expected default EncryptedDataset 'bbpool/buddybackup/secure', got '$($defaults.EncryptedDataset)'"
    }
}

Assert-Test "Get-SetupZfsValues respects custom lab configuration values" {
    $customLab = [pscustomobject]@{
        setup = [pscustomobject]@{
            zfs = [pscustomobject]@{
                poolName               = "tank"
                datasetRoot            = "backups"
                unencryptedDatasetName = "unenc"
                encryptedDatasetName   = "secret"
            }
        }
    }

    $custom = Get-SetupZfsValues -Lab $customLab
    if ($custom.PoolName -ne "tank") {
        throw "Expected PoolName 'tank', got '$($custom.PoolName)'"
    }
    if ($custom.DatasetRoot -ne "tank/backups") {
        throw "Expected DatasetRoot 'tank/backups', got '$($custom.DatasetRoot)'"
    }
    if ($custom.UnencryptedDataset -ne "tank/backups/unenc") {
        throw "Expected UnencryptedDataset 'tank/backups/unenc', got '$($custom.UnencryptedDataset)'"
    }
    if ($custom.EncryptedDataset -ne "tank/backups/secret") {
        throw "Expected EncryptedDataset 'tank/backups/secret', got '$($custom.EncryptedDataset)'"
    }
}

# ---------------------------------------------------------------------------
# Test 5: ConvertFrom-UpgradeStateOutput parsing mock state text
# ---------------------------------------------------------------------------
Assert-Test "ConvertFrom-UpgradeStateOutput parses formatted state summary text" {
    $mockOutput = @'
plugin_cfg_sha256=a1b2c3d4e5f6
backups_cfg_sha256=123456abcdef
snapshots_cfg_sha256=fedcba654321
sender_key_sha256=keyhash123
known_hosts_sha256=khash456
known_hosts_key_material_sha256=khmathash789
known_hosts_line_count=4
known_hosts_key_types=ecdsa-sha2-nistp256,ssh-ed25519,ssh-rsa
authorized_keys_sha256=akhash012
authorized_keys_key_material_sha256=akmathash345
sanoid_conf_sha256=sanoidhash678
sanoid_conf_contains_receive_dataset=yes
incoming_cfg_present=yes
receive_enable=yes
receive_destinations=bbpool/buddybackup/upgrade/receive-nodeA
receive_ssh_key_count=1
buddybackup_user_present=yes
allow_users_contains_buddybackup=yes
match_user_buddybackup=yes
plugin_cfg_line=ReceiveBackups="enable"
plugin_cfg_line=ReceiveDestinationDataset="bbpool/buddybackup/upgrade/receive-nodeA"
plugin_cfg_line=UtcTimezone="yes"
plugin_cfg_line=AllowUnencryptedRemoteBackups="no"
general_plugin_cfg_line=UtcTimezone="yes"
general_plugin_cfg_line=AllowUnencryptedRemoteBackups="no"
backup_section=aupgrm01
backup_section=aupglc01
snapshot_section=aupgsn01
backup_cron=backup-aupgrm01.cron
backup_cron=backup-aupglc01.cron
'@

    $snapshot = ConvertFrom-UpgradeStateOutput -Output $mockOutput

    if ($snapshot.pluginCfgSha256 -ne "a1b2c3d4e5f6") { throw "pluginCfgSha256 mismatch" }
    if ($snapshot.backupsCfgSha256 -ne "123456abcdef") { throw "backupsCfgSha256 mismatch" }
    if ($snapshot.snapshotsCfgSha256 -ne "fedcba654321") { throw "snapshotsCfgSha256 mismatch" }
    if ($snapshot.senderKeySha256 -ne "keyhash123") { throw "senderKeySha256 mismatch" }
    if ($snapshot.knownHostsSha256 -ne "khash456") { throw "knownHostsSha256 mismatch" }
    if ($snapshot.knownHostsKeyMaterialSha256 -ne "khmathash789") { throw "knownHostsKeyMaterialSha256 mismatch" }
    if ($snapshot.knownHostsLineCount -ne 4) { throw "knownHostsLineCount mismatch: expected 4, got $($snapshot.knownHostsLineCount)" }
    if (@($snapshot.knownHostsKeyTypes).Count -ne 3) { throw "Expected 3 knownHostsKeyTypes, got $($snapshot.knownHostsKeyTypes.Count)" }
    if ($snapshot.incomingCfgPresent -ne "yes") { throw "incomingCfgPresent mismatch" }
    if ($snapshot.receiveEnable -ne "yes") { throw "receiveEnable mismatch" }
    if (@($snapshot.receiveDestinations) -notcontains "bbpool/buddybackup/upgrade/receive-nodeA") { throw "receiveDestinations mismatch" }
    if ($snapshot.receiveSshKeyCount -ne 1) { throw "receiveSshKeyCount mismatch: expected 1, got $($snapshot.receiveSshKeyCount)" }
    if ($snapshot.authorizedKeysSha256 -ne "akhash012") { throw "authorizedKeysSha256 mismatch" }
    if ($snapshot.authorizedKeysKeyMaterialSha256 -ne "akmathash345") { throw "authorizedKeysKeyMaterialSha256 mismatch" }
    if ($snapshot.sanoidConfSha256 -ne "sanoidhash678") { throw "sanoidConfSha256 mismatch" }
    if ($snapshot.sanoidConfContainsReceiveDataset -ne "yes") { throw "sanoidConfContainsReceiveDataset mismatch" }
    if ($snapshot.buddybackupUserPresent -ne "yes") { throw "buddybackupUserPresent mismatch" }
    if ($snapshot.allowUsersContainsBuddybackup -ne "yes") { throw "allowUsersContainsBuddybackup mismatch" }
    if ($snapshot.matchUserBuddybackup -ne "yes") { throw "matchUserBuddybackup mismatch" }

    if ($snapshot.pluginCfgLines.Count -ne 4) { throw "Expected 4 pluginCfgLines, got $($snapshot.pluginCfgLines.Count)" }
    if ($snapshot.backupSections.Count -ne 2) { throw "Expected 2 backupSections, got $($snapshot.backupSections.Count)" }
    if ($snapshot.snapshotSections.Count -ne 1) { throw "Expected 1 snapshotSections, got $($snapshot.snapshotSections.Count)" }
    if ($snapshot.backupCrons.Count -ne 2) { throw "Expected 2 backupCrons, got $($snapshot.backupCrons.Count)" }

    # Arrays must be sorted uniquely
    if ($snapshot.backupSections[0] -ne "aupglc01" -or $snapshot.backupSections[1] -ne "aupgrm01") {
        throw "backupSections not sorted alphabetically"
    }
}

# ---------------------------------------------------------------------------
# Test 6: Compare-UpgradeStateSnapshots detects identical vs altered state
# ---------------------------------------------------------------------------
Assert-Test "Compare-UpgradeStateSnapshots passes when states are identical" {
    $stateA = [pscustomobject]@{
        backupsCfgSha256                 = "abc"
        snapshotsCfgSha256               = "def"
        senderKeySha256                  = "ghi"
        knownHostsKeyTypes               = @("ssh-ed25519")
        authorizedKeysKeyMaterialSha256  = "mno"
        sanoidConfContainsReceiveDataset = "yes"
        receiveEnable                    = "yes"
        receiveDestinations              = @("ds1")
        receiveSshKeyCount               = 1
        buddybackupUserPresent           = "yes"
        allowUsersContainsBuddybackup    = "yes"
        matchUserBuddybackup             = "yes"
        generalPluginCfgLines            = @('UtcTimezone="yes"', 'AllowUnencrypted="no"')
        backupSections                   = @("sec1", "sec2")
        snapshotSections                 = @("snap1")
        backupCrons                      = @("cron1", "cron2")
    }

    $stateB = [pscustomobject]@{
        backupsCfgSha256                 = "abc"
        snapshotsCfgSha256               = "def"
        senderKeySha256                  = "ghi"
        knownHostsKeyTypes               = @("ssh-ed25519")
        authorizedKeysKeyMaterialSha256  = "mno"
        sanoidConfContainsReceiveDataset = "yes"
        receiveEnable                    = "yes"
        receiveDestinations              = @("ds1")
        receiveSshKeyCount               = 1
        buddybackupUserPresent           = "yes"
        allowUsersContainsBuddybackup    = "yes"
        matchUserBuddybackup             = "yes"
        generalPluginCfgLines            = @('UtcTimezone="yes"', 'AllowUnencrypted="no"')
        backupSections                   = @("sec1", "sec2")
        snapshotSections                 = @("snap1")
        backupCrons                      = @("cron1", "cron2")
    }

    $comp = Compare-UpgradeStateSnapshots -NodeName "nodeA" -Before $stateA -After $stateB
    if (-not $comp.Success) {
        throw "Expected identical comparison to succeed, but got error: $($comp.Error)"
    }
}

Assert-Test "Compare-UpgradeStateSnapshots detects scalar and array alterations" {
    $baseState = [pscustomobject]@{
        backupsCfgSha256                 = "abc"
        snapshotsCfgSha256               = "def"
        senderKeySha256                  = "ghi"
        knownHostsKeyTypes               = @("ssh-ed25519")
        authorizedKeysKeyMaterialSha256  = "mno"
        sanoidConfContainsReceiveDataset = "yes"
        receiveEnable                    = "yes"
        receiveDestinations              = @("ds1")
        receiveSshKeyCount               = 1
        buddybackupUserPresent           = "yes"
        allowUsersContainsBuddybackup    = "yes"
        matchUserBuddybackup             = "yes"
        generalPluginCfgLines            = @('UtcTimezone="yes"')
        backupSections                   = @("sec1", "sec2")
        snapshotSections                 = @("snap1")
        backupCrons                      = @("cron1", "cron2")
    }

    # Alter scalar property
    $alteredScalar = [pscustomobject]@{
        backupsCfgSha256                 = "CHANGED"
        snapshotsCfgSha256               = "def"
        senderKeySha256                  = "ghi"
        knownHostsKeyTypes               = @("ssh-ed25519")
        authorizedKeysKeyMaterialSha256  = "mno"
        sanoidConfContainsReceiveDataset = "yes"
        receiveEnable                    = "yes"
        receiveDestinations              = @("ds1")
        receiveSshKeyCount               = 1
        buddybackupUserPresent           = "yes"
        allowUsersContainsBuddybackup    = "yes"
        matchUserBuddybackup             = "yes"
        generalPluginCfgLines            = @('UtcTimezone="yes"')
        backupSections                   = @("sec1", "sec2")
        snapshotSections                 = @("snap1")
        backupCrons                      = @("cron1", "cron2")
    }

    $compScalar = Compare-UpgradeStateSnapshots -NodeName "nodeA" -Before $baseState -After $alteredScalar
    if ($compScalar.Success) {
        throw "Expected comparison to fail for altered scalar"
    }
    if ($compScalar.Error -notmatch "backupsCfgSha256: before=\[abc\] after=\[CHANGED\]") {
        throw "Unexpected error message: $($compScalar.Error)"
    }

    # Alter array property
    $alteredArray = [pscustomobject]@{
        backupsCfgSha256                 = "abc"
        snapshotsCfgSha256               = "def"
        senderKeySha256                  = "ghi"
        knownHostsKeyTypes               = @("ssh-ed25519")
        authorizedKeysKeyMaterialSha256  = "mno"
        sanoidConfContainsReceiveDataset = "yes"
        receiveEnable                    = "yes"
        receiveDestinations              = @("ds1")
        receiveSshKeyCount               = 1
        buddybackupUserPresent           = "yes"
        allowUsersContainsBuddybackup    = "yes"
        matchUserBuddybackup             = "yes"
        generalPluginCfgLines            = @('UtcTimezone="yes"')
        backupSections                   = @("sec1", "sec2", "sec3")
        snapshotSections                 = @("snap1")
        backupCrons                      = @("cron1", "cron2")
    }

    $compArray = Compare-UpgradeStateSnapshots -NodeName "nodeA" -Before $baseState -After $alteredArray
    if ($compArray.Success) {
        throw "Expected comparison to fail for altered array"
    }
    if ($compArray.Error -notmatch "backupSections:") {
        throw "Unexpected error message for array alteration: $($compArray.Error)"
    }

    # Known host key types are a superset check: scans may discover an extra
    # algorithm, but an algorithm present before the upgrade must not vanish.
    $supersetState = $baseState.PSObject.Copy()
    $supersetState.knownHostsKeyTypes = @("ssh-ed25519", "ssh-rsa")
    $compSuperset = Compare-UpgradeStateSnapshots -NodeName "nodeA" -Before $baseState -After $supersetState
    if (-not $compSuperset.Success) {
        throw "Expected added known_hosts key types to be accepted, got: $($compSuperset.Error)"
    }

    $subsetState = $baseState.PSObject.Copy()
    $subsetState.knownHostsKeyTypes = @()
    $compSubset = Compare-UpgradeStateSnapshots -NodeName "nodeA" -Before $baseState -After $subsetState
    if ($compSubset.Success) {
        throw "Expected comparison to fail when a known_hosts key type disappears"
    }
    if ($compSubset.Error -notmatch "knownHostsKeyTypes:") {
        throw "Unexpected error message for known_hosts key type loss: $($compSubset.Error)"
    }
}

# ---------------------------------------------------------------------------
# Test 7: Get-UpgradeScenarioNodePlan generates valid node configs
# ---------------------------------------------------------------------------
Assert-Test "Get-UpgradeScenarioNodePlan produces correct node plans for nodeA and nodeB" {
    $zfsValues = [pscustomobject]@{ DatasetRoot = "bbpool/buddybackup" }
    $funcCfg = [pscustomobject]@{
        nodeAAliasIp = "10.0.2.20"
        nodeBAliasIp = "10.0.2.21"
    }
    $connA = [pscustomobject]@{ Port = 2222 }
    $connB = [pscustomobject]@{ Port = 2223 }

    $planA = Get-UpgradeScenarioNodePlan -NodeName "sender" -Connection $connA -ZfsValues $zfsValues -FunctionalCfg $funcCfg
    if ($planA.NodeName -ne "nodeA") { throw "Expected NodeName 'nodeA', got '$($planA.NodeName)'" }
    if ($planA.RemoteBackupUid -ne "aupgrm01") { throw "Expected RemoteBackupUid 'aupgrm01', got '$($planA.RemoteBackupUid)'" }
    if ($planA.LocalBackupUid -ne "aupglc01") { throw "Expected LocalBackupUid 'aupglc01', got '$($planA.LocalBackupUid)'" }
    if ($planA.SnapshotUid -ne "aupgsn01") { throw "Expected SnapshotUid 'aupgsn01', got '$($planA.SnapshotUid)'" }
    if ($planA.AliasIp -ne "10.0.2.20") { throw "Expected AliasIp '10.0.2.20', got '$($planA.AliasIp)'" }
    if ($planA.Port -ne 2222) { throw "Expected Port 2222, got $($planA.Port)" }

    $planB = Get-UpgradeScenarioNodePlan -NodeName "nodeB" -Connection $connB -ZfsValues $zfsValues -FunctionalCfg $funcCfg
    if ($planB.NodeName -ne "nodeB") { throw "Expected NodeName 'nodeB', got '$($planB.NodeName)'" }
    if ($planB.RemoteBackupUid -ne "bupgrm01") { throw "Expected RemoteBackupUid 'bupgrm01', got '$($planB.RemoteBackupUid)'" }
    if ($planB.LocalBackupUid -ne "bupglc01") { throw "Expected LocalBackupUid 'bupglc01', got '$($planB.LocalBackupUid)'" }
    if ($planB.SnapshotUid -ne "bupgsn01") { throw "Expected SnapshotUid 'bupgsn01', got '$($planB.SnapshotUid)'" }
    if ($planB.AliasIp -ne "10.0.2.21") { throw "Expected AliasIp '10.0.2.21', got '$($planB.AliasIp)'" }
    if ($planB.Port -ne 2223) { throw "Expected Port 2223, got $($planB.Port)" }
}

# ---------------------------------------------------------------------------
# Test 8: ManualAccess and Lifecycle dry-run safety
# ---------------------------------------------------------------------------
Assert-Test "Manual access commands format properly and lifecycle dry-run succeeds" {
    $manualCfg = Get-ManualAccessConfig -Lab $null
    if ($manualCfg.webGuiUser -ne "root") { throw "Expected root user" }
    if ($manualCfg.webGuiPassword -ne "buddybackup-testlab") { throw "Expected default password" }

    $verifyCmd = Get-ManualAccessVerifyCommand -Lab $null
    if ($verifyCmd -notmatch 'awk -F: ''\$1=="root" \{ print \$2 \}'' /etc/shadow') {
        throw "Manual access verify command missing shadow awk check"
    }

    $fakeConn = [pscustomobject]@{ User = "root"; Host = "127.0.0.1"; Port = 22; IdentityFile = $null }

    $bootSettle = Wait-NodeBootSettle -NodeConnection $fakeConn -DoExecute:$false
    if (-not $bootSettle.Success) { throw "Dry-run Wait-NodeBootSettle failed" }

    $rebootCycle = Wait-ForRebootCycle -NodeConnection $fakeConn -DoExecute:$false
    if (-not $rebootCycle.Success -or $rebootCycle.BootId -ne "dry-run-boot-id") {
        throw "Dry-run Wait-ForRebootCycle failed"
    }

    $zfsCreate = New-ZfsDataset -NodeConnection $fakeConn -Dataset "bbpool/test" -DoExecute:$false
    if (-not $zfsCreate.Success) { throw "Dry-run New-ZfsDataset failed" }

    $zfsDestroy = Ensure-ZfsDatasetAbsent -NodeConnection $fakeConn -Dataset "bbpool/test" -DoExecute:$false
    if (-not $zfsDestroy.Success) { throw "Dry-run Ensure-ZfsDatasetAbsent failed" }
}

# ---------------------------------------------------------------------------
# Test 9: Post-Reboot Ready Command Shadow Check
# ---------------------------------------------------------------------------
Assert-Test "BuddyBackup post-reboot ready command enforces unlocked shadow account check" {
    $readyCmd = Get-BuddyBackupPostRebootReadyCommand
    if ($readyCmd -notmatch 'awk -F: ''BEGIN\{rc=1\} \$1=="buddybackup"') {
        throw "Post-reboot ready command missing awk shadow account check for buddybackup"
    }
    if ($readyCmd -notmatch '\(\$2 ~ /\^\[!\*\]/\)') {
        throw "Post-reboot ready command missing locked password check in shadow"
    }
}

Write-Host "--------------------------------------------------"
$summaryColor = if ($testsFailed -eq 0) { "Green" } else { "Red" }
Write-Host "Guest Tests: $testsRun Total | $testsPassed Passed | $testsFailed Failed" -ForegroundColor $summaryColor

if ($testsFailed -gt 0) {
    exit 1
}
exit 0
