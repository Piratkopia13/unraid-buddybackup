<#
.SYNOPSIS
    Layer 4 Scenario: Functional smoke testing for BuddyBackup Unraid testlab.
.DESCRIPTION
    Validates end-to-end functionality between nodeA and nodeB:
    - Reads lab configuration and resolves node connections.
    - Reads sender public keys, configures backup and incoming configurations on both nodes,
      sets up peer forward rules, primes known hosts, and updates plugins.
    - Tests connections between nodeA and nodeB.
    - Creates payload file on source dataset, snapshots, and executes backup send.
    - Verifies backup reached destination dataset.
    - Restores backup to local restore dataset and verifies SHA256 matches.
    - Tests bidirectional replication (nodeB to nodeA).
    - Verifies backup hooks lifecycle and failure modes.
    - Verifies snapshot trigger decoupling and background detachment.
    - Audits log hygiene.
    - Returns structured result object and writes functional smoke report JSON.
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
if (Test-Path Variable:\PSNativeCommandUseErrorActionPreference) {
    $PSNativeCommandUseErrorActionPreference = $false
}

$workspaceRoot = [System.IO.Path]::GetFullPath((Join-Path $PSScriptRoot "..\.."))
$modulesRoot = Join-Path $workspaceRoot "testlab\modules"

Import-Module -Name (Resolve-Path -LiteralPath (Join-Path $modulesRoot "TestLab.Core\TestLab.Core.psm1")).ProviderPath -DisableNameChecking
Import-Module -Name (Resolve-Path -LiteralPath (Join-Path $modulesRoot "TestLab.Transport\TestLab.Transport.psm1")).ProviderPath -DisableNameChecking
Import-Module -Name (Resolve-Path -LiteralPath (Join-Path $modulesRoot "TestLab.Guest\TestLab.Guest.psm1")).ProviderPath -DisableNameChecking

# ---------------- Helper Functions ----------------

function Convert-ToShellSingleQuoted {
    param([string]$Value)
    return Convert-ToRemoteSingleQuotedArgument -Value $Value
}

function Get-FunctionalTestConfig {
    param($Lab)

    $setupCfg = Get-ObjectValue -Object $Lab -Name "setup"
    $functionalCfg = Get-ObjectValue -Object $setupCfg -Name "functionalTests"

    $hostGatewayIp = [string](Get-ObjectValue -Object $functionalCfg -Name "hostGatewayIp")
    if ([string]::IsNullOrWhiteSpace($hostGatewayIp)) {
        $hostGatewayIp = "10.0.2.2"
    }

    $testDatasetRootName = [string](Get-ObjectValue -Object $functionalCfg -Name "testDatasetRootName")
    if ([string]::IsNullOrWhiteSpace($testDatasetRootName)) {
        $testDatasetRootName = "functional"
    }

    $receiveDatasetName = [string](Get-ObjectValue -Object $functionalCfg -Name "receiveDatasetName")
    if ([string]::IsNullOrWhiteSpace($receiveDatasetName)) {
        $receiveDatasetName = "receive"
    }

    $nodeAAliasIp = [string](Get-ObjectValue -Object $functionalCfg -Name "nodeAAliasIp")
    if ([string]::IsNullOrWhiteSpace($nodeAAliasIp)) {
        $nodeAAliasIp = [string](Get-ObjectValue -Object $functionalCfg -Name "senderAliasIp")
    }
    if ([string]::IsNullOrWhiteSpace($nodeAAliasIp)) {
        $nodeAAliasIp = "10.254.0.22"
    }

    $nodeBAliasIp = [string](Get-ObjectValue -Object $functionalCfg -Name "nodeBAliasIp")
    if ([string]::IsNullOrWhiteSpace($nodeBAliasIp)) {
        $nodeBAliasIp = [string](Get-ObjectValue -Object $functionalCfg -Name "receiverAliasIp")
    }
    if ([string]::IsNullOrWhiteSpace($nodeBAliasIp)) {
        $nodeBAliasIp = "10.254.0.23"
    }

    $allowUnencryptedRemoteBackups = "yes"
    $allowUnencryptedValue = Get-ObjectValue -Object $functionalCfg -Name "allowUnencryptedRemoteBackups"
    if ($null -ne $allowUnencryptedValue) {
        $allowUnencryptedRemoteBackups = if ([bool]$allowUnencryptedValue) { "yes" } else { "no" }
    }

    return [pscustomobject]@{
        hostGatewayIp                 = $hostGatewayIp
        testDatasetRootName           = $testDatasetRootName
        receiveDatasetName            = $receiveDatasetName
        nodeAAliasIp                  = $nodeAAliasIp
        nodeBAliasIp                  = $nodeBAliasIp
        allowUnencryptedRemoteBackups = $allowUnencryptedRemoteBackups
    }
}

function Invoke-NodeSshCommand {
    param(
        $NodeConnection,
        [string]$Command,
        [string]$Label,
        [switch]$DoExecute
    )

    $res = Invoke-RemoteCommand -NodeConnection $NodeConnection -Command $Command -Label $Label -DoExecute:$DoExecute
    $outputLines = if ($res.Output -is [array]) { $res.Output } elseif ($null -ne $res.Output) { @([string]$res.Output -split "`r?`n") } else { @() }
    return [pscustomobject]@{
        node     = $NodeConnection.NodeName
        label    = $Label
        command  = $Command
        success  = [bool]$res.Success
        exitCode = [int]$res.ExitCode
        output   = $outputLines
    }
}

function Invoke-NodeBashScript {
    param(
        $NodeConnection,
        [string]$ScriptContent,
        [string[]]$Arguments,
        [string]$Label,
        [switch]$DoExecute
    )

    $res = Invoke-RemoteBash -NodeConnection $NodeConnection -BashScript $ScriptContent -Arguments $Arguments -Label $Label -DoExecute:$DoExecute
    $outputLines = if ($res.Output -is [array]) { $res.Output } elseif ($null -ne $res.Output) { @([string]$res.Output -split "`r?`n") } else { @() }
    return [pscustomobject]@{
        node     = $NodeConnection.NodeName
        label    = $Label
        command  = $res.Command
        success  = [bool]$res.Success
        exitCode = [int]$res.ExitCode
        output   = $outputLines
    }
}

function Invoke-NodeBashScriptWithRetry {
    param(
        $NodeConnection,
        [string]$ScriptContent,
        [string[]]$Arguments,
        [string]$Label,
        [int]$MaxAttempts = 6,
        [int]$RetryDelaySeconds = 8,
        [switch]$DoExecute
    )

    $attempts = @()
    $result = $null

    for ($attempt = 1; $attempt -le $MaxAttempts; $attempt++) {
        $result = Invoke-NodeBashScript -NodeConnection $NodeConnection -ScriptContent $ScriptContent -Arguments $Arguments -Label $Label -DoExecute:$DoExecute
        $attempts += $result
        if ($result.success) {
            break
        }

        if (-not $DoExecute -or -not (Test-IsTransientSshFailure -Result $result) -or $attempt -ge $MaxAttempts) {
            break
        }

        Start-Sleep -Seconds $RetryDelaySeconds
    }

    if ($result -and $attempts.Count -gt 1) {
        $result | Add-Member -NotePropertyName AttemptCount -NotePropertyValue $attempts.Count -Force
        $result | Add-Member -NotePropertyName Attempts -NotePropertyValue @($attempts) -Force
    }

    return $result
}

function Invoke-NodeSshCommandWithRetry {
    param(
        $NodeConnection,
        [string]$Command,
        [string]$Label,
        [int]$MaxAttempts = 12,
        [int]$RetryDelaySeconds = 4,
        [switch]$DoExecute
    )

    $attempts = @()
    $result = $null

    for ($attempt = 1; $attempt -le $MaxAttempts; $attempt++) {
        $result = Invoke-NodeSshCommand -NodeConnection $NodeConnection -Command $Command -Label $Label -DoExecute:$DoExecute
        $attempts += $result
        if ($result.success) {
            break
        }

        if (-not $DoExecute -or -not (Test-IsTransientSshFailure -Result $result) -or $attempt -ge $MaxAttempts) {
            break
        }

        Start-Sleep -Seconds $RetryDelaySeconds
    }

    if ($result -and $attempts.Count -gt 1) {
        $result | Add-Member -NotePropertyName AttemptCount -NotePropertyValue $attempts.Count -Force
        $result | Add-Member -NotePropertyName Attempts -NotePropertyValue @($attempts) -Force
    }

    return $result
}

function Invoke-BuddyBackupPhpCommand {
    param(
        $NodeConnection,
        [string]$Action,
        [string[]]$Arguments,
        [string]$Label,
        [switch]$DoExecute
    )

    $parts = @("/usr/local/emhttp/plugins/buddybackup/scripts/rc.buddybackup.php", $Action)
    if ($Arguments) {
        $parts += $Arguments
    }

    $command = ($parts | ForEach-Object { Convert-ToShellSingleQuoted -Value ([string]$_) }) -join " "
    return Invoke-NodeSshCommand -NodeConnection $NodeConnection -Command $command -Label $Label -DoExecute:$DoExecute
}

function Invoke-BuddyBackupShellCommand {
    param(
        $NodeConnection,
        [string]$Action,
        [string[]]$Arguments,
        [string]$Label,
        [switch]$DoExecute
    )

    $parts = @("/usr/local/emhttp/plugins/buddybackup/scripts/rc.buddybackup", $Action)
    if ($Arguments) {
        $parts += $Arguments
    }

    $command = ($parts | ForEach-Object { Convert-ToShellSingleQuoted -Value ([string]$_) }) -join " "
    return Invoke-NodeSshCommand -NodeConnection $NodeConnection -Command $command -Label $Label -DoExecute:$DoExecute
}

