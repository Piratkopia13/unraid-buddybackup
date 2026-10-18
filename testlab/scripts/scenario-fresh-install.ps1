<#
.SYNOPSIS
    Legacy wrapper for BuddyBackup fresh-install test scenario.
.DESCRIPTION
    Forwards execution to testlab/scenarios/Scenario-FreshInstall.ps1.
#>

[CmdletBinding()]
param(
    [Parameter(Mandatory = $false)]
    [string]$LabConfig = "testlab/config/lab.local.json",

    [Parameter(Mandatory = $false)]
    [string]$NodeAPlugin = "workspace-build",

    [Parameter(Mandatory = $false)]
    [string]$NodeBPlugin = "workspace-build",

    [Parameter(Mandatory = $false)]
    [string]$OutputDir = $null,

    [switch]$Execute
)

$ErrorActionPreference = "Stop"

$scenarioScript = Join-Path $PSScriptRoot "..\scenarios\Scenario-FreshInstall.ps1"
if (-not (Test-Path -LiteralPath $scenarioScript)) {
    throw "Target scenario script not found: $scenarioScript"
}

$res = & $scenarioScript -LabConfig $LabConfig -NodeAPlugin $NodeAPlugin -NodeBPlugin $NodeBPlugin -OutputDir $OutputDir -Execute:$Execute
if ($LASTEXITCODE -ne 0) {
    exit $LASTEXITCODE
}
return $res
