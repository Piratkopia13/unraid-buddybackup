<#
.SYNOPSIS
    BuddyBackup fresh-install test scenario.
.DESCRIPTION
    Installs BuddyBackup plugin on nodeA and nodeB and verifies installation health.
#>

[CmdletBinding()]
param(
    [string]$LabConfig = "testlab/config/lab.local.json",
    [string]$NodeAPlugin = "workspace-build",
    [string]$NodeBPlugin = "workspace-build",
    [string]$CellId = "fresh-install",
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
    $nodeAPluginRequest = Resolve-TestLabPluginRequest -RequestedValue $NodeAPlugin -WorkspaceRoot $workspaceRoot -ConfiguredBuildCacheRoot $configuredBuildCacheRoot
    $nodeBPluginRequest = Resolve-TestLabPluginRequest -RequestedValue $NodeBPlugin -WorkspaceRoot $workspaceRoot -ConfiguredBuildCacheRoot $configuredBuildCacheRoot

    Write-Host "[testlab] Scenario '$CellId': Installing BuddyBackup on nodeA ($($nodeAPluginRequest.label))..."
    $results += Install-Plugin -Lab $Lab -NodeConnection $sender -PluginRequest $nodeAPluginRequest -DoExecute:$Execute

    Write-Host "[testlab] Scenario '$CellId': Installing BuddyBackup on nodeB ($($nodeBPluginRequest.label))..."
    $results += Install-Plugin -Lab $Lab -NodeConnection $receiver -PluginRequest $nodeBPluginRequest -DoExecute:$Execute

    $pluginVerifyCommand = Get-BuddyBackupPluginVerifyCommand

    Write-Host "[testlab] Scenario '$CellId': Verifying BuddyBackup plugin on nodeA..."
    $nodeACheck = Wait-ForRemoteSuccess -NodeConnection $sender -Command $pluginVerifyCommand -Label "nodeA-plugin-check" -TimeoutSeconds 60 -DoExecute:$Execute
    $results += $nodeACheck.Result

    Write-Host "[testlab] Scenario '$CellId': Verifying BuddyBackup plugin on nodeB..."
    $nodeBCheck = Wait-ForRemoteSuccess -NodeConnection $receiver -Command $pluginVerifyCommand -Label "nodeB-plugin-check" -TimeoutSeconds 60 -DoExecute:$Execute
    $results += $nodeBCheck.Result

    $failed = @($results | Where-Object { -not $_.Success })
    $success = ($failed.Count -eq 0)
    $errorMessage = if (-not $success) {
        $labels = @($failed | ForEach-Object { $_.Label }) -join ", "
        "Failed command labels: $labels"
    } else {
        $null
    }

    $scenarioResult = [pscustomobject]@{
        Scenario = 'fresh-install'
        Success  = $success
        Results  = $results
        Error    = $errorMessage
    }

    if (-not [string]::IsNullOrWhiteSpace($resolvedOutputDir)) {
        Ensure-TestLabDir -Path $resolvedOutputDir
        $outputPath = Join-Path $resolvedOutputDir "scenario-fresh-install.json"
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
        Scenario = 'fresh-install'
        Success  = $false
        Results  = $results
        Error    = $err
    }

    if (-not [string]::IsNullOrWhiteSpace($resolvedOutputDir)) {
        try {
            Ensure-TestLabDir -Path $resolvedOutputDir
            $outputPath = Join-Path $resolvedOutputDir "scenario-fresh-install.json"
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