function Add-ReportAction {
    param(
        $Report,
        $Result
    )

    $action = [ordered]@{
        node     = $Result.node
        label    = $Result.label
        success  = [bool]$Result.success
        exitCode = [int]$Result.exitCode
        command  = [string]$Result.command
        output   = @($Result.output)
    }

    $attemptsProperty = $Result.PSObject.Properties['Attempts']
    if ($attemptsProperty) {
        $action.attemptCount = [int]$Result.AttemptCount
        $action.attempts = @($Result.Attempts | ForEach-Object {
            [pscustomobject]@{
                success  = [bool]$_.success
                exitCode = [int]$_.exitCode
                command  = [string]$_.command
                output   = @($_.output)
            }
        })
    }

    $Report.actions += [pscustomobject]$action
}

function Assert-CommandSucceeded {
    param(
        $Result,
        [string]$FailureMessage
    )

    if (-not $Result.success) {
        $details = (($Result.output | ForEach-Object { [string]$_ }) -join [Environment]::NewLine).Trim()
        if ([string]::IsNullOrWhiteSpace($details)) {
            throw $FailureMessage
        }

        throw "$FailureMessage`n$details"
    }
}

function Test-IsTransientSshFailure {
    param($Result)

    if ($null -eq $Result) {
        return $false
    }

    $outputText = (@($Result.output | ForEach-Object { [string]$_ }) -join "`n").Trim()
    $transientPattern = '(?i)connection closed by|connection reset by peer|connection refused|operation timed out|connection timed out|broken pipe|kex_exchange_identification|no route to host|network is unreachable'

    if ([int]$Result.exitCode -notin @(255, -1)) {
        return (-not [string]::IsNullOrWhiteSpace($outputText)) -and ($outputText -match $transientPattern)
    }

    if ([string]::IsNullOrWhiteSpace($outputText)) {
        return $true
    }

    return $outputText -match $transientPattern
}

function Get-ResultOutputText {
    param($Result)

    if ($null -eq $Result) {
        return ""
    }

    return (@($Result.output | ForEach-Object { [string]$_ }) -join "`n").Trim()
}

function Test-IsRetryableTestConnectionFailure {
    param($Result)

    if ($null -eq $Result) {
        return $false
    }

    $outputText = Get-ResultOutputText -Result $Result
    if ([string]::IsNullOrWhiteSpace($outputText)) {
        return [int]$Result.exitCode -in @(255, -1)
    }

    return $outputText -match '(?i)Host key verification failed|SSH security validation failed|connection closed by|connection reset by peer|connection refused|connection timed out|operation timed out|kex_exchange_identification|no route to host|network is unreachable'
}

function Test-IsHostKeyVerificationFailure {
    param($Result)

    if ($null -eq $Result) {
        return $false
    }

    $outputText = Get-ResultOutputText -Result $Result
    return $outputText -match '(?i)Host key verification failed|REMOTE HOST IDENTIFICATION HAS CHANGED|hostfile_replace_entries|update_known_hosts'
}

