<#
.SYNOPSIS
    Unit tests for TestLab.Core and TestLab.Platform modules.

.DESCRIPTION
    Validates SMB-safe file I/O, JSON serialization, canonical and legacy node naming,
    object value helpers, logging/heartbeat functions, and platform helpers without booting VMs.
#>

param(
    [switch]$VerboseOutput
)

$ErrorActionPreference = "Stop"

$workspaceRoot = [System.IO.Path]::GetFullPath((Join-Path $PSScriptRoot "..\.."))
$modulesRoot = Join-Path $workspaceRoot "testlab\modules"
$coreModulePath = Join-Path $modulesRoot "TestLab.Core\TestLab.Core.psm1"
$platformModulePath = Join-Path $modulesRoot "TestLab.Platform\TestLab.Platform.psm1"

Import-Module (Resolve-Path -LiteralPath $coreModulePath).ProviderPath -Force -DisableNameChecking
Import-Module (Resolve-Path -LiteralPath $platformModulePath).ProviderPath -Force -DisableNameChecking

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

Write-Host "=== Running TestLab.Core & TestLab.Platform Unit Tests ===" -ForegroundColor Cyan

# ---------------------------------------------------------------------------
# Test Group 1: SMB-safe File I/O
# ---------------------------------------------------------------------------
Assert-Test "Read-TestLabTextFile and Write-TestLabTextFile perform safe file I/O on SMB share" {
    $tempDir = Join-Path $workspaceRoot "testlab\.testlab\tmp_test_io"
    Ensure-TestLabDir -Path $tempDir | Out-Null
    $testFilePath = Join-Path $tempDir ("test-smb-io-{0}.txt" -f [guid]::NewGuid().ToString("N"))

    try {
        $content = "Line 1: Hello World!`r`nLine 2: BuddyBackup SMB test with unicode: 🚀 \$$100 123`r`nLine 3: End of file."
        Write-TestLabTextFile -Path $testFilePath -Content $content

        if (-not (Test-Path -LiteralPath $testFilePath)) {
            throw "File was not created at '$testFilePath'."
        }

        $readBack = Read-TestLabTextFile -Path $testFilePath
        if ($readBack -ne $content) {
            throw "Read content does not match written content.`nExpected:`n$content`nGot:`n$readBack"
        }

        # Test concurrent read with open FileShare.ReadWrite stream
        $shareStream = [System.IO.FileStream]::new(
            $testFilePath,
            [System.IO.FileMode]::Open,
            [System.IO.FileAccess]::Read,
            [System.IO.FileShare]::ReadWrite
        )
        try {
            $concurrentRead = Read-TestLabTextFile -Path $testFilePath
            if ($concurrentRead -ne $content) {
                throw "Concurrent read while file is open with FileShare.ReadWrite failed to return expected content."
            }
        } finally {
            $shareStream.Dispose()
        }
    } finally {
        if (Test-Path -LiteralPath $testFilePath) {
            Remove-Item -LiteralPath $testFilePath -Force -ErrorAction SilentlyContinue
        }
        if (Test-Path -LiteralPath $tempDir) {
            Remove-Item -LiteralPath $tempDir -Recurse -Force -ErrorAction SilentlyContinue
        }
    }
}

Assert-Test "Read-TestLabTextFile throws FileNotFoundException for missing file" {
    $missingPath = Join-Path $workspaceRoot "testlab\.testlab\nonexistent-file-12345.txt"
    $threwExpected = $false
    try {
        Read-TestLabTextFile -Path $missingPath
    } catch [System.IO.FileNotFoundException] {
        $threwExpected = $true
    } catch {
        if ($_.Exception.Message -match "File not found") {
            $threwExpected = $true
        } else {
            throw "Unexpected exception type: $($_.Exception.GetType().FullName)"
        }
    }

    if (-not $threwExpected) {
        throw "Expected FileNotFoundException when reading nonexistent path."
    }
}

