param(
    [string]$LabConfig = "testlab/config/lab.local.json",
    [switch]$Execute
)

$ErrorActionPreference = "Stop"

. (Join-Path $PSScriptRoot "unraid-payload-cache.ps1")
. (Join-Path $PSScriptRoot "wsl-common.ps1")

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

function Resolve-NodeConnection {
    param(
        $Lab,
        $Node
    )

    $defaultPort = if ($Lab.ssh -and $Lab.ssh.port) { [int]$Lab.ssh.port } else { 22 }
    $defaultUser = if ($Lab.ssh -and $Lab.ssh.user) { [string]$Lab.ssh.user } else { "root" }
    $defaultIdentityFile = if ($Lab.ssh -and $Lab.ssh.identityFile) { [string]$Lab.ssh.identityFile } else { $null }

    $identityFile = Get-ObjectValue -Object $Node -Name "identityFile"
    return [pscustomobject]@{
        User = if (Get-ObjectValue -Object $Node -Name "user") { [string](Get-ObjectValue -Object $Node -Name "user") } else { $defaultUser }
        Host = [string](Get-ObjectValue -Object $Node -Name "host")
        Port = if (Get-ObjectValue -Object $Node -Name "port") { [int](Get-ObjectValue -Object $Node -Name "port") } else { $defaultPort }
        IdentityFile = if ($identityFile) { [string]$identityFile } else { $defaultIdentityFile }
    }
}

