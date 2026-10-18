<#
.SYNOPSIS
    Fast automated unit and regression test harness for BuddyBackup testlab scripts.

.DESCRIPTION
    Validates testlab helper functions, remote shell command escaping, manifest parsing,
    and config resolution in < 3 seconds without booting VMs.
#>

param(
    [switch]$VerboseOutput
)

$ErrorActionPreference = "Stop"

$workspaceRoot = [System.IO.Path]::GetFullPath((Join-Path $PSScriptRoot "..\.."))
$testlabScriptsRoot = Join-Path $workspaceRoot "testlab\scripts"

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
    }
}

Write-Host "=== Running BuddyBackup Testlab Harness Tests ===" -ForegroundColor Cyan

# Test 1: Plugin Manifest Display Version Parsing (SMB-Safe)
Assert-Test "Get-TestLabPluginDisplayVersion parses manifest reliably" {
    . (Join-Path $testlabScriptsRoot "testlab-plugin-source.ps1")
    $version = Get-TestLabPluginDisplayVersion -WorkspaceRoot $workspaceRoot
    if ([string]::IsNullOrWhiteSpace($version)) {
        throw "Version was empty."
    }
    if ($version -notmatch '^\d{4}\.\d{2}\.\d{2}$') {
        throw "Version '$version' did not match expected YYYY.MM.DD format."
    }
}

# Test 2: Convert-ToRemoteShellCommand encodes complex single-line commands
Assert-Test "Convert-ToRemoteShellCommand Base64 encodes commands with shell metacharacters" {
    . (Join-Path $testlabScriptsRoot "run-matrix.ps1")

    $simpleCmd = "zpool list -H -o name bbpool"
    $convertedSimple = Convert-ToRemoteShellCommand -Command $simpleCmd
    if ($convertedSimple -ne $simpleCmd) {
        throw "Simple command should remain unencoded. Got: $convertedSimple"
    }

    $complexCmd = 'uptime_secs=$(cut -d. -f1 /proc/uptime 2>/dev/null || echo 60); if [ "$uptime_secs" -lt 45 ]; then sleep $((45 - uptime_secs)); fi; while pidof -x reload_services >/dev/null 2>&1; do sleep 1; done; echo settled'
    $convertedComplex = Convert-ToRemoteShellCommand -Command $complexCmd
    if ($convertedComplex -notmatch "^printf '%s' '([^']+)' \| base64 -d \| bash$") {
        throw "Complex single-line command was not Base64 encoded! Got: $convertedComplex"
    }

    $match = [regex]::Match($convertedComplex, "^printf '%s' '([^']+)' \| base64 -d \| bash$")
    $decodedBytes = [System.Convert]::FromBase64String($match.Groups[1].Value)
    $decodedText = [System.Text.Encoding]::UTF8.GetString($decodedBytes)
    if ($decodedText -ne $complexCmd) {
        throw "Decoded text does not match original!`nExpected: $complexCmd`nGot: $decodedText"
    }
}

# Test 3: Remote shell command escaping with quotes and awk syntax
Assert-Test "Convert-ToRemoteShellCommand preserves nested quotes and dollar syntax" {
    . (Join-Path $testlabScriptsRoot "run-matrix.ps1")

    $awkCmd = 'awk "{print int(\$1)}" /proc/uptime'
    $converted = Convert-ToRemoteShellCommand -Command $awkCmd
    if ($converted -notmatch "^printf '%s' '([^']+)' \| base64 -d \| bash$") {
        throw "Command with quotes was not Base64 encoded! Got: $converted"
    }

    $match = [regex]::Match($converted, "^printf '%s' '([^']+)' \| base64 -d \| bash$")
    $decodedBytes = [System.Convert]::FromBase64String($match.Groups[1].Value)
    $decodedText = [System.Text.Encoding]::UTF8.GetString($decodedBytes)
    if ($decodedText -ne $awkCmd) {
        throw "Decoded text does not match original!`nExpected: $awkCmd`nGot: $decodedText"
    }
}

# Test 4: Settle command bash syntax validation (via WSL if available)
Assert-Test "Settle command has valid bash syntax" {
    $wsl = Get-Command wsl.exe -ErrorAction SilentlyContinue
    if (-not $wsl) {
        Write-Host "         (Skipping WSL bash syntax check: wsl.exe not available)" -ForegroundColor Yellow
        return
    }

    $settleScript = 'uptime_secs=$(cut -d. -f1 /proc/uptime 2>/dev/null || echo 60); if [ -n "$uptime_secs" ] && [ "$uptime_secs" -lt 45 ] 2>/dev/null; then :; fi; while pidof -x reload_services >/dev/null 2>&1; do :; done; echo settled'
    $b64 = [Convert]::ToBase64String([System.Text.Encoding]::UTF8.GetBytes($settleScript))
    $checkCmd = "echo $b64 | base64 -d | bash -n"
    $proc = Start-Process -FilePath "wsl.exe" -ArgumentList @("--", "bash", "-c", $checkCmd) -NoNewWindow -Wait -PassThru
    if ($proc.ExitCode -ne 0) {
        throw "Bash syntax validation failed with exit code $($proc.ExitCode)"
    }
}

# Test 5: Lab local config and small matrix parsing
Assert-Test "Lab config and matrix small configs parse valid JSON" {
    $labConfigPath = Join-Path $workspaceRoot "testlab\config\lab.local.json"
    $matrixPath = Join-Path $workspaceRoot "testlab\config\matrix.small.json"

    if (Test-Path -LiteralPath $labConfigPath) {
        $labJson = [System.IO.File]::ReadAllText((Resolve-Path -LiteralPath $labConfigPath).ProviderPath) | ConvertFrom-Json
        if (-not $labJson.provider) { throw "lab.local.json missing provider field" }
        if (-not $labJson.nodes.nodeA) { throw "lab.local.json missing nodes.nodeA" }
    }

    if (Test-Path -LiteralPath $matrixPath) {
        $matrixJson = [System.IO.File]::ReadAllText((Resolve-Path -LiteralPath $matrixPath).ProviderPath) | ConvertFrom-Json
        if (-not $matrixJson.cells -or $matrixJson.cells.Count -eq 0) { throw "matrix.small.json has no cells" }
    }
}

Write-Host "--------------------------------------------------"
$summaryColor = if ($testsFailed -eq 0) { "Green" } else { "Red" }
Write-Host "Harness Tests: $testsRun Total | $testsPassed Passed | $testsFailed Failed" -ForegroundColor $summaryColor

if ($testsFailed -gt 0) {
    exit 1
}
