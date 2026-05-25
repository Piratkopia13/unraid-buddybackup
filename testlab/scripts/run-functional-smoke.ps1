param(
    [string]$LabConfig = "testlab/config/lab.local.json",
    [switch]$Execute
)

$ErrorActionPreference = "Stop"

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

function Get-SetupZfsValues {
    param($Lab)

    $setupCfg = Get-ObjectValue -Object $Lab -Name "setup"
    $zfsCfg = Get-ObjectValue -Object $setupCfg -Name "zfs"

    $poolName = [string](Get-ObjectValue -Object $zfsCfg -Name "poolName")
    if ([string]::IsNullOrWhiteSpace($poolName)) {
        $poolName = "bbpool"
    }

    $datasetRootName = [string](Get-ObjectValue -Object $zfsCfg -Name "datasetRoot")
    if ([string]::IsNullOrWhiteSpace($datasetRootName)) {
        $datasetRootName = "buddybackup"
    }

    return [pscustomobject]@{
        PoolName = $poolName
        DatasetRoot = "$poolName/$datasetRootName"
    }
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
        hostGatewayIp = $hostGatewayIp
        testDatasetRootName = $testDatasetRootName
        receiveDatasetName = $receiveDatasetName
        nodeAAliasIp = $nodeAAliasIp
        nodeBAliasIp = $nodeBAliasIp
        allowUnencryptedRemoteBackups = $allowUnencryptedRemoteBackups
    }
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

    $Report.actions += [pscustomobject]@{
        node = $Result.node
        label = $Result.label
        success = [bool]$Result.success
        exitCode = [int]$Result.exitCode
        command = [string]$Result.command
        output = @($Result.output)
    }
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

function Get-NodeBuddyBackupPublicKey {
    param(
        $NodeConnection,
        [switch]$DoExecute
    )

    $result = Invoke-NodeSshCommand -NodeConnection $NodeConnection -Command "cat /boot/config/plugins/buddybackup/buddybackup_sender_key.pub" -Label "read-buddybackup-public-key" -DoExecute:$DoExecute
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
        nodeName = $canonicalNodeName
        hostPort = $Port
        aliasIp = $aliasIp
        testRootDataset = $testRoot
        receiveRootDataset = $receiveRoot
        sourceDataset = "$testRoot/$canonicalNodeName-source"
        sourceMountpoint = "/mnt/buddybackup-functional/$canonicalNodeName-source"
        localBackupDataset = "$testRoot/$canonicalNodeName-local-backup"
        localRestoreDataset = "$testRoot/$canonicalNodeName-local-restore"
        remoteRestoreDataset = "$testRoot/$canonicalNodeName-remote-restore"
        localBackupUid = $localUid
        remoteBackupUid = $remoteUid
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
                    name = $snapshotName
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
                name = [string]$snapshotProperty.Name
                creation = $creationValue
            }
        }
    }

    if ($snapshotEntries.Count -eq 0) {
        throw "Snapshot query for uid '$Uid' on node '$NodeName' returned no snapshots."
    }

    $selectedSnapshot = $snapshotEntries | Sort-Object -Property @{ Expression = { [long]($_.creation) } } -Descending | Select-Object -First 1
    return [pscustomobject]@{
        dataset = [string]$datasetProperty.Name
        snapshot = [string]$selectedSnapshot.name
        warning = [string]$snapshotData.warning
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
fi

/usr/local/emhttp/plugins/buddybackup/scripts/rc.buddybackup.php update

echo "configured_node=${node_name}"
echo "configured_remote_host=${remote_host}"
echo "configured_receive_root=${receive_root_dataset}"
'@
    return $script
}

$resolvedLabConfig = Resolve-TestLabPath $LabConfig
if (-not (Test-Path -LiteralPath $resolvedLabConfig)) {
    throw "Missing lab config: $resolvedLabConfig"
}

$lab = Get-Json -Path $resolvedLabConfig
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

$logsRoot = if ($lab.logsRoot) { Resolve-TestLabPath ([string]$lab.logsRoot) } else { Resolve-TestLabPath ".testlab/logs" }
Ensure-Dir $logsRoot
$runId = Get-Date -Format "yyyyMMdd-HHmmss"
$reportPath = Join-Path $logsRoot ("functional-smoke-{0}.json" -f $runId)
$snapshotRunId = $runId.Replace("-", "_")

$senderPlan | Add-Member -NotePropertyName sourceSnapshot -NotePropertyValue "$($senderPlan.sourceDataset)@functional_smoke_${snapshotRunId}_nodeA"
$receiverPlan | Add-Member -NotePropertyName sourceSnapshot -NotePropertyValue "$($receiverPlan.sourceDataset)@functional_smoke_${snapshotRunId}_nodeB"

$report = [ordered]@{
    runId = $runId
    executeMode = [bool]$Execute
    success = $false
    error = $null
    reportPath = $reportPath
    nodes = @(
        [pscustomobject]@{ node = "nodeA"; sshPort = $senderConnection.Port; remoteHost = $senderPlan.remoteHost; webUi = "http://127.0.0.1:8080" },
        [pscustomobject]@{ node = "nodeB"; sshPort = $receiverConnection.Port; remoteHost = $receiverPlan.remoteHost; webUi = "http://127.0.0.1:8081" }
    )
    actions = @()
}

