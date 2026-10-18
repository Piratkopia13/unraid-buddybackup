<#
.SYNOPSIS
    Unit and dry-run tests for BuddyBackup lifecycle test scenarios.
.DESCRIPTION
    Validates standalone execution, dry-run safety, structured object returns,
    and output JSON generation for:
      - Scenario-FreshInstall.ps1
      - Scenario-PostReboot.ps1
      - Scenario-UpgradePreservesConfig.ps1
#>

param(
    [switch]$VerboseOutput
)

$ErrorActionPreference = "Stop"

$workspaceRoot = [System.IO.Path]::GetFullPath((Join-Path $PSScriptRoot "..\.."))
$scenariosRoot = Join-Path $workspaceRoot "testlab\scenarios"
$labConfigPath = "testlab/config/lab.local.json"

$tempOutputDir = Join-Path ([System.IO.Path]::GetTempPath()) ("bb-lifecycle-tests-" + [System.Guid]::NewGuid().ToString("N"))
[System.IO.Directory]::CreateDirectory($tempOutputDir) | Out-Null

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

Write-Host "=== Running Lifecycle Scenarios Unit Tests ===" -ForegroundColor Cyan

# ---------------------------------------------------------------------------
# Test 1: Scenario-FreshInstall.ps1 dry-run execution
# ---------------------------------------------------------------------------
Assert-Test "Scenario-FreshInstall dry-run returns Success and valid structured results" {
    $scriptPath = Join-Path $scenariosRoot "Scenario-FreshInstall.ps1"
    if (-not (Test-Path -LiteralPath $scriptPath)) {
        throw "Scenario-FreshInstall.ps1 not found at '$scriptPath'"
    }

    $outSubdir = Join-Path $tempOutputDir "fresh-install"
    $res = & $scriptPath -LabConfig $labConfigPath -OutputDir $outSubdir

    if ($null -eq $res) {
        throw "Scenario script returned null"
    }
    if ($res.Scenario -ne "fresh-install") {
        throw "Expected Scenario 'fresh-install', got '$($res.Scenario)'"
    }
    if ($res.Success -ne $true) {
        throw "Expected Success = `$true, got $($res.Success). Error: $($res.Error)"
    }
    if ($null -ne $res.Error) {
        throw "Expected Error = `$null, got '$($res.Error)'"
    }
    if ($null -eq $res.Results -or $res.Results.Count -eq 0) {
        throw "Expected non-empty Results array"
    }

    # Verify JSON output
    $jsonFile = Join-Path $outSubdir "scenario-fresh-install.json"
    if (-not (Test-Path -LiteralPath $jsonFile)) {
        throw "Output JSON not created at '$jsonFile'"
    }
    $savedJson = [System.IO.File]::ReadAllText((Resolve-Path -LiteralPath $jsonFile).ProviderPath, [System.Text.Encoding]::UTF8) | ConvertFrom-Json
    if ($savedJson.Scenario -ne "fresh-install" -or $savedJson.Success -ne $true) {
        throw "Saved JSON scenario or success mismatch"
    }
}

# ---------------------------------------------------------------------------
# Test 2: Scenario-PostReboot.ps1 dry-run execution
# ---------------------------------------------------------------------------
Assert-Test "Scenario-PostReboot dry-run returns Success and covers full reboot cycle steps" {
    $scriptPath = Join-Path $scenariosRoot "Scenario-PostReboot.ps1"
    if (-not (Test-Path -LiteralPath $scriptPath)) {
        throw "Scenario-PostReboot.ps1 not found at '$scriptPath'"
    }

    $outSubdir = Join-Path $tempOutputDir "post-reboot"
    $res = & $scriptPath -LabConfig $labConfigPath -OutputDir $outSubdir

    if ($null -eq $res) {
        throw "Scenario script returned null"
    }
    if ($res.Scenario -ne "post-reboot") {
        throw "Expected Scenario 'post-reboot', got '$($res.Scenario)'"
    }
    if ($res.Success -ne $true) {
        throw "Expected Success = `$true, got $($res.Success). Error: $($res.Error)"
    }
    if ($null -ne $res.Error) {
        throw "Expected Error = `$null, got '$($res.Error)'"
    }
    if ($null -eq $res.Results -or $res.Results.Count -eq 0) {
        throw "Expected non-empty Results array"
    }

    # Verify required steps are present in results
    $labels = @($res.Results | ForEach-Object { $_.Label })
    $requiredLabels = @(
        "nodeA-upgrade-state-snapshot",
        "nodeA-ensure-postboot-refresh",
        "nodeA-boot-id-before-reboot",
        "nodeA-reboot",
        "nodeA-post-reboot-state-compare",
        "nodeB-upgrade-state-snapshot",
        "nodeB-ensure-postboot-refresh",
        "nodeB-boot-id-before-reboot",
        "nodeB-reboot",
        "nodeB-post-reboot-state-compare"
    )
    foreach ($req in $requiredLabels) {
        if ($labels -notcontains $req) {
            throw "Expected label '$req' was not found in results: $($labels -join ', ')"
        }
    }

    # Verify JSON output
    $jsonFile = Join-Path $outSubdir "scenario-post-reboot.json"
    if (-not (Test-Path -LiteralPath $jsonFile)) {
        throw "Output JSON not created at '$jsonFile'"
    }
    $savedJson = [System.IO.File]::ReadAllText((Resolve-Path -LiteralPath $jsonFile).ProviderPath, [System.Text.Encoding]::UTF8) | ConvertFrom-Json
    if ($savedJson.Scenario -ne "post-reboot" -or $savedJson.Success -ne $true) {
        throw "Saved JSON scenario or success mismatch"
    }
}

