<#
.SYNOPSIS
    Legacy wrapper for BuddyBackup multi-dataset hot-standby scenario.
.DESCRIPTION
    Forwards execution to testlab/scenarios/Scenario-MultiDataset.ps1.
#>

[CmdletBinding()]
param(
    [Parameter(Mandatory = $false)]
    [string]$LabConfig = "testlab/config/lab.local.json",

    [Parameter(Mandatory = $false)]
    [string]$OutputDir = $null,

    [switch]$Execute
)

$ErrorActionPreference = "Stop"

$scenarioScript = Join-Path $PSScriptRoot "..\scenarios\Scenario-MultiDataset.ps1"
if (-not (Test-Path -LiteralPath $scenarioScript)) {
    throw "Target scenario script not found: $scenarioScript"
}

$res = & $scenarioScript -LabConfig $LabConfig -OutputDir $OutputDir -Execute:$Execute
if ($LASTEXITCODE -ne 0) {
    exit $LASTEXITCODE
}
return $res