# ---------------------------------------------------------------------------
# Test Group 2: JSON Parse and Serialize
# ---------------------------------------------------------------------------
Assert-Test "Get-TestLabJson and Set-TestLabJson round-trip complex data structures" {
    $tempDir = Join-Path $workspaceRoot "testlab\.testlab\tmp_test_json"
    Ensure-TestLabDir -Path $tempDir | Out-Null
    $testJsonPath = Join-Path $tempDir ("test-json-{0}.json" -f [guid]::NewGuid().ToString("N"))

    try {
        $original = [ordered]@{
            provider = "windows-wsl-qemu"
            enabled = $true
            retryCount = 42
            tags = @("zfs", "replication", "syncoid")
            nested = [ordered]@{
                target = "buddybackup-node-a"
                subConfig = [ordered]@{
                    port = 2222
                    active = $false
                }
            }
        }

        Set-TestLabJson -Path $testJsonPath -Object $original -Depth 10
        if (-not (Test-Path -LiteralPath $testJsonPath)) {
            throw "JSON file was not created at '$testJsonPath'."
        }

        $deserialized = Get-TestLabJson -Path $testJsonPath
        if ($null -eq $deserialized) {
            throw "Get-TestLabJson returned null."
        }

        if ($deserialized.provider -ne "windows-wsl-qemu") {
            throw "Property 'provider' mismatched: expected 'windows-wsl-qemu', got '$($deserialized.provider)'"
        }
        if ($deserialized.retryCount -ne 42) {
            throw "Property 'retryCount' mismatched: expected 42, got '$($deserialized.retryCount)'"
        }
        if ($deserialized.enabled -ne $true) {
            throw "Property 'enabled' mismatched: expected true"
        }
        if ($deserialized.tags.Count -ne 3 -or $deserialized.tags[1] -ne "replication") {
            throw "Tags array mismatched."
        }
        if ($deserialized.nested.subConfig.port -ne 2222) {
            throw "Nested subConfig port mismatched: expected 2222, got '$($deserialized.nested.subConfig.port)'"
        }
    } finally {
        if (Test-Path -LiteralPath $testJsonPath) {
            Remove-Item -LiteralPath $testJsonPath -Force -ErrorAction SilentlyContinue
        }
        if (Test-Path -LiteralPath $tempDir) {
            Remove-Item -LiteralPath $tempDir -Recurse -Force -ErrorAction SilentlyContinue
        }
    }
}

Assert-Test "Get-TestLabConfig loads configuration and supports fallback" {
    $labConfig = Get-TestLabConfig -Path "testlab/config/lab.local.json" -FallbackPath "testlab/config/lab.example.json"
    if ($null -eq $labConfig) {
        throw "Get-TestLabConfig returned null for lab.local.json / lab.example.json"
    }
    if ([string]::IsNullOrWhiteSpace($labConfig.provider)) {
        throw "Loaded config is missing 'provider' field."
    }

    # Verify fallback behavior with nonexistent primary path
    $fallbackConfig = Get-TestLabConfig -Path "testlab/config/nonexistent-config.json" -FallbackPath "testlab/config/lab.example.json"
    if ($null -eq $fallbackConfig -or [string]::IsNullOrWhiteSpace($fallbackConfig.provider)) {
        throw "Fallback to lab.example.json failed."
    }
}