# ---------------------------------------------------------------------------
# Test 3: Scenario-UpgradePreservesConfig.ps1 dry-run execution
# ---------------------------------------------------------------------------
Assert-Test "Scenario-UpgradePreservesConfig dry-run returns Success and covers upgrade diff steps" {
    $scriptPath = Join-Path $scenariosRoot "Scenario-UpgradePreservesConfig.ps1"
    if (-not (Test-Path -LiteralPath $scriptPath)) {
        throw "Scenario-UpgradePreservesConfig.ps1 not found at '$scriptPath'"
    }

    $outSubdir = Join-Path $tempOutputDir "upgrade-preserves-config"
    $res = & $scriptPath -LabConfig $labConfigPath -UpgradeFrom "2026.05.02" -UpgradeTo "workspace-build" -OutputDir $outSubdir

    if ($null -eq $res) {
        throw "Scenario script returned null"
    }
    if ($res.Scenario -ne "upgrade-preserves-config") {
        throw "Expected Scenario 'upgrade-preserves-config', got '$($res.Scenario)'"
    }
    if ($res.Success -ne $true) {
        throw "Expected Success = `$true, got $($res.Success). Error: $($res.Error)"
    }
    if ($null -ne $res.Error) {
        throw "Expected Error = `$null, got '$($res.Error)'"
    }
    if ($null -eq $res.Results -or $res.Results.Count -eq 0) {
        throw "Expected non-empty Results array"
    }

    # Verify key upgrade steps are recorded
    $labels = @($res.Results | ForEach-Object { $_.Label })
    $requiredLabels = @(
        "nodeA-upgrade-public-key",
        "nodeB-upgrade-public-key",
        "nodeA-upgrade-seed",
        "nodeB-upgrade-seed",
        "nodeA-upgrade-before-sanity",
        "nodeB-upgrade-before-sanity",
        "nodeA-upgrade-state-compare",
        "nodeB-upgrade-state-compare"
    )
    foreach ($req in $requiredLabels) {
        if ($labels -notcontains $req) {
            throw "Expected label '$req' was not found in results: $($labels -join ', ')"
        }
    }

    # Verify JSON output
    $jsonFile = Join-Path $outSubdir "scenario-upgrade-preserves-config.json"
    if (-not (Test-Path -LiteralPath $jsonFile)) {
        throw "Output JSON not created at '$jsonFile'"
    }
    $savedJson = [System.IO.File]::ReadAllText((Resolve-Path -LiteralPath $jsonFile).ProviderPath, [System.Text.Encoding]::UTF8) | ConvertFrom-Json
    if ($savedJson.Scenario -ne "upgrade-preserves-config" -or $savedJson.Success -ne $true) {
        throw "Saved JSON scenario or success mismatch"
    }
}

# ---------------------------------------------------------------------------
# Test 4: Direct CLI execution with exit code verification
# ---------------------------------------------------------------------------
Assert-Test "Scenario scripts exit 0 on success when executed as standalone CLI process" {
    foreach ($scenario in @("Scenario-FreshInstall.ps1", "Scenario-PostReboot.ps1", "Scenario-UpgradePreservesConfig.ps1")) {
        $fullPath = Join-Path $scenariosRoot $scenario
        $output = & powershell.exe -NoProfile -ExecutionPolicy Bypass -File $fullPath -LabConfig $labConfigPath 2>&1
        $exitCode = $LASTEXITCODE

        if ($exitCode -ne 0) {
            throw "$scenario exited with code $($exitCode): $($output -join "`n")"
        }
    }
}

# Cleanup temporary output directory
try {
    if (Test-Path -LiteralPath $tempOutputDir) {
        Remove-Item -LiteralPath $tempOutputDir -Recurse -Force -ErrorAction SilentlyContinue
    }
} catch { }

Write-Host "--------------------------------------------------"
$summaryColor = if ($testsFailed -eq 0) { "Green" } else { "Red" }
Write-Host "Lifecycle Scenario Tests: $testsRun Total | $testsPassed Passed | $testsFailed Failed" -ForegroundColor $summaryColor

if ($testsFailed -gt 0) {
    exit 1
}