function Test-OutputHasWarningsOrErrors {
    param([string[]]$OutputLines)

    if (-not $OutputLines) {
        return $false
    }

    $joined = ($OutputLines -join [Environment]::NewLine)
    return ($joined -match '(?im)\b(error|warning)\b')
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

    return $cachedPath
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
        Write-Host "[dry-run][setup][$Label] ssh $($sshArgs -join ' ')"
        return [pscustomobject]@{
            label = $Label
            success = $true
            exitCode = 0
            output = @("dry-run")
            warningsOrErrorsDetected = $false
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

    $outputLines = @($rawOutput | ForEach-Object { [string]$_ })
    return [pscustomobject]@{
        label = $Label
        success = ($exitCode -eq 0)
        exitCode = $exitCode
        output = $outputLines
        warningsOrErrorsDetected = (Test-OutputHasWarningsOrErrors -OutputLines $outputLines)
    }
}

function Get-ManualAccessConfig {
    param($Lab)

    $setupCfg = Get-ObjectValue -Object $Lab -Name "setup"
    $manualAccessCfg = Get-ObjectValue -Object $setupCfg -Name "manualAccess"
    $rootPassword = [string](Get-ObjectValue -Object $manualAccessCfg -Name "rootPassword")
    if ([string]::IsNullOrWhiteSpace($rootPassword)) {
        $rootPassword = "buddybackup-testlab"
    }

    return [pscustomobject]@{
        webGuiUser = "root"
        webGuiPassword = $rootPassword
    }
}

function Invoke-NodeManualAccessSetup {
    param(
        $Lab,
        [string]$NodeName,
        $NodeConnection,
        [switch]$DoExecute
    )

    $manualAccess = Get-ManualAccessConfig -Lab $Lab
    $passwordB64 = [Convert]::ToBase64String([System.Text.Encoding]::UTF8.GetBytes([string]$manualAccess.webGuiPassword))
        $manualAccessCommand = ((@'
set -euo pipefail

if ! command -v chpasswd >/dev/null 2>&1; then
    echo "chpasswd is unavailable on this guest" >&2
    exit 1
fi

password="$(printf '%s' '{0}' | base64 -d)"
printf 'root:%s\n' "$password" | chpasswd

if [ -d /boot/config ] && [ -f /etc/shadow ]; then
    cp /etc/shadow /boot/config/shadow 2>/dev/null || true
fi

sync || true

echo "webgui_user=root"
echo "webgui_password_configured=yes"
'@ -f $passwordB64) -replace "`r`n", "`n").Trim()
    $manualAccessResult = Invoke-NodeSshCommand -NodeConnection $NodeConnection -Command $manualAccessCommand -Label "webgui-login-setup" -DoExecute:$DoExecute
    if (-not $manualAccessResult.success) {
                $manualAccessOutput = (($manualAccessResult.output | ForEach-Object { [string]$_ }) -join [Environment]::NewLine).Trim()
                if ([string]::IsNullOrWhiteSpace($manualAccessOutput)) {
                        throw "WebGUI login setup failed on node '$NodeName' with exit code $($manualAccessResult.exitCode)."
                }

                throw "WebGUI login setup failed on node '$NodeName' with exit code $($manualAccessResult.exitCode): $manualAccessOutput"
    }

    return [pscustomobject]@{
        success = $true
        webGuiUser = [string]$manualAccess.webGuiUser
        webGuiPassword = [string]$manualAccess.webGuiPassword
        actions = @($manualAccessResult)
    }
}

function Invoke-NodeBaseSetup {
    param(
        $Lab,
        $Node,
        [string]$NodeName,
        $NodeConnection,
        [string]$PluginVersion,
        [string]$PluginUrlTemplate,
        [switch]$DoExecute
    )

    $setupCfg = Get-ObjectValue -Object $Lab -Name "setup"
    $zfsCfg = Get-ObjectValue -Object $setupCfg -Name "zfs"
    $buddyCfg = Get-ObjectValue -Object $setupCfg -Name "buddybackup"

    $failOnInstallWarnings = $true
    $buddyFailOnWarnings = Get-ObjectValue -Object $buddyCfg -Name "failOnWarningOrError"
    if ($null -ne $buddyFailOnWarnings) {
        $failOnInstallWarnings = [bool]$buddyFailOnWarnings
    }

    $poolName = [string](Get-ObjectValue -Object $zfsCfg -Name "poolName")
    if ([string]::IsNullOrWhiteSpace($poolName)) {
        $poolName = "bbpool"
    }
    $datasetRootName = [string](Get-ObjectValue -Object $zfsCfg -Name "datasetRoot")
    if ([string]::IsNullOrWhiteSpace($datasetRootName)) {
        $datasetRootName = "buddybackup"
    }
    $plainDatasetName = [string](Get-ObjectValue -Object $zfsCfg -Name "unencryptedDatasetName")
    if ([string]::IsNullOrWhiteSpace($plainDatasetName)) {
        $plainDatasetName = "plain"
    }
    $encDatasetName = [string](Get-ObjectValue -Object $zfsCfg -Name "encryptedDatasetName")
    if ([string]::IsNullOrWhiteSpace($encDatasetName)) {
        $encDatasetName = "secure"
    }
    $encryptionPassphrase = [string](Get-ObjectValue -Object $zfsCfg -Name "encryptedPassphrase")
    if ([string]::IsNullOrWhiteSpace($encryptionPassphrase)) {
        $encryptionPassphrase = "buddybackup-testlab-passphrase"
    }

    $datasetRoot = "$poolName/$datasetRootName"
    $plainDataset = "$datasetRoot/$plainDatasetName"
    $encryptedDataset = "$datasetRoot/$encDatasetName"

    $results = @()

    if ([string]::IsNullOrWhiteSpace($PluginVersion)) {
        throw "Missing plugin version for node '$NodeName'. Set nodes.$NodeName.pluginVersion or setup.buddybackup.pluginVersion in lab config."
    }
    if ([string]::IsNullOrWhiteSpace($PluginUrlTemplate)) {
        throw "Missing plugin URL template for BuddyBackup installation on node '$NodeName'."
    }

    $pluginUrl = if ($PluginUrlTemplate -match '\{version\}') {
        $PluginUrlTemplate.Replace("{version}", $PluginVersion)
    } else {
        $PluginUrlTemplate
    }

    $pluginInstallResult = Invoke-NodeSshCommand -NodeConnection $NodeConnection -Command ("plugin install {0}" -f $pluginUrl) -Label "buddybackup-plugin-install" -DoExecute:$DoExecute
    $results += $pluginInstallResult
    if (-not $pluginInstallResult.success) {
        throw "BuddyBackup plugin install failed on node '$NodeName'."
    }
    if ($failOnInstallWarnings -and $pluginInstallResult.warningsOrErrorsDetected) {
        throw "BuddyBackup plugin install output on node '$NodeName' contained warning/error text."
    }

    $pluginVerifyCommand = ((@'
set -eu

if plugin list | grep -i buddybackup >/dev/null 2>&1; then
  plugin list | grep -i buddybackup
  exit 0
fi

if [ -f /boot/config/plugins/buddybackup/buddybackup.txz ] && [ -f /boot/config/plugins/buddybackup/buddybackup.cfg ] && [ -f /usr/local/emhttp/plugins/buddybackup/scripts/rc.buddybackup.php ]; then
  echo "buddybackup verified via installed plugin files"
  exit 0
fi

echo "buddybackup missing from plugin list and expected plugin files were not found" >&2
plugin list || true
ls -la /boot/config/plugins/buddybackup 2>/dev/null || true
ls -la /usr/local/emhttp/plugins/buddybackup/scripts 2>/dev/null || true
exit 1
'@) -replace "`r`n", "`n").Trim()
    $pluginVerifyResult = Invoke-NodeSshCommand -NodeConnection $NodeConnection -Command $pluginVerifyCommand -Label "buddybackup-plugin-verify" -DoExecute:$DoExecute
    $results += $pluginVerifyResult
    if (-not $pluginVerifyResult.success) {
        $pluginVerifyOutput = (($pluginVerifyResult.output | ForEach-Object { [string]$_ }) -join [Environment]::NewLine).Trim()
        if ([string]::IsNullOrWhiteSpace($pluginVerifyOutput)) {
            throw "BuddyBackup plugin verification failed on node '$NodeName'."
        }

        throw "BuddyBackup plugin verification failed on node '$NodeName': $pluginVerifyOutput"
    }

    $passphraseB64 = [Convert]::ToBase64String([System.Text.Encoding]::UTF8.GetBytes($encryptionPassphrase))
    $zfsScript = @'
passphrase_b64="$1"
pool_name="$2"
dataset_root="$3"
plain_dataset="$4"
encrypted_dataset="$5"

set -euo pipefail

if ! command -v zpool >/dev/null 2>&1 || ! command -v zfs >/dev/null 2>&1; then
  echo "zpool/zfs commands are unavailable on this guest" >&2
  exit 1
fi

if command -v modprobe >/dev/null 2>&1; then
    modprobe zfs >/dev/null 2>&1 || true
fi

if command -v udevadm >/dev/null 2>&1; then
    udevadm settle >/dev/null 2>&1 || true
fi

disk_by_id="/dev/disk/by-id/virtio-buddybackup_data"
attempts=15
while [ ! -b "$disk_by_id" ] && [ "$attempts" -gt 0 ]; do
    sleep 2
    attempts=$((attempts - 1))
done

if [ ! -b "$disk_by_id" ]; then
  echo "Expected data disk not found: $disk_by_id" >&2
  ls -la /dev/disk/by-id >&2 || true
  exit 1
fi

if ! zpool list -H -o name "$pool_name" >/dev/null 2>&1; then
  zpool create -f -o ashift=12 "$pool_name" "$disk_by_id"
fi

zpool set autoexpand=on "$pool_name" >/dev/null 2>&1 || true

if [ -f /boot/config/go ] && ! grep -Fq "BuddyBackup testlab: import standalone zpool on every boot" /boot/config/go; then
    cat >> /boot/config/go <<EOF

# BuddyBackup testlab: import standalone zpool on every boot
if command -v modprobe >/dev/null 2>&1; then
    modprobe zfs >/dev/null 2>&1 || true
fi
if command -v udevadm >/dev/null 2>&1; then
    udevadm settle >/dev/null 2>&1 || true
fi
if ! zpool list -H -o name "$pool_name" >/dev/null 2>&1; then
    zpool import -N -d /dev/disk/by-id "$pool_name" >/dev/null 2>&1 || true
fi
zfs mount "$plain_dataset" >/dev/null 2>&1 || true
EOF
fi

if ! zfs list -H -o name "$dataset_root" >/dev/null 2>&1; then
  zfs create -o mountpoint=none "$dataset_root"
fi

if ! zfs list -H -o name "$plain_dataset" >/dev/null 2>&1; then
  zfs create "$plain_dataset"
fi

if ! zfs list -H -o name "$encrypted_dataset" >/dev/null 2>&1; then
  passphrase="$(printf '%s' "$passphrase_b64" | base64 -d)"
  printf '%s\n' "$passphrase" | zfs create -o encryption=aes-256-gcm -o keyformat=passphrase -o keylocation=prompt "$encrypted_dataset"
fi

encryption_value="$(zfs get -H -o value encryption "$encrypted_dataset")"
if [ "$encryption_value" = "off" ]; then
  echo "Encrypted dataset has encryption=off: $encrypted_dataset" >&2
  exit 1
fi

echo "pool=$pool_name"
echo "dataset_root=$dataset_root"
echo "plain_dataset=$plain_dataset"
echo "encrypted_dataset=$encrypted_dataset"
echo "encrypted_dataset_encryption=$encryption_value"
'@
    $zfsScriptNormalized = ($zfsScript -replace "`r`n", "`n").Trim()
    $zfsScriptB64 = [Convert]::ToBase64String([System.Text.Encoding]::UTF8.GetBytes($zfsScriptNormalized))
    $zfsCommand = "printf '%s' '$zfsScriptB64' | base64 -d | bash -s -- '$passphraseB64' '$poolName' '$datasetRoot' '$plainDataset' '$encryptedDataset'"
    $zfsSetupResult = Invoke-NodeSshCommand -NodeConnection $NodeConnection -Command $zfsCommand -Label "zfs-base-setup" -DoExecute:$DoExecute
    $results += $zfsSetupResult
    if (-not $zfsSetupResult.success) {
        $zfsSetupOutput = (($zfsSetupResult.output | ForEach-Object { [string]$_ }) -join [Environment]::NewLine).Trim()
        if ([string]::IsNullOrWhiteSpace($zfsSetupOutput)) {
            throw "ZFS base setup failed on node '$NodeName'."
        }

        throw "ZFS base setup failed on node '$NodeName': $zfsSetupOutput"
    }

    return [pscustomobject]@{
        success = $true
        poolName = $poolName
        datasetRoot = $datasetRoot
        unencryptedDataset = $plainDataset
        encryptedDataset = $encryptedDataset
        pluginVersion = $PluginVersion
        actions = @($results)
    }
}

function Stop-WslLabInstance {
    param(
        [string]$Distro,
        [string]$InstanceName,
        [switch]$DoExecute
    )

    $workRoot = "/tmp/buddybackup-qemu-$InstanceName"
    if (-not $DoExecute) {
        Write-Host "[dry-run] Would stop WSL/QEMU instance '$InstanceName' at $workRoot"
        return
    }

    $stopScript = @'
set -euo pipefail

work_root="$1"
pid_file="$work_root/qemu.pid"

if [ -f "$pid_file" ]; then
  kill "$(cat "$pid_file")" 2>/dev/null || true
fi

pkill -f "$work_root/unraid-boot.img" 2>/dev/null || true
rm -rf "$work_root"
'@

    $stopResult = Invoke-WslRootBash -Distro $Distro -ScriptContent $stopScript -Arguments @($workRoot)
    if ($stopResult.ExitCode -ne 0) {
        throw (("Failed to stop WSL/QEMU instance '{0}' with exit code {1}`n{2}" -f $InstanceName, $stopResult.ExitCode, (($stopResult.Output | ForEach-Object { [string]$_ }) -join [Environment]::NewLine)).Trim())
    }
}

if (-not (Test-Path -LiteralPath $LabConfig)) {
    throw "Missing lab config: $LabConfig"
}

$lab = Get-Json -Path $LabConfig
$wslCfg = $lab.wslQemu
$distro = if ($wslCfg -and $wslCfg.distro) { [string]$wslCfg.distro } else { "Ubuntu" }
$cacheRoot = if ($wslCfg -and $wslCfg.cacheRoot) { [string]$wslCfg.cacheRoot } else { ".testlab/cache" }
$imageSizeMB = if ($wslCfg -and $wslCfg.imageSizeMB) { [int]$wslCfg.imageSizeMB } else { 1024 }
$dataDiskSizeGB = if ($wslCfg -and $wslCfg.dataDiskSizeGB) { [int]$wslCfg.dataDiskSizeGB } else { 3 }
$bootWaitSeconds = if ($wslCfg -and $wslCfg.bootWaitSeconds) { [int]$wslCfg.bootWaitSeconds } else { 120 }
$downloadUrlTemplate = if ($wslCfg -and $wslCfg.unraidDownloadUrlTemplate) { [string]$wslCfg.unraidDownloadUrlTemplate } else { $null }

$setupCfg = Get-ObjectValue -Object $lab -Name "setup"
$applyBaseSetup = $true
$applyBaseSetupConfig = Get-ObjectValue -Object $setupCfg -Name "applyBaseConfigAfterSsh"
if ($null -ne $applyBaseSetupConfig) {
    $applyBaseSetup = [bool]$applyBaseSetupConfig
}

$buddyCfg = Get-ObjectValue -Object $setupCfg -Name "buddybackup"
$defaultPluginVersion = [string](Get-ObjectValue -Object $buddyCfg -Name "pluginVersion")
$defaultPluginUrlTemplate = [string](Get-ObjectValue -Object $buddyCfg -Name "pluginUrlTemplate")
if ([string]::IsNullOrWhiteSpace($defaultPluginUrlTemplate) -and $lab.plugin -and $lab.plugin.plgUrlTemplate) {
    $defaultPluginUrlTemplate = [string]$lab.plugin.plgUrlTemplate
}

$privateKeyPath = if ($wslCfg -and $wslCfg.sshPrivateKeyPath) {
    Resolve-TestLabPath ([string]$wslCfg.sshPrivateKeyPath)
} elseif ($lab.ssh -and $lab.ssh.identityFile) {
    Resolve-TestLabPath ([string]$lab.ssh.identityFile)
} else {
    Resolve-TestLabPath ".testlab/lab_key"
}

$publicKeyPath = if ($wslCfg -and $wslCfg.sshPublicKeyPath) {
    Resolve-TestLabPath ([string]$wslCfg.sshPublicKeyPath)
} else {
    "$privateKeyPath.pub"
}

$logsRoot = if ($lab.logsRoot) { Resolve-TestLabPath ([string]$lab.logsRoot) } else { Resolve-TestLabPath ".testlab/logs" }
$screenshotRoot = if ($wslCfg -and $wslCfg.screenshotRoot) {
    Resolve-TestLabPath ([string]$wslCfg.screenshotRoot)
} else {
    Join-Path $env:LOCALAPPDATA "BuddyBackup\screenshots"
}

Ensure-Dir $logsRoot
Ensure-Dir $screenshotRoot

$runId = Get-Date -Format "yyyyMMdd-HHmmss"
$reportPath = Join-Path $logsRoot ("local-provider-{0}.json" -f $runId)
$probeScript = Join-Path $PSScriptRoot "probe-wsl-qemu-unraid.ps1"

$report = [ordered]@{
    runId       = $runId
    provider    = "windows-local"
    executeMode = [bool]$Execute
    success     = $false
    error       = $null
    nodes       = @()
}

$startedInstances = @()

try {
    foreach ($entry in @(
        @{ NodeName = "sender"; DefaultPort = 2222; DefaultHttpPort = 8080; DefaultHttpsPort = 8443 },
        @{ NodeName = "receiver"; DefaultPort = 2223; DefaultHttpPort = 8081; DefaultHttpsPort = 8444 }
    )) {
        $nodeName = [string]$entry["NodeName"]
        $defaultPort = [int]$entry["DefaultPort"]
        $defaultHttpPort = [int]$entry["DefaultHttpPort"]
        $defaultHttpsPort = [int]$entry["DefaultHttpsPort"]
        $node = Get-ObjectValue -Object $lab.nodes -Name $nodeName
        if (-not $node) {
            continue
        }

        $nodeHost = Get-ObjectValue -Object $node -Name "host"
        if ($nodeHost -and ([string]$nodeHost) -notin @("127.0.0.1", "localhost")) {
            throw "lab.nodes.$nodeName.host must be 127.0.0.1 or localhost for the windows-local WSL/QEMU provider."
        }

        $version = [string](Get-ObjectValue -Object $node -Name "unraidVersion")
        if ([string]::IsNullOrWhiteSpace($version)) {
            throw "Missing lab.nodes.$nodeName.unraidVersion"
        }

        $desiredPortValue = Get-ObjectValue -Object $node -Name "port"
        $desiredPort = if ($desiredPortValue) { [int]$desiredPortValue } else { $defaultPort }
        $desiredHttpPortValue = Get-ObjectValue -Object $node -Name "webGuiHttpPort"
        $desiredHttpPort = if ($desiredHttpPortValue) { [int]$desiredHttpPortValue } else { $defaultHttpPort }
        $desiredHttpsPortValue = Get-ObjectValue -Object $node -Name "webGuiHttpsPort"
        $desiredHttpsPort = if ($desiredHttpsPortValue) { [int]$desiredHttpsPortValue } else { $defaultHttpsPort }
        $instanceNameValue = Get-ObjectValue -Object $node -Name "instanceName"
        $instanceName = if ($instanceNameValue) { [string]$instanceNameValue } else { "lab-$nodeName" }
        if ($instanceName -notmatch '^[A-Za-z0-9._-]+$') {
            throw "Invalid instance name '$instanceName' for node '$nodeName'. Use only letters, digits, dots, underscores, and hyphens."
        }

        $nodePayloadPath = Get-ObjectValue -Object $node -Name "payloadPath"
        $nodeNameValue = Get-ObjectValue -Object $node -Name "name"
        $nodePluginVersion = [string](Get-ObjectValue -Object $node -Name "pluginVersion")
        $nodePluginUrlTemplate = [string](Get-ObjectValue -Object $node -Name "pluginUrlTemplate")
        if ([string]::IsNullOrWhiteSpace($nodePluginUrlTemplate)) {
            $nodePluginUrlTemplate = $defaultPluginUrlTemplate
        }
        $pluginVersion = if ($nodePluginVersion) { $nodePluginVersion } else { $defaultPluginVersion }

        $nodeConnection = Resolve-NodeConnection -Lab $lab -Node $node

        Write-Host "[testlab] Preparing local node $nodeName (Unraid $version, SSH localhost:$desiredPort)"

        $payloadPath = if ($nodePayloadPath) {
            Resolve-TestLabPath ([string]$nodePayloadPath)
        } elseif ($wslCfg -and $wslCfg.payloadPath) {
            Resolve-TestLabPath ([string]$wslCfg.payloadPath)
        } else {
            Ensure-UnraidPayload -Version $version -CacheRoot $cacheRoot -UrlTemplate $downloadUrlTemplate -DoExecute:$Execute
        }

        Write-Host ("[testlab] Payload for {0}: {1}" -f $nodeName, $payloadPath)

        if ($Execute) {
            if (-not (Test-Path -LiteralPath $privateKeyPath)) {
                throw "SSH private key not found: $privateKeyPath"
            }
            if (-not (Test-Path -LiteralPath $publicKeyPath)) {
                throw "SSH public key not found: $publicKeyPath"
            }
            if (-not (Test-UnraidPayloadRoot -Path $payloadPath)) {
                throw "Unraid payload is missing required files for node '$nodeName': $payloadPath"
            }
        }

        $outputPath = Join-Path $screenshotRoot ("qemu-unraid-{0}-{1}.png" -f $nodeName, $runId)
        $statusPath = [System.IO.Path]::ChangeExtension($outputPath, ".json")
        $nodeEntry = [ordered]@{
            node                = $nodeName
            name                = if ($nodeNameValue) { [string]$nodeNameValue } else { "buddybackup-$nodeName" }
            host                = "127.0.0.1"
            port                = $desiredPort
            unraidVersion       = $version
            payloadPath         = $payloadPath
            instanceName        = $instanceName
            pluginVersion       = $pluginVersion
            outputPath          = $outputPath
            statusPath          = $statusPath
            sshReady            = $false
            selectedHostSshPort = $null
            selectedHostHttpPort = $desiredHttpPort
            selectedHostHttpsPort = $desiredHttpsPort
            webGuiHttpUrl       = "http://127.0.0.1:$desiredHttpPort"
            webGuiHttpsUrl      = "https://127.0.0.1:$desiredHttpsPort"
            monitorSocketPath   = "/tmp/buddybackup-qemu-$instanceName/qemu-monitor.sock"
            serialLogPath       = "/tmp/buddybackup-qemu-$instanceName/unraid-serial.log"
            wslWorkingRoot      = "/tmp/buddybackup-qemu-$instanceName"
            dataDiskSizeGB      = $dataDiskSizeGB
            manualAccess        = $null
            baseSetupApplied    = $false
            baseSetup           = $null
        }

        if ($Execute) {
            Write-Host "[testlab] Resetting local instance '$instanceName' for $nodeName"
            Stop-WslLabInstance -Distro $distro -InstanceName $instanceName -DoExecute

            Write-Host "[testlab] Starting WSL/QEMU probe for $nodeName (boot wait ${bootWaitSeconds}s)"
            & $probeScript -Distro $distro -PayloadPath $payloadPath -SshPublicKeyPath $publicKeyPath -SshPrivateKeyPath $privateKeyPath -ImageSizeMB $imageSizeMB -DataDiskSizeGB $dataDiskSizeGB -BootWaitSeconds $bootWaitSeconds -HostSshPort $desiredPort -HostHttpPort $desiredHttpPort -HostHttpsPort $desiredHttpsPort -OutputPath $outputPath -StatusPath $statusPath -InstanceName $instanceName -LeaveRunning

            if (-not (Test-Path -LiteralPath $statusPath)) {
                throw "Probe status file was not written for node '$nodeName': $statusPath"
            }

            $nodeStatus = Get-Json -Path $statusPath
            $nodeEntry.sshReady = [bool]$nodeStatus.sshReady
            $nodeEntry.selectedHostSshPort = [int]$nodeStatus.selectedHostSshPort
            $nodeEntry.selectedHostHttpPort = [int]$nodeStatus.selectedHostHttpPort
            $nodeEntry.selectedHostHttpsPort = [int]$nodeStatus.selectedHostHttpsPort
            $nodeEntry.webGuiHttpUrl = [string]$nodeStatus.webGuiHttpUrl
            $nodeEntry.webGuiHttpsUrl = [string]$nodeStatus.webGuiHttpsUrl
            $nodeEntry.monitorSocketPath = [string]$nodeStatus.monitorSocketPath
            $nodeEntry.serialLogPath = [string]$nodeStatus.serialLogPath
            $nodeEntry.wslWorkingRoot = [string]$nodeStatus.wslWorkingRoot
            $nodeEntry.dataDiskPath = [string]$nodeStatus.dataDiskPath

            if (-not $nodeStatus.success) {
                throw "WSL/QEMU probe failed for node '$nodeName': $($nodeStatus.error)"
            }
            if (-not $nodeStatus.sshReady) {
                throw "WSL/QEMU probe did not reach SSH readiness for node '$nodeName'."
            }
            if ([int]$nodeStatus.selectedHostSshPort -ne $desiredPort) {
                throw "Configured host SSH port $desiredPort for node '$nodeName' is busy; the probe fell back to $($nodeStatus.selectedHostSshPort). Update the lab config or free the configured port."
            }

            $startedInstances += $instanceName
            Write-Host "[testlab] Configuring manual WebGUI access on $nodeName"
            $manualAccess = Invoke-NodeManualAccessSetup -Lab $lab -NodeName $nodeName -NodeConnection $nodeConnection -DoExecute
            $nodeEntry.manualAccess = $manualAccess

            if ($applyBaseSetup) {
                Write-Host "[testlab] Applying BuddyBackup and ZFS base setup on $nodeName"
                $baseSetup = Invoke-NodeBaseSetup -Lab $lab -Node $node -NodeName $nodeName -NodeConnection $nodeConnection -PluginVersion $pluginVersion -PluginUrlTemplate $nodePluginUrlTemplate -DoExecute
                $nodeEntry.baseSetupApplied = $true
                $nodeEntry.baseSetup = $baseSetup
            }

            Write-Host "[testlab] Local node $nodeName ready on 127.0.0.1:$desiredPort"
            Write-Host "[testlab] $nodeName WebGUI HTTP: $($nodeEntry.webGuiHttpUrl)"
            Write-Host "[testlab] $nodeName WebGUI HTTPS: $($nodeEntry.webGuiHttpsUrl)"
            Write-Host "[testlab] $nodeName WebGUI login: $($manualAccess.webGuiUser) / $($manualAccess.webGuiPassword)"
        } else {
            Write-Host "[dry-run] Would start local node $nodeName on 127.0.0.1:$desiredPort from payload $payloadPath"
            $nodeEntry.sshReady = $true
            $nodeEntry.selectedHostSshPort = $desiredPort
            $nodeEntry.manualAccess = Invoke-NodeManualAccessSetup -Lab $lab -NodeName $nodeName -NodeConnection $nodeConnection -DoExecute:$false
            if ($applyBaseSetup) {
                $nodeEntry.baseSetupApplied = $true
                $nodeEntry.baseSetup = Invoke-NodeBaseSetup -Lab $lab -Node $node -NodeName $nodeName -NodeConnection $nodeConnection -PluginVersion $pluginVersion -PluginUrlTemplate $nodePluginUrlTemplate -DoExecute:$false
            }
        }

        $report.nodes += [pscustomobject]$nodeEntry
    }

    $report.success = $true
} catch {
    $report.error = ($_ | Out-String).Trim()
    if ($Execute) {
        foreach ($instanceName in $startedInstances) {
            try {
                Stop-WslLabInstance -Distro $distro -InstanceName $instanceName -DoExecute
            } catch {
                Write-Host "[testlab] WARNING: failed to stop instance '$instanceName' during cleanup: $($_.Exception.Message)"
            }
        }
    }
    throw
} finally {
    $report.finishedAt = (Get-Date).ToString("o")
    $report | ConvertTo-Json -Depth 8 | Set-Content -Path $reportPath -Encoding UTF8
    Write-Host "[testlab] Local provider report written to $reportPath"
}