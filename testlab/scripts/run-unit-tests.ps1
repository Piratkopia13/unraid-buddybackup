<#
.SYNOPSIS
    Runs all Perl TAP unit and integration tests in the t/ directory.

.DESCRIPTION
    Discovers Perl (system perl or Git for Windows perl) and executes all .t test files,
    measuring execution time and reporting PASS/FAIL status for each test. Exits with 0
    if all tests pass, or 1 if any test fails.

.PARAMETER Test
    Optional name or pattern to run only specific test file(s), e.g., "restrict_zfs" or "php".

.PARAMETER VerboseOutput
    If specified, prints the full test output (stdout and stderr) for all tests.
    By default, full output is only displayed for failed tests.

.PARAMETER FailFast
    If specified, halts immediately upon the first failing test.

.EXAMPLE
    ./testlab/scripts/run-unit-tests.ps1

.EXAMPLE
    ./testlab/scripts/run-unit-tests.ps1 -Test php_syntax_and_eval.t -VerboseOutput
#>

param(
    [string]$Test,
    [switch]$VerboseOutput,
    [switch]$FailFast,
    [switch]$UseWsl
)

$ErrorActionPreference = "Stop"

function Get-WorkspaceRoot {
    return [System.IO.Path]::GetFullPath((Join-Path $PSScriptRoot "..\.."))
}

$workspaceRoot = Get-WorkspaceRoot

if ($UseWsl) {
    $wslCmd = Get-Command wsl.exe -ErrorAction SilentlyContinue
    if (-not $wslCmd) {
        throw "wsl.exe is not available on this system."
    }
    $drive = $workspaceRoot.Substring(0, 1).ToLowerInvariant()
    $wslPath = "/mnt/$drive" + ($workspaceRoot.Substring(2) -replace '\\', '/')
    $testFilter = if (-not [string]::IsNullOrWhiteSpace($Test)) {
        if ($Test.EndsWith(".t")) { "t/*$Test*" } else { "t/*$Test*.t" }
    } else {
        "t/*.t"
    }
    Write-Host "[unit-tests] Executing tests inside WSL environment ($wslPath)..." -ForegroundColor Cyan
    $bashCmd = "cd '$wslPath' && prove -r $testFilter"
    if ($VerboseOutput) {
        $bashCmd = "cd '$wslPath' && prove -v -r $testFilter"
    }
    & $wslCmd.Source -- bash -c $bashCmd
    exit $LASTEXITCODE
}

function Get-PerlPath {
    $perlCmd = Get-Command -Name "perl.exe" -ErrorAction SilentlyContinue
    if (-not $perlCmd) {
        $perlCmd = Get-Command -Name "perl" -ErrorAction SilentlyContinue
    }
    if ($perlCmd) {
        return [string]$perlCmd.Source
    }

    $gitPerl = Join-Path ${env:ProgramFiles} "Git\usr\bin\perl.exe"
    if (Test-Path -LiteralPath $gitPerl) {
        return $gitPerl
    }

    throw "Unable to locate perl.exe. Please install Perl or Git for Windows."
}

$workspaceRoot = Get-WorkspaceRoot
$tDir = Join-Path $workspaceRoot "t"

if (-not (Test-Path -LiteralPath $tDir)) {
    throw "Directory not found: $tDir"
}

$perlPath = Get-PerlPath
Write-Host "[unit-tests] Using Perl: $perlPath" -ForegroundColor Cyan

$pattern = "*.t"
if (-not [string]::IsNullOrWhiteSpace($Test)) {
    $pattern = if ($Test.EndsWith(".t")) { "*$Test*" } else { "*$Test*.t" }
}

$testFiles = Get-ChildItem -Path $tDir -Filter $pattern | Sort-Object Name
if ($testFiles.Count -eq 0) {
    Write-Warning "[unit-tests] No test files matching '$pattern' found in $tDir"
    exit 0
}

Write-Host "[unit-tests] Discovered $($testFiles.Count) test file(s) in $tDir`n"

$results = @()
$suiteStart = Get-Date

foreach ($file in $testFiles) {
    $relPath = "t/$($file.Name)"
    Write-Host -NoNewline ("  Running {0,-35} ... " -f $relPath)

    $started = Get-Date
    $previousErrorAction = $ErrorActionPreference
    $hadNativePref = Test-Path Variable:\PSNativeCommandUseErrorActionPreference
    if ($hadNativePref) {
        $previousNativePref = $PSNativeCommandUseErrorActionPreference
    }

    try {
        $ErrorActionPreference = "Continue"
        if ($hadNativePref) {
            $PSNativeCommandUseErrorActionPreference = $false
        }

        # Run test from workspace root so relative anchors in tests resolve cleanly
        Push-Location $workspaceRoot
        try {
            $rawOutput = & $perlPath $file.FullName 2>&1
            $exitCode = $LASTEXITCODE
        } finally {
            Pop-Location
        }
    } finally {
        $ErrorActionPreference = $previousErrorAction
        if ($hadNativePref) {
            $PSNativeCommandUseErrorActionPreference = $previousNativePref
        }
    }

    $completed = Get-Date
    $duration = [math]::Round((New-TimeSpan -Start $started -End $completed).TotalSeconds, 2)
    $outputStr = (@($rawOutput | ForEach-Object { [string]$_ }) -join [Environment]::NewLine).TrimEnd()
    $passed = ($exitCode -eq 0)

    if ($passed) {
        Write-Host "PASS" -ForegroundColor Green -NoNewline
        Write-Host (" ({0}s)" -f $duration) -ForegroundColor DarkGray
    } else {
        Write-Host "FAIL" -ForegroundColor Red -NoNewline
        Write-Host (" (exit code {0}, {1}s)" -f $exitCode, $duration) -ForegroundColor Red
    }

    if ($VerboseOutput -or (-not $passed)) {
        Write-Host "`n--- Output for $relPath ---" -ForegroundColor DarkGray
        Write-Host $outputStr
        Write-Host "--- End of output ---`n" -ForegroundColor DarkGray
    }

    $results += [pscustomobject]@{
        Test = $relPath
        Passed = $passed
        Duration = $duration
        ExitCode = $exitCode
        Output = $outputStr
    }

    if ($FailFast -and -not $passed) {
        Write-Warning "[unit-tests] Halting execution due to -FailFast"
        break
    }
}

$suiteEnd = Get-Date
$totalDuration = [math]::Round((New-TimeSpan -Start $suiteStart -End $suiteEnd).TotalSeconds, 2)
$totalTests = $results.Count
$passedTests = @($results | Where-Object { $_.Passed }).Count
$failedTests = @($results | Where-Object { -not $_.Passed }).Count

Write-Host "`n" + ("=" * 60)
Write-Host "Unit Test Summary: $passedTests/$totalTests passed in ${totalDuration}s" -ForegroundColor $(if ($failedTests -eq 0) { "Green" } else { "Red" })
Write-Host ("=" * 60)

if ($failedTests -gt 0) {
    Write-Host "`nFailed tests:" -ForegroundColor Red
    $results | Where-Object { -not $_.Passed } | ForEach-Object {
        Write-Host "  - $($_.Test) (exit code $($_.ExitCode))" -ForegroundColor Red
    }
    exit 1
}

exit 0