# ---------------------------------------------------------------------------
# Test Group 3: Canonical and Legacy Node Naming Normalization (nodeA <-> buddybackup-node-a)
# ---------------------------------------------------------------------------
Assert-Test "Get-TestLabCanonicalNodeName normalizes aliases and hostnames to canonical node names" {
    # NodeA variants
    $canonicalA1 = Get-TestLabCanonicalNodeName -NodeName "sender"
    $canonicalA2 = Get-TestLabCanonicalNodeName -NodeName "buddybackup-node-a"
    $canonicalA3 = Get-TestLabCanonicalNodeName -NodeName "buddybackup-nodea"
    $canonicalA4 = Get-TestLabCanonicalNodeName -NodeName "node-a"
    $canonicalA5 = Get-TestLabCanonicalNodeName -NodeName "nodeA"

    if ($canonicalA1 -ne "nodeA" -or $canonicalA2 -ne "nodeA" -or $canonicalA3 -ne "nodeA" -or $canonicalA4 -ne "nodeA" -or $canonicalA5 -ne "nodeA") {
        throw "Canonical normalization for NodeA failed: got A1='$canonicalA1', A2='$canonicalA2', A3='$canonicalA3', A4='$canonicalA4', A5='$canonicalA5'"
    }

    # NodeB variants
    $canonicalB1 = Get-TestLabCanonicalNodeName -NodeName "receiver"
    $canonicalB2 = Get-TestLabCanonicalNodeName -NodeName "buddybackup-node-b"
    $canonicalB3 = Get-TestLabCanonicalNodeName -NodeName "buddybackup-nodeb"
    $canonicalB4 = Get-TestLabCanonicalNodeName -NodeName "node-b"
    $canonicalB5 = Get-TestLabCanonicalNodeName -NodeName "nodeB"

    if ($canonicalB1 -ne "nodeB" -or $canonicalB2 -ne "nodeB" -or $canonicalB3 -ne "nodeB" -or $canonicalB4 -ne "nodeB" -or $canonicalB5 -ne "nodeB") {
        throw "Canonical normalization for NodeB failed: got B1='$canonicalB1', B2='$canonicalB2', B3='$canonicalB3', B4='$canonicalB4', B5='$canonicalB5'"
    }

    # NodeC variants
    $canonicalC1 = Get-TestLabCanonicalNodeName -NodeName "generic"
    $canonicalC2 = Get-TestLabCanonicalNodeName -NodeName "buddybackup-node-c"
    $canonicalC3 = Get-TestLabCanonicalNodeName -NodeName "buddybackup-node-c-generic"
    $canonicalC4 = Get-TestLabCanonicalNodeName -NodeName "node-c"
    $canonicalC5 = Get-TestLabCanonicalNodeName -NodeName "nodeC"

    if ($canonicalC1 -ne "nodeC" -or $canonicalC2 -ne "nodeC" -or $canonicalC3 -ne "nodeC" -or $canonicalC4 -ne "nodeC" -or $canonicalC5 -ne "nodeC") {
        throw "Canonical normalization for NodeC failed: got C1='$canonicalC1', C2='$canonicalC2', C3='$canonicalC3', C4='$canonicalC4', C5='$canonicalC5'"
    }
}

Assert-Test "Get-TestLabLegacyNodeName and Get-TestLabHostNodeName convert between canonical, legacy, and host names" {
    # Legacy names (sender / receiver)
    if ((Get-TestLabLegacyNodeName -NodeName "nodeA") -ne "sender") {
        throw "Legacy node name for 'nodeA' should be 'sender'"
    }
    if ((Get-TestLabLegacyNodeName -NodeName "buddybackup-node-a") -ne "sender") {
        throw "Legacy node name for 'buddybackup-node-a' should be 'sender'"
    }
    if ((Get-TestLabLegacyNodeName -NodeName "nodeB") -ne "receiver") {
        throw "Legacy node name for 'nodeB' should be 'receiver'"
    }
    if ((Get-TestLabLegacyNodeName -NodeName "buddybackup-node-b") -ne "receiver") {
        throw "Legacy node name for 'buddybackup-node-b' should be 'receiver'"
    }

    # Host names (buddybackup-node-a / buddybackup-node-b)
    if ((Get-TestLabHostNodeName -NodeName "nodeA") -ne "buddybackup-node-a") {
        throw "Host node name for 'nodeA' should be 'buddybackup-node-a'"
    }
    if ((Get-TestLabHostNodeName -NodeName "sender") -ne "buddybackup-node-a") {
        throw "Host node name for 'sender' should be 'buddybackup-node-a'"
    }
    if ((Get-TestLabHostNodeName -NodeName "nodeB") -ne "buddybackup-node-b") {
        throw "Host node name for 'nodeB' should be 'buddybackup-node-b'"
    }
    if ((Get-TestLabHostNodeName -NodeName "receiver") -ne "buddybackup-node-b") {
        throw "Host node name for 'receiver' should be 'buddybackup-node-b'"
    }
    if ((Get-TestLabHostNodeName -NodeName "nodeC") -ne "buddybackup-node-c-generic") {
        throw "Host node name for 'nodeC' should be 'buddybackup-node-c-generic'"
    }
}