try {
    Write-Host "[testlab] Functional smoke starting: nodeA localhost:$($senderConnection.Port), nodeB localhost:$($receiverConnection.Port)"
    Write-Host "[testlab] Functional smoke: reading BuddyBackup public keys"
    $senderPublicKey = Get-NodeBuddyBackupPublicKey -NodeConnection $senderConnection -DoExecute:$Execute
    $receiverPublicKey = Get-NodeBuddyBackupPublicKey -NodeConnection $receiverConnection -DoExecute:$Execute

    $setupScript = New-FunctionalSetupScript

    Write-Host "[testlab] Functional smoke: applying environment setup on nodeA and nodeB"
    $senderSetup = Invoke-NodeBashScript -NodeConnection $senderConnection -ScriptContent $setupScript -Arguments @(
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
    ) -Label "functional-setup" -DoExecute:$Execute
    Add-ReportAction -Report $report -Result $senderSetup
    Assert-CommandSucceeded -Result $senderSetup -FailureMessage "Functional setup failed on nodeA."

    $receiverSetup = Invoke-NodeBashScript -NodeConnection $receiverConnection -ScriptContent $setupScript -Arguments @(
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
    ) -Label "functional-setup" -DoExecute:$Execute
    Add-ReportAction -Report $report -Result $receiverSetup
    Assert-CommandSucceeded -Result $receiverSetup -FailureMessage "Functional setup failed on nodeB."

    Write-Host "[testlab] Functional smoke: validating BuddyBackup connectivity"
    foreach ($pair in @(
        @{ Connection = $senderConnection; Plan = $senderPlan; Label = "nodeA-test-connection" },
        @{ Connection = $receiverConnection; Plan = $receiverPlan; Label = "nodeB-test-connection" }
    )) {
        $connectionResult = Invoke-BuddyBackupShellCommand -NodeConnection $pair.Connection -Action "test_connection" -Arguments @($pair.Plan.remoteHost, $pair.Plan.remoteDestinationDataset) -Label $pair.Label -DoExecute:$Execute
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
        $snapshotResult = Invoke-NodeSshCommand -NodeConnection $snapshot.Connection -Command ("zfs snapshot {0}" -f (Convert-ToShellSingleQuoted -Value $snapshot.Snapshot)) -Label $snapshot.Label -DoExecute:$Execute
        Add-ReportAction -Report $report -Result $snapshotResult
        Assert-CommandSucceeded -Result $snapshotResult -FailureMessage "Failed to create source snapshot '$($snapshot.Snapshot)' on node '$($snapshot.Connection.NodeName)'."
    }

    Write-Host "[testlab] Functional smoke: sending remote and local backups"
    foreach ($pair in @(
        @{ Connection = $senderConnection; Type = "remote"; SourceDataset = $senderPlan.sourceDataset; Recursive = "no"; DestinationHost = $senderPlan.remoteHost; DestinationDataset = $senderPlan.remoteDestinationDataset; Uid = $senderPlan.remoteBackupUid; Label = "nodeA-remote-send"; Action = "send_backup" },
        @{ Connection = $senderConnection; Type = "local"; SourceDataset = $senderPlan.sourceDataset; Recursive = "no"; DestinationHost = ""; DestinationDataset = $senderPlan.localBackupDataset; Uid = $senderPlan.localBackupUid; Label = "nodeA-local-send"; Action = "send_local_backup" },
        @{ Connection = $receiverConnection; Type = "remote"; SourceDataset = $receiverPlan.sourceDataset; Recursive = "no"; DestinationHost = $receiverPlan.remoteHost; DestinationDataset = $receiverPlan.remoteDestinationDataset; Uid = $receiverPlan.remoteBackupUid; Label = "nodeB-remote-send"; Action = "send_backup" },
        @{ Connection = $receiverConnection; Type = "local"; SourceDataset = $receiverPlan.sourceDataset; Recursive = "no"; DestinationHost = ""; DestinationDataset = $receiverPlan.localBackupDataset; Uid = $receiverPlan.localBackupUid; Label = "nodeB-local-send"; Action = "send_local_backup" }
    )) {
        $sendArgs = if ($pair.Type -eq "remote") {
            @($pair.SourceDataset, $pair.Recursive, $pair.DestinationHost, $pair.DestinationDataset, $pair.Uid)
        } else {
            @($pair.SourceDataset, $pair.Recursive, $pair.DestinationDataset, $pair.Uid)
        }
        $sendResult = Invoke-BuddyBackupShellCommand -NodeConnection $pair.Connection -Action $pair.Action -Arguments $sendArgs -Label $pair.Label -DoExecute:$Execute
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
        $datasetCheck = Invoke-NodeSshCommand -NodeConnection $check.Connection -Command ("zfs list -H -o name {0}" -f (Convert-ToShellSingleQuoted -Value $check.Dataset)) -Label $check.Label -DoExecute:$Execute
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
        $snapshotResult = Invoke-BuddyBackupShellCommand -NodeConnection $query.Connection -Action "get_available_snapshots" -Arguments $snapshotArgs -Label $query.Key -DoExecute:$Execute
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
        $restoreResult = Invoke-BuddyBackupShellCommand -NodeConnection $restore.Connection -Action "restore_snapshot" -Arguments $restoreArgs -Label $restore.Label -DoExecute:$Execute
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
        $datasetCheck = Invoke-NodeSshCommand -NodeConnection $check.Connection -Command ("zfs list -H -o name {0}" -f (Convert-ToShellSingleQuoted -Value $check.Dataset)) -Label $check.Label -DoExecute:$Execute
        Add-ReportAction -Report $report -Result $datasetCheck
        Assert-CommandSucceeded -Result $datasetCheck -FailureMessage "Expected restore dataset '$($check.Dataset)' was not found on node '$($check.Connection.NodeName)'."
    }

    $report.success = $true
    Write-Host "[testlab] Functional smoke completed successfully"
} catch {
    $report.error = ($_ | Out-String).Trim()
    throw
} finally {
    $report.finishedAt = (Get-Date).ToString("o")
    $report | ConvertTo-Json -Depth 8 | Set-Content -Path $reportPath -Encoding UTF8
    Write-Host "[testlab] Functional smoke report written to $reportPath"
}