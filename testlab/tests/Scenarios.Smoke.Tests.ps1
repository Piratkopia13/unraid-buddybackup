<#
.SYNOPSIS
    Unit and dry-run tests for smoke test scenarios.
.DESCRIPTION
    Validates dry-run execution of Scenario-FunctionalSmoke.ps1,
    Scenario-MultiDataset.ps1, and Scenario-GenericSmoke.ps1 against
    testlab/config/lab.local.json without running live VMs.
#>

param(
    [switch]$VerboseOutput
)

$ErrorActionPreference = "Stop"

$workspaceRoot = [System.IO.Path]::GetFullPath((Join-Path $PSScriptRoot "..\.."))
$modulesRoot = Join-Path $workspaceRoot "testlab\modules"
$scenariosRoot = Join-Path $workspaceRoot "testlab\scenarios"
$labConfigPath = Join-Path $workspaceRoot "testlab\config\lab.local.json"

Import-Module -Name (Resolve-Path -LiteralPath (Join-Path $modulesRoot "TestLab.Core\TestLab.Core.psm1")).ProviderPath -Force -DisableNameChecking
Import-Module -Name (Resolve-Path -LiteralPath (Join-Path $modulesRoot "TestLab.Transport\TestLab.Transport.psm1")).ProviderPath -Force -DisableNameChecking
Import-Module -Name (Resolve-Path -LiteralPath (Join-Path $modulesRoot "TestLab.Guest\TestLab.Guest.psm1")).ProviderPath -Force -DisableNameChecking

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

Write-Host "=== Running TestLab Smoke Scenarios Dry-Run Tests ===" -ForegroundColor Cyan

$tempOutputDir = Join-Path $workspaceRoot "testlab\.testlab\tmp_smoke_tests"
Ensure-TestLabDir -Path $tempOutputDir | Out-Null