Assert-Test "Get-TestLabNodeValue retrieves nodes using canonical, legacy, or hostname identifiers" {
    # 1. Test against hashtable keyed with canonical names
    $canonicalNodes = @{
        nodeA = @{ name = "buddybackup-node-a"; unraidVersion = "7.2.6" }
        nodeB = @{ name = "buddybackup-node-b"; unraidVersion = "7.3.0" }
    }

    $nodeA_by_canonical = Get-TestLabNodeValue -Object $canonicalNodes -NodeName "nodeA"
    $nodeA_by_legacy    = Get-TestLabNodeValue -Object $canonicalNodes -NodeName "sender"
    $nodeA_by_host      = Get-TestLabNodeValue -Object $canonicalNodes -NodeName "buddybackup-node-a"

    if ($null -eq $nodeA_by_canonical -or $nodeA_by_canonical.unraidVersion -ne "7.2.6") {
        throw "Failed to retrieve nodeA by canonical name."
    }
    if ($null -eq $nodeA_by_legacy -or $nodeA_by_legacy.unraidVersion -ne "7.2.6") {
        throw "Failed to retrieve nodeA by legacy name 'sender'."
    }
    if ($null -eq $nodeA_by_host -or $nodeA_by_host.unraidVersion -ne "7.2.6") {
        throw "Failed to retrieve nodeA by hostname 'buddybackup-node-a'."
    }

    # 2. Test against legacy dictionary keyed with 'sender' and 'receiver'
    $legacyNodes = @{
        sender   = @{ name = "buddybackup-node-a"; unraidVersion = "6.12.14" }
        receiver = @{ name = "buddybackup-node-b"; unraidVersion = "7.0.0" }
    }

    $nodeA_from_legacy = Get-TestLabNodeValue -Object $legacyNodes -NodeName "nodeA"
    if ($null -eq $nodeA_from_legacy -or $nodeA_from_legacy.unraidVersion -ne "6.12.14") {
        throw "Failed to retrieve nodeA from legacy-keyed dictionary."
    }

    # 3. Test against PSCustomObject as loaded from JSON
    $jsonObj = [PSCustomObject]@{
        nodeA = [PSCustomObject]@{ name = "buddybackup-node-a"; host = "127.0.0.1"; port = 2222 }
        nodeB = [PSCustomObject]@{ name = "buddybackup-node-b"; host = "127.0.0.1"; port = 2223 }
    }

    $nodeB_obj = Get-TestLabNodeValue -Object $jsonObj -NodeName "buddybackup-node-b"
    if ($null -eq $nodeB_obj -or $nodeB_obj.port -ne 2223) {
        throw "Failed to retrieve nodeB from PSCustomObject by hostname."
    }
}

# ---------------------------------------------------------------------------
# Test Group 4: Get-ObjectValue and Set-ObjectValue
# ---------------------------------------------------------------------------
Assert-Test "Get-ObjectValue and Set-ObjectValue operate safely on IDictionary and PSCustomObject" {
    # Test on Hashtable
    $hash = @{ key1 = "val1"; count = 10 }
    if ((Get-ObjectValue -Object $hash -Name "key1") -ne "val1") {
        throw "Get-ObjectValue failed on hashtable for 'key1'."
    }
    if ($null -ne (Get-ObjectValue -Object $hash -Name "nonexistent")) {
        throw "Get-ObjectValue should return null for missing hashtable key."
    }

    Set-ObjectValue -Object $hash -Name "key1" -Value "updated"
    Set-ObjectValue -Object $hash -Name "newKey" -Value "created"
    if ($hash["key1"] -ne "updated" -or $hash["newKey"] -ne "created") {
        throw "Set-ObjectValue failed on hashtable."
    }

    # Test on PSCustomObject
    $pso = [PSCustomObject]@{
        name = "test-node"
        port = 8080
    }
    if ((Get-ObjectValue -Object $pso -Name "name") -ne "test-node") {
        throw "Get-ObjectValue failed on PSCustomObject for 'name'."
    }
    if ($null -ne (Get-ObjectValue -Object $pso -Name "missingProp")) {
        throw "Get-ObjectValue should return null for missing PSCustomObject property."
    }

    Set-ObjectValue -Object $pso -Name "port" -Value 9090
    Set-ObjectValue -Object $pso -Name "status" -Value "online"
    if ($pso.port -ne 9090 -or $pso.status -ne "online") {
        throw "Set-ObjectValue failed on PSCustomObject."
    }

    # Null object safety
    if ($null -ne (Get-ObjectValue -Object $null -Name "foo")) {
        throw "Get-ObjectValue on null should return null."
    }
    Set-ObjectValue -Object $null -Name "foo" -Value "bar" # Should not throw
}

