<#
.SYNOPSIS
    BuddyBackup upgrade configuration persistence test scenario.
.DESCRIPTION
    Installs an older version of BuddyBackup, seeds configuration and datasets,
    takes a pre-upgrade state snapshot, upgrades to a target version,
    takes a post-upgrade state snapshot, and verifies complete configuration persistence.
#>

[CmdletBinding()]
param(
    [string]$LabConfig = "testlab/config/lab.local.json",
    [string]$UpgradeFrom = "2026.05.02",
    [string]$UpgradeTo = "workspace-build",
    [string]$CellId = "upgrade-preserves-config",
    [string]$OutputDir = $null,
    [switch]$Execute
)

$ErrorActionPreference = "Stop"

# Import required modules
$modulesRoot = Join-Path $PSScriptRoot "..\modules"
foreach ($module in @("TestLab.Core", "TestLab.Transport", "TestLab.Guest")) {
    $manifestPath = Join-Path $modulesRoot "$module\$module.psd1"
    $modulePath = if (Test-Path -LiteralPath $manifestPath) { $manifestPath } else { Join-Path $modulesRoot "$module\$module.psm1" }
    if (Test-Path -LiteralPath $modulePath) {
        Import-Module (Resolve-Path -LiteralPath $modulePath).ProviderPath -DisableNameChecking -Force:$false
    }
}

$results = @()
$resolvedOutputDir = if (-not [string]::IsNullOrWhiteSpace($OutputDir)) { Resolve-TestLabPath -Path $OutputDir } else { $null }

