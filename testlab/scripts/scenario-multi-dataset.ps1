param(
    [string]$LabConfig = "testlab/config/lab.local.json",
    [switch]$Execute
)

$ErrorActionPreference = "Stop"
if (Test-Path Variable:\PSNativeCommandUseErrorActionPreference) {
    $PSNativeCommandUseErrorActionPreference = $false
}

. (Join-Path $PSScriptRoot "testlab-logging.ps1")

function Get-Json {
    param([string]$Path)
    return Get-Content -Raw -Path $Path | ConvertFrom-Json
}

function Ensure-Dir {
    param([string]$Path)
    if (-not (Test-Path -LiteralPath $Path)) {
        New-Item -ItemType Directory -Path $Path -Force | Out-Null
    }
}

function Get-ObjectValue {
    param(
        $Object,
        [string]$Name
    )

    if ($null -eq $Object -or [string]::IsNullOrWhiteSpace($Name)) {
        return $null
    }

    if ($Object -is [System.Collections.IDictionary]) {
        return $Object[$Name]
    }

    $property = $Object.PSObject.Properties[$Name]
    if ($property) {
        return $property.Value
    }

    return $null
}

function Get-TestLabCanonicalNodeName {
    param([string]$NodeName)

    switch ($NodeName) {
        "sender" { return "nodeA" }
        "receiver" { return "nodeB" }
        default { return $NodeName }
    }
}

function Get-TestLabLegacyNodeName {
    param([string]$NodeName)

    switch (Get-TestLabCanonicalNodeName -NodeName $NodeName) {
        "nodeA" { return "sender" }
        "nodeB" { return "receiver" }
        default { return $null }
    }
}

function Get-TestLabNodeValue {
    param(
        $Object,
        [string]$NodeName
    )

    $canonicalNodeName = Get-TestLabCanonicalNodeName -NodeName $NodeName
    $value = Get-ObjectValue -Object $Object -Name $canonicalNodeName
    if ($null -ne $value) {
        return $value
    }

    $legacyNodeName = Get-TestLabLegacyNodeName -NodeName $NodeName
    if (-not [string]::IsNullOrWhiteSpace($legacyNodeName)) {
        return Get-ObjectValue -Object $Object -Name $legacyNodeName
    }

    return $null
}

