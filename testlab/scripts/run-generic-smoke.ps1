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

function Get-GenericTestConfig {
    param($Lab)

    $setupCfg = Get-ObjectValue -Object $Lab -Name "setup"
    $functionalCfg = Get-ObjectValue -Object $setupCfg -Name "functionalTests"

    $hostGatewayIp = [string](Get-ObjectValue -Object $functionalCfg -Name "hostGatewayIp")
    if ([string]::IsNullOrWhiteSpace($hostGatewayIp)) {
        $hostGatewayIp = "10.0.2.2"
    }

    $nodeCAliasIp = [string](Get-ObjectValue -Object $functionalCfg -Name "nodeCAliasIp")
    if ([string]::IsNullOrWhiteSpace($nodeCAliasIp)) {
        $nodeCAliasIp = "10.254.0.24"
    }

    $genericUser = [string](Get-ObjectValue -Object $functionalCfg -Name "genericUser")
    if ([string]::IsNullOrWhiteSpace($genericUser)) {
        $genericUser = "buddybackup"
    }

    $genericSshPort = [string](Get-ObjectValue -Object $functionalCfg -Name "genericSshPort")
    if ([string]::IsNullOrWhiteSpace($genericSshPort)) {
        $genericSshPort = "22"
    }

    $allowUnencryptedRemoteBackups = "yes"
    $allowUnencryptedValue = Get-ObjectValue -Object $functionalCfg -Name "allowUnencryptedRemoteBackups"
    if ($null -ne $allowUnencryptedValue) {
        $allowUnencryptedRemoteBackups = if ([bool]$allowUnencryptedValue) { "yes" } else { "no" }
    }

    return [pscustomobject]@{
        hostGatewayIp = $hostGatewayIp
        nodeCAliasIp = $nodeCAliasIp
        genericUser = $genericUser
        genericSshPort = $genericSshPort
        allowUnencryptedRemoteBackups = $allowUnencryptedRemoteBackups
    }
}