try {
    # ---------------------------------------------------------------------------
    # Test 1: Scenario-FunctionalSmoke dry-run execution
    # ---------------------------------------------------------------------------
    Assert-Test "Scenario-FunctionalSmoke runs in dry-run mode and writes structured report" {
        $scriptPath = Join-Path $scenariosRoot "Scenario-FunctionalSmoke.ps1"
        if (-not (Test-Path -LiteralPath $scriptPath)) {
            throw "Script not found: $scriptPath"
        }

        $result = & $scriptPath -LabConfig $labConfigPath -OutputDir $tempOutputDir
        if ($null -eq $result) {
            throw "Scenario returned null result."
        }

        if ($result.Scenario -ne 'functional-smoke') {
            throw "Expected Scenario 'functional-smoke', got '$($result.Scenario)'"
        }

        if (-not $result.Success) {
            throw "Scenario returned Success=$false with error: $($result.Error)"
        }

        if (-not [string]::IsNullOrWhiteSpace($result.Error)) {
            throw "Expected empty Error, got: $($result.Error)"
        }

        if ([string]::IsNullOrWhiteSpace($result.ReportPath)) {
            throw "ReportPath is empty or null."
        }

        if (-not (Test-Path -LiteralPath $result.ReportPath)) {
            throw "Report file does not exist at: $($result.ReportPath)"
        }

        $reportJson = Get-TestLabJson -Path $result.ReportPath
        if (-not $reportJson.success) {
            throw "Report JSON indicated failure."
        }

        if ($reportJson.executeMode) {
            throw "Report JSON indicated executeMode=$true when dry-run was requested."
        }

        if ($null -eq $result.Results -or $result.Results.Count -eq 0) {
            throw "Results array is empty."
        }
    }

    # ---------------------------------------------------------------------------
    # Test 2: Scenario-MultiDataset dry-run execution
    # ---------------------------------------------------------------------------
    Assert-Test "Scenario-MultiDataset runs in dry-run mode and writes structured report" {
        $scriptPath = Join-Path $scenariosRoot "Scenario-MultiDataset.ps1"
        if (-not (Test-Path -LiteralPath $scriptPath)) {
            throw "Script not found: $scriptPath"
        }

        $result = & $scriptPath -LabConfig $labConfigPath -OutputDir $tempOutputDir
        if ($null -eq $result) {
            throw "Scenario returned null result."
        }

        if ($result.Scenario -ne 'multi-dataset') {
            throw "Expected Scenario 'multi-dataset', got '$($result.Scenario)'"
        }

        if (-not $result.Success) {
            throw "Scenario returned Success=$false with error: $($result.Error)"
        }

        if (-not [string]::IsNullOrWhiteSpace($result.Error)) {
            throw "Expected empty Error, got: $($result.Error)"
        }

        if ([string]::IsNullOrWhiteSpace($result.ReportPath)) {
            throw "ReportPath is empty or null."
        }

        if (-not (Test-Path -LiteralPath $result.ReportPath)) {
            throw "Report file does not exist at: $($result.ReportPath)"
        }

        $reportJson = Get-TestLabJson -Path $result.ReportPath
        if (-not $reportJson.success) {
            throw "Report JSON indicated failure."
        }

        if ($reportJson.executeMode) {
            throw "Report JSON indicated executeMode=$true when dry-run was requested."
        }

        if ($null -eq $result.Results -or $result.Results.Count -eq 0) {
            throw "Results array is empty."
        }
    }

    # ---------------------------------------------------------------------------
    # Test 3: Scenario-GenericSmoke dry-run execution
    # ---------------------------------------------------------------------------
    Assert-Test "Scenario-GenericSmoke runs in dry-run mode and writes structured report" {
        $scriptPath = Join-Path $scenariosRoot "Scenario-GenericSmoke.ps1"
        if (-not (Test-Path -LiteralPath $scriptPath)) {
            throw "Script not found: $scriptPath"
        }

        $result = & $scriptPath -LabConfig $labConfigPath -OutputDir $tempOutputDir
        if ($null -eq $result) {
            throw "Scenario returned null result."
        }

        if ($result.Scenario -ne 'generic-smoke') {
            throw "Expected Scenario 'generic-smoke', got '$($result.Scenario)'"
        }

        if (-not $result.Success) {
            throw "Scenario returned Success=$false with error: $($result.Error)"
        }

        if (-not [string]::IsNullOrWhiteSpace($result.Error)) {
            throw "Expected empty Error, got: $($result.Error)"
        }

        if ([string]::IsNullOrWhiteSpace($result.ReportPath)) {
            throw "ReportPath is empty or null."
        }

        if (-not (Test-Path -LiteralPath $result.ReportPath)) {
            throw "Report file does not exist at: $($result.ReportPath)"
        }

        $reportJson = Get-TestLabJson -Path $result.ReportPath
        if (-not $reportJson.success) {
            throw "Report JSON indicated failure."
        }

        if ($reportJson.executeMode) {
            throw "Report JSON indicated executeMode=$true when dry-run was requested."
        }

        if ($null -eq $result.Results -or $result.Results.Count -eq 0) {
            throw "Results array is empty."
        }
    }

    # ---------------------------------------------------------------------------
    # Test 4: Dot-sourcing scenario scripts returns structured result without premature exit
    # ---------------------------------------------------------------------------
    Assert-Test "Dot-sourcing scenarios returns structured result" {
        $smokeScript = Join-Path $scenariosRoot "Scenario-FunctionalSmoke.ps1"
        $dotResult = . $smokeScript -LabConfig $labConfigPath -OutputDir $tempOutputDir
        if ($null -eq $dotResult -or $dotResult.Scenario -ne 'functional-smoke' -or -not $dotResult.Success) {
            throw "Dot-sourcing Scenario-FunctionalSmoke did not return valid result."
        }

        $multiScript = Join-Path $scenariosRoot "Scenario-MultiDataset.ps1"
        $dotResult2 = . $multiScript -LabConfig $labConfigPath -OutputDir $tempOutputDir
        if ($null -eq $dotResult2 -or $dotResult2.Scenario -ne 'multi-dataset' -or -not $dotResult2.Success) {
            throw "Dot-sourcing Scenario-MultiDataset did not return valid result."
        }

        $genericScript = Join-Path $scenariosRoot "Scenario-GenericSmoke.ps1"
        $dotResult3 = . $genericScript -LabConfig $labConfigPath -OutputDir $tempOutputDir
        if ($null -eq $dotResult3 -or $dotResult3.Scenario -ne 'generic-smoke' -or -not $dotResult3.Success) {
            throw "Dot-sourcing Scenario-GenericSmoke did not return valid result."
        }
    }

} finally {
    if (Test-Path -LiteralPath $tempOutputDir) {
        Remove-Item -LiteralPath $tempOutputDir -Recurse -Force -ErrorAction SilentlyContinue
    }
}

Write-Host "--------------------------------------------------" -ForegroundColor Gray
Write-Host "Smoke Scenario Tests: $testsRun Total | $testsPassed Passed | $testsFailed Failed" -ForegroundColor $(if ($testsFailed -eq 0) { "Green" } else { "Red" })

if ($testsFailed -gt 0) {
    exit 1
} else {
    exit 0
}
