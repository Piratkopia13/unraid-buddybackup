<#
.SYNOPSIS
    BuddyBackup post-reboot test scenario.
.DESCRIPTION
    Installs BuddyBackup plugin on nodeA and nodeB, takes state snapshots,
    triggers reboots, validates reboot cycles and service recovery,
    and verifies that state and configuration persisted across the reboot.
#>

[CmdletBinding()]
param(
    [string]$LabConfig = "testlab/config/lab.local.json",
    [string]$NodeAPlugin = "workspace-build",
    [string]$NodeBPlugin = "workspace-build",
    [string]$CellId = "post-reboot",
    [string]$OutputDir = $null,
    [switch]$Execute,
    [int]$TimeoutSeconds = 120,
    [int]$SettleSeconds = 0
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
    $nodeAPluginRequest = Resolve-TestLabPluginRequest -RequestedValue $NodeAPlugin -WorkspaceRoot $workspaceRoot -ConfiguredBuildCacheRoot $configuredBuildCacheRoot
    $nodeBPluginRequest = Resolve-TestLabPluginRequest -RequestedValue $NodeBPlugin -WorkspaceRoot $workspaceRoot -ConfiguredBuildCacheRoot $configuredBuildCacheRoot

    $timeout = $TimeoutSeconds
    if (-not $PSBoundParameters.ContainsKey('TimeoutSeconds') -and $Lab.timeouts -and $Lab.timeouts.sshReadySeconds) {
        $timeout = [int]$Lab.timeouts.sshReadySeconds
    }

    $rebootSettleSeconds = $SettleSeconds
    if (-not $PSBoundParameters.ContainsKey('SettleSeconds') -and $Lab.timeouts -and $Lab.timeouts.rebootSettleSeconds) {
        $rebootSettleSeconds = [int]$Lab.timeouts.rebootSettleSeconds
    }

    $zfsValues = Get-SetupZfsValues -Lab $Lab
    $pluginVerifyCommand = Get-BuddyBackupPluginVerifyCommand
    $manualAccessVerifyCommand = Get-ManualAccessVerifyCommand -Lab $Lab
    $manualAccessVerifyLoggedCommand = Get-ManualAccessVerifyLoggedCommand
    $buddyBackupPostRebootReadyCommand = Get-BuddyBackupPostRebootReadyCommand
    $buddyBackupPostRebootReadyLoggedCommand = Get-BuddyBackupPostRebootReadyLoggedCommand
    $postBootRefreshCommand = Get-TestLabPostBootRefreshCommand

    Write-Host "[testlab] Scenario '$CellId': Installing BuddyBackup on nodeA ($($nodeAPluginRequest.label))..."
    $results += Install-Plugin -Lab $Lab -NodeConnection $sender -PluginRequest $nodeAPluginRequest -DoExecute:$Execute

    Write-Host "[testlab] Scenario '$CellId': Installing BuddyBackup on nodeB ($($nodeBPluginRequest.label))..."
    $results += Install-Plugin -Lab $Lab -NodeConnection $receiver -PluginRequest $nodeBPluginRequest -DoExecute:$Execute

    $nodeSnapshots = @{}

    foreach ($node in @(
        [pscustomobject]@{ Name = "nodeA"; Connection = $sender },
        [pscustomobject]@{ Name = "nodeB"; Connection = $receiver }
    )) {
        Write-Host "[testlab] Scenario '$CellId': validating reboot persistence on $($node.Name)"
        $manualAccessLabel = "$($node.Name)-manual-access-check"

        $beforeSnapshot = Get-UpgradeStateSnapshot -NodeName $node.Name -NodeConnection $node.Connection -DoExecute:$Execute
        $results += $beforeSnapshot.Result
        if ($Execute -and (-not $beforeSnapshot.Result.Success -or $null -eq $beforeSnapshot.Snapshot)) {
            throw "Failed to capture BuddyBackup state before reboot for $($node.Name)."
        }
        if ($Execute) {
            $nodeSnapshots[$node.Name] = [ordered]@{
                Before = $beforeSnapshot.Snapshot
            }
        }

        $results += Invoke-RemoteCommand -NodeConnection $node.Connection -Command $postBootRefreshCommand -LoggedCommand "ensure post-boot refresh script on $($node.Name)" -Label "$($node.Name)-ensure-postboot-refresh" -DoExecute:$Execute

        $beforeBootId = Get-RemoteBootId -NodeConnection $node.Connection -Label "$($node.Name)-boot-id-before-reboot" -DoExecute:$Execute
        $results += $beforeBootId.Result
        if ($Execute -and (-not $beforeBootId.Result.Success -or [string]::IsNullOrWhiteSpace($beforeBootId.BootId))) {
            throw "Failed to read boot_id before reboot for $($node.Name)."
        }

        $results += Invoke-RemoteCommand -NodeConnection $node.Connection -Command "sync; reboot" -Label "$($node.Name)-reboot" -DoExecute:$Execute

        if ($Execute) {
            $rebootCycle = Wait-ForRebootCycle -NodeConnection $node.Connection -PreviousBootId $beforeBootId.BootId -TimeoutSeconds $timeout -SettleSeconds $rebootSettleSeconds -ReadyCommand $manualAccessVerifyCommand -ReadyLoggedCommand $manualAccessVerifyLoggedCommand -ReadyLabel $manualAccessLabel -DoExecute:$Execute
            if (-not $rebootCycle.Success) {
                throw "$($node.Name) reboot validation failed: $($rebootCycle.Error)"
            }

            if ($rebootCycle.ReadyResult) {
                $results += $rebootCycle.ReadyResult
            }

            $buddyBackupReadyCheck = Wait-ForRemoteSuccess -NodeConnection $node.Connection -Command $buddyBackupPostRebootReadyCommand -LoggedCommand $buddyBackupPostRebootReadyLoggedCommand -Label "$($node.Name)-buddybackup-post-reboot-ready" -TimeoutSeconds $timeout -DoExecute:$Execute
            $results += $buddyBackupReadyCheck.Result

            $pluginCheck = Wait-ForRemoteSuccess -NodeConnection $node.Connection -Command $pluginVerifyCommand -Label "$($node.Name)-plugin-check" -TimeoutSeconds $timeout -DoExecute:$Execute
            $results += $pluginCheck.Result

            $zpoolCheck = Wait-ForRemoteSuccess -NodeConnection $node.Connection -Command ("zpool list -H -o name {0}" -f $zfsValues.PoolName) -Label "$($node.Name)-zpool-check" -TimeoutSeconds $timeout -DoExecute:$Execute
            $results += $zpoolCheck.Result

            $plainDatasetCheck = Wait-ForRemoteSuccess -NodeConnection $node.Connection -Command ("zfs list -H -o name {0}" -f $zfsValues.UnencryptedDataset) -Label "$($node.Name)-plain-dataset-check" -TimeoutSeconds $timeout -DoExecute:$Execute
            $results += $plainDatasetCheck.Result

            $encryptedDatasetCheck = Wait-ForRemoteSuccess -NodeConnection $node.Connection -Command ("zfs get -H -o value encryption {0}" -f $zfsValues.EncryptedDataset) -Label "$($node.Name)-encrypted-dataset-check" -TimeoutSeconds $timeout -DoExecute:$Execute
            $results += $encryptedDatasetCheck.Result

            $afterSnapshot = Get-UpgradeStateSnapshot -NodeName $node.Name -NodeConnection $node.Connection -DoExecute:$Execute
            $results += $afterSnapshot.Result
            if (-not $afterSnapshot.Result.Success -or $null -eq $afterSnapshot.Snapshot) {
                throw "Failed to capture BuddyBackup state after reboot for $($node.Name)."
            }

            $stateCompare = Compare-UpgradeStateSnapshots -NodeName $node.Name -Before $nodeSnapshots[$node.Name].Before -After $afterSnapshot.Snapshot

            $results += [pscustomobject]@{
                Label    = "$($node.Name)-post-reboot-state-compare"
                Command  = "compare pre-reboot and post-reboot BuddyBackup state"
                ExitCode = if ($stateCompare.Success) { 0 } else { 1 }
                Output   = if ($stateCompare.Success) { "State persisted across reboot." } else { $stateCompare.Error }
                Success  = $stateCompare.Success
            }
            if (-not $stateCompare.Success) {
                throw "$($node.Name) BuddyBackup state changed across reboot: $($stateCompare.Error)"
            }
        } else {
            $results += [pscustomobject]@{
                Label    = "$($node.Name)-post-reboot-state-compare"
                Command  = "compare pre-reboot and post-reboot BuddyBackup state"
                ExitCode = 0
                Output   = 'dry-run'
                Success  = $true
            }
            $results += Invoke-RemoteCommand -NodeConnection $node.Connection -Command $pluginVerifyCommand -Label "$($node.Name)-plugin-check" -DoExecute:$Execute
            $results += Invoke-RemoteCommand -NodeConnection $node.Connection -Command $manualAccessVerifyCommand -LoggedCommand $manualAccessVerifyLoggedCommand -Label "$($node.Name)-manual-access-check" -DoExecute:$Execute
            $results += Invoke-RemoteCommand -NodeConnection $node.Connection -Command ("zpool list -H -o name {0}" -f $zfsValues.PoolName) -Label "$($node.Name)-zpool-check" -DoExecute:$Execute
            $results += Invoke-RemoteCommand -NodeConnection $node.Connection -Command ("zfs list -H -o name {0}" -f $zfsValues.UnencryptedDataset) -Label "$($node.Name)-plain-dataset-check" -DoExecute:$Execute
            $results += Invoke-RemoteCommand -NodeConnection $node.Connection -Command ("zfs get -H -o value encryption {0}" -f $zfsValues.EncryptedDataset) -Label "$($node.Name)-encrypted-dataset-check" -DoExecute:$Execute
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
        Scenario = 'post-reboot'
        Success  = $success
        Results  = $results
        Error    = $errorMessage
    }

    if (-not [string]::IsNullOrWhiteSpace($resolvedOutputDir)) {
        Ensure-TestLabDir -Path $resolvedOutputDir
        $outputPath = Join-Path $resolvedOutputDir "scenario-post-reboot.json"
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
        Scenario = 'post-reboot'
        Success  = $false
        Results  = $results
        Error    = $err
    }

    if (-not [string]::IsNullOrWhiteSpace($resolvedOutputDir)) {
        try {
            Ensure-TestLabDir -Path $resolvedOutputDir
            $outputPath = Join-Path $resolvedOutputDir "scenario-post-reboot.json"
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