function Get-NodeConnection {
    param(
        $Lab,
        [string]$NodeName
    )

    $node = Get-ObjectValue -Object (Get-ObjectValue -Object $Lab -Name 'nodes') -NodeName $NodeName
    if (-not $node -or -not (Get-ObjectValue -Object $node -Name "host")) {
        throw "Missing lab.nodes.$NodeName.host"
    }

    $defaultPort = if ($Lab.ssh -and $Lab.ssh.port) { [int]$Lab.ssh.port } else { 22 }
    $defaultUser = if ($Lab.ssh -and $Lab.ssh.user) { [string]$Lab.ssh.user } else { "root" }
    $defaultIdentityFile = if ($Lab.ssh -and $Lab.ssh.identityFile) { [string]$Lab.ssh.identityFile } else { $null }

    $identityFile = Get-ObjectValue -Object $node -Name "identityFile"
    return [pscustomobject]@{
        NodeName = $NodeName
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

function Test-IsTransientSshFailure {
    param($Result)

    if ($null -eq $Result) {
        return $false
    }

    if ([int]$Result.exitCode -ne 255) {
        return $false
    }

    $outputText = (@($Result.output | ForEach-Object { [string]$_ }) -join "`n").Trim()
    if ([string]::IsNullOrWhiteSpace($outputText)) {
        return $true
    }

    return $outputText -match '(?i)connection closed by remote host|connection refused|operation timed out|connection timed out|broken pipe'
}

function Invoke-NodeBashScriptWithRetry {
    param(
        $NodeConnection,
        [string]$ScriptContent,
        [string[]]$Arguments,
        [string]$Label,
        [int]$MaxAttempts = 4,
        [int]$RetryDelaySeconds = 10,
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

function Add-ReportAction {
    param(
        $Report,
        $Result
    )

    $action = [ordered]@{
        node = $Result.node
        label = $Result.label
        success = [bool]$Result.success
        exitCode = [int]$Result.exitCode
        command = [string]$Result.command
        output = @($Result.output)
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

function Get-ResultOutputText {
    param($Result)

    if ($null -eq $Result) {
        return ""
    }

    return (@($Result.output | ForEach-Object { [string]$_ }) -join "`n").Trim()
}

function Test-GenericConnectionOutput {
    param(
        [string[]]$Output,
        [string]$NodeName
    )

    $joined = ($Output -join [Environment]::NewLine)
    if ($joined -notmatch 'Success!') {
        throw "BuddyBackup generic test_connection did not report success on node '$NodeName'.`n$joined"
    }

    if ($joined -match 'security validation failed') {
        throw "BuddyBackup generic test_connection reported an SSH security validation problem on node '$NodeName'.`n$joined"
    }
}

function Test-GenericSendOutput {
    param(
        [string[]]$Output,
        [string]$Flow,
        [string]$NodeName
    )

    $joined = ($Output -join [Environment]::NewLine)
    if ($joined -match 'Aborting backup\.' -or $joined -match 'Sending backup failed\.' -or $joined -match 'Pulling backup failed\.') {
        throw "BuddyBackup generic $Flow reported a failure on node '$NodeName'.`n$joined"
    }

    $successMarker = if ($Flow -eq "push") { "Successfully synced backup to buddy!" } else { "Successfully pulled backup from" }
    if ($joined -notmatch [regex]::Escape($successMarker)) {
        throw "BuddyBackup generic $Flow did not report success on node '$NodeName'.`n$joined"
    }
}

function New-GenericNodePrepScript {
    $script = @'
pool="$1"
dataset_root="$2"
snapshot_name="$3"

set -euo pipefail

if ! zpool list -H -o name "$pool" >/dev/null 2>&1; then
    echo "ERROR: zpool '$pool' does not exist on the generic node." >&2
    exit 1
fi

source_dataset="${pool}/${dataset_root}/generic-source"
if zfs list -H -o name "$source_dataset" >/dev/null 2>&1; then
    zfs destroy -r "$source_dataset"
fi

if ! zfs list -H -o name "${pool}/${dataset_root}" >/dev/null 2>&1; then
    zfs create -o mountpoint=none "${pool}/${dataset_root}"
fi

zfs create -o mountpoint=/mnt/buddybackup-generic-source "$source_dataset"
printf 'node=generic\nstage=generic-smoke\n' > /mnt/buddybackup-generic-source/payload.txt
sync || true

existing_snapshot=$(zfs list -H -o name "$source_dataset@$snapshot_name" 2>/dev/null || true)
if [ -z "$existing_snapshot" ]; then
    zfs snapshot "$source_dataset@$snapshot_name"
fi

echo "generic_source_dataset=${source_dataset}"
echo "generic_snapshot=${source_dataset}@${snapshot_name}"
'@
    return $script
}

function New-UnraidGenericSetupScript {
    $script = @'
node_name="$1"
source_dataset="$2"
source_mountpoint="$3"
push_destination_dataset="$4"
pull_destination_dataset="$5"
restore_destination_dataset="$6"
generic_host="${7}"
generic_user="${8}"
generic_port="${9}"
allow_unencrypted="${10}"
peer_public_key="${11}"
host_gateway_ip="${12}"
peer_port="${13}"
peer_alias_ip="${14}"
push_uid="${15}"
pull_uid="${16}"
generic_source_dataset="${17}"

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

for dataset in "$source_dataset" "$pull_destination_dataset" "$restore_destination_dataset"; do
  ensure_dataset_absent "$dataset"
done

mkdir -p "$source_mountpoint"
zfs create -o mountpoint="$source_mountpoint" "$source_dataset"
printf 'node=%s\nstage=generic-smoke\n' "$node_name" > "$source_mountpoint/payload.txt"
sync || true

touch "$plugin_cfg"

set_ini_value "AllowUnencryptedRemoteBackups" "$allow_unencrypted" "$plugin_cfg"

cat > "$backups_cfg" <<EOF
[${push_uid}]
enable="yes"
source_dataset="${source_dataset}"
recursive="no"
backup_cron="0 0 * * *"
type="remote_generic"
destination_host="${generic_host}"
destination_dataset="${push_destination_dataset}"
destination_user="${generic_user}"
destination_port="22"

[${pull_uid}]
enable="yes"
source_dataset="${generic_source_dataset}"
recursive="no"
backup_cron="0 0 * * *"
type="remote_pull"
source_host="${generic_host}"
source_user="${generic_user}"
source_port="22"
destination_host=""
destination_dataset="${pull_destination_dataset}"
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

echo "configured_node=${node_name}"
echo "configured_generic_host=${generic_host}"
'@
    return $script
}

$resolvedLabConfig = Resolve-TestLabPath $LabConfig
if (-not (Test-Path -LiteralPath $resolvedLabConfig)) {
    throw "Missing lab config: $resolvedLabConfig"
}

$lab = Get-Json -Path $resolvedLabConfig
$zfsValues = Get-SetupZfsValues -Lab $lab
$genericCfg = Get-GenericTestConfig -Lab $lab
$unraidConnection = Get-NodeConnection -Lab $lab -NodeName "nodeA"
$genericConnection = Get-NodeConnection -Lab $lab -NodeName "nodeC"

$genericNodeCfg = Get-ObjectValue -Object (Get-ObjectValue -Object $lab -Name 'nodes') -NodeName 'nodeC'
$genericPool = [string](Get-ObjectValue -Object $genericNodeCfg -Name "zfsPool")
if ([string]::IsNullOrWhiteSpace($genericPool)) {
    $genericPool = $zfsValues.PoolName
}
$genericDatasetRootName = [string](Get-ObjectValue -Object $genericNodeCfg -Name "datasetRoot")
if ([string]::IsNullOrWhiteSpace($genericDatasetRootName)) {
    $genericDatasetRootName = [string](Get-ObjectValue -Object (Get-ObjectValue -Object $lab -Name 'setup') -Name 'datasetRoot')
}
if ([string]::IsNullOrWhiteSpace($genericDatasetRootName)) {
    $genericDatasetRootName = "buddybackup"
}
$genericDatasetRoot = "$genericPool/$genericDatasetRootName"

$genericSourceDataset = "$genericDatasetRoot/generic-source"
$genericReceiveParent = "$genericDatasetRoot/generic-receive"
$pushDestinationDataset = "$genericReceiveParent/from-nodeA"
$unraidGenericRoot = "$($zfsValues.DatasetRoot)/generic"
$unraidSourceDataset = "$unraidGenericRoot/nodeA-source"
$unraidSourceMountpoint = "/mnt/buddybackup-generic/nodeA-source"
$pullDestinationDataset = "$unraidGenericRoot/nodeA-pull"
$restoreDestinationDataset = "$unraidGenericRoot/nodeA-restore"
$pushUid = "agen0001"
$pullUid = "apul0001"

$logsRoot = if ($lab.logsRoot) { Resolve-TestLabPath ([string]$lab.logsRoot) } else { Resolve-TestLabPath ".testlab/logs" }
Ensure-Dir $logsRoot
$runId = Get-Date -Format "yyyyMMdd-HHmmss"
$reportPath = Join-Path $logsRoot ("generic-smoke-{0}.json" -f $runId)
$snapshotRunId = $runId.Replace("-", "_")
$genericSnapshotName = "generic_smoke_${snapshotRunId}"

$setupScriptPath = Resolve-TestLabPath "src/usr/local/emhttp/plugins/buddybackup/deps/generic_host_setup.sh"
if (-not (Test-Path -LiteralPath $setupScriptPath)) {
    throw "generic_host_setup.sh not found at $setupScriptPath"
}
$setupScriptContent = Get-Content -Raw -Path $setupScriptPath

$report = [ordered]@{
    runId = $runId
    executeMode = [bool]$Execute
    success = $false
    error = $null
    reportPath = $reportPath
    nodes = @(
        [pscustomobject]@{ node = "nodeA"; role = "unraid"; sshPort = $unraidConnection.Port },
        [pscustomobject]@{ node = "nodeC"; role = "generic"; sshPort = $genericConnection.Port }
    )
    actions = @()
}

try {
    Write-Host "[testlab] Generic smoke starting: nodeA localhost:$($unraidConnection.Port), nodeC localhost:$($genericConnection.Port)"

    Write-Host "[testlab] Generic smoke: preparing datasets and snapshot on nodeC"
    $genericPrep = Invoke-NodeBashScriptWithRetry -NodeConnection $genericConnection -ScriptContent (New-GenericNodePrepScript) -Arguments @(
        $genericPool,
        $genericDatasetRootName,
        $genericSnapshotName
    ) -Label "nodeC-prep" -MaxAttempts 4 -RetryDelaySeconds 10 -DoExecute:$Execute
    Add-ReportAction -Report $report -Result $genericPrep
    Assert-CommandSucceeded -Result $genericPrep -FailureMessage "Generic node preparation failed on nodeC."

    Write-Host "[testlab] Generic smoke: reading BuddyBackup public key from nodeA"
    $keyResult = Invoke-NodeSshCommand -NodeConnection $unraidConnection -Command "cat /boot/config/plugins/buddybackup/buddybackup_sender_key.pub" -Label "read-buddybackup-public-key" -DoExecute:$Execute
    Add-ReportAction -Report $report -Result $keyResult
    Assert-CommandSucceeded -Result $keyResult -FailureMessage "Failed to read BuddyBackup public key on nodeA."
    $unraidPublicKey = (($keyResult.output | ForEach-Object { [string]$_ }) -join "`n").Trim()

    Write-Host "[testlab] Generic smoke: running generic_host_setup.sh receiver role on nodeC"
    $receiverSetup = Invoke-NodeBashScriptWithRetry -NodeConnection $genericConnection -ScriptContent $setupScriptContent -Arguments @(
        "--role", "receiver",
        "--user", $genericCfg.genericUser,
        "--dataset", $genericReceiveParent,
        "--port", $genericCfg.genericSshPort,
        "--pubkey", $unraidPublicKey
    ) -Label "nodeC-generic-setup-receiver" -MaxAttempts 2 -DoExecute:$Execute
    Add-ReportAction -Report $report -Result $receiverSetup
    Assert-CommandSucceeded -Result $receiverSetup -FailureMessage "generic_host_setup.sh receiver role failed on nodeC."

    Write-Host "[testlab] Generic smoke: running generic_host_setup.sh sender role on nodeC"
    $senderSetup = Invoke-NodeBashScriptWithRetry -NodeConnection $genericConnection -ScriptContent $setupScriptContent -Arguments @(
        "--role", "sender",
        "--user", $genericCfg.genericUser,
        "--dataset", $genericSourceDataset,
        "--port", $genericCfg.genericSshPort,
        "--pubkey", $unraidPublicKey
    ) -Label "nodeC-generic-setup-sender" -MaxAttempts 2 -DoExecute:$Execute
    Add-ReportAction -Report $report -Result $senderSetup
    Assert-CommandSucceeded -Result $senderSetup -FailureMessage "generic_host_setup.sh sender role failed on nodeC."

    Write-Host "[testlab] Generic smoke: preparing nodeA backup entries"
    $unraidSetup = Invoke-NodeBashScriptWithRetry -NodeConnection $unraidConnection -ScriptContent (New-UnraidGenericSetupScript) -Arguments @(
        "nodeA",
        $unraidSourceDataset,
        $unraidSourceMountpoint,
        $pushDestinationDataset,
        $pullDestinationDataset,
        $restoreDestinationDataset,
        $genericCfg.nodeCAliasIp,
        $genericCfg.genericUser,
        $genericCfg.genericSshPort,
        $genericCfg.allowUnencryptedRemoteBackups,
        $unraidPublicKey,
        $genericCfg.hostGatewayIp,
        [string]$genericConnection.Port,
        $genericCfg.nodeCAliasIp,
        $pushUid,
        $pullUid,
        $genericSourceDataset
    ) -Label "nodeA-generic-setup" -MaxAttempts 4 -RetryDelaySeconds 10 -DoExecute:$Execute
    Add-ReportAction -Report $report -Result $unraidSetup
    Assert-CommandSucceeded -Result $unraidSetup -FailureMessage "Unraid nodeA generic setup failed."
    $unraidSourceSnapshot = "$unraidSourceDataset@generic_smoke_${snapshotRunId}"

    Write-Host "[testlab] Generic smoke: testing generic push connection from nodeA"
    $pushConnection = Invoke-BuddyBackupShellCommand -NodeConnection $unraidConnection -Action "test_generic_connection" -Arguments @(
        $genericCfg.nodeCAliasIp, $genericCfg.genericUser, "22", $pushDestinationDataset, "push"
    ) -Label "nodeA-generic-push-test-connection" -DoExecute:$Execute
    Add-ReportAction -Report $report -Result $pushConnection
    Assert-CommandSucceeded -Result $pushConnection -FailureMessage "BuddyBackup test_generic_connection (push) failed on nodeA."
    if ($Execute) {
        Test-GenericConnectionOutput -Output $pushConnection.output -NodeName "nodeA"
    }

    Write-Host "[testlab] Generic smoke: testing generic pull connection from nodeA"
    $pullConnection = Invoke-BuddyBackupShellCommand -NodeConnection $unraidConnection -Action "test_generic_connection" -Arguments @(
        $genericCfg.nodeCAliasIp, $genericCfg.genericUser, "22", $genericSourceDataset, "pull"
    ) -Label "nodeA-generic-pull-test-connection" -DoExecute:$Execute
    Add-ReportAction -Report $report -Result $pullConnection
    Assert-CommandSucceeded -Result $pullConnection -FailureMessage "BuddyBackup test_generic_connection (pull) failed on nodeA."
    if ($Execute) {
        Test-GenericConnectionOutput -Output $pullConnection.output -NodeName "nodeA"
    }

    Write-Host "[testlab] Generic smoke: creating nodeA source snapshot"
    $unraidSnapshot = Invoke-NodeSshCommand -NodeConnection $unraidConnection -Command ("zfs snapshot {0}" -f (Convert-ToShellSingleQuoted -Value $unraidSourceSnapshot)) -Label "nodeA-create-source-snapshot" -DoExecute:$Execute
    Add-ReportAction -Report $report -Result $unraidSnapshot
    Assert-CommandSucceeded -Result $unraidSnapshot -FailureMessage "Failed to create source snapshot on nodeA."

    Write-Host "[testlab] Generic smoke: pushing backup from nodeA to nodeC"
    $pushResult = Invoke-BuddyBackupShellCommandWithRetry -NodeConnection $unraidConnection -Action "send_backup" -Arguments @(
        "remote_generic", $unraidSourceDataset, "no", $genericCfg.nodeCAliasIp, $pushDestinationDataset, $pushUid, $genericCfg.genericUser, "22"
    ) -Label "nodeA-generic-push" -DoExecute:$Execute
    Add-ReportAction -Report $report -Result $pushResult
    Assert-CommandSucceeded -Result $pushResult -FailureMessage "Generic push failed for uid '$pushUid' on nodeA."
    if ($Execute) {
        Test-GenericSendOutput -Output $pushResult.output -Flow "push" -NodeName "nodeA"
    }

    Write-Host "[testlab] Generic smoke: pulling backup from nodeC to nodeA"
    $pullResult = Invoke-BuddyBackupShellCommand -NodeConnection $unraidConnection -Action "pull_backup" -Arguments @(
        $genericCfg.nodeCAliasIp, $genericCfg.genericUser, "22", $genericSourceDataset, "no", $pullDestinationDataset, $pullUid
    ) -Label "nodeA-generic-pull" -DoExecute:$Execute
    Add-ReportAction -Report $report -Result $pullResult
    Assert-CommandSucceeded -Result $pullResult -FailureMessage "Generic pull failed for uid '$pullUid' on nodeA."
    if ($Execute) {
        Test-GenericSendOutput -Output $pullResult.output -Flow "pull" -NodeName "nodeA"
    }

    Write-Host "[testlab] Generic smoke: verifying pushed and pulled datasets"
    foreach ($check in @(
        @{ Connection = $genericConnection; Dataset = $pushDestinationDataset; Label = "nodeC-pushed-dataset-check" },
        @{ Connection = $unraidConnection; Dataset = $pullDestinationDataset; Label = "nodeA-pulled-dataset-check" }
    )) {
        $datasetCheck = Invoke-NodeSshCommand -NodeConnection $check.Connection -Command ("zfs list -H -o name {0}" -f (Convert-ToShellSingleQuoted -Value $check.Dataset)) -Label $check.Label -DoExecute:$Execute
        Add-ReportAction -Report $report -Result $datasetCheck
        Assert-CommandSucceeded -Result $datasetCheck -FailureMessage "Expected dataset '$($check.Dataset)' was not found on node '$($check.Connection.NodeName)'."
    }

    $remoteSnapshotSelection = $null
    Write-Host "[testlab] Generic smoke: listing pushed snapshots on the generic receiver"
    $remoteSnapshotList = Invoke-BuddyBackupShellCommand -NodeConnection $unraidConnection -Action "get_available_snapshots" -Arguments @(
        "remote_generic", $genericCfg.nodeCAliasIp, $pushDestinationDataset, $genericCfg.genericUser, "22"
    ) -Label "nodeA-generic-remote-snapshots" -DoExecute:$Execute
    Add-ReportAction -Report $report -Result $remoteSnapshotList
    Assert-CommandSucceeded -Result $remoteSnapshotList -FailureMessage "Snapshot listing failed for the remote_generic uid on nodeA."
    if ($Execute) {
        $snapshotJson = (($remoteSnapshotList.output -join "`n").Trim()) | ConvertFrom-Json
        if ($snapshotJson.status -ne "ok") {
            throw "Snapshot listing for the remote_generic uid failed: $($snapshotJson.error)"
        }
        $firstDataset = @($snapshotJson.data.PSObject.Properties)[0]
        if (-not $firstDataset) {
            throw "Snapshot listing for the remote_generic uid returned no datasets."
        }
        $newestSnapshot = @($firstDataset.Value.PSObject.Properties) |
            Sort-Object -Property @{ Expression = { [long]($_.Value.creation) } } -Descending |
            Select-Object -First 1
        if (-not $newestSnapshot) {
            throw "Snapshot listing for the remote_generic uid returned no snapshots."
        }
        $remoteSnapshotSelection = [pscustomobject]@{
            dataset = [string]$firstDataset.Name
            snapshot = [string]$newestSnapshot.Name
        }
    }

    Write-Host "[testlab] Generic smoke: restoring a pushed snapshot back to nodeA"
    if ($Execute -and $remoteSnapshotSelection) {
        $restoreResult = Invoke-BuddyBackupShellCommand -NodeConnection $unraidConnection -Action "restore_snapshot" -Arguments @(
            "remote_generic", $genericCfg.nodeCAliasIp, "selected", $remoteSnapshotSelection.snapshot, $remoteSnapshotSelection.dataset, $restoreDestinationDataset, "nchan", $genericCfg.genericUser, "22"
        ) -Label "nodeA-generic-restore" -DoExecute:$Execute
        Add-ReportAction -Report $report -Result $restoreResult
        Assert-CommandSucceeded -Result $restoreResult -FailureMessage "Generic restore failed on nodeA."

        $restoreCheck = Invoke-NodeSshCommand -NodeConnection $unraidConnection -Command ("zfs list -H -o name {0}" -f (Convert-ToShellSingleQuoted -Value $restoreDestinationDataset)) -Label "nodeA-restore-dataset-check" -DoExecute:$Execute
        Add-ReportAction -Report $report -Result $restoreCheck
        Assert-CommandSucceeded -Result $restoreCheck -FailureMessage "Expected restore dataset '$restoreDestinationDataset' was not found on nodeA."
    } elseif (-not $Execute) {
        Write-Host "[dry-run] restore_snapshot remote_generic ..."
    }

    $report.success = $true
    Write-Host "[testlab] Generic smoke completed successfully"
} catch {
    $report.error = ($_ | Out-String).Trim()
    throw
} finally {
    $report.finishedAt = (Get-Date).ToString("o")
    $report | ConvertTo-Json -Depth 8 | Set-Content -Path $reportPath -Encoding UTF8
    Write-Host "[testlab] Generic smoke report written to $reportPath"
}