# ---------------------------------------------------------------------------
# Test Group 5: Logging, Timestamps, and Heartbeats
# ---------------------------------------------------------------------------
Assert-Test "Get-TestLabTimestamp and Resolve-TestLabDateTime format and parse timestamps correctly" {
    $timestamp = Get-TestLabTimestamp
    if ($timestamp -notmatch '^\d{2}:\d{2}:\d{2}$') {
        throw "Timestamp '$timestamp' did not match expected 'HH:mm:ss' format."
    }

    $now = Get-Date
    $resolvedDate = Resolve-TestLabDateTime -Value $now
    if ($resolvedDate.Year -ne $now.Year -or $resolvedDate.Minute -ne $now.Minute) {
        throw "Resolve-TestLabDateTime did not preserve DateTime object."
    }

    $stringDate = "2026-10-18T12:00:00Z"
    $resolvedFromString = Resolve-TestLabDateTime -Value $stringDate
    if ($null -eq $resolvedFromString -or $resolvedFromString.Year -ne 2026) {
        throw "Resolve-TestLabDateTime failed to parse ISO string date."
    }

    $fallbackDate = Get-Date "2025-01-01"
    $resolvedFallback = Resolve-TestLabDateTime -Value $null -Fallback $fallbackDate
    if ($resolvedFallback.Year -ne 2025) {
        throw "Resolve-TestLabDateTime failed to return fallback on null input."
    }
}

Assert-Test "Write-TestLabHeartbeat updates and throttles heartbeat correctly" {
    $start = (Get-Date).AddSeconds(-30)

    # Initial heartbeat call should emit message and return current datetime
    $hb1 = Write-TestLabHeartbeat -Message "Test heartbeat" -StartedAt $start -IntervalSeconds 15
    if ($null -eq $hb1 -or ($hb1 -isnot [datetime])) {
        throw "Write-TestLabHeartbeat did not return a DateTime object on initial trigger."
    }

    # Immediate second call within 15s interval should be throttled and return previous hb timestamp
    $hb2 = Write-TestLabHeartbeat -Message "Throttled heartbeat" -StartedAt $start -LastHeartbeatAt $hb1 -IntervalSeconds 15
    if ($hb2 -ne $hb1) {
        throw "Write-TestLabHeartbeat should have throttled and returned the existing LastHeartbeatAt timestamp."
    }

    # Call with expired interval (simulate by giving past LastHeartbeatAt) should return updated datetime
    $oldHb = (Get-Date).AddSeconds(-20)
    $hb3 = Write-TestLabHeartbeat -Message "Updated heartbeat" -StartedAt $start -LastHeartbeatAt $oldHb -IntervalSeconds 15
    if ($hb3 -le $oldHb) {
        throw "Write-TestLabHeartbeat should have emitted a new heartbeat for expired interval."
    }
}

# ---------------------------------------------------------------------------
# Test Group 6: Workspace Root and Path Helpers
# ---------------------------------------------------------------------------
Assert-Test "Get-TestLabWorkspaceRoot and Resolve-TestLabWorkspacePath resolve repository paths" {
    $detectedRoot = Get-TestLabWorkspaceRoot -ScriptRoot $PSScriptRoot
    if ([string]::IsNullOrWhiteSpace($detectedRoot) -or -not (Test-Path -LiteralPath (Join-Path $detectedRoot "testlab"))) {
        throw "Get-TestLabWorkspaceRoot failed to locate workspace root containing 'testlab'. Got: '$detectedRoot'"
    }

    $resolvedRel = Resolve-TestLabWorkspacePath -WorkspaceRoot $detectedRoot -Path "testlab/config/lab.local.json"
    $expectedPath = [System.IO.Path]::GetFullPath((Join-Path $detectedRoot "testlab\config\lab.local.json"))
    if ($resolvedRel -ne $expectedPath) {
        throw "Resolve-TestLabWorkspacePath mismatched.`nExpected: $expectedPath`nGot: $resolvedRel"
    }

    $resolvedRooted = Resolve-TestLabWorkspacePath -WorkspaceRoot $detectedRoot -Path "C:\Windows\System32"
    if ($resolvedRooted -ne "C:\Windows\System32") {
        throw "Resolve-TestLabWorkspacePath should return rooted paths unmodified."
    }
}

