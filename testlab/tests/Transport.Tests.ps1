<#
.SYNOPSIS
    Unit tests for TestLab.Transport module.
.DESCRIPTION
    Validates connection resolution, argument generators for SSH/SCP, Base64 remote command
    escaping, bash script wrappers, and adaptive polling probes without requiring running VMs.
#>

param(
    [switch]$VerboseOutput
)

$ErrorActionPreference = "Stop"

$workspaceRoot = [System.IO.Path]::GetFullPath((Join-Path $PSScriptRoot "..\.."))
$modulePath = Join-Path $workspaceRoot "testlab\modules\TestLab.Transport\TestLab.Transport.psm1"

Import-Module -Name (Resolve-Path -LiteralPath $modulePath).ProviderPath -Force

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

Write-Host "=== Running TestLab.Transport Unit Tests ===" -ForegroundColor Cyan

# Test 1: Convert-ToRemoteShellCommand on simple commands
Assert-Test "Convert-ToRemoteShellCommand keeps simple commands unencoded" {
    $simpleCmd = "ls -la /boot"
    $converted = Convert-ToRemoteShellCommand -Command $simpleCmd
    if ($converted -ne $simpleCmd) {
        throw "Expected simple command '$simpleCmd' to remain unencoded, but got '$converted'"
    }

    $simpleCmd2 = "zpool list -H -o name bbpool"
    $converted2 = Convert-ToRemoteShellCommand -Command $simpleCmd2
    if ($converted2 -ne $simpleCmd2) {
        throw "Expected simple command '$simpleCmd2' to remain unencoded, but got '$converted2'"
    }
}

# Test 2: Convert-ToRemoteShellCommand on commands with metacharacters
Assert-Test "Convert-ToRemoteShellCommand Base64 encodes commands with metacharacters" {
    $metacharCommands = @(
        'echo "hello world"',
        "echo 'single quotes'",
        'echo $PATH',
        'uptime_secs=$(cut -d. -f1 /proc/uptime 2>/dev/null || echo 60)',
        'if [ "$a" -eq 1 ]; then echo ok; fi',
        'cmd1 && cmd2 || cmd3',
        'cat < input.txt > output.txt',
        'echo `hostname`',
        'echo -e "line1\nline2"'
    )

    foreach ($cmd in $metacharCommands) {
        $converted = Convert-ToRemoteShellCommand -Command $cmd
        if ($converted -notmatch "^printf '%s' '([^']+)' \| base64 -d \| bash$") {
            throw "Command with metacharacter was not Base64 encoded: '$cmd' -> '$converted'"
        }

        $match = [regex]::Match($converted, "^printf '%s' '([^']+)' \| base64 -d \| bash$")
        $decoded = [System.Text.Encoding]::UTF8.GetString([System.Convert]::FromBase64String($match.Groups[1].Value))
        $expected = ($cmd -replace "`r`n", "`n").Trim()
        if ($decoded -ne $expected) {
            throw "Decoded text does not match expected.`nExpected: $expected`nGot: $decoded"
        }
    }
}

# Test 3: Convert-ToRemoteShellCommand on multi-line commands
Assert-Test "Convert-ToRemoteShellCommand normalizes and encodes multi-line commands" {
    $multiLine = "line1`r`nline2`r`nline3"
    $converted = Convert-ToRemoteShellCommand -Command $multiLine
    if ($converted -notmatch "^printf '%s' '([^']+)' \| base64 -d \| bash$") {
        throw "Multi-line command was not Base64 encoded: '$converted'"
    }

    $match = [regex]::Match($converted, "^printf '%s' '([^']+)' \| base64 -d \| bash$")
    $decoded = [System.Text.Encoding]::UTF8.GetString([System.Convert]::FromBase64String($match.Groups[1].Value))
    if ($decoded -ne "line1`nline2`nline3") {
        throw "Decoded multi-line command mismatch: '$decoded'"
    }
}

# Test 4: Convert-ToRemoteSingleQuotedArgument
Assert-Test "Convert-ToRemoteSingleQuotedArgument handles quotes, spaces, and empty values" {
    $cases = @(
        @{ Input = ""; Expected = "''" },
        @{ Input = $null; Expected = "''" },
        @{ Input = "simple"; Expected = "'simple'" },
        @{ Input = "two words"; Expected = "'two words'" },
        @{ Input = "don't stop"; Expected = "'don'\''t stop'" },
        @{ Input = "'already quoted'"; Expected = "''\''already quoted'\'''" }
    )

    foreach ($case in $cases) {
        $actual = Convert-ToRemoteSingleQuotedArgument -Value $case.Input
        if ($actual -ne $case.Expected) {
            throw "Quoting failure for '$($case.Input)'. Expected $($case.Expected), got $actual"
        }
    }
}