function Resolve-TestLabPath {
    param([string]$Path)

    if ([string]::IsNullOrWhiteSpace($Path)) {
        return $Path
    }

    if ($Path.StartsWith('~/') -or $Path.StartsWith('~\')) {
        return Join-Path -Path $HOME -ChildPath $Path.Substring(2)
    }

    if ([System.IO.Path]::IsPathRooted($Path)) {
        return [System.IO.Path]::GetFullPath($Path)
    }

    $workspaceRoot = [System.IO.Path]::GetFullPath((Join-Path $PSScriptRoot "..\.."))
    return [System.IO.Path]::GetFullPath((Join-Path $workspaceRoot $Path))
}

function Get-NodeConnection {
    param(
        $Lab,
        [string]$NodeName
    )

    $canonicalNodeName = Get-TestLabCanonicalNodeName -NodeName $NodeName
    $node = Get-TestLabNodeValue -Object (Get-ObjectValue -Object $Lab -Name 'nodes') -NodeName $canonicalNodeName
    if (-not $node -or -not (Get-ObjectValue -Object $node -Name "host")) {
        throw "Missing lab.nodes.$canonicalNodeName.host"
    }

    $defaultPort = if ($Lab.ssh -and $Lab.ssh.port) { [int]$Lab.ssh.port } else { 22 }
    $defaultUser = if ($Lab.ssh -and $Lab.ssh.user) { [string]$Lab.ssh.user } else { "root" }
    $defaultIdentityFile = if ($Lab.ssh -and $Lab.ssh.identityFile) { [string]$Lab.ssh.identityFile } else { $null }

    $identityFile = Get-ObjectValue -Object $node -Name "identityFile"
    return [pscustomobject]@{
        NodeName = $canonicalNodeName
        User = if (Get-ObjectValue -Object $node -Name "user") { [string](Get-ObjectValue -Object $node -Name "user") } else { $defaultUser }
        Host = [string](Get-ObjectValue -Object $node -Name "host")
        Port = if (Get-ObjectValue -Object $node -Name "port") { [int](Get-ObjectValue -Object $node -Name "port") } else { $defaultPort }
        IdentityFile = if ($identityFile) { [string]$identityFile } else { $defaultIdentityFile }
    }
}

function Get-LocalSshIdentityFile {
    param([string]$IdentityFile)

    if ([string]::IsNullOrWhiteSpace($IdentityFile)) {
        return $IdentityFile
    }

    $resolvedPath = Resolve-TestLabPath $IdentityFile
    if (-not (Test-Path -LiteralPath $resolvedPath)) {
        throw "SSH identity file not found: $resolvedPath"
    }

    $cacheRoot = Join-Path $env:LOCALAPPDATA "BuddyBackup\ssh-cache"
    Ensure-Dir $cacheRoot

    $pathHashBytes = [System.Text.Encoding]::UTF8.GetBytes($resolvedPath)
    $pathHash = [System.BitConverter]::ToString(([System.Security.Cryptography.SHA256]::Create().ComputeHash($pathHashBytes))).Replace("-", "").ToLowerInvariant()
    $fileName = "{0}-{1}" -f ([System.IO.Path]::GetFileName($resolvedPath)), $pathHash.Substring(0, 12)
    $cachedPath = Join-Path $cacheRoot $fileName

    Copy-Item -LiteralPath $resolvedPath -Destination $cachedPath -Force

    if ($env:OS -eq 'Windows_NT') {
        $currentUser = [System.Security.Principal.WindowsIdentity]::GetCurrent().Name
        & icacls $cachedPath /inheritance:r /grant:r "${currentUser}:(F)" | Out-Null
    }

    return $cachedPath
}

function Convert-ToShellSingleQuoted {
    param([string]$Value)

    if ($null -eq $Value) {
        $Value = ""
    }

    $singleQuoteEscape = "'" + '"' + "'" + '"' + "'"
    return "'" + $Value.Replace("'", $singleQuoteEscape) + "'"
}

function Invoke-NodeSshCommand {
    param(
        $NodeConnection,
        [string]$Command,
        [string]$Label,
        [switch]$DoExecute
    )

    $sshArgs = @(
        "-F", "NUL",
        "-o", "BatchMode=yes",
        "-o", "ConnectTimeout=8",
        "-o", "IdentitiesOnly=yes",
        "-o", "LogLevel=ERROR",
        "-o", "StrictHostKeyChecking=no",
        "-o", "UserKnownHostsFile=NUL",
        "-o", "GlobalKnownHostsFile=NUL",
        "-p", ([string]$NodeConnection.Port)
    )

    if ($NodeConnection.IdentityFile) {
        $identityPath = Get-LocalSshIdentityFile -IdentityFile ([string]$NodeConnection.IdentityFile)
        $sshArgs += @("-i", $identityPath)
    }

    $sshArgs += @("$($NodeConnection.User)@$($NodeConnection.Host)", $Command)

    if (-not $DoExecute) {
        Write-Host "[dry-run][$($NodeConnection.NodeName)][$Label] ssh $($sshArgs -join ' ')"
        return [pscustomobject]@{
            node = $NodeConnection.NodeName
            label = $Label
            command = $Command
            success = $true
            exitCode = 0
            output = @("dry-run")
        }
    }

    $previousErrorActionPreference = $ErrorActionPreference
    try {
        $ErrorActionPreference = "Continue"
        $rawOutput = & ssh @sshArgs 2>&1
        $exitCode = $LASTEXITCODE
    } finally {
        $ErrorActionPreference = $previousErrorActionPreference
    }

    return [pscustomobject]@{
        node = $NodeConnection.NodeName
        label = $Label
        command = $Command
        success = ($exitCode -eq 0)
        exitCode = $exitCode
        output = @($rawOutput | ForEach-Object { [string]$_ })
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

    $normalizedScript = ($ScriptContent -replace "`r`n", "`n").Trim()
    $scriptB64 = [Convert]::ToBase64String([System.Text.Encoding]::UTF8.GetBytes($normalizedScript))
    $command = "printf '%s' '$scriptB64' | base64 -d | bash -s --"
    if ($Arguments -and $Arguments.Count -gt 0) {
        $command += " " + (($Arguments | ForEach-Object { Convert-ToShellSingleQuoted -Value ([string]$_) }) -join " ")
    }

    return Invoke-NodeSshCommand -NodeConnection $NodeConnection -Command $command -Label $Label -DoExecute:$DoExecute
}

# ---------------- Main Scenario Execution ----------------

$resolvedConfigPath = Resolve-TestLabPath $LabConfig
if (-not (Test-Path -LiteralPath $resolvedConfigPath)) {
    throw "Lab config not found: $resolvedConfigPath"
}

$lab = Get-Json $resolvedConfigPath
$nodeA = Get-NodeConnection -Lab $lab -NodeName "nodeA"
$nodeB = Get-NodeConnection -Lab $lab -NodeName "nodeB"

$setupCfg = Get-ObjectValue -Object $lab -Name "setup"
$zfsCfg = Get-ObjectValue -Object $setupCfg -Name "zfs"
$poolName = [string](Get-ObjectValue -Object $zfsCfg -Name "poolName")
if ([string]::IsNullOrWhiteSpace($poolName)) {
    $poolName = "bbpool"
}

$functionalCfg = Get-ObjectValue -Object $setupCfg -Name "functionalTests"
$nodeBAliasIp = [string](Get-ObjectValue -Object $functionalCfg -Name "nodeBAliasIp")
if ([string]::IsNullOrWhiteSpace($nodeBAliasIp)) {
    $nodeBAliasIp = [string](Get-ObjectValue -Object $functionalCfg -Name "receiverAliasIp")
}
if ([string]::IsNullOrWhiteSpace($nodeBAliasIp)) {
    $nodeBAliasIp = "10.254.0.23"
}
$receiverHost = if ($nodeB.Port -eq 22) { [string]$nodeB.Host } else { $nodeBAliasIp }

$logsRoot = if ($lab.logsRoot) { Resolve-TestLabPath ([string]$lab.logsRoot) } else { Resolve-TestLabPath ".testlab/logs" }
Ensure-Dir $logsRoot

$runId = (Get-Date).ToString("yyyyMMdd-HHmmss")
$reportPath = Join-Path $logsRoot ("scenario-multi-dataset-{0}.json" -f $runId)
$actions = @()
$scenarioSuccess = $true
$scenarioError = $null

Write-Host ("[testlab] Starting multi-dataset hot-standby scenario ({0})" -f $runId)

try {
    # ---------------- 1. Read Node A sender public key ----------------
    Write-Host "[testlab] Reading sender public key from Node A"
    $keyResult = Invoke-NodeSshCommand -NodeConnection $nodeA -Command "cat /boot/config/plugins/buddybackup/buddybackup_sender_key.pub" -Label "nodeA-read-pubkey" -DoExecute:$Execute
    $actions += $keyResult

    $senderPubKey = if ($Execute) {
        ($keyResult.output -join "").Trim()
    } else {
        "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIDRYRUNKEYFORTESTING buddy@nodeA"
    }

    if ($Execute -and [string]::IsNullOrWhiteSpace($senderPubKey)) {
        throw "Failed to read sender public key from Node A."
    }

    # ---------------- 2. Setup Node B (Receiver) ----------------
    Write-Host "[testlab] Configuring Node B (Receiver) with consolidated parent containers"
    $cardAppdataUid = "appdata01"
    $cardDomainsUid = "mintvm001"

    $receiverSetupScript = @'
pool_name="$1"
sender_pub_key="$2"
appdata_uid="$3"
domains_uid="$4"

set -euo pipefail

# Ensure parent container datasets exist
if ! zfs list -H -o name "${pool_name}/appdata" >/dev/null 2>&1; then
    zfs create "${pool_name}/appdata"
fi
if ! zfs list -H -o name "${pool_name}/domains" >/dev/null 2>&1; then
    zfs create "${pool_name}/domains"
fi

# Ensure test child dataset does NOT exist initially (clean state for initial sync)
if zfs list -H -o name "${pool_name}/domains/MintCinnamon" >/dev/null 2>&1; then
    zfs destroy -r "${pool_name}/domains/MintCinnamon"
fi

# Clean any existing telemetry files for these cards
rm -f "/var/run/buddybackup/buddy-${appdata_uid}" "/var/run/buddybackup/buddy-${domains_uid}" "/tmp/buddybackup-buddy-${appdata_uid}" "/tmp/buddybackup-buddy-${domains_uid}"

# Configure incoming.cfg with 2 cards sharing the sender SSH key
mkdir -p /boot/config/plugins/buddybackup
cat > /boot/config/plugins/buddybackup/incoming.cfg << EOF
[${appdata_uid}]
name="Appdata"
enable="yes"
destination_dataset="${pool_name}/appdata"
immutable="no"
ssh_key="${sender_pub_key}"
hourly="0"
daily="7"
weekly="4"
monthly="3"
yearly="0"

[${domains_uid}]
name="MintVM"
enable="yes"
destination_dataset="${pool_name}/domains"
immutable="no"
ssh_key="${sender_pub_key}"
hourly="0"
daily="7"
weekly="4"
monthly="3"
yearly="0"
EOF

# Run BuddyBackup update to consolidate authorized_keys and apply zfs allow
/usr/local/emhttp/plugins/buddybackup/scripts/rc.buddybackup.php update
'@
    $receiverSetupResult = Invoke-NodeBashScript -NodeConnection $nodeB -ScriptContent $receiverSetupScript -Arguments @($poolName, $senderPubKey, $cardAppdataUid, $cardDomainsUid) -Label "nodeB-setup-incoming" -DoExecute:$Execute
    $actions += $receiverSetupResult
    if ($Execute -and -not $receiverSetupResult.success) {
        throw "Failed to configure incoming datasets on Node B."
    }

    # Verify authorized_keys consolidation on Node B
    Write-Host "[testlab] Verifying authorized_keys consolidation on Node B"
    $authKeysResult = Invoke-NodeSshCommand -NodeConnection $nodeB -Command "cat /home/buddybackup/.ssh/authorized_keys" -Label "nodeB-verify-authkeys" -DoExecute:$Execute
    $actions += $authKeysResult
    if ($Execute) {
        $authKeysText = ($authKeysResult.output -join "`n")
        if ($authKeysText -notmatch "--dataset\s+'${poolName}/appdata'") {
            throw "authorized_keys missing --dataset '${poolName}/appdata'."
        }
        if ($authKeysText -notmatch "--dataset\s+'${poolName}/domains'") {
            throw "authorized_keys missing --dataset '${poolName}/domains'."
        }
        # Check active non-comment lines
        $activeLines = @($authKeysResult.output | Where-Object { $_ -match "^restrict,command=" })
        if ($activeLines.Count -ne 1) {
            throw ("Expected exactly 1 consolidated authorized_keys line, found {0}." -f $activeLines.Count)
        }
    }

    # Verify OpenZFS permission delegation on parent containers on Node B
    Write-Host "[testlab] Verifying OpenZFS permissions on parent containers on Node B"
    $zfsAllowResult = Invoke-NodeSshCommand -NodeConnection $nodeB -Command "zfs allow ${poolName}/domains" -Label "nodeB-verify-zfs-allow" -DoExecute:$Execute
    $actions += $zfsAllowResult
    if ($Execute) {
        $zfsAllowText = ($zfsAllowResult.output -join "`n")
        if ($zfsAllowText -notmatch "user buddybackup" -or
            $zfsAllowText -notmatch "create" -or
            $zfsAllowText -notmatch "mount" -or
            $zfsAllowText -notmatch "receive" -or
            $zfsAllowText -notmatch "send") {
            throw "OpenZFS permissions on ${poolName}/domains missing create/mount/receive delegation."
        }
    }

    # ---------------- 3. Setup Node A (Sender) ----------------
    Write-Host "[testlab] Configuring Node A (Sender) with source datasets and outgoing jobs"
    $jobAppdataUid = "d5174696"
    $jobMintUid    = "115e80fb"

    $senderSetupScript = @'
pool_name="$1"
receiver_ip="$2"
job_appdata_uid="$3"
job_mint_uid="$4"
peer_port="${5:-22}"
host_gateway_ip="${6:-10.0.2.2}"

set -euo pipefail

# Map alias IP to peer port via DNAT if running in port-forwarded lab
if [[ "${peer_port}" != "22" ]]; then
    if command -v iptables >/dev/null 2>&1; then
        iptables -t nat -C OUTPUT -d "${receiver_ip}/32" -p tcp --dport 22 -j DNAT --to-destination "${host_gateway_ip}:${peer_port}" >/dev/null 2>&1 || \
            iptables -t nat -A OUTPUT -d "${receiver_ip}/32" -p tcp --dport 22 -j DNAT --to-destination "${host_gateway_ip}:${peer_port}"
    fi
fi

# Ensure source datasets exist on sender
if ! zfs list -H -o name "${pool_name}/appdata" >/dev/null 2>&1; then
    zfs create "${pool_name}/appdata"
fi
if ! zfs list -H -o name "${pool_name}/domains" >/dev/null 2>&1; then
    zfs create "${pool_name}/domains"
fi
if ! zfs list -H -o name "${pool_name}/domains/MintCinnamon" >/dev/null 2>&1; then
    zfs create "${pool_name}/domains/MintCinnamon"
fi

# Ensure test payload and initial snapshot exist
mkdir -p "/${pool_name}/domains/MintCinnamon" 2>/dev/null || true
echo "MintCinnamon test disk data $(date +%s)" > "/${pool_name}/domains/MintCinnamon/vdisk.img"
snap_name="autosnap_$(date +%Y-%m-%d_%H:%M:%S)_hourly"
zfs snapshot "${pool_name}/domains/MintCinnamon@${snap_name}"

# Allow unencrypted remote backups for local testlab
mkdir -p /boot/config/plugins/buddybackup
if [ -f /boot/config/plugins/buddybackup/buddybackup.cfg ]; then
    if grep -q "^AllowUnencryptedRemoteBackups=" /boot/config/plugins/buddybackup/buddybackup.cfg; then
        sed -i 's|^AllowUnencryptedRemoteBackups=.*|AllowUnencryptedRemoteBackups="yes"|' /boot/config/plugins/buddybackup/buddybackup.cfg
    else
        echo 'AllowUnencryptedRemoteBackups="yes"' >> /boot/config/plugins/buddybackup/buddybackup.cfg
    fi
else
    echo 'AllowUnencryptedRemoteBackups="yes"' > /boot/config/plugins/buddybackup/buddybackup.cfg
fi

# Configure backups.cfg
cat > /boot/config/plugins/buddybackup/backups.cfg << EOF
[${job_appdata_uid}]
enable="no"
source_dataset="${pool_name}/appdata"
recursive="no"
skip_parent="no"
backup_cron="0 0 * * *"
type="remote"
destination_host="${receiver_ip}"
destination_user=""
destination_port=""
destination_dataset="${pool_name}/appdata"

[${job_mint_uid}]
enable="no"
source_dataset="${pool_name}/domains/MintCinnamon"
recursive="no"
skip_parent="no"
backup_cron="0 0 * * *"
type="remote"
destination_host="${receiver_ip}"
destination_user=""
destination_port=""
destination_dataset="${pool_name}/domains/MintCinnamon"
EOF

# Update known_hosts
/usr/local/emhttp/plugins/buddybackup/scripts/rc.buddybackup.php update
'@
    $peerPort = [string]$nodeB.Port
    $hostGatewayIp = [string](Get-ObjectValue -Object $functionalCfg -Name "hostGatewayIp")
    if ([string]::IsNullOrWhiteSpace($hostGatewayIp)) {
        $hostGatewayIp = "10.0.2.2"
    }
    $senderSetupResult = Invoke-NodeBashScript -NodeConnection $nodeA -ScriptContent $senderSetupScript -Arguments @($poolName, $receiverHost, $jobAppdataUid, $jobMintUid, $peerPort, $hostGatewayIp) -Label "nodeA-setup-outgoing" -DoExecute:$Execute
    $actions += $senderSetupResult
    if ($Execute -and -not $senderSetupResult.success) {
        throw "Failed to configure outgoing jobs on Node A."
    }

    # ---------------- 4. Test Connections from Node A ----------------
    Write-Host "[testlab] Testing connection for Job 1 (Appdata: exact match)"
    $testConnAppdata = Invoke-NodeSshCommand -NodeConnection $nodeA -Command ("/usr/local/emhttp/plugins/buddybackup/scripts/rc.buddybackup test_connection {0} {1}/appdata" -f $receiverHost, $poolName) -Label "nodeA-testconn-appdata" -DoExecute:$Execute
    $actions += $testConnAppdata
    if ($Execute) {
        $outputStr = ($testConnAppdata.output -join "`n")
        if ($outputStr -notmatch "Success!") {
            throw "test_connection failed for Appdata: $outputStr"
        }
        if ($outputStr -notmatch "matches the receiver's configured dataset") {
            throw "test_connection output did not report matching receiver dataset for Appdata: $outputStr"
        }
    }

    Write-Host "[testlab] Testing connection for Job 2 (MintVM: sub-dataset under parent container)"
    $testConnDomains = Invoke-NodeSshCommand -NodeConnection $nodeA -Command ("/usr/local/emhttp/plugins/buddybackup/scripts/rc.buddybackup test_connection {0} {1}/domains/MintCinnamon" -f $receiverHost, $poolName) -Label "nodeA-testconn-mintvm" -DoExecute:$Execute
    $actions += $testConnDomains
    if ($Execute) {
        $outputStr = ($testConnDomains.output -join "`n")
        if ($outputStr -notmatch "Success!") {
            throw "test_connection failed for MintVM: $outputStr"
        }
        if ($outputStr -notmatch "is under the receiver's configured dataset") {
            throw "test_connection output did not report child dataset under parent container: $outputStr"
        }
    }

    # ---------------- 5. Execute Live Replication for MintVM from Node A ----------------
    Write-Host "[testlab] Executing live send_backup for Job 2 (MintVM) from Node A"
    $sendResult = Invoke-NodeSshCommand -NodeConnection $nodeA -Command ("/usr/local/emhttp/plugins/buddybackup/scripts/rc.buddybackup.php send_backup {0}" -f $jobMintUid) -Label "nodeA-send-backup-mintvm" -DoExecute:$Execute
    $actions += $sendResult
    if ($Execute) {
        $sendOutput = ($sendResult.output -join "`n")
        if (-not $sendResult.success -or ($sendOutput -notmatch "Successfully synced backup to buddy!")) {
            throw "send_backup failed for MintVM:`n$sendOutput"
        }
    }

    # ---------------- 6. Verify Results on Node B (Receiver) ----------------
    Write-Host "[testlab] Verifying dataset creation and telemetry on Node B"
    $zfsListResult = Invoke-NodeSshCommand -NodeConnection $nodeB -Command ("zfs list -H -o name {0}/domains/MintCinnamon" -f $poolName) -Label "nodeB-verify-dataset-created" -DoExecute:$Execute
    $actions += $zfsListResult
    if ($Execute -and -not $zfsListResult.success) {
        throw "Dataset ${poolName}/domains/MintCinnamon was not created on Node B."
    }

    # Verify telemetry attribution specifically to Card 2 (MintVM)
    $telemetryMint = Invoke-NodeSshCommand -NodeConnection $nodeB -Command ("cat /var/run/buddybackup/buddy-{0} 2>/dev/null || cat /tmp/buddybackup-buddy-{0}" -f $cardDomainsUid) -Label "nodeB-verify-telemetry-mint" -DoExecute:$Execute
    $actions += $telemetryMint
    if ($Execute) {
        $telemetryContent = ($telemetryMint.output -join "`n")
        if ($telemetryContent -notmatch "last_ran=" -or $telemetryContent -notmatch "dest_size=") {
            throw "Telemetry file for MintVM missing last_ran or dest_size:`n$telemetryContent"
        }
    }

    # Verify telemetry for Card 1 (Appdata) was NOT written by the Mint send
    $telemetryAppdata = Invoke-NodeSshCommand -NodeConnection $nodeB -Command ("test ! -f /var/run/buddybackup/buddy-{0} && test ! -f /tmp/buddybackup-buddy-{0} && echo 'isolated_clean'" -f $cardAppdataUid) -Label "nodeB-verify-telemetry-isolation" -DoExecute:$Execute
    $actions += $telemetryAppdata
    if ($Execute) {
        $isolationOutput = ($telemetryAppdata.output -join "")
        if ($isolationOutput -notmatch "isolated_clean") {
            throw "Telemetry isolation violated: Appdata telemetry file was unexpectedly modified by MintVM backup."
        }
    }

    Write-Host "[testlab] Multi-dataset hot-standby scenario PASSED successfully!"
} catch {
    $scenarioSuccess = $false
    $scenarioError = ($_ | Out-String).Trim()
    Write-Warning ("[testlab] Multi-dataset scenario FAILED: {0}" -f $scenarioError)
}

# Write test report
$report = [pscustomobject]@{
    runId = $runId
    executeMode = [bool]$Execute
    success = $scenarioSuccess
    error = $scenarioError
    reportPath = $reportPath
    actions = $actions
}

$report | ConvertTo-Json -Depth 6 | Set-Content -LiteralPath $reportPath

if (-not $scenarioSuccess) {
    throw $scenarioError
}

return [pscustomobject]@{
    Success = $scenarioSuccess
    ReportPath = $reportPath
    Error = $scenarioError
}