try {
    Write-Host "[testlab] Resolving testlab configuration from '$LabConfig'..."
    $Lab = Get-TestLabConfig -Path $LabConfig
    $sender = Get-NodeConnection -Lab $Lab -NodeName "nodeA"
    $receiver = Get-NodeConnection -Lab $Lab -NodeName "nodeB"

    $workspaceRoot = Get-TestLabWorkspaceRoot -ScriptRoot $PSScriptRoot
    $configuredBuildCacheRoot = Get-ObjectValue -Target $Lab -Path "plugin.buildCacheRoot"
    $fromRequestA = Resolve-TestLabPluginRequest -RequestedValue $UpgradeFrom -WorkspaceRoot $workspaceRoot -ConfiguredBuildCacheRoot $configuredBuildCacheRoot
    $fromRequestB = Resolve-TestLabPluginRequest -RequestedValue $UpgradeFrom -WorkspaceRoot $workspaceRoot -ConfiguredBuildCacheRoot $configuredBuildCacheRoot
    $toRequestA = Resolve-TestLabPluginRequest -RequestedValue $UpgradeTo -WorkspaceRoot $workspaceRoot -ConfiguredBuildCacheRoot $configuredBuildCacheRoot
    $toRequestB = Resolve-TestLabPluginRequest -RequestedValue $UpgradeTo -WorkspaceRoot $workspaceRoot -ConfiguredBuildCacheRoot $configuredBuildCacheRoot

    $functionalCfg = Get-FunctionalTestConfig -Lab $Lab
    $zfsValues = Get-SetupZfsValues -Lab $Lab

    $senderPlan = Get-UpgradeScenarioNodePlan -NodeName "nodeA" -Connection $sender -ZfsValues $zfsValues -FunctionalCfg $functionalCfg
    $receiverPlan = Get-UpgradeScenarioNodePlan -NodeName "nodeB" -Connection $receiver -ZfsValues $zfsValues -FunctionalCfg $functionalCfg

    $senderPlan | Add-Member -NotePropertyName RemoteDestinationDataset -NotePropertyValue "$($receiverPlan.ReceiveRootDataset)/from-nodeA" -Force
    $senderPlan | Add-Member -NotePropertyName RemoteHost -NotePropertyValue $(if ($receiver.Port -eq 22) { $receiver.Host } else { $receiverPlan.AliasIp }) -Force
    $senderPlan | Add-Member -NotePropertyName PeerAliasIp -NotePropertyValue $receiverPlan.AliasIp -Force
    $receiverPlan | Add-Member -NotePropertyName RemoteDestinationDataset -NotePropertyValue "$($senderPlan.ReceiveRootDataset)/from-nodeB" -Force
    $receiverPlan | Add-Member -NotePropertyName RemoteHost -NotePropertyValue $(if ($sender.Port -eq 22) { $sender.Host } else { $senderPlan.AliasIp }) -Force
    $receiverPlan | Add-Member -NotePropertyName PeerAliasIp -NotePropertyValue $senderPlan.AliasIp -Force

    Write-Host "[testlab] Scenario '$CellId': Installing pre-upgrade BuddyBackup ($($fromRequestA.label)) on nodeA..."
    $results += Install-Plugin -Lab $Lab -NodeConnection $sender -PluginRequest $fromRequestA -DoExecute:$Execute

    Write-Host "[testlab] Scenario '$CellId': Installing pre-upgrade BuddyBackup ($($fromRequestB.label)) on nodeB..."
    $results += Install-Plugin -Lab $Lab -NodeConnection $receiver -PluginRequest $fromRequestB -DoExecute:$Execute

    $senderKeyInfo = Get-RemoteFileValue -NodeConnection $sender -Path "/boot/config/plugins/buddybackup/buddybackup_sender_key.pub" -Label "nodeA-upgrade-public-key" -DoExecute:$Execute
    $receiverKeyInfo = Get-RemoteFileValue -NodeConnection $receiver -Path "/boot/config/plugins/buddybackup/buddybackup_sender_key.pub" -Label "nodeB-upgrade-public-key" -DoExecute:$Execute
    $results += $senderKeyInfo.Result
    $results += $receiverKeyInfo.Result

    $setupScript = New-UpgradePreservesConfigSetupScript
    if (-not $Execute -or (($senderKeyInfo.Result.Success -and $senderKeyInfo.Value) -and ($receiverKeyInfo.Result.Success -and $receiverKeyInfo.Value))) {
        $senderSetupCommand = Convert-ToRemoteBashScriptCommand -Script $setupScript -Arguments @(
            'nodeA',
            [string]$senderPlan.SourceDataset,
            [string]$senderPlan.SourceMountpoint,
            [string]$senderPlan.LocalBackupDataset,
            [string]$senderPlan.ReceiveRootDataset,
            [string]$senderPlan.RemoteBackupUid,
            [string]$senderPlan.LocalBackupUid,
            [string]$senderPlan.SnapshotUid,
            [string]$senderPlan.RemoteHost,
            [string]$senderPlan.RemoteDestinationDataset,
            [string]$functionalCfg.allowUnencryptedRemoteBackups,
            [string]$(if ($receiverKeyInfo.Value) { $receiverKeyInfo.Value } else { 'dry-run' }),
            [string]$functionalCfg.hostGatewayIp,
            [string]$receiver.Port,
            [string]$senderPlan.PeerAliasIp
        )
        $receiverSetupCommand = Convert-ToRemoteBashScriptCommand -Script $setupScript -Arguments @(
            'nodeB',
            [string]$receiverPlan.SourceDataset,
            [string]$receiverPlan.SourceMountpoint,
            [string]$receiverPlan.LocalBackupDataset,
            [string]$receiverPlan.ReceiveRootDataset,
            [string]$receiverPlan.RemoteBackupUid,
            [string]$receiverPlan.LocalBackupUid,
            [string]$receiverPlan.SnapshotUid,
            [string]$receiverPlan.RemoteHost,
            [string]$receiverPlan.RemoteDestinationDataset,
            [string]$functionalCfg.allowUnencryptedRemoteBackups,
            [string]$(if ($senderKeyInfo.Value) { $senderKeyInfo.Value } else { 'dry-run' }),
            [string]$functionalCfg.hostGatewayIp,
            [string]$sender.Port,
            [string]$receiverPlan.PeerAliasIp
        )
        $results += Invoke-RemoteCommandWithRetry -NodeConnection $sender -Command $senderSetupCommand -LoggedCommand "seed pre-upgrade BuddyBackup state on nodeA" -Label "nodeA-upgrade-seed" -DoExecute:$Execute
        $results += Invoke-RemoteCommandWithRetry -NodeConnection $receiver -Command $receiverSetupCommand -LoggedCommand "seed pre-upgrade BuddyBackup state on nodeB" -Label "nodeB-upgrade-seed" -DoExecute:$Execute
    } else {
        $results += [pscustomobject]@{
            Label    = 'upgrade-seed-prerequisites'
            Command  = 'read BuddyBackup public keys'
            ExitCode = 1
            Output   = 'Failed to read the BuddyBackup public keys needed to seed pre-upgrade state.'
            Success  = $false
        }
    }

    $senderBefore = Get-UpgradeStateSnapshot -NodeName 'nodeA' -NodeConnection $sender -DoExecute:$Execute
    $receiverBefore = Get-UpgradeStateSnapshot -NodeName 'nodeB' -NodeConnection $receiver -DoExecute:$Execute
    $results += $senderBefore.Result
    $results += $receiverBefore.Result

    if ($Execute) {
        if ($senderBefore.Snapshot) {
            if (-not [string]::IsNullOrWhiteSpace($resolvedOutputDir)) {
                $senderBefore.Snapshot | ConvertTo-Json -Depth 6 | Set-Content -Path (Join-Path $resolvedOutputDir 'nodeA-upgrade-state-before.json')
            }
            $senderBeforeCheck = Test-UpgradeStateSnapshot -NodeName 'nodeA' -Snapshot $senderBefore.Snapshot -Plan $senderPlan -AllowUnencryptedRemoteBackups $functionalCfg.allowUnencryptedRemoteBackups
            $results += [pscustomobject]@{
                Label    = 'nodeA-upgrade-before-sanity'
                Command  = 'verify seeded pre-upgrade BuddyBackup state'
                ExitCode = if ($senderBeforeCheck.Success) { 0 } else { 1 }
                Output   = if ($senderBeforeCheck.Success) { 'Seeded pre-upgrade state is present.' } else { $senderBeforeCheck.Error }
                Success  = $senderBeforeCheck.Success
            }
        }

        if ($receiverBefore.Snapshot) {
            if (-not [string]::IsNullOrWhiteSpace($resolvedOutputDir)) {
                $receiverBefore.Snapshot | ConvertTo-Json -Depth 6 | Set-Content -Path (Join-Path $resolvedOutputDir 'nodeB-upgrade-state-before.json')
            }
            $receiverBeforeCheck = Test-UpgradeStateSnapshot -NodeName 'nodeB' -Snapshot $receiverBefore.Snapshot -Plan $receiverPlan -AllowUnencryptedRemoteBackups $functionalCfg.allowUnencryptedRemoteBackups
            $results += [pscustomobject]@{
                Label    = 'nodeB-upgrade-before-sanity'
                Command  = 'verify seeded pre-upgrade BuddyBackup state'
                ExitCode = if ($receiverBeforeCheck.Success) { 0 } else { 1 }
                Output   = if ($receiverBeforeCheck.Success) { 'Seeded pre-upgrade state is present.' } else { $receiverBeforeCheck.Error }
                Success  = $receiverBeforeCheck.Success
            }
        }
    } else {
        $results += [pscustomobject]@{
            Label    = 'nodeA-upgrade-before-sanity'
            Command  = 'verify seeded pre-upgrade BuddyBackup state'
            ExitCode = 0
            Output   = 'dry-run'
            Success  = $true
        }
        $results += [pscustomobject]@{
            Label    = 'nodeB-upgrade-before-sanity'
            Command  = 'verify seeded pre-upgrade BuddyBackup state'
            ExitCode = 0
            Output   = 'dry-run'
            Success  = $true
        }
    }

    Write-Host "[testlab] Scenario '$CellId': Upgrading BuddyBackup on nodeA to $($toRequestA.label)..."
    $results += Install-Plugin -Lab $Lab -NodeConnection $sender -PluginRequest $toRequestA -DoExecute:$Execute

    Write-Host "[testlab] Scenario '$CellId': Upgrading BuddyBackup on nodeB to $($toRequestB.label)..."
    $results += Install-Plugin -Lab $Lab -NodeConnection $receiver -PluginRequest $toRequestB -DoExecute:$Execute

    $senderAfter = Get-UpgradeStateSnapshot -NodeName 'nodeA' -NodeConnection $sender -DoExecute:$Execute
    $receiverAfter = Get-UpgradeStateSnapshot -NodeName 'nodeB' -NodeConnection $receiver -DoExecute:$Execute
    $results += $senderAfter.Result
    $results += $receiverAfter.Result

    if ($Execute) {
        if ($senderAfter.Snapshot -and -not [string]::IsNullOrWhiteSpace($resolvedOutputDir)) {
            $senderAfter.Snapshot | ConvertTo-Json -Depth 6 | Set-Content -Path (Join-Path $resolvedOutputDir 'nodeA-upgrade-state-after.json')
        }
        if ($receiverAfter.Snapshot -and -not [string]::IsNullOrWhiteSpace($resolvedOutputDir)) {
            $receiverAfter.Snapshot | ConvertTo-Json -Depth 6 | Set-Content -Path (Join-Path $resolvedOutputDir 'nodeB-upgrade-state-after.json')
        }

        if ($senderBefore.Snapshot -and $senderAfter.Snapshot) {
            $senderCompare = Compare-UpgradeStateSnapshots -NodeName 'nodeA' -Before $senderBefore.Snapshot -After $senderAfter.Snapshot
            if (-not $senderCompare.Success -and $senderCompare.Error -like "*KeyMaterialSha256*") {
                for ($attempt = 1; $attempt -le 5; $attempt++) {
                    Write-Host "[testlab] Refreshing BuddyBackup known_hosts post-upgrade for nodeA (attempt $attempt)"
                    Start-Sleep -Seconds 2
                    $refreshResult = Invoke-RemoteCommand -NodeConnection $sender -Command "/usr/local/emhttp/plugins/buddybackup/scripts/rc.buddybackup.php update" -Label "nodeA-post-upgrade-refresh-retry-$attempt" -DoExecute:$Execute
                    $results += $refreshResult
                    $senderAfter = Get-UpgradeStateSnapshot -NodeName 'nodeA' -NodeConnection $sender -DoExecute:$Execute
                    $results += $senderAfter.Result
                    $senderCompare = Compare-UpgradeStateSnapshots -NodeName 'nodeA' -Before $senderBefore.Snapshot -After $senderAfter.Snapshot
                    if ($senderCompare.Success -or ($senderCompare.Error -notlike "*KeyMaterialSha256*")) {
                        break
                    }
                }
            }
            $results += [pscustomobject]@{
                Label    = 'nodeA-upgrade-state-compare'
                Command  = 'compare pre-upgrade and post-upgrade BuddyBackup state'
                ExitCode = if ($senderCompare.Success) { 0 } else { 1 }
                Output   = if ($senderCompare.Success) { 'BuddyBackup state was preserved across the upgrade.' } else { $senderCompare.Error }
                Success  = $senderCompare.Success
            }
        }

        if ($receiverBefore.Snapshot -and $receiverAfter.Snapshot) {
            $receiverCompare = Compare-UpgradeStateSnapshots -NodeName 'nodeB' -Before $receiverBefore.Snapshot -After $receiverAfter.Snapshot
            if (-not $receiverCompare.Success -and $receiverCompare.Error -like "*KeyMaterialSha256*") {
                for ($attempt = 1; $attempt -le 5; $attempt++) {
                    Write-Host "[testlab] Refreshing BuddyBackup known_hosts post-upgrade for nodeB (attempt $attempt)"
                    Start-Sleep -Seconds 2
                    $refreshResult = Invoke-RemoteCommand -NodeConnection $receiver -Command "/usr/local/emhttp/plugins/buddybackup/scripts/rc.buddybackup.php update" -Label "nodeB-post-upgrade-refresh-retry-$attempt" -DoExecute:$Execute
                    $results += $refreshResult
                    $receiverAfter = Get-UpgradeStateSnapshot -NodeName 'nodeB' -NodeConnection $receiver -DoExecute:$Execute
                    $results += $receiverAfter.Result
                    $receiverCompare = Compare-UpgradeStateSnapshots -NodeName 'nodeB' -Before $receiverBefore.Snapshot -After $receiverAfter.Snapshot
                    if ($receiverCompare.Success -or ($receiverCompare.Error -notlike "*KeyMaterialSha256*")) {
                        break
                    }
                }
            }
            $results += [pscustomobject]@{
                Label    = 'nodeB-upgrade-state-compare'
                Command  = 'compare pre-upgrade and post-upgrade BuddyBackup state'
                ExitCode = if ($receiverCompare.Success) { 0 } else { 1 }
                Output   = if ($receiverCompare.Success) { 'BuddyBackup state was preserved across the upgrade.' } else { $receiverCompare.Error }
                Success  = $receiverCompare.Success
            }
        }
    } else {
        $results += [pscustomobject]@{
            Label    = 'nodeA-upgrade-state-compare'
            Command  = 'compare pre-upgrade and post-upgrade BuddyBackup state'
            ExitCode = 0
            Output   = 'dry-run'
            Success  = $true
        }
        $results += [pscustomobject]@{
            Label    = 'nodeB-upgrade-state-compare'
            Command  = 'compare pre-upgrade and post-upgrade BuddyBackup state'
            ExitCode = 0
            Output   = 'dry-run'
            Success  = $true
        }
    }

    $failed = @($results | Where-Object { -not $_.Success })
    $success = ($failed.Count -eq 0)
    $errorMessage = if (-not $success) {
        $labels = @($failed | ForEach-Object { $_.Label }) -join ", "
        "Failed command labels: $labels"
    } else {
        $null
    }

    $scenarioResult = [pscustomobject]@{
        Scenario = 'upgrade-preserves-config'
        Success  = $success
        Results  = $results
        Error    = $errorMessage
    }

    if (-not [string]::IsNullOrWhiteSpace($resolvedOutputDir)) {
        Ensure-TestLabDir -Path $resolvedOutputDir
        $outputPath = Join-Path $resolvedOutputDir "scenario-upgrade-preserves-config.json"
        Set-TestLabJson -Path $outputPath -Object $scenarioResult
        Write-Host "[testlab] Scenario results written to $outputPath"
    }

    if ($MyInvocation.InvocationName -eq '.') {
        return $scenarioResult
    } else {
        $scenarioResult
        if ($success) { exit 0 } else { exit 1 }
    }
} catch {
    $err = ($_ | Out-String).Trim()
    Write-Warning "[testlab] Scenario '$CellId' encountered an error: $err"
    $scenarioResult = [pscustomobject]@{
        Scenario = 'upgrade-preserves-config'
        Success  = $false
        Results  = $results
        Error    = $err
    }

    if (-not [string]::IsNullOrWhiteSpace($resolvedOutputDir)) {
        try {
            Ensure-TestLabDir -Path $resolvedOutputDir
            $outputPath = Join-Path $resolvedOutputDir "scenario-upgrade-preserves-config.json"
            Set-TestLabJson -Path $outputPath -Object $scenarioResult
        } catch { }
    }

    if ($MyInvocation.InvocationName -eq '.') {
        return $scenarioResult
    } else {
        $scenarioResult
        exit 1
    }
}