# Test 5: Convert-ToRemoteBashScriptCommand
Assert-Test "Convert-ToRemoteBashScriptCommand wraps scripts with and without arguments" {
    $script = "set -eu`necho `"`$1`""

    # Without arguments
    $noArgs = Convert-ToRemoteBashScriptCommand -ScriptContent $script
    if ($noArgs -notmatch "^printf '%s' '([^']+)' \| base64 -d \| bash$") {
        throw "Script without arguments wrapped incorrectly: $noArgs"
    }

    # With arguments
    $args = @("first arg", "don't fail")
    $withArgs = Convert-ToRemoteBashScriptCommand -ScriptContent $script -Arguments $args
    if ($withArgs -notmatch "^printf '%s' '([^']+)' \| base64 -d \| bash -s -- 'first arg' 'don'\\''t fail'$") {
        throw "Script with arguments wrapped incorrectly: $withArgs"
    }
}

# Test 6: Get-SshCommandLineArguments
Assert-Test "Get-SshCommandLineArguments generates expected standard SSH argument array" {
    $node = [pscustomobject]@{
        User         = "root"
        Host         = "192.168.122.100"
        Port         = 2222
        IdentityFile = "C:\keys\test_id"
    }

    # With command
    $cmd = "uptime"
    $sshArgs = Get-SshCommandLineArguments -NodeConnection $node -Command $cmd

    if ($sshArgs -notcontains "-F" -or $sshArgs -notcontains "NUL") { throw "Missing -F NUL" }
    if ($sshArgs -notcontains "-o" -or $sshArgs -notcontains "BatchMode=yes") { throw "Missing -o BatchMode=yes" }
    if ($sshArgs -notcontains "-o" -or $sshArgs -notcontains "ConnectTimeout=8") { throw "Missing -o ConnectTimeout=8" }
    if ($sshArgs -notcontains "-p" -or $sshArgs -notcontains "2222") { throw "Missing -p 2222" }
    if ($sshArgs -notcontains "-i" -or $sshArgs -notcontains "C:\keys\test_id") { throw "Missing -i C:\keys\test_id" }

    $targetIndex = [array]::IndexOf($sshArgs, "root@192.168.122.100")
    if ($targetIndex -lt 0) { throw "Missing target 'root@192.168.122.100'" }
    if ($sshArgs[$targetIndex + 1] -ne "uptime") { throw "Command 'uptime' should immediately follow target" }

    # Without command
    $sshArgsNoCmd = Get-SshCommandLineArguments -NodeConnection $node
    if ($sshArgsNoCmd[-1] -ne "root@192.168.122.100") {
        throw "Last element should be target when no command is passed. Got: $($sshArgsNoCmd[-1])"
    }

    # Without identity file
    $nodeNoKey = [pscustomobject]@{
        User = "root"
        Host = "192.168.122.100"
        Port = 22
    }
    $sshArgsNoKey = Get-SshCommandLineArguments -NodeConnection $nodeNoKey
    if ($sshArgsNoKey -contains "-i") { throw "Should not contain -i when IdentityFile is null" }
    if ($sshArgsNoKey -notcontains "-p" -or $sshArgsNoKey -notcontains "22") { throw "Default port 22 missing" }
}

# Test 7: Get-ScpCommandLineArguments
Assert-Test "Get-ScpCommandLineArguments formats -P port and target correctly" {
    $node = [pscustomobject]@{
        User         = "backupuser"
        Host         = "10.0.0.50"
        Port         = 2205
        IdentityFile = "C:\keys\scp_id"
    }
    $localFiles = @("C:\staging\pkg.txz", "C:\staging\pkg.cfg")
    $remoteDir = "/boot/config/plugins/buddybackup"

    $scpArgs = Get-ScpCommandLineArguments -NodeConnection $node -LocalPaths $localFiles -RemotePath $remoteDir

    if ($scpArgs -notcontains "-P" -or $scpArgs -notcontains "2205") { throw "Missing -P 2205 for SCP" }
    if ($scpArgs -ccontains "-p") { throw "SCP should use capital -P, not -p" }
    if ($scpArgs -notcontains "-i" -or $scpArgs -notcontains "C:\keys\scp_id") { throw "Missing -i C:\keys\scp_id" }
    if ($scpArgs -notcontains "C:\staging\pkg.txz" -or $scpArgs -notcontains "C:\staging\pkg.cfg") { throw "Missing local paths" }

    $target = "backupuser@10.0.0.50:/boot/config/plugins/buddybackup"
    if ($scpArgs[-1] -ne $target) {
        throw "Last element should be target '$target', got '$($scpArgs[-1])'"
    }
}

# Test 8: Wait-UntilReady adaptive polling
Assert-Test "Wait-UntilReady adaptive polling succeeds immediately on true" {
    $state = [pscustomobject]@{ calls = 0 }
    $probe = {
        $state.calls++
        return $true
    }

    $result = Wait-UntilReady -ProbeScriptBlock $probe -TimeoutSeconds 5
    if (-not $result.Success) { throw "Expected Success = true" }
    if ($result.Attempts -ne 1) { throw "Expected 1 attempt, got $($result.Attempts)" }
    if ($state.calls -ne 1) { throw "Expected probe to be called once, called $($state.calls) times" }
}

