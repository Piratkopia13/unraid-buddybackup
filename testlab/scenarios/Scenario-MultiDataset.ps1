<#
.SYNOPSIS
    Layer 4 Scenario: Multi-dataset hot-standby replication test for BuddyBackup testlab.
.DESCRIPTION
    Validates consolidated parent container delegation, multi-job authorized_keys
    consolidation, child dataset auto-creation under parent containers, live replication,
    and isolated telemetry tracking between nodeA and nodeB.
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
        [string]$LoggedCommand = $null,
        [switch]$DoExecute
    )

    $res = Invoke-RemoteBash -NodeConnection $NodeConnection -BashScript $ScriptContent -Arguments $Arguments -Label $Label -LoggedCommand $LoggedCommand -DoExecute:$DoExecute
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

# ---------------- Main Scenario Execution ----------------

$resolvedConfigPath = Resolve-TestLabPath $LabConfig
if (-not (Test-Path -LiteralPath $resolvedConfigPath)) {
    throw "Lab config not found: $resolvedConfigPath"
}

$lab = Get-TestLabJson $resolvedConfigPath
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
    $reportPath = Join-Path $reportsDir ("scenario-multi-dataset-{0}.json" -f $runId)
}
$null = Ensure-TestLabDir $reportsDir

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
$report = [ordered]@{
    runId       = $runId
    executeMode = [bool]$Execute
    success     = $scenarioSuccess
    error       = $scenarioError
    reportPath  = $reportPath
    actions     = $actions
}

$report | ConvertTo-Json -Depth 6 | Set-Content -LiteralPath $reportPath -Encoding UTF8
Write-Host "[testlab] Multi-dataset scenario report written to $reportPath"

$scenarioResult = [pscustomobject]@{
    Scenario   = 'multi-dataset'
    Success    = [bool]$scenarioSuccess
    Results    = $actions
    Error      = $scenarioError
    ReportPath = $reportPath
}

if ($MyInvocation.InvocationName -ne '.') {
    $scenarioResult
    if ($scenarioSuccess) {
        exit 0
    } else {
        exit 1
    }
} else {
    return $scenarioResult
}