# ---------------------------------------------------------------------------
# Test Group 7: Matrix Unraid Version Check
# ---------------------------------------------------------------------------
Assert-Test "Test-LabSupportsMatrixUnraidVersions validates matching vs mismatched Unraid versions" {
    $lab = [PSCustomObject]@{
        provider = "windows-wsl-qemu"
        nodes = [PSCustomObject]@{
            nodeA = [PSCustomObject]@{ unraidVersion = "7.2.6" }
            nodeB = [PSCustomObject]@{ unraidVersion = "7.3.0" }
        }
    }

    $matchingCells = @(
        [PSCustomObject]@{
            cellId = "cell-1"
            nodeA = [PSCustomObject]@{ unraid = "7.2.6" }
            nodeB = [PSCustomObject]@{ unraid = "7.3.0" }
        }
    )

    $matchResult = Test-LabSupportsMatrixUnraidVersions -Lab $lab -MatrixCells $matchingCells
    if (-not $matchResult.Success) {
        throw "Expected matching versions to succeed, got error: $($matchResult.Error)"
    }

    $mismatchedCells = @(
        [PSCustomObject]@{
            cellId = "cell-2"
            nodeA = [PSCustomObject]@{ unraid = "6.12.14" }
            nodeB = [PSCustomObject]@{ unraid = "7.3.0" }
        }
    )

    $mismatchResult = Test-LabSupportsMatrixUnraidVersions -Lab $lab -MatrixCells $mismatchedCells
    if ($mismatchResult.Success) {
        throw "Expected mismatched versions to fail validation, but it succeeded."
    }
    if ($mismatchResult.Error -notmatch "nodeA lab=7.2.6 matrix=6.12.14") {
        throw "Error message did not detail the specific version mismatch. Got: $($mismatchResult.Error)"
    }
}

# ---------------------------------------------------------------------------
# Test Group 8: Platform Network Helpers
# ---------------------------------------------------------------------------
Assert-Test "Test-PortAvailable and Get-FreeLoopbackPort scan localhost TCP ports" {
    # Check that a common high ephemeral port can be tested
    $testPort = Get-FreeLoopbackPort -StartPort 39100 -EndPort 39200
    if ($testPort -lt 39100 -or $testPort -gt 39200) {
        throw "Get-FreeLoopbackPort returned port $testPort outside requested range [39100, 39200]."
    }

    $isAvail = Test-PortAvailable -Port $testPort
    if (-not $isAvail) {
        throw "Test-PortAvailable reported returned free port $testPort as unavailable."
    }

    # Verify exclusion list is respected
    $excluded = @($testPort)
    $nextPort = Get-FreeLoopbackPort -StartPort 39100 -EndPort 39200 -ExcludedPorts $excluded
    if ($nextPort -eq $testPort) {
        throw "Get-FreeLoopbackPort returned excluded port $testPort."
    }
}

# ---------------------------------------------------------------------------
# Test Group 9: WSL Instance Management
# ---------------------------------------------------------------------------
Assert-Test "Stop-WslLabInstance dry run calculates work root and executes cleanly" {
    $dryRunOutput = @(Stop-WslLabInstance -InstanceName "nodeTest" 6>&1)
    # Also test absolute path variant
    $dryRunAbsOutput = @(Stop-WslLabInstance -InstanceName "/tmp/custom-work-root" 6>&1)
}

Write-Host "--------------------------------------------------"
$summaryColor = if ($testsFailed -eq 0) { "Green" } else { "Red" }
Write-Host "Core & Platform Tests: $testsRun Total | $testsPassed Passed | $testsFailed Failed" -ForegroundColor $summaryColor

if ($testsFailed -gt 0) {
    exit 1
}
exit 0