function Invoke-PrimeLegacyKnownHostsOnNode {
    param(
        $NodeConnection,
        [string]$RemoteHost,
        [switch]$DoExecute
    )

    if (-not $DoExecute -or [string]::IsNullOrWhiteSpace($RemoteHost)) {
        return
    }

    $script = @'
remote_host="$1"
known_hosts_file="/root/.ssh/known_hosts"
ssh_config_file="/root/.ssh/config"
flash_ssh_config="/boot/config/ssh/root/config"
begin_marker="# buddybackup start"
end_marker="# buddybackup end"

mkdir -p /root/.ssh /boot/config/ssh/root
chmod 700 /root/.ssh /boot/config/ssh/root 2>/dev/null || true
touch "$known_hosts_file"
chmod 600 "$known_hosts_file"

for cfg in "$ssh_config_file" "$flash_ssh_config"; do
    touch "$cfg"
    chmod 600 "$cfg"
    if ! grep -q "UpdateHostKeys" "$cfg" 2>/dev/null; then
        cat >> "$cfg" <<'EOF'
Host *
    UpdateHostKeys no
EOF
    fi
done

scanned_keys=""
for attempt in 1 2 3 4 5; do
    attempt_keys=$(ssh-keyscan -T 3 "$remote_host" 2>/dev/null || true)
    hashed_keys=$(ssh-keyscan -T 3 -H "$remote_host" 2>/dev/null || true)
    combined=""
    if [[ -n "$attempt_keys" && -n "$hashed_keys" ]]; then
        combined="${attempt_keys}"$'\n'"${hashed_keys}"
    elif [[ -n "$attempt_keys" ]]; then
        combined="$attempt_keys"
    elif [[ -n "$hashed_keys" ]]; then
        combined="$hashed_keys"
    fi

    if [[ -n "$combined" ]]; then
        if [[ -n "$scanned_keys" ]]; then
            scanned_keys=$(printf '%s\n%s\n' "$scanned_keys" "$combined" | sed '/^[[:space:]]*$/d' | awk '
                /^[[:space:]]*#/ { if (!comment[$0]++) print; next }
                NF >= 3 { key = $2 " " $3; if (!material[key]++) print; next }
                { print }
            ')
        else
            scanned_keys=$(printf '%s\n' "$combined" | sed '/^[[:space:]]*$/d')
        fi

        if printf '%s\n' "$scanned_keys" | grep -q 'ssh-ed25519' && \
           printf '%s\n' "$scanned_keys" | grep -q 'ecdsa-sha2-nistp256' && \
           printf '%s\n' "$scanned_keys" | grep -q 'ssh-rsa'; then
            break
        fi
    fi

    if [[ "$attempt" -lt 5 ]]; then
        sleep 1
    fi
done

if [[ -n "$scanned_keys" ]]; then
    tmp_known_hosts="$(mktemp)"
    next_known_hosts="${tmp_known_hosts}.next"

    awk -v begin="$begin_marker" -v end="$end_marker" '
        $0 == begin { skip=1; next }
        $0 == end { skip=0; next }
        !skip { print }
    ' "$known_hosts_file" > "$tmp_known_hosts"

    {
        cat "$tmp_known_hosts"
        printf '%s\n' "$begin_marker"
        printf '%s\n' "$scanned_keys"
        printf '%s\n' "$end_marker"
    } > "$next_known_hosts"

    mv "$next_known_hosts" "$known_hosts_file"
    rm -f "$tmp_known_hosts"
fi
'@
    $cmd = Convert-ToRemoteBashScriptCommand -ScriptContent $script -Arguments @($RemoteHost)
    Invoke-NodeSshCommandWithRetry -NodeConnection $NodeConnection -Command $cmd -Label "$($NodeConnection.NodeName)-prime-legacy-known-hosts" -DoExecute:$DoExecute | Out-Null
}

function Invoke-BuddyBackupRefreshKnownHosts {
    param(
        $NodeConnection,
        [string]$RemoteHost = "",
        [switch]$DoExecute
    )

    if (-not $DoExecute) {
        return
    }

    Write-Host "[testlab] Refreshing BuddyBackup known_hosts on $($NodeConnection.NodeName) after a host key verification failure"
    $probeManagedCmd = "grep -q 'ssh_known_hosts_path' /usr/local/emhttp/plugins/buddybackup/scripts/rc.buddybackup && echo 'managed' || echo 'legacy'"
    $probeResult = Invoke-NodeSshCommand -NodeConnection $NodeConnection -Command $probeManagedCmd -Label "$($NodeConnection.NodeName)-probe-managed-for-refresh" -DoExecute:$DoExecute
    $isManaged = $true
    if ($probeResult -and $probeResult.success) {
        $out = ($probeResult.output -join "`n").Trim()
        if ($out -eq "legacy") {
            $isManaged = $false
        }
    }

    if ($isManaged) {
        Invoke-BuddyBackupPhpCommandWithRetry -NodeConnection $NodeConnection -Action "update" -Label "$($NodeConnection.NodeName)-known-hosts-refresh" -MaxAttempts 3 -DoExecute:$DoExecute | Out-Null
    } else {
        if (-not [string]::IsNullOrWhiteSpace($RemoteHost)) {
            Invoke-PrimeLegacyKnownHostsOnNode -NodeConnection $NodeConnection -RemoteHost $RemoteHost -DoExecute:$DoExecute
        }
    }
}

function Invoke-BuddyBackupShellCommandWithRetry {
    param(
        $NodeConnection,
        [string]$Action,
        [string[]]$Arguments,
        [string]$Label,
        [int]$MaxAttempts = 10,
        [switch]$RetryTransientSshFailure,
        [switch]$RetryHostKeyFailure,
        [string]$RemoteHost = "",
        [switch]$DoExecute
    )

    $attempts = @()
    $result = $null

    for ($attempt = 1; $attempt -le $MaxAttempts; $attempt++) {
        $result = Invoke-BuddyBackupShellCommand -NodeConnection $NodeConnection -Action $Action -Arguments $Arguments -Label $Label -DoExecute:$DoExecute
        $attempts += $result

        $hostKeyFailure = $RetryHostKeyFailure -and (Test-IsHostKeyVerificationFailure -Result $result)
        if ($result.success -and -not $hostKeyFailure) {
            break
        }

        if ($DoExecute -and $hostKeyFailure -and $attempt -lt $MaxAttempts) {
            Invoke-BuddyBackupRefreshKnownHosts -NodeConnection $NodeConnection -RemoteHost $RemoteHost -DoExecute:$DoExecute
            Start-Sleep -Seconds 2
            continue
        }

        if (-not $DoExecute -or -not $RetryTransientSshFailure -or -not (Test-IsTransientSshFailure -Result $result) -or $attempt -ge $MaxAttempts) {
            break
        }

        Start-Sleep -Seconds 4
    }

    if ($result -and $attempts.Count -gt 1) {
        $result | Add-Member -NotePropertyName AttemptCount -NotePropertyValue $attempts.Count -Force
        $result | Add-Member -NotePropertyName Attempts -NotePropertyValue @($attempts) -Force
    }

    return $result
}

function Invoke-BuddyBackupPhpCommandWithRetry {
    param(
        $NodeConnection,
        [string]$Action,
        [string[]]$Arguments,
        [string]$Label,
        [int]$MaxAttempts = 10,
        [switch]$DoExecute
    )

    $attempts = @()
    $result = $null

    for ($attempt = 1; $attempt -le $MaxAttempts; $attempt++) {
        $result = Invoke-BuddyBackupPhpCommand -NodeConnection $NodeConnection -Action $Action -Arguments $Arguments -Label $Label -DoExecute:$DoExecute
        $attempts += $result
        if ($result.success) {
            break
        }

        if (-not $DoExecute -or -not (Test-IsTransientSshFailure -Result $result) -or $attempt -ge $MaxAttempts) {
            break
        }

        Start-Sleep -Seconds 4
    }

    if ($result -and $attempts.Count -gt 1) {
        $result | Add-Member -NotePropertyName AttemptCount -NotePropertyValue $attempts.Count -Force
        $result | Add-Member -NotePropertyName Attempts -NotePropertyValue @($attempts) -Force
    }

    return $result
}

function Invoke-BuddyBackupTestConnectionWithRetry {
    param(
        $NodeConnection,
        [string[]]$Arguments,
        [string]$Label,
        [int]$MaxAttempts = 12,
        [int]$RetryDelaySeconds = 4,
        [switch]$DoExecute
    )

    $attempts = @()
    $result = $null

    for ($attempt = 1; $attempt -le $MaxAttempts; $attempt++) {
        $result = Invoke-BuddyBackupShellCommand -NodeConnection $NodeConnection -Action "test_connection" -Arguments $Arguments -Label $Label -DoExecute:$DoExecute
        $attempts += $result

        $outputText = Get-ResultOutputText -Result $result
        $hasKnownHostsUpdateError = $outputText -match '(?i)hostfile_replace_entries|update_known_hosts: hostfile_replace_entries failed'
        $reportedSuccess = [int]$result.exitCode -eq 0 -and $outputText -match 'Success!' -and $outputText -notmatch '(?i)security validation failed' -and -not $hasKnownHostsUpdateError
        if ($reportedSuccess) {
            break
        }

        $hostKeyFailure = (Test-IsHostKeyVerificationFailure -Result $result) -or $hasKnownHostsUpdateError
        $shouldRetry = $DoExecute -and $attempt -lt $MaxAttempts -and ($hostKeyFailure -or (Test-IsTransientSshFailure -Result $result) -or (Test-IsRetryableTestConnectionFailure -Result $result))
        if (-not $shouldRetry) {
            break
        }

        if ($hostKeyFailure) {
            $remoteTargetHost = if ($Arguments -and $Arguments.Count -gt 0) { [string]$Arguments[0] } else { "" }
            Invoke-BuddyBackupRefreshKnownHosts -NodeConnection $NodeConnection -RemoteHost $remoteTargetHost -DoExecute:$DoExecute
            Start-Sleep -Seconds 2
        } else {
            Start-Sleep -Seconds $RetryDelaySeconds
        }
    }

    if ($result -and $attempts.Count -gt 1) {
        $result | Add-Member -NotePropertyName AttemptCount -NotePropertyValue $attempts.Count -Force
        $result | Add-Member -NotePropertyName Attempts -NotePropertyValue @($attempts) -Force
    }

    return $result
}

function Get-NodeBuddyBackupPublicKey {
    param(
        $NodeConnection,
        [switch]$DoExecute
    )

    $result = Invoke-NodeSshCommandWithRetry -NodeConnection $NodeConnection -Command "cat /boot/config/plugins/buddybackup/buddybackup_sender_key.pub" -Label "read-buddybackup-public-key" -DoExecute:$DoExecute
    Assert-CommandSucceeded -Result $result -FailureMessage "Failed to read BuddyBackup public key on node '$($NodeConnection.NodeName)'."
    return (($result.output | ForEach-Object { [string]$_ }) -join "`n").Trim()
}

function Get-FunctionalNodePlan {
    param(
        [string]$NodeName,
        $ZfsValues,
        $FunctionalCfg,
        [int]$Port
    )

    $canonicalNodeName = Get-TestLabCanonicalNodeName -NodeName $NodeName
    $testRoot = "$($ZfsValues.DatasetRoot)/$($FunctionalCfg.testDatasetRootName)"
    $receiveRoot = "$testRoot/$($FunctionalCfg.receiveDatasetName)"
    $aliasIp = if ($canonicalNodeName -eq "nodeA") { $FunctionalCfg.nodeAAliasIp } else { $FunctionalCfg.nodeBAliasIp }
    $localUid = if ($canonicalNodeName -eq "nodeA") { "aloc0001" } else { "bloc0001" }
    $remoteUid = if ($canonicalNodeName -eq "nodeA") { "arem0001" } else { "brem0001" }

    return [pscustomobject]@{
        nodeName              = $canonicalNodeName
        hostPort              = $Port
        aliasIp               = $aliasIp
        testRootDataset       = $testRoot
        receiveRootDataset    = $receiveRoot
        sourceDataset         = "$testRoot/$canonicalNodeName-source"
        sourceMountpoint      = "/mnt/buddybackup-functional/$canonicalNodeName-source"
        localBackupDataset    = "$testRoot/$canonicalNodeName-local-backup"
        localRestoreDataset   = "$testRoot/$canonicalNodeName-local-restore"
        remoteRestoreDataset  = "$testRoot/$canonicalNodeName-remote-restore"
        localBackupUid        = $localUid
        remoteBackupUid       = $remoteUid
    }
}

function Get-SnapshotSelection {
    param(
        [string]$JsonText,
        [string]$Uid,
        [string]$NodeName
    )

    if ([string]::IsNullOrWhiteSpace($JsonText)) {
        throw "Snapshot query for uid '$Uid' on node '$NodeName' returned no output."
    }

    $snapshotData = $JsonText | ConvertFrom-Json
    if ($snapshotData.status -ne "ok") {
        $message = if ($snapshotData.error) { [string]$snapshotData.error } else { "unknown snapshot query failure" }
        throw "Snapshot query for uid '$Uid' on node '$NodeName' failed: $message"
    }

    $datasetProperty = @($snapshotData.data.PSObject.Properties)[0]
    if (-not $datasetProperty) {
        throw "Snapshot query for uid '$Uid' on node '$NodeName' returned no datasets."
    }

    $snapshotEntries = @()
    $snapshotValue = $datasetProperty.Value
    if ($snapshotValue -is [System.Array]) {
        foreach ($snapshotItem in $snapshotValue) {
            $snapshotName = [string](Get-ObjectValue -Object $snapshotItem -Name "name")
            if ([string]::IsNullOrWhiteSpace($snapshotName)) {
                $snapshotName = [string](Get-ObjectValue -Object $snapshotItem -Name "Name")
            }

            $creationValue = 0L
            $rawCreationValue = Get-ObjectValue -Object $snapshotItem -Name "creation"
            if ($null -ne $rawCreationValue) {
                [long]::TryParse([string]$rawCreationValue, [ref]$creationValue) | Out-Null
            }

            if (-not [string]::IsNullOrWhiteSpace($snapshotName)) {
                $snapshotEntries += [pscustomobject]@{
                    name     = $snapshotName
                    creation = $creationValue
                }
            }
        }
    } else {
        foreach ($snapshotProperty in $snapshotValue.PSObject.Properties) {
            $creationValue = 0L
            $rawCreationValue = Get-ObjectValue -Object $snapshotProperty.Value -Name "creation"
            if ($null -ne $rawCreationValue) {
                [long]::TryParse([string]$rawCreationValue, [ref]$creationValue) | Out-Null
            }

            $snapshotEntries += [pscustomobject]@{
                name     = [string]$snapshotProperty.Name
                creation = $creationValue
            }
        }
    }

    if ($snapshotEntries.Count -eq 0) {
        throw "Snapshot query for uid '$Uid' on node '$NodeName' returned no snapshots."
    }

    $selectedSnapshot = $snapshotEntries | Sort-Object -Property @{ Expression = { [long]($_.creation) } } -Descending | Select-Object -First 1
    return [pscustomobject]@{
        dataset  = [string]$datasetProperty.Name
        snapshot = [string]$selectedSnapshot.name
        warning  = [string]$snapshotData.warning
    }
}

function Test-ConnectionOutput {
    param(
        [string[]]$Output,
        [string]$NodeName
    )

    $joined = ($Output -join [Environment]::NewLine)
    if ($joined -notmatch 'Success!') {
        throw "BuddyBackup test_connection did not report success on node '$NodeName'.`n$joined"
    }

    if ($joined -match 'security validation failed') {
        throw "BuddyBackup test_connection reported an SSH security validation problem on node '$NodeName'.`n$joined"
    }

    if ($joined -match '(?i)hostfile_replace_entries|update_known_hosts: hostfile_replace_entries failed') {
        throw "BuddyBackup test_connection failed due to known_hosts update restrictions on node '$NodeName'.`n$joined"
    }
}

function Test-BackupSendOutput {
    param(
        [string[]]$Output,
        [string]$Type,
        [string]$NodeName
    )

    $joined = ($Output -join [Environment]::NewLine)
    if ($joined -match 'Aborting backup\.' -or $joined -match 'Sending backup failed\.' -or $joined -match 'Local backup failed\.') {
        throw "BuddyBackup $Type send reported a failure on node '$NodeName'.`n$joined"
    }

    $successMarker = if ($Type -eq "remote") { "Successfully synced backup to buddy!" } else { "Successfully synced local backup!" }
    if ($joined -notmatch [regex]::Escape($successMarker)) {
        throw "BuddyBackup $Type send did not report success on node '$NodeName'.`n$joined"
    }
}

function New-FunctionalSetupScript {
    $script = @'
node_name="$1"
source_dataset="$2"
source_mountpoint="$3"
local_backup_dataset="$4"
local_restore_dataset="$5"
remote_restore_dataset="$6"
receive_root_dataset="$7"
inbound_remote_dataset="$8"
remote_uid="$9"
local_uid="${10}"
remote_host="${11}"
remote_destination_dataset="${12}"
allow_unencrypted="${13}"
peer_public_key="${14}"
host_gateway_ip="${15}"
peer_port="${16}"
peer_alias_ip="${17}"

set -euo pipefail

plugin_cfg="/boot/config/plugins/buddybackup/buddybackup.cfg"
backups_cfg="/boot/config/plugins/buddybackup/backups.cfg"
incoming_cfg="/boot/config/plugins/buddybackup/incoming.cfg"

set_ini_value() {
  local key="$1"
  local value="$2"
  local file="$3"
  local escaped
  escaped=$(printf '%s' "$value" | sed 's/[&|\\]/\\&/g')

  if grep -q "^${key}=" "$file" 2>/dev/null; then
    sed -i "s|^${key}=.*|${key}=\"${escaped}\"|" "$file"
  else
    printf '%s="%s"\n' "$key" "$value" >> "$file"
  fi
}

persist_peer_forward_rule() {
    local peer_alias_ip="$1"
    local host_gateway_ip="$2"
    local peer_port="$3"
    local go_file="/boot/config/go"
    local start_marker="# BuddyBackup testlab: persist peer forward ${peer_alias_ip} start"
    local end_marker="# BuddyBackup testlab: persist peer forward ${peer_alias_ip} end"
    local tmp_go

    if [ ! -f "$go_file" ]; then
        return 0
    fi

    tmp_go="${go_file}.buddybackup.tmp"
    awk -v start="$start_marker" -v end="$end_marker" '
        $0 == start { skip=1; next }
        $0 == end { skip=0; next }
        !skip { print }
    ' "$go_file" > "$tmp_go"

    cat >> "$tmp_go" <<EOF

$start_marker
if command -v iptables >/dev/null 2>&1; then
    iptables -t nat -C OUTPUT -d "${peer_alias_ip}/32" -p tcp --dport 22 -j DNAT --to-destination "${host_gateway_ip}:${peer_port}" >/dev/null 2>&1 || \
        iptables -t nat -A OUTPUT -d "${peer_alias_ip}/32" -p tcp --dport 22 -j DNAT --to-destination "${host_gateway_ip}:${peer_port}"
fi
$end_marker
EOF

    mv "$tmp_go" "$go_file"
}

prime_legacy_known_hosts() {
    local remote_host="$1"
    local known_hosts_file="/root/.ssh/known_hosts"
    local ssh_config_file="/root/.ssh/config"
    local flash_ssh_config="/boot/config/ssh/root/config"
    local begin_marker="# buddybackup start"
    local end_marker="# buddybackup end"
    local scanned_keys=""
    local attempt_keys=""
    local attempt
    local tmp_known_hosts=""
    local next_known_hosts=""

    mkdir -p /root/.ssh /boot/config/ssh/root
    chmod 700 /root/.ssh /boot/config/ssh/root 2>/dev/null || true
    touch "$known_hosts_file"
    chmod 600 "$known_hosts_file"

    for cfg in "$ssh_config_file" "$flash_ssh_config"; do
        touch "$cfg"
        chmod 600 "$cfg"
        if ! grep -q "UpdateHostKeys" "$cfg" 2>/dev/null; then
            cat >> "$cfg" <<'EOF'
Host *
    UpdateHostKeys no
EOF
        fi
    done

    for attempt in 1 2 3 4 5; do
        attempt_keys=$(ssh-keyscan -T 3 "$remote_host" 2>/dev/null || true)
        hashed_keys=$(ssh-keyscan -T 3 -H "$remote_host" 2>/dev/null || true)
        local combined_attempt=""
        if [[ -n "$attempt_keys" && -n "$hashed_keys" ]]; then
            combined_attempt="${attempt_keys}"$'\n'"${hashed_keys}"
        elif [[ -n "$attempt_keys" ]]; then
            combined_attempt="$attempt_keys"
        elif [[ -n "$hashed_keys" ]]; then
            combined_attempt="$hashed_keys"
        fi

        if [[ -n "$combined_attempt" ]]; then
            if [[ -n "$scanned_keys" ]]; then
                scanned_keys=$(printf '%s\n%s\n' "$scanned_keys" "$combined_attempt" | sed '/^[[:space:]]*$/d' | awk '
                    /^[[:space:]]*#/ { if (!comment[$0]++) print; next }
                    NF >= 3 { key = $2 " " $3; if (!material[key]++) print; next }
                    { print }
                ')
            else
                scanned_keys=$(printf '%s\n' "$combined_attempt" | sed '/^[[:space:]]*$/d')
            fi

            if printf '%s\n' "$scanned_keys" | grep -q 'ssh-ed25519' && \
               printf '%s\n' "$scanned_keys" | grep -q 'ecdsa-sha2-nistp256' && \
               printf '%s\n' "$scanned_keys" | grep -q 'ssh-rsa'; then
                break
            fi
        fi

        if [[ "$attempt" -lt 5 ]]; then
            sleep 1
        fi
    done

    if [[ -z "$scanned_keys" ]]; then
        return 0
    fi

    tmp_known_hosts="$(mktemp)"
    next_known_hosts="${tmp_known_hosts}.next"

    awk -v begin="$begin_marker" -v end="$end_marker" '
        $0 == begin { skip=1; next }
        $0 == end { skip=0; next }
        !skip { print }
    ' "$known_hosts_file" > "$tmp_known_hosts"

    {
        cat "$tmp_known_hosts"
        printf '%s\n' "$begin_marker"
        printf '%s\n' "$scanned_keys"
        printf '%s\n' "$end_marker"
    } > "$next_known_hosts"

    mv "$next_known_hosts" "$known_hosts_file"
    rm -f "$tmp_known_hosts"
}

ensure_dataset_absent() {
  local dataset="$1"
  if zfs list -H -o name "$dataset" >/dev/null 2>&1; then
    zfs destroy -r "$dataset"
  fi
}

if command -v modprobe >/dev/null 2>&1; then
  modprobe zfs >/dev/null 2>&1 || true
fi

if command -v udevadm >/dev/null 2>&1; then
  udevadm settle >/dev/null 2>&1 || true
fi

functional_root="${source_dataset%/*}"
mkdir -p /boot/config/plugins/buddybackup

if ! zfs list -H -o name "$functional_root" >/dev/null 2>&1; then
  zfs create -o mountpoint=none "$functional_root"
fi

if ! zfs list -H -o name "$receive_root_dataset" >/dev/null 2>&1; then
  zfs create -o mountpoint=none "$receive_root_dataset"
fi

for dataset in "$source_dataset" "$local_backup_dataset" "$local_restore_dataset" "$remote_restore_dataset" "$inbound_remote_dataset"; do
  ensure_dataset_absent "$dataset"
done

mkdir -p "$source_mountpoint"
zfs create -o mountpoint="$source_mountpoint" "$source_dataset"
printf 'node=%s\nstage=functional-smoke\n' "$node_name" > "$source_mountpoint/payload.txt"
sync || true

cat > "$incoming_cfg" <<EOF
[1ml3g4cy]
name="Buddy"
enable="yes"
destination_dataset="${receive_root_dataset}"
ssh_key="${peer_public_key}"
hourly="0"
daily="7"
weekly="4"
monthly="3"
yearly="0"
EOF

touch "$plugin_cfg"
set_ini_value "ReceiveBackups" "enable" "$plugin_cfg"
set_ini_value "DestinationPubSSHKey" "$peer_public_key" "$plugin_cfg"
set_ini_value "ReceiveDestinationDataset" "$receive_root_dataset" "$plugin_cfg"
set_ini_value "AllowUnencryptedRemoteBackups" "$allow_unencrypted" "$plugin_cfg"

cat > "$backups_cfg" <<EOF
[${remote_uid}]
enable="yes"
source_dataset="${source_dataset}"
recursive="no"
backup_cron="0 0 * * *"
type="remote"
destination_host="${remote_host}"
destination_dataset="${remote_destination_dataset}"

[${local_uid}]
enable="yes"
source_dataset="${source_dataset}"
recursive="no"
backup_cron="0 0 * * *"
type="local"
destination_host=""
destination_dataset="${local_backup_dataset}"
EOF

if [[ "$peer_port" != "22" ]]; then
  if ! command -v iptables >/dev/null 2>&1; then
    echo "iptables is unavailable, cannot map ${peer_alias_ip}:22 to ${host_gateway_ip}:${peer_port}" >&2
    exit 1
  fi

  iptables -t nat -C OUTPUT -d "${peer_alias_ip}/32" -p tcp --dport 22 -j DNAT --to-destination "${host_gateway_ip}:${peer_port}" >/dev/null 2>&1 || \
    iptables -t nat -A OUTPUT -d "${peer_alias_ip}/32" -p tcp --dport 22 -j DNAT --to-destination "${host_gateway_ip}:${peer_port}"
    persist_peer_forward_rule "$peer_alias_ip" "$host_gateway_ip" "$peer_port"
fi

/usr/local/emhttp/plugins/buddybackup/scripts/rc.buddybackup.php update

prime_legacy_known_hosts "$remote_host"

echo "configured_node=${node_name}"
echo "configured_remote_host=${remote_host}"
echo "configured_receive_root=${receive_root_dataset}"
'@
    return $script
}

# ---------------- Main Scenario Execution ----------------

$resolvedLabConfig = Resolve-TestLabPath $LabConfig
if (-not (Test-Path -LiteralPath $resolvedLabConfig)) {
    throw "Missing lab config: $resolvedLabConfig"
}

$lab = Get-TestLabJson -Path $resolvedLabConfig
$zfsValues = Get-SetupZfsValues -Lab $lab
$functionalCfg = Get-FunctionalTestConfig -Lab $lab
$senderConnection = Get-NodeConnection -Lab $lab -NodeName "nodeA"
$receiverConnection = Get-NodeConnection -Lab $lab -NodeName "nodeB"
$senderPlan = Get-FunctionalNodePlan -NodeName "nodeA" -ZfsValues $zfsValues -FunctionalCfg $functionalCfg -Port $senderConnection.Port
$receiverPlan = Get-FunctionalNodePlan -NodeName "nodeB" -ZfsValues $zfsValues -FunctionalCfg $functionalCfg -Port $receiverConnection.Port

$senderPlan | Add-Member -NotePropertyName inboundRemoteDataset -NotePropertyValue "$($senderPlan.receiveRootDataset)/from-nodeB"
$senderPlan | Add-Member -NotePropertyName remoteDestinationDataset -NotePropertyValue "$($receiverPlan.receiveRootDataset)/from-nodeA"
$senderPlan | Add-Member -NotePropertyName remoteHost -NotePropertyValue $(if ($receiverConnection.Port -eq 22) { $receiverConnection.Host } else { $receiverPlan.aliasIp })
$senderPlan | Add-Member -NotePropertyName peerAliasIp -NotePropertyValue $receiverPlan.aliasIp

$receiverPlan | Add-Member -NotePropertyName inboundRemoteDataset -NotePropertyValue "$($receiverPlan.receiveRootDataset)/from-nodeA"
$receiverPlan | Add-Member -NotePropertyName remoteDestinationDataset -NotePropertyValue "$($senderPlan.receiveRootDataset)/from-nodeB"
$receiverPlan | Add-Member -NotePropertyName remoteHost -NotePropertyValue $(if ($senderConnection.Port -eq 22) { $senderConnection.Host } else { $senderPlan.aliasIp })
$receiverPlan | Add-Member -NotePropertyName peerAliasIp -NotePropertyValue $senderPlan.aliasIp

$reportsDir = if (-not [string]::IsNullOrWhiteSpace($OutputDir)) {
    Resolve-TestLabPath $OutputDir
} elseif ($lab.logsRoot) {
    Resolve-TestLabPath ([string]$lab.logsRoot)
} else {
    Resolve-TestLabPath ".testlab/logs"
}

$runId = (Get-Date).ToString("yyyyMMdd-HHmmss")
if ([System.IO.Path]::GetExtension($reportsDir) -eq '.json') {
    $reportPath = $reportsDir
    $reportsDir = [System.IO.Path]::GetDirectoryName($reportPath)
} else {
    $reportPath = Join-Path $reportsDir ("functional-smoke-{0}.json" -f $runId)
}
Ensure-TestLabDir $reportsDir

$snapshotRunId = $runId.Replace("-", "_")
$senderPlan | Add-Member -NotePropertyName sourceSnapshot -NotePropertyValue "$($senderPlan.sourceDataset)@functional_smoke_${snapshotRunId}_nodeA"
$receiverPlan | Add-Member -NotePropertyName sourceSnapshot -NotePropertyValue "$($receiverPlan.sourceDataset)@functional_smoke_${snapshotRunId}_nodeB"

$report = [ordered]@{
    runId       = $runId
    executeMode = [bool]$Execute
    success     = $false
    error       = $null
    reportPath  = $reportPath
    nodes       = @(
        [pscustomobject]@{ node = "nodeA"; sshPort = $senderConnection.Port; remoteHost = $senderPlan.remoteHost; webUi = "http://127.0.0.1:8080" },
        [pscustomobject]@{ node = "nodeB"; sshPort = $receiverConnection.Port; remoteHost = $receiverPlan.remoteHost; webUi = "http://127.0.0.1:8081" }
    )
    actions     = @()
}

try {
    Write-Host "[testlab] Functional smoke starting: nodeA localhost:$($senderConnection.Port), nodeB localhost:$($receiverConnection.Port)"
    Write-Host "[testlab] Functional smoke: reading BuddyBackup public keys"
    $senderPublicKey = Get-NodeBuddyBackupPublicKey -NodeConnection $senderConnection -DoExecute:$Execute
    $receiverPublicKey = Get-NodeBuddyBackupPublicKey -NodeConnection $receiverConnection -DoExecute:$Execute

    $setupScript = New-FunctionalSetupScript

    Write-Host "[testlab] Functional smoke: applying environment setup on nodeA and nodeB"
    $senderSetup = Invoke-NodeBashScriptWithRetry -NodeConnection $senderConnection -ScriptContent $setupScript -Arguments @(
        "nodeA",
        $senderPlan.sourceDataset,
        $senderPlan.sourceMountpoint,
        $senderPlan.localBackupDataset,
        $senderPlan.localRestoreDataset,
        $senderPlan.remoteRestoreDataset,
        $senderPlan.receiveRootDataset,
        $senderPlan.inboundRemoteDataset,
        $senderPlan.remoteBackupUid,
        $senderPlan.localBackupUid,
        $senderPlan.remoteHost,
        $senderPlan.remoteDestinationDataset,
        $functionalCfg.allowUnencryptedRemoteBackups,
        $receiverPublicKey,
        $functionalCfg.hostGatewayIp,
        [string]$receiverConnection.Port,
        $senderPlan.peerAliasIp
    ) -Label "functional-setup" -MaxAttempts 6 -RetryDelaySeconds 8 -DoExecute:$Execute
    Add-ReportAction -Report $report -Result $senderSetup
    Assert-CommandSucceeded -Result $senderSetup -FailureMessage "Functional setup failed on nodeA."

    $receiverSetup = Invoke-NodeBashScriptWithRetry -NodeConnection $receiverConnection -ScriptContent $setupScript -Arguments @(
        "nodeB",
        $receiverPlan.sourceDataset,
        $receiverPlan.sourceMountpoint,
        $receiverPlan.localBackupDataset,
        $receiverPlan.localRestoreDataset,
        $receiverPlan.remoteRestoreDataset,
        $receiverPlan.receiveRootDataset,
        $receiverPlan.inboundRemoteDataset,
        $receiverPlan.remoteBackupUid,
        $receiverPlan.localBackupUid,
        $receiverPlan.remoteHost,
        $receiverPlan.remoteDestinationDataset,
        $functionalCfg.allowUnencryptedRemoteBackups,
        $senderPublicKey,
        $functionalCfg.hostGatewayIp,
        [string]$senderConnection.Port,
        $receiverPlan.peerAliasIp
    ) -Label "functional-setup" -MaxAttempts 6 -RetryDelaySeconds 8 -DoExecute:$Execute
    Add-ReportAction -Report $report -Result $receiverSetup
    Assert-CommandSucceeded -Result $receiverSetup -FailureMessage "Functional setup failed on nodeB."

    Write-Host "[testlab] Functional smoke: refreshing managed BuddyBackup host keys"
    foreach ($refresh in @(
        @{ Connection = $senderConnection; NodeName = "nodeA"; RemoteHost = $senderPlan.remoteHost },
        @{ Connection = $receiverConnection; NodeName = "nodeB"; RemoteHost = $receiverPlan.remoteHost }
    )) {
        $probeManagedCmd = "grep -q 'ssh_known_hosts_path' /usr/local/emhttp/plugins/buddybackup/scripts/rc.buddybackup && echo 'managed' || echo 'legacy'"
        $probeManagedResult = Invoke-NodeSshCommandWithRetry -NodeConnection $refresh.Connection -Command $probeManagedCmd -Label "$($refresh.NodeName)-probe-managed-known-hosts" -DoExecute:$Execute
        Add-ReportAction -Report $report -Result $probeManagedResult

        $isManaged = $true
        if ($Execute -and $probeManagedResult.success) {
            $outputStr = ($probeManagedResult.output -join "`n").Trim()
            if ($outputStr -eq "legacy") {
                $isManaged = $false
            }
        }

        if ($isManaged) {
            $clearKnownHostsResult = Invoke-BuddyBackupShellCommandWithRetry -NodeConnection $refresh.Connection -Action "clear_known_hosts" -Label "$($refresh.NodeName)-clear-known-hosts" -RetryTransientSshFailure -DoExecute:$Execute
            Add-ReportAction -Report $report -Result $clearKnownHostsResult
            Assert-CommandSucceeded -Result $clearKnownHostsResult -FailureMessage "Failed to clear BuddyBackup managed known_hosts on node '$($refresh.Connection.NodeName)'."

            $refreshUpdateResult = Invoke-BuddyBackupPhpCommandWithRetry -NodeConnection $refresh.Connection -Action "update" -Label "$($refresh.NodeName)-refresh-config" -DoExecute:$Execute
            Add-ReportAction -Report $report -Result $refreshUpdateResult
            Assert-CommandSucceeded -Result $refreshUpdateResult -FailureMessage "Failed to rebuild BuddyBackup managed known_hosts on node '$($refresh.Connection.NodeName)'."
        } else {
            Write-Host "[testlab] $($refresh.NodeName) is running a legacy release without managed known_hosts; re-priming legacy known_hosts."
            Invoke-PrimeLegacyKnownHostsOnNode -NodeConnection $refresh.Connection -RemoteHost ([string]$refresh.RemoteHost) -DoExecute:$Execute
        }
    }

    Write-Host "[testlab] Functional smoke: validating BuddyBackup connectivity"
    foreach ($pair in @(
        @{ Connection = $senderConnection; Plan = $senderPlan; Label = "nodeA-test-connection" },
        @{ Connection = $receiverConnection; Plan = $receiverPlan; Label = "nodeB-test-connection" }
    )) {
        $connectionResult = Invoke-BuddyBackupTestConnectionWithRetry -NodeConnection $pair.Connection -Arguments @($pair.Plan.remoteHost, $pair.Plan.remoteDestinationDataset) -Label $pair.Label -DoExecute:$Execute
        Add-ReportAction -Report $report -Result $connectionResult
        Assert-CommandSucceeded -Result $connectionResult -FailureMessage "BuddyBackup test_connection failed on node '$($pair.Connection.NodeName)'."
        if ($Execute) {
            Test-ConnectionOutput -Output $connectionResult.output -NodeName $pair.Connection.NodeName
        }
    }

    Write-Host "[testlab] Functional smoke: creating source snapshots"
    foreach ($snapshot in @(
        @{ Connection = $senderConnection; Snapshot = $senderPlan.sourceSnapshot; Label = "nodeA-create-source-snapshot" },
        @{ Connection = $receiverConnection; Snapshot = $receiverPlan.sourceSnapshot; Label = "nodeB-create-source-snapshot" }
    )) {
        $snapshotResult = Invoke-NodeSshCommandWithRetry -NodeConnection $snapshot.Connection -Command ("zfs snapshot {0}" -f (Convert-ToShellSingleQuoted -Value $snapshot.Snapshot)) -Label $snapshot.Label -DoExecute:$Execute
        Add-ReportAction -Report $report -Result $snapshotResult
        Assert-CommandSucceeded -Result $snapshotResult -FailureMessage "Failed to create source snapshot '$($snapshot.Snapshot)' on node '$($snapshot.Connection.NodeName)'."
    }

    Write-Host "[testlab] Functional smoke: sending remote and local backups"
    $nodeSupportsTypedSendBackup = @{}
    foreach ($pair in @(
        @{ Connection = $senderConnection; Type = "remote"; SourceDataset = $senderPlan.sourceDataset; Recursive = "no"; DestinationHost = $senderPlan.remoteHost; DestinationDataset = $senderPlan.remoteDestinationDataset; Uid = $senderPlan.remoteBackupUid; Label = "nodeA-remote-send"; Action = "send_backup" },
        @{ Connection = $senderConnection; Type = "local"; SourceDataset = $senderPlan.sourceDataset; Recursive = "no"; DestinationHost = ""; DestinationDataset = $senderPlan.localBackupDataset; Uid = $senderPlan.localBackupUid; Label = "nodeA-local-send"; Action = "send_local_backup" },
        @{ Connection = $receiverConnection; Type = "remote"; SourceDataset = $receiverPlan.sourceDataset; Recursive = "no"; DestinationHost = $receiverPlan.remoteHost; DestinationDataset = $receiverPlan.remoteDestinationDataset; Uid = $receiverPlan.remoteBackupUid; Label = "nodeB-remote-send"; Action = "send_backup" },
        @{ Connection = $receiverConnection; Type = "local"; SourceDataset = $receiverPlan.sourceDataset; Recursive = "no"; DestinationHost = ""; DestinationDataset = $receiverPlan.localBackupDataset; Uid = $receiverPlan.localBackupUid; Label = "nodeB-local-send"; Action = "send_local_backup" }
    )) {
        $sendArgs = if ($pair.Type -eq "remote") {
            $nodeName = $pair.Connection.NodeName
            if (-not $nodeSupportsTypedSendBackup.ContainsKey($nodeName)) {
                $probeCmd = "sed -n '/^send_backup()/,/^}/p' /usr/local/emhttp/plugins/buddybackup/scripts/rc.buddybackup | grep -q 'local type=' && echo 'typed' || echo 'legacy'"
                $probeResult = Invoke-NodeSshCommandWithRetry -NodeConnection $pair.Connection -Command $probeCmd -Label "$nodeName-probe-send-signature" -DoExecute:$Execute
                Add-ReportAction -Report $report -Result $probeResult
                $isTyped = $true
                if ($Execute -and $probeResult.success) {
                    $outputStr = ($probeResult.output -join "`n").Trim()
                    if ($outputStr -eq "legacy") {
                        $isTyped = $false
                    }
                }
                $nodeSupportsTypedSendBackup[$nodeName] = $isTyped
            }

            if ($nodeSupportsTypedSendBackup[$nodeName]) {
                @($pair.Type, $pair.SourceDataset, $pair.Recursive, $pair.DestinationHost, $pair.DestinationDataset, $pair.Uid)
            } else {
                @($pair.SourceDataset, $pair.Recursive, $pair.DestinationHost, $pair.DestinationDataset, $pair.Uid)
            }
        } else {
            @($pair.SourceDataset, $pair.Recursive, $pair.DestinationDataset, $pair.Uid)
        }
        $sendResult = Invoke-BuddyBackupShellCommandWithRetry -NodeConnection $pair.Connection -Action $pair.Action -Arguments $sendArgs -Label $pair.Label -RetryTransientSshFailure:($pair.Type -eq "remote") -RetryHostKeyFailure:($pair.Type -eq "remote") -DoExecute:$Execute
        Add-ReportAction -Report $report -Result $sendResult
        Assert-CommandSucceeded -Result $sendResult -FailureMessage "BuddyBackup $($pair.Action) failed for uid '$($pair.Uid)' on node '$($pair.Connection.NodeName)'."
        if ($Execute) {
            Test-BackupSendOutput -Output $sendResult.output -Type $pair.Type -NodeName $pair.Connection.NodeName
        }
    }

    Write-Host "[testlab] Functional smoke: verifying backup datasets"
    foreach ($check in @(
        @{ Connection = $senderConnection; Dataset = $senderPlan.localBackupDataset; Label = "nodeA-local-backup-dataset-check" },
        @{ Connection = $senderConnection; Dataset = $senderPlan.inboundRemoteDataset; Label = "nodeA-remote-backup-dataset-check" },
        @{ Connection = $receiverConnection; Dataset = $receiverPlan.localBackupDataset; Label = "nodeB-local-backup-dataset-check" },
        @{ Connection = $receiverConnection; Dataset = $receiverPlan.inboundRemoteDataset; Label = "nodeB-remote-backup-dataset-check" }
    )) {
        $datasetCheck = Invoke-NodeSshCommandWithRetry -NodeConnection $check.Connection -Command ("zfs list -H -o name {0}" -f (Convert-ToShellSingleQuoted -Value $check.Dataset)) -Label $check.Label -DoExecute:$Execute
        Add-ReportAction -Report $report -Result $datasetCheck
        Assert-CommandSucceeded -Result $datasetCheck -FailureMessage "Expected dataset '$($check.Dataset)' was not found on node '$($check.Connection.NodeName)'."
    }

    $snapshotSelections = @{}
    Write-Host "[testlab] Functional smoke: listing available snapshots"
    foreach ($query in @(
        @{ Connection = $senderConnection; Uid = $senderPlan.remoteBackupUid; Type = "remote"; DestinationHost = $senderPlan.remoteHost; DestinationDataset = $senderPlan.remoteDestinationDataset; Key = "nodeA-remote-snapshots" },
        @{ Connection = $senderConnection; Uid = $senderPlan.localBackupUid; Type = "local"; DestinationHost = ""; DestinationDataset = $senderPlan.localBackupDataset; Key = "nodeA-local-snapshots" },
        @{ Connection = $receiverConnection; Uid = $receiverPlan.remoteBackupUid; Type = "remote"; DestinationHost = $receiverPlan.remoteHost; DestinationDataset = $receiverPlan.remoteDestinationDataset; Key = "nodeB-remote-snapshots" },
        @{ Connection = $receiverConnection; Uid = $receiverPlan.localBackupUid; Type = "local"; DestinationHost = ""; DestinationDataset = $receiverPlan.localBackupDataset; Key = "nodeB-local-snapshots" }
    )) {
        $snapshotArgs = if ($query.Type -eq "remote") { @($query.Type, $query.DestinationHost, $query.DestinationDataset) } else { @($query.Type, $query.DestinationDataset) }
        $snapshotResult = Invoke-BuddyBackupShellCommandWithRetry -NodeConnection $query.Connection -Action "get_available_snapshots" -Arguments $snapshotArgs -Label $query.Key -RetryTransientSshFailure:($query.Type -eq "remote") -RetryHostKeyFailure:($query.Type -eq "remote") -RemoteHost:($query.DestinationHost) -DoExecute:$Execute
        Add-ReportAction -Report $report -Result $snapshotResult
        Assert-CommandSucceeded -Result $snapshotResult -FailureMessage "Snapshot query failed for uid '$($query.Uid)' on node '$($query.Connection.NodeName)'."
        if ($Execute) {
            $snapshotSelections[$query.Key] = Get-SnapshotSelection -JsonText (($snapshotResult.output -join "`n").Trim()) -Uid $query.Uid -NodeName $query.Connection.NodeName
        }
    }

    Write-Host "[testlab] Functional smoke: restoring selected snapshots"
    foreach ($restore in @(
        @{ Connection = $senderConnection; Type = "remote"; DestinationHost = $senderPlan.remoteHost; Selection = $snapshotSelections["nodeA-remote-snapshots"]; Destination = $senderPlan.remoteRestoreDataset; Label = "nodeA-remote-restore" },
        @{ Connection = $senderConnection; Type = "local"; DestinationHost = ""; Selection = $snapshotSelections["nodeA-local-snapshots"]; Destination = $senderPlan.localRestoreDataset; Label = "nodeA-local-restore" },
        @{ Connection = $receiverConnection; Type = "remote"; DestinationHost = $receiverPlan.remoteHost; Selection = $snapshotSelections["nodeB-remote-snapshots"]; Destination = $receiverPlan.remoteRestoreDataset; Label = "nodeB-remote-restore" },
        @{ Connection = $receiverConnection; Type = "local"; DestinationHost = ""; Selection = $snapshotSelections["nodeB-local-snapshots"]; Destination = $receiverPlan.localRestoreDataset; Label = "nodeB-local-restore" }
    )) {
        $restoreArgs = if ($restore.Type -eq "remote") {
            @($restore.Type, $restore.DestinationHost, "selected", $restore.Selection.snapshot, $restore.Selection.dataset, $restore.Destination)
        } else {
            @($restore.Type, "selected", $restore.Selection.snapshot, $restore.Selection.dataset, $restore.Destination)
        }
        $restoreResult = Invoke-BuddyBackupShellCommandWithRetry -NodeConnection $restore.Connection -Action "restore_snapshot" -Arguments $restoreArgs -Label $restore.Label -RetryTransientSshFailure:($restore.Type -eq "remote") -RetryHostKeyFailure:($restore.Type -eq "remote") -RemoteHost:($restore.DestinationHost) -DoExecute:$Execute
        Add-ReportAction -Report $report -Result $restoreResult
        Assert-CommandSucceeded -Result $restoreResult -FailureMessage "Restore failed for label '$($restore.Label)' on node '$($restore.Connection.NodeName)'."
    }

    Write-Host "[testlab] Functional smoke: verifying restored datasets"
    foreach ($check in @(
        @{ Connection = $senderConnection; Dataset = $senderPlan.localRestoreDataset; Label = "nodeA-local-restore-dataset-check" },
        @{ Connection = $senderConnection; Dataset = $senderPlan.remoteRestoreDataset; Label = "nodeA-remote-restore-dataset-check" },
        @{ Connection = $receiverConnection; Dataset = $receiverPlan.localRestoreDataset; Label = "nodeB-local-restore-dataset-check" },
        @{ Connection = $receiverConnection; Dataset = $receiverPlan.remoteRestoreDataset; Label = "nodeB-remote-restore-dataset-check" }
    )) {
        $datasetCheck = Invoke-NodeSshCommandWithRetry -NodeConnection $check.Connection -Command ("zfs list -H -o name {0}" -f (Convert-ToShellSingleQuoted -Value $check.Dataset)) -Label $check.Label -DoExecute:$Execute
        Add-ReportAction -Report $report -Result $datasetCheck
        Assert-CommandSucceeded -Result $datasetCheck -FailureMessage "Expected restore dataset '$($check.Dataset)' was not found on node '$($check.Connection.NodeName)'."
    }

    Write-Host "[testlab] Functional smoke: verifying SHA256 payload integrity on restored datasets"
    foreach ($verify in @(
        @{ Connection = $senderConnection; SourceMount = $senderPlan.sourceMountpoint; RestoreDataset = $senderPlan.localRestoreDataset; Label = "nodeA-verify-sha256-local-restore" },
        @{ Connection = $receiverConnection; SourceMount = $receiverPlan.sourceMountpoint; RestoreDataset = $receiverPlan.localRestoreDataset; Label = "nodeB-verify-sha256-local-restore" }
    )) {
        $shaScript = @'
source_mount="$1"
restore_dataset="$2"

set -euo pipefail
src_file="${source_mount}/payload.txt"
if [ ! -f "$src_file" ]; then
    echo "ERROR: source payload file not found: $src_file" >&2
    exit 1
fi
src_sha=$(sha256sum "$src_file" | awk '{print $1}')

restore_mp=$(zfs get -H -o value mountpoint "$restore_dataset" 2>/dev/null || true)
if [ -z "$restore_mp" ] || [ "$restore_mp" = "none" ] || [ "$restore_mp" = "legacy" ]; then
    restore_mp="/mnt/${restore_dataset}"
    mkdir -p "$restore_mp"
    zfs set mountpoint="$restore_mp" "$restore_dataset" 2>/dev/null || true
fi
zfs mount "$restore_dataset" 2>/dev/null || true

dst_file="${restore_mp}/payload.txt"
if [ ! -f "$dst_file" ]; then
    echo "ERROR: restored payload file not found: $dst_file" >&2
    exit 1
fi
dst_sha=$(sha256sum "$dst_file" | awk '{print $1}')

if [ "$src_sha" != "$dst_sha" ]; then
    echo "ERROR: SHA256 mismatch! src=$src_sha dst=$dst_sha" >&2
    exit 1
fi

echo "SHA256_VERIFIED: $src_sha"
'@
        $shaResult = Invoke-NodeBashScript -NodeConnection $verify.Connection -ScriptContent $shaScript -Arguments @($verify.SourceMount, $verify.RestoreDataset) -Label $verify.Label -DoExecute:$Execute
        Add-ReportAction -Report $report -Result $shaResult
        Assert-CommandSucceeded -Result $shaResult -FailureMessage "SHA256 payload verification failed on $($verify.Connection.NodeName)."
    }

    # Check if sender or receiver supports backup hooks
    $hookTargetConnection = $null
    $hookTargetPlan = $null
    $hookTargetNode = ""

    foreach ($candidate in @(
        @{ Connection = $senderConnection; Plan = $senderPlan; NodeName = "nodeA" },
        @{ Connection = $receiverConnection; Plan = $receiverPlan; NodeName = "nodeB" }
    )) {
        $probeHooksCmd = "grep -q 'run_hook' /usr/local/emhttp/plugins/buddybackup/scripts/rc.buddybackup && echo 'supported' || echo 'legacy'"
        $probeHooksResult = Invoke-NodeSshCommandWithRetry -NodeConnection $candidate.Connection -Command $probeHooksCmd -Label "$($candidate.NodeName)-probe-hooks-support" -DoExecute:$Execute
        Add-ReportAction -Report $report -Result $probeHooksResult

        $supportsHooks = $true
        if ($Execute -and $probeHooksResult.success) {
            $outputStr = ($probeHooksResult.output -join "`n").Trim()
            if ($outputStr -eq "legacy") {
                $supportsHooks = $false
            }
        }

        if ($supportsHooks) {
            $hookTargetConnection = $candidate.Connection
            $hookTargetPlan = $candidate.Plan
            $hookTargetNode = $candidate.NodeName
            break
        }
    }

    if ($null -ne $hookTargetConnection) {
        Write-Host "[testlab] Functional smoke: verifying backup hooks lifecycle and failure modes on $hookTargetNode"
        $hooksDir = "/boot/config/plugins/buddybackup/hooks"
        $hookLog = "/tmp/buddybackup-hooks-test.log"
        $testPreHook = "$hooksDir/test-pre.sh"
        $testPostHook = "$hooksDir/test-post.sh"
        $testAbortHook = "$hooksDir/test-abort.sh"

        $setupHooksCmd = @"
mkdir -p '$hooksDir'
cat > '$testPreHook' <<'EOF'
#!/bin/bash
echo "pre_ran uid=`${BB_TASK_UID:-}" >> '$hookLog'
exit 0
EOF
cat > '$testPostHook' <<'EOF'
#!/bin/bash
echo "post_ran status=`${BB_STATUS:-} exit=`${BB_EXIT_CODE:-} uid=`${BB_TASK_UID:-} type=`${BB_TASK_TYPE:-}" >> '$hookLog'
exit 0
EOF
cat > '$testAbortHook' <<'EOF'
#!/bin/bash
echo "abort_pre_ran" >> '$hookLog'
exit 42
EOF
chmod 755 '$testPreHook' '$testPostHook' '$testAbortHook'
rm -f '$hookLog'
"@

        $setupHooksResult = Invoke-NodeSshCommandWithRetry -NodeConnection $hookTargetConnection -Command $setupHooksCmd -Label "$hookTargetNode-setup-test-hooks" -DoExecute:$Execute
        Add-ReportAction -Report $report -Result $setupHooksResult
        Assert-CommandSucceeded -Result $setupHooksResult -FailureMessage "Failed to stage test hooks on $hookTargetNode."

        try {
            # 1. Success lifecycle: pre-hook runs, syncoid runs, post-hook receives success context
            $hookSuccessArgs = @($hookTargetPlan.sourceDataset, "no", $hookTargetPlan.localBackupDataset, $hookTargetPlan.localBackupUid, "no", $testPreHook, $testPostHook, "30", "abort")
            $hookSuccessResult = Invoke-BuddyBackupShellCommandWithRetry -NodeConnection $hookTargetConnection -Action "send_local_backup" -Arguments $hookSuccessArgs -Label "$hookTargetNode-hook-success-test" -RetryTransientSshFailure -DoExecute:$Execute
            Add-ReportAction -Report $report -Result $hookSuccessResult
            Assert-CommandSucceeded -Result $hookSuccessResult -FailureMessage "BuddyBackup send_local_backup with hooks failed on $hookTargetNode."

            if ($Execute) {
                $readLogResult = Invoke-NodeSshCommandWithRetry -NodeConnection $hookTargetConnection -Command "cat '$hookLog' && rm -f '$hookLog'" -Label "$hookTargetNode-check-hook-success-log" -DoExecute:$Execute
                Add-ReportAction -Report $report -Result $readLogResult
                $logText = Get-ResultOutputText -Result $readLogResult
                if ($logText -notmatch 'pre_ran' -or $logText -notmatch 'post_ran status=success exit=0') {
                    throw "Hook success test failed: unexpected hook log contents on $hookTargetNode.`n$logText"
                }
            }

            # 2. Abort failure mode: failing pre-hook aborts syncoid, post-hook receives failed status and pre-hook exit code
            $hookAbortArgs = @($hookTargetPlan.sourceDataset, "no", $hookTargetPlan.localBackupDataset, $hookTargetPlan.localBackupUid, "no", $testAbortHook, $testPostHook, "30", "abort")
            $hookAbortResult = Invoke-BuddyBackupShellCommandWithRetry -NodeConnection $hookTargetConnection -Action "send_local_backup" -Arguments $hookAbortArgs -Label "$hookTargetNode-hook-abort-test" -RetryTransientSshFailure -DoExecute:$Execute
            Add-ReportAction -Report $report -Result $hookAbortResult

            if ($Execute) {
                if ($hookAbortResult.exitCode -eq 0) {
                    throw "Hook abort test failed: send_local_backup unexpectedly succeeded when pre-hook exited 42 with abort mode."
                }
                $readLogResult = Invoke-NodeSshCommandWithRetry -NodeConnection $hookTargetConnection -Command "cat '$hookLog' && rm -f '$hookLog'" -Label "$hookTargetNode-check-hook-abort-log" -DoExecute:$Execute
                Add-ReportAction -Report $report -Result $readLogResult
                $logText = Get-ResultOutputText -Result $readLogResult
                if ($logText -notmatch 'abort_pre_ran' -or $logText -notmatch 'post_ran status=failed exit=42') {
                    throw "Hook abort test failed: unexpected hook log contents on $hookTargetNode.`n$logText"
                }
            }

            # 3. Warn failure mode: failing pre-hook logs warning, syncoid proceeds, post-hook receives success context
            $hookWarnArgs = @($hookTargetPlan.sourceDataset, "no", $hookTargetPlan.localBackupDataset, $hookTargetPlan.localBackupUid, "no", $testAbortHook, $testPostHook, "30", "warn")
            $hookWarnResult = Invoke-BuddyBackupShellCommandWithRetry -NodeConnection $hookTargetConnection -Action "send_local_backup" -Arguments $hookWarnArgs -Label "$hookTargetNode-hook-warn-test" -RetryTransientSshFailure -DoExecute:$Execute
            Add-ReportAction -Report $report -Result $hookWarnResult
            Assert-CommandSucceeded -Result $hookWarnResult -FailureMessage "BuddyBackup send_local_backup in warn mode failed on $hookTargetNode."

            if ($Execute) {
                $readLogResult = Invoke-NodeSshCommandWithRetry -NodeConnection $hookTargetConnection -Command "cat '$hookLog' && rm -f '$hookLog'" -Label "$hookTargetNode-check-hook-warn-log" -DoExecute:$Execute
                Add-ReportAction -Report $report -Result $readLogResult
                $logText = Get-ResultOutputText -Result $readLogResult
                if ($logText -notmatch 'abort_pre_ran' -or $logText -notmatch 'post_ran status=success exit=0') {
                    throw "Hook warn test failed: unexpected hook log contents on $hookTargetNode.`n$logText"
                }
            }
        } finally {
            $cleanupHooksResult = Invoke-NodeSshCommandWithRetry -NodeConnection $hookTargetConnection -Command "rm -f '$testPreHook' '$testPostHook' '$testAbortHook' '$hookLog'" -Label "$hookTargetNode-cleanup-test-hooks" -DoExecute:$Execute
            Add-ReportAction -Report $report -Result $cleanupHooksResult
        }
    } else {
        Write-Host "[testlab] Skipping backup hooks test: neither node supports hooks in this cell."
    }

    # 4. Snapshot trigger decoupling & background detachment test
    $nodeSupportsTriggerRunner = $false
    if ($null -ne $hookTargetConnection) {
        $triggerProbeCmd = "grep -q 'run_snapshot_post_hook_and_trigger' /usr/local/emhttp/plugins/buddybackup/scripts/rc.buddybackup && echo 'supported' || echo 'unsupported'"
        $triggerProbeResult = Invoke-NodeSshCommandWithRetry -NodeConnection $hookTargetConnection -Command $triggerProbeCmd -Label "$hookTargetNode-probe-trigger-runner" -DoExecute:$Execute
        Add-ReportAction -Report $report -Result $triggerProbeResult
        if ($Execute -and $triggerProbeResult.success) {
            $probeStr = ($triggerProbeResult.output -join "`n").Trim()
            if ($probeStr -eq "supported") {
                $nodeSupportsTriggerRunner = $true
            }
        }
    }

    if ($nodeSupportsTriggerRunner) {
        Write-Host "[testlab] Functional smoke: verifying snapshot trigger decoupling and background detachment on $hookTargetNode"
        $triggerThawHook = "/boot/config/plugins/buddybackup/hooks/test-trigger-thaw.sh"
        $triggerEventLog = "/tmp/buddybackup-trigger-test.log"
        $setupTriggerCmd = @"
cat > '$triggerThawHook' <<'EOF'
#!/bin/bash
echo "thaw_executed" >> '$triggerEventLog'
exit 0
EOF
chmod 755 '$triggerThawHook'
rm -f '$triggerEventLog'
rm -f '/var/run/buddybackup/$($hookTargetPlan.localBackupUid)' '/tmp/buddybackup-$($hookTargetPlan.localBackupUid)' '/var/lock/buddybackup-$($hookTargetPlan.localBackupUid)'
"@
        $setupTriggerResult = Invoke-NodeSshCommandWithRetry -NodeConnection $hookTargetConnection -Command $setupTriggerCmd -Label "$hookTargetNode-setup-trigger-hooks" -DoExecute:$Execute
        Add-ReportAction -Report $report -Result $setupTriggerResult
        Assert-CommandSucceeded -Result $setupTriggerResult -FailureMessage "Failed to stage trigger test hook on $hookTargetNode."

        try {
            $triggerArgs = @($hookTargetPlan.sourceDataset, $triggerThawHook, "30", $hookTargetPlan.localBackupUid)
            $triggerResult = Invoke-BuddyBackupShellCommandWithRetry -NodeConnection $hookTargetConnection -Action "run_snapshot_post_hook_and_trigger" -Arguments $triggerArgs -Label "$hookTargetNode-trigger-decoupling-test" -RetryTransientSshFailure -DoExecute:$Execute
            Add-ReportAction -Report $report -Result $triggerResult
            Assert-CommandSucceeded -Result $triggerResult -FailureMessage "BuddyBackup run_snapshot_post_hook_and_trigger failed on $hookTargetNode."

            if ($Execute) {
                # Verify wrapper returned immediately and thaw hook ran
                $readTriggerLogCmd = "cat '$triggerEventLog' 2>/dev/null || echo '(no-log)'"
                $readTriggerLogResult = Invoke-NodeSshCommandWithRetry -NodeConnection $hookTargetConnection -Command $readTriggerLogCmd -Label "$hookTargetNode-check-trigger-thaw-log" -DoExecute:$Execute
                Add-ReportAction -Report $report -Result $readTriggerLogResult
                $thawOutput = Get-ResultOutputText -Result $readTriggerLogResult
                if ($thawOutput -notmatch 'thaw_executed') {
                    throw "Snapshot trigger test failed: thaw hook was not executed before trigger return on $hookTargetNode."
                }

                # Poll runtime telemetry file for up to 30 seconds to verify background backup completes and reports last_status="success" (not killed by SIGTERM)
                $pollScript = @'
uid="$1"
run_file="/var/run/buddybackup/${uid}"
tmp_file="/tmp/buddybackup-${uid}"

for i in {1..30}; do
    target_file=""
    if [[ -f "$run_file" ]]; then
        target_file="$run_file"
    elif [[ -f "$tmp_file" ]]; then
        target_file="$tmp_file"
    fi

    if [[ -n "$target_file" ]]; then
        status=$(grep '^last_status=' "$target_file" 2>/dev/null | cut -d'=' -f2 | tr -d '"\r\n' || true)
        if [[ "$status" == "success" ]]; then
            echo "TRIGGER_BACKUP_SUCCESS"
            exit 0
        elif [[ "$status" == "failed" ]]; then
            error_msg=$(grep '^last_error_message=' "$target_file" 2>/dev/null | cut -d'=' -f2- | tr -d '"\r\n' || true)
            echo "TRIGGER_BACKUP_FAILED: $error_msg"
            exit 1
        fi
    fi
    sleep 1
done

echo "TRIGGER_BACKUP_TIMEOUT"
if [[ -f /var/log/buddybackup.log ]]; then
    echo "--- Recent /var/log/buddybackup.log ---"
    tail -n 25 /var/log/buddybackup.log
fi
exit 1
'@
                $pollResult = Invoke-NodeBashScript -NodeConnection $hookTargetConnection -ScriptContent $pollScript -Arguments @($hookTargetPlan.localBackupUid) -Label "$hookTargetNode-verify-trigger-backup-success" -DoExecute:$Execute
                Add-ReportAction -Report $report -Result $pollResult
                Assert-CommandSucceeded -Result $pollResult -FailureMessage "Triggered backup task did not succeed on $hookTargetNode (possible SIGTERM kill or timeout)."
            }
        } finally {
            $cleanupTriggerResult = Invoke-NodeSshCommandWithRetry -NodeConnection $hookTargetConnection -Command "rm -f '$triggerThawHook' '$triggerEventLog'" -Label "$hookTargetNode-cleanup-trigger-hooks" -DoExecute:$Execute
            Add-ReportAction -Report $report -Result $cleanupTriggerResult
        }
    }

    # 5. Log hygiene and warning auditing
    if ($Execute -and $null -ne $hookTargetConnection) {
        Write-Host "[testlab] Functional smoke: auditing /var/log/buddybackup.log for suppressed warnings and errors on $hookTargetNode"
        $auditScript = @'
if [[ -f /var/log/buddybackup.log ]]; then
    if grep -E 'print\(\) on closed filehandle FH|filehandle FH at .*sanoid line' /var/log/buddybackup.log; then
        echo "LOG_AUDIT_FAILED_SANOID_WARNING"
        exit 1
    fi
    echo "LOG_AUDIT_PASSED"
    exit 0
else
    echo "LOG_AUDIT_SKIPPED_NO_LOG"
    exit 0
fi
'@
        $auditResult = Invoke-NodeBashScript -NodeConnection $hookTargetConnection -ScriptContent $auditScript -Label "$hookTargetNode-audit-log-cleanliness" -DoExecute:$Execute
        Add-ReportAction -Report $report -Result $auditResult
        Assert-CommandSucceeded -Result $auditResult -FailureMessage "Log hygiene audit failed on ${hookTargetNode}: unhandled Sanoid filehandle warning detected in buddybackup.log."
    }

    $report.success = $true
    Write-Host "[testlab] Functional smoke completed successfully"
} catch {
    $report.success = $false
    $report.error = ($_ | Out-String).Trim()
    Write-Warning "[testlab] Functional smoke failed: $($report.error)"
} finally {
    $report.finishedAt = (Get-Date).ToString("o")
    $reportJson = $report | ConvertTo-Json -Depth 8
    Set-Content -LiteralPath $reportPath -Value $reportJson -Encoding UTF8
    Write-Host "[testlab] Functional smoke report written to $reportPath"
}

$scenarioResult = [pscustomobject]@{
    Scenario   = 'functional-smoke'
    Success    = [bool]$report.success
    Results    = $report.actions
    Error      = $report.error
    ReportPath = $reportPath
}

if ($MyInvocation.InvocationName -ne '.') {
    $scenarioResult
    if ($report.success) {
        exit 0
    } else {
        exit 1
    }
} else {
    return $scenarioResult
}