Assert-Test "Wait-UntilReady adaptive polling succeeds on attempt 3" {
    $state = [pscustomobject]@{ calls = 0 }
    $probe = {
        $state.calls++
        if ($state.calls -ge 3) {
            return $true
        }
        return $false
    }

    $result = Wait-UntilReady -ProbeScriptBlock $probe -TimeoutSeconds 10 -InitialIntervalSeconds 0
    if (-not $result.Success) { throw "Expected Success = true" }
    if ($result.Attempts -ne 3) { throw "Expected 3 attempts, got $($result.Attempts)" }
    if ($state.calls -ne 3) { throw "Expected probe to be called 3 times, called $($state.calls) times" }
}

Assert-Test "Wait-UntilReady recognizes object with .Success property" {
    $probe = {
        return [pscustomobject]@{
            Success  = $true
            Output   = "ready"
            ExitCode = 0
        }
    }

    $result = Wait-UntilReady -ProbeScriptBlock $probe -TimeoutSeconds 5
    if (-not $result.Success) { throw "Expected Success = true" }
    if ($result.Attempts -ne 1) { throw "Expected 1 attempt, got $($result.Attempts)" }
    if ($result.Result.Output -ne "ready") { throw "Expected Result.Output == 'ready'" }
}

Assert-Test "Wait-UntilReady times out when probe never succeeds" {
    $state = [pscustomobject]@{ calls = 0 }
    $probe = {
        $state.calls++
        return $false
    }

    $result = Wait-UntilReady -ProbeScriptBlock $probe -TimeoutSeconds 1 -InitialIntervalSeconds 0
    if ($result.Success) { throw "Expected Success = false upon timeout" }
    if ($result.Attempts -lt 1) { throw "Expected at least 1 attempt" }
    if ($state.calls -lt 1) { throw "Expected at least 1 probe invocation" }
}

# Test 9: Get-NodeConnection and Resolve-NodeConnection
Assert-Test "Get-NodeConnection resolves canonical and legacy node names from lab config" {
    $labConfig = [pscustomobject]@{
        ssh = [pscustomobject]@{
            port         = 22
            user         = "root"
            identityFile = "testlab/keys/id_ed25519"
        }
        nodes = [pscustomobject]@{
            nodeA = [pscustomobject]@{
                host = "192.168.122.10"
                port = 2201
            }
            nodeB = [pscustomobject]@{
                host = "192.168.122.11"
            }
        }
    }

    $connA = Get-NodeConnection -Object $labConfig -NodeName "nodeA"
    if ($connA.NodeName -ne "nodeA") { throw "Expected NodeName 'nodeA', got '$($connA.NodeName)'" }
    if ($connA.Host -ne "192.168.122.10") { throw "Expected Host '192.168.122.10', got '$($connA.Host)'" }
    if ($connA.Port -ne 2201) { throw "Expected Port 2201, got $($connA.Port)" }
    if ($connA.User -ne "root") { throw "Expected User 'root', got '$($connA.User)'" }
    if ($connA.IdentityFile -ne "testlab/keys/id_ed25519") { throw "Expected default IdentityFile" }

    # Legacy alias "sender" resolves to "nodeA"
    $connSender = Get-NodeConnection -Object $labConfig -NodeName "sender"
    if ($connSender.NodeName -ne "nodeA") { throw "Expected NodeName 'nodeA' for 'sender', got '$($connSender.NodeName)'" }
    if ($connSender.Host -ne "192.168.122.10") { throw "Expected Host '192.168.122.10'" }

    # NodeB default port inherits from ssh config (22)
    $connB = Get-NodeConnection -Object $labConfig -NodeName "receiver"
    if ($connB.NodeName -ne "nodeB") { throw "Expected NodeName 'nodeB' for 'receiver', got '$($connB.NodeName)'" }
    if ($connB.Port -ne 22) { throw "Expected Port 22 for nodeB" }
}

# Test 10: New-RetrySummaryResult
Assert-Test "New-RetrySummaryResult records attempts on retries" {
    $singleResult = [pscustomobject]@{ Success = $true; Output = "ok" }
    $summary1 = New-RetrySummaryResult -Result $singleResult -Attempts @($singleResult)
    if ($summary1.PSObject.Properties['AttemptCount'] -ne $null) {
        throw "Single attempt should not attach AttemptCount"
    }

    $failedAttempt = [pscustomobject]@{ Success = $false; Output = "fail" }
    $succeededAttempt = [pscustomobject]@{ Success = $true; Output = "ok" }
    $summaryMulti = New-RetrySummaryResult -Result $succeededAttempt -Attempts @($failedAttempt, $succeededAttempt)
    if ($summaryMulti.AttemptCount -ne 2) {
        throw "Expected AttemptCount == 2, got $($summaryMulti.AttemptCount)"
    }
    if ($summaryMulti.Attempts.Count -ne 2) {
        throw "Expected Attempts array length 2"
    }
}

Write-Host "--------------------------------------------------"
$summaryColor = if ($testsFailed -eq 0) { "Green" } else { "Red" }
Write-Host "Transport Tests: $testsRun Total | $testsPassed Passed | $testsFailed Failed" -ForegroundColor $summaryColor

if ($testsFailed -gt 0) {
    exit 1
}
exit 0
