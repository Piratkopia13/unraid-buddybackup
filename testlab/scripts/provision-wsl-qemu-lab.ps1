param(
    [string]$LabConfig = "testlab/config/lab.local.json",
    [switch]$Execute
)

$ErrorActionPreference = "Stop"

. (Join-Path $PSScriptRoot "unraid-payload-cache.ps1")
. (Join-Path $PSScriptRoot "wsl-common.ps1")
. (Join-Path $PSScriptRoot "testlab-plugin-source.ps1")

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

function Get-WslUnraidDownloadUrl {
    param(
        $WslConfig,
        [string]$Version
    )

    if ($null -eq $WslConfig) {
        return $null
    }

    $versionUrls = Get-ObjectValue -Object $WslConfig -Name "unraidDownloadUrls"
    $versionUrl = [string](Get-ObjectValue -Object $versionUrls -Name $Version)
    if (-not [string]::IsNullOrWhiteSpace($versionUrl)) {
        return $versionUrl
    }

    $urlTemplate = [string](Get-ObjectValue -Object $WslConfig -Name "unraidDownloadUrlTemplate")
    if (-not [string]::IsNullOrWhiteSpace($urlTemplate)) {
        return $urlTemplate
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

    if ($env:OS -eq 'Windows_NT') {
        $currentUser = [System.Security.Principal.WindowsIdentity]::GetCurrent().Name
        & icacls $cachedPath /inheritance:r /grant:r "${currentUser}:(F)" | Out-Null
    }

    return $cachedPath
}

function Convert-ToRemoteShellCommand {
    param([string]$Command)

    if ([string]::IsNullOrWhiteSpace($Command)) {
        return $Command
    }

    if ($Command -notmatch "[`r`n]") {
        return $Command
    }

    $normalizedCommand = ($Command -replace "`r`n", "`n").Trim()
    $commandB64 = [Convert]::ToBase64String([System.Text.Encoding]::UTF8.GetBytes($normalizedCommand))
    return "printf '%s' '$commandB64' | base64 -d | bash"
}

function Convert-ToRemoteSingleQuotedArgument {
    param([string]$Value)

    return "'{0}'" -f (($Value -replace "'", "'\\''"))
}

function Convert-ToRemoteBashScriptCommand {
    param(
        [string]$Script,
        [string[]]$Arguments
    )

    $normalizedScript = ($Script -replace "`r`n", "`n").Trim()
    $scriptB64 = [Convert]::ToBase64String([System.Text.Encoding]::UTF8.GetBytes($normalizedScript))
    $quotedArguments = @($Arguments | ForEach-Object { Convert-ToRemoteSingleQuotedArgument -Value ([string]$_) })
    if ($quotedArguments.Count -gt 0) {
        return "printf '%s' '$scriptB64' | base64 -d | bash -s -- $($quotedArguments -join ' ')"
    }

    return "printf '%s' '$scriptB64' | base64 -d | bash"
}

function Get-SetupPluginBuildCacheRoot {
    param($Lab)

    $setupCfg = Get-ObjectValue -Object $Lab -Name "setup"
    $buddyCfg = Get-ObjectValue -Object $setupCfg -Name "buddybackup"
    $buildCacheRoot = [string](Get-ObjectValue -Object $buddyCfg -Name "buildCacheRoot")
    if (-not [string]::IsNullOrWhiteSpace($buildCacheRoot)) {
        return $buildCacheRoot
    }

    $pluginCfg = Get-ObjectValue -Object $Lab -Name "plugin"
    return [string](Get-ObjectValue -Object $pluginCfg -Name "buildCacheRoot")
}

function Resolve-SetupPluginRequest {
    param(
        $Lab,
        [string]$RequestedValue
    )

    $workspaceRoot = Get-TestLabWorkspaceRoot -ScriptRoot $PSScriptRoot
    $buildCacheRoot = Get-SetupPluginBuildCacheRoot -Lab $Lab
    return Resolve-TestLabPluginRequest -RequestedValue $RequestedValue -WorkspaceRoot $workspaceRoot -ConfiguredBuildCacheRoot $buildCacheRoot
}

function Invoke-NodeSshCommand {
    param(
        $NodeConnection,
        [string]$Command,
        [string]$Label,
        [string]$PreviewCommand = $null,
        [switch]$DoExecute
    )

    $sshBaseArgs = @(
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
        $sshBaseArgs += @("-i", $identityPath)
    }

    $sshTarget = "$($NodeConnection.User)@$($NodeConnection.Host)"
    $remoteCommand = Convert-ToRemoteShellCommand -Command $Command
    $sshArgs = @($sshBaseArgs + @($sshTarget, $remoteCommand))

    if (-not $DoExecute) {
        $commandPreview = if ([string]::IsNullOrWhiteSpace($PreviewCommand)) { $Command } else { $PreviewCommand }
        $previewArgs = @($sshBaseArgs + @($sshTarget, $commandPreview))
        Write-Host "[dry-run][setup][$Label] ssh $($previewArgs -join ' ')"
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

function Invoke-NodeUpload {
    param(
        $NodeConnection,
        [string[]]$LocalPaths,
        [string]$RemoteDirectory,
        [string]$Label,
        [switch]$DoExecute
    )

    $pathsToUpload = @($LocalPaths | Where-Object { -not [string]::IsNullOrWhiteSpace($_) })
    if ($pathsToUpload.Count -eq 0) {
        throw "Remote upload '$Label' was called without any local paths."
    }

    $scpBaseArgs = @(
        "-F", "NUL",
        "-o", "BatchMode=yes",
        "-o", "ConnectTimeout=8",
        "-o", "IdentitiesOnly=yes",
        "-o", "LogLevel=ERROR",
        "-o", "StrictHostKeyChecking=no",
        "-o", "UserKnownHostsFile=NUL",
        "-o", "GlobalKnownHostsFile=NUL",
        "-P", ([string]$NodeConnection.Port)
    )

    if ($NodeConnection.IdentityFile) {
        $identityPath = Get-LocalSshIdentityFile -IdentityFile ([string]$NodeConnection.IdentityFile)
        $scpBaseArgs += @("-i", $identityPath)
    }

    $target = "{0}@{1}:{2}/" -f $NodeConnection.User, $NodeConnection.Host, $RemoteDirectory
    if (-not $DoExecute) {
        $previewArgs = @($scpBaseArgs + $pathsToUpload + @($target))
        Write-Host "[dry-run][upload][$Label] scp $($previewArgs -join ' ')"
        return [pscustomobject]@{
            label = $Label
            success = $true
            exitCode = 0
            output = @("dry-run")
            warningsOrErrorsDetected = $false
        }
    }

    $ensureDirResult = Invoke-NodeSshCommand -NodeConnection $NodeConnection -Command ("mkdir -p {0}" -f $RemoteDirectory) -Label ("{0}-mkdir" -f $Label) -DoExecute
    if (-not $ensureDirResult.success) {
        return [pscustomobject]@{
            label = $Label
            success = $false
            exitCode = $ensureDirResult.exitCode
            output = @($ensureDirResult.output)
            warningsOrErrorsDetected = $false
        }
    }

    $scpArgs = @($scpBaseArgs + $pathsToUpload + @($target))
    $previousErrorActionPreference = $ErrorActionPreference
    try {
        $ErrorActionPreference = "Continue"
        $rawOutput = & scp @scpArgs 2>&1
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

function Set-NodePluginSourceMetadata {
    param(
        $NodeConnection,
        $PluginRequest,
        [switch]$DoExecute
    )

    $commitSha = if ($PluginRequest.buildInfo) { [string]$PluginRequest.buildInfo.commitSha } else { "" }
    $packageSha256 = if ($PluginRequest.buildInfo) { [string]$PluginRequest.buildInfo.packageSha256 } else { "" }
    $packageMd5 = if ($PluginRequest.buildInfo) { [string]$PluginRequest.buildInfo.packageMd5 } else { "" }
    $metadataScript = @'
source_type="$1"
requested_value="$2"
display_version="$3"
commit_sha="$4"
package_sha256="$5"
package_md5="$6"

set -euo pipefail

plugin_root="/boot/config/plugins/buddybackup"
marker_path="$plugin_root/testlab-plugin-source.json"
mkdir -p "$plugin_root"

cat > "$marker_path" <<EOF
{
  "sourceType": "$source_type",
  "requestedValue": "$requested_value",
  "displayVersion": "$display_version",
  "commitSha": "$commit_sha",
  "packageSha256": "$package_sha256",
  "packageMd5": "$package_md5"
}
EOF

echo "plugin source metadata written to $marker_path"
'@
    $command = Convert-ToRemoteBashScriptCommand -Script $metadataScript -Arguments @(
        [string]$PluginRequest.sourceType,
        [string]$PluginRequest.requestedValue,
        [string]$PluginRequest.displayVersion,
        $commitSha,
        $packageSha256,
        $packageMd5
    )

    return Invoke-NodeSshCommand -NodeConnection $NodeConnection -Command $command -PreviewCommand "write BuddyBackup plugin source metadata" -Label "plugin-source-metadata" -DoExecute:$DoExecute
}

function Install-WorkspaceBuildPlugin {
    param(
        $NodeConnection,
        $PluginRequest,
        [switch]$DoExecute
    )

    $buildInfo = $PluginRequest.buildInfo
    if ($null -eq $buildInfo) {
        throw "Workspace-build plugin request is missing build metadata."
    }

    $remoteStageRoot = "/boot/config/plugins/buddybackup-testlab-staging/{0}" -f $buildInfo.shortSha
    $remoteDepsRoot = "$remoteStageRoot/deps"
    $results = @()

    $results += Invoke-NodeUpload -NodeConnection $NodeConnection -LocalPaths @($buildInfo.packagePath) -RemoteDirectory $remoteStageRoot -Label "workspace-build-package-upload" -DoExecute:$DoExecute
    if ($buildInfo.dependencyPackagePaths -and $buildInfo.dependencyPackagePaths.Count -gt 0) {
        $results += Invoke-NodeUpload -NodeConnection $NodeConnection -LocalPaths @($buildInfo.dependencyPackagePaths) -RemoteDirectory $remoteDepsRoot -Label "workspace-build-deps-upload" -DoExecute:$DoExecute
    }

    $failedUpload = @($results | Where-Object { -not $_.success })
    if ($failedUpload.Count -gt 0) {
        return $results
    }

    $installScript = @'
stage_root="$1"
stage_deps_root="$2"

set -euo pipefail

plugin_root="/boot/config/plugins/buddybackup"
stage_package="$stage_root/buddybackup.txz"

install_dep() {
  local file="$1"
  if [ ! -f "$file" ]; then
    echo "Missing staged dependency: $file" >&2
    exit 1
  fi

  installpkg "$file"
}

if [ ! -f "$stage_package" ]; then
  echo "Missing staged workspace package: $stage_package" >&2
  exit 1
fi

mkdir -p "$plugin_root"

source /etc/unraid-version >/dev/null 2>&1 || true
major_version="0"
if [ -n "${version:-}" ]; then
  major_version="${version%%.*}"
fi

install_dep "$stage_deps_root/perl-Capture-Tiny-0.48-x86_64-1ponce.txz"
install_dep "$stage_deps_root/perl-Exporter-Tiny-1.000000-x86_64-1ponce.txz"
install_dep "$stage_deps_root/perl-Config-IniFiles-2.82-x86_64-3_slonly.txz"
install_dep "$stage_deps_root/perl-List-MoreUtils-0.425-x86_64-2_slonly.txz"
if [ "$major_version" -lt 7 ]; then
  install_dep "$stage_deps_root/mbuffer-20240107-x86_64-1_SBo.tgz"
fi

if [ ! -f "$plugin_root/buddybackup.cfg" ]; then
  cat > "$plugin_root/buddybackup.cfg" <<'EOF'
ReceiveBackups=disable
ReceiveDestinationRententionHourly=0
ReceiveDestinationRententionDaily=7
ReceiveDestinationRententionWeekly=4
ReceiveDestinationRententionMonthly=3
ReceiveDestinationRententionYearly=0
EOF
fi

cp "$stage_package" "$plugin_root/buddybackup.txz"
upgradepkg --install-new --reinstall "$plugin_root/buddybackup.txz"
/usr/local/emhttp/plugins/buddybackup/scripts/rc.buddybackup.php update

echo "workspace-build package installed from $stage_package"
'@
    $installCommand = Convert-ToRemoteBashScriptCommand -Script $installScript -Arguments @($remoteStageRoot, $remoteDepsRoot)
    $results += Invoke-NodeSshCommand -NodeConnection $NodeConnection -Command $installCommand -PreviewCommand "install BuddyBackup workspace-build package" -Label "workspace-build-install" -DoExecute:$DoExecute
    if ($results[-1].success) {
        $results += Set-NodePluginSourceMetadata -NodeConnection $NodeConnection -PluginRequest $PluginRequest -DoExecute:$DoExecute
    }

    return $results
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
    $manualAccessCommand = (((@'
set -euo pipefail

restore_script="/boot/config/plugins/buddybackup/manual-access-restore.sh"
go_file="/boot/config/go"
go_begin_marker="#BUDDYBACKUP_MANUAL_ACCESS_RESTORE_BEGIN"
go_end_marker="#BUDDYBACKUP_MANUAL_ACCESS_RESTORE_END"

if ! command -v chpasswd >/dev/null 2>&1; then
    echo "chpasswd is unavailable on this guest" >&2
    exit 1
fi

mkdir -p "$(dirname "$restore_script")"

cat > "$restore_script" <<'EOF_BUDDYBACKUP_MANUAL_ACCESS'
#!/bin/bash
set -euo pipefail

password_b64="__BUDDYBACKUP_PASSWORD_B64__"
use_php=0
if command -v php >/dev/null 2>&1; then
    use_php=1
fi

apply_password() {
    password="$(printf '%s' "$password_b64" | base64 -d)"
    printf 'root:%s\n' "$password" | chpasswd
    if [ -f /etc/shadow ]; then
        cp /etc/shadow /boot/config/shadow 2>/dev/null || true
        chmod 600 /boot/config/shadow 2>/dev/null || true
    fi
    if [ -f /boot/config/shadow ]; then
        cp /boot/config/shadow /etc/shadow 2>/dev/null || true
        chmod 600 /etc/shadow 2>/dev/null || true
    fi
}

attempts=180
while [ "$attempts" -gt 0 ]; do
    runtime_hash="$(awk -F: '$1=="root" { print $2 }' /etc/shadow 2>/dev/null || true)"
    persistent_hash="$(awk -F: '$1=="root" { print $2 }' /boot/config/shadow 2>/dev/null || true)"

    if [ "$use_php" -eq 1 ]; then
        runtime_ok=1
        persistent_ok=1

        if [ -z "$runtime_hash" ] || ! BUDDYBACKUP_PASSWORD_B64="$password_b64" BUDDYBACKUP_HASH_TO_CHECK="$runtime_hash" php -r '$password=base64_decode(getenv("BUDDYBACKUP_PASSWORD_B64")); $hash=getenv("BUDDYBACKUP_HASH_TO_CHECK"); exit(($hash !== false && $hash !== "" && crypt($password, $hash) === $hash) ? 0 : 1);'; then
            runtime_ok=0
        fi

        if [ -z "$persistent_hash" ] || ! BUDDYBACKUP_PASSWORD_B64="$password_b64" BUDDYBACKUP_HASH_TO_CHECK="$persistent_hash" php -r '$password=base64_decode(getenv("BUDDYBACKUP_PASSWORD_B64")); $hash=getenv("BUDDYBACKUP_HASH_TO_CHECK"); exit(($hash !== false && $hash !== "" && crypt($password, $hash) === $hash) ? 0 : 1);'; then
            persistent_ok=0
        fi

        if [ "$runtime_ok" -eq 1 ] && [ "$persistent_ok" -eq 1 ]; then
            exit 0
        fi
    else
        if [ -n "$runtime_hash" ] && [ "$runtime_hash" = "$persistent_hash" ]; then
            exit 0
        fi
    fi

    apply_password
    sleep 2
    attempts=$((attempts - 1))
done

apply_password
EOF_BUDDYBACKUP_MANUAL_ACCESS

chmod 700 "$restore_script"

tmp_go="$(mktemp)"
if [ -f "$go_file" ]; then
    awk -v begin="$go_begin_marker" -v end="$go_end_marker" '
        $0 == begin { skip=1; next }
        $0 == end { skip=0; next }
        skip != 1 { print }
    ' "$go_file" > "$tmp_go"
else
    : > "$tmp_go"
fi

cat >> "$tmp_go" <<'EOF_BUDDYBACKUP_GO'
#BUDDYBACKUP_MANUAL_ACCESS_RESTORE_BEGIN
if [ -f /boot/config/plugins/buddybackup/manual-access-restore.sh ]; then
    bash /boot/config/plugins/buddybackup/manual-access-restore.sh >/dev/null 2>&1 &
fi
#BUDDYBACKUP_MANUAL_ACCESS_RESTORE_END
EOF_BUDDYBACKUP_GO

mv "$tmp_go" "$go_file"

bash "$restore_script"

sync || true

echo "webgui_user=root"
echo "webgui_password_configured=yes"
'@).Replace("__BUDDYBACKUP_PASSWORD_B64__", $passwordB64)) -replace "`r`n", "`n").Trim()
    $manualAccessResult = Invoke-NodeSshCommand -NodeConnection $NodeConnection -Command $manualAccessCommand -Label "webgui-login-setup" -PreviewCommand "configure manual WebGUI access (password redacted)" -DoExecute:$DoExecute
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
        passwordConfigured = $true
        passwordSource = "setup.manualAccess.rootPassword"
        actions = @($manualAccessResult)
    }
}

function Invoke-NodeBaseSetup {
    param(
        $Lab,
        $Node,
        [string]$NodeName,
        $NodeConnection,
        $PluginRequest,
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

    if ($null -eq $PluginRequest) {
        throw "Missing plugin request for node '$NodeName'. Set nodes.$NodeName.pluginVersion or setup.buddybackup.pluginVersion in lab config."
    }

    $resolvedPluginVersion = [string]$PluginRequest.displayVersion
    if ([string]::IsNullOrWhiteSpace($resolvedPluginVersion)) {
        $resolvedPluginVersion = [string]$PluginRequest.requestedValue
    }

    $pluginInstallResults = @()
    if ($PluginRequest.sourceType -eq "workspace-build") {
        $pluginInstallResults = @(Install-WorkspaceBuildPlugin -NodeConnection $NodeConnection -PluginRequest $PluginRequest -DoExecute:$DoExecute)
    } else {
        if ([string]::IsNullOrWhiteSpace($PluginUrlTemplate)) {
            throw "Missing plugin URL template for BuddyBackup installation on node '$NodeName'."
        }

        $pluginUrl = if ($PluginUrlTemplate -match '\{version\}') {
            $PluginUrlTemplate.Replace("{version}", [string]$PluginRequest.requestedValue)
        } else {
            $PluginUrlTemplate
        }

        $pluginInstallResult = Invoke-NodeSshCommand -NodeConnection $NodeConnection -Command ("plugin install {0}" -f $pluginUrl) -Label "buddybackup-plugin-install" -DoExecute:$DoExecute
        $pluginInstallResults += $pluginInstallResult
        if ($pluginInstallResult.success) {
            $pluginInstallResults += Set-NodePluginSourceMetadata -NodeConnection $NodeConnection -PluginRequest $PluginRequest -DoExecute:$DoExecute
        }
    }

    $results += $pluginInstallResults
    $failedPluginInstallResults = @($pluginInstallResults | Where-Object { -not $_.success })
    if ($failedPluginInstallResults.Count -gt 0) {
        $failedLabels = @($failedPluginInstallResults | ForEach-Object { $_.label }) -join ","
        throw "BuddyBackup plugin install failed on node '$NodeName'. Failed labels: $failedLabels"
    }
    if ($failOnInstallWarnings -and @($pluginInstallResults | Where-Object { $_.warningsOrErrorsDetected }).Count -gt 0) {
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
    $zfsSetupResult = Invoke-NodeSshCommand -NodeConnection $NodeConnection -Command $zfsCommand -Label "zfs-base-setup" -PreviewCommand "configure ZFS base setup (passphrase redacted)" -DoExecute:$DoExecute
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
        pluginVersion = $resolvedPluginVersion
        actions = @($results)
    }
}

function Invoke-PostProvisionNodeSshCheck {
    param(
        [string]$NodeName,
        $NodeConnection,
        [int]$Attempts = 10,
        [int]$RetryDelaySeconds = 3,
        [switch]$DoExecute
    )

    $attemptCount = [Math]::Max($Attempts, 1)
    $attemptResults = @()
    for ($attempt = 1; $attempt -le $attemptCount; $attempt++) {
        $probeResult = Invoke-NodeSshCommand -NodeConnection $NodeConnection -Command "echo probe-ok; uname -a" -Label "post-provision-ssh-check" -PreviewCommand "post-provision SSH reachability check" -DoExecute:$DoExecute
        $attemptResults += [pscustomobject]@{
            attempt = $attempt
            success = $probeResult.success
            exitCode = $probeResult.exitCode
            output = @($probeResult.output)
        }

        if ($probeResult.success) {
            return [pscustomobject]@{
                success = $true
                exitCode = $probeResult.exitCode
                output = @($probeResult.output)
                attempts = @($attemptResults)
            }
        }

        if ($DoExecute -and $attempt -lt $attemptCount) {
            Start-Sleep -Seconds $RetryDelaySeconds
        }
    }

    $lastAttempt = $attemptResults[-1]
    return [pscustomobject]@{
        success = $false
        exitCode = $lastAttempt.exitCode
        output = @($lastAttempt.output)
        attempts = @($attemptResults)
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
        @{ NodeName = "nodeA"; DefaultPort = 2222; DefaultHttpPort = 8080; DefaultHttpsPort = 8443 },
        @{ NodeName = "nodeB"; DefaultPort = 2223; DefaultHttpPort = 8081; DefaultHttpsPort = 8444 }
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
        $pluginRequest = Resolve-SetupPluginRequest -Lab $lab -RequestedValue $pluginVersion

        $nodeConnection = Resolve-NodeConnection -Lab $lab -Node $node

        Write-Host "[testlab] Preparing local node $nodeName (Unraid $version, SSH localhost:$desiredPort)"

        $payloadPath = if ($nodePayloadPath) {
            Resolve-TestLabPath ([string]$nodePayloadPath)
        } elseif ($wslCfg -and $wslCfg.payloadPath) {
            Resolve-TestLabPath ([string]$wslCfg.payloadPath)
        } else {
            $downloadUrl = Get-WslUnraidDownloadUrl -WslConfig $wslCfg -Version $version
            Ensure-UnraidPayload -Version $version -CacheRoot $cacheRoot -UrlTemplate $downloadUrl -DoExecute:$Execute
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
            pluginVersion       = $pluginRequest.displayVersion
            pluginRequested     = $pluginRequest.requestedValue
            pluginSource        = $pluginRequest.sourceType
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
            postProvisionSshCheck = $null
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
                $baseSetup = Invoke-NodeBaseSetup -Lab $lab -Node $node -NodeName $nodeName -NodeConnection $nodeConnection -PluginRequest $pluginRequest -PluginUrlTemplate $nodePluginUrlTemplate -DoExecute
                $nodeEntry.baseSetupApplied = $true
                $nodeEntry.baseSetup = $baseSetup
            }

            Write-Host "[testlab] Local node $nodeName ready on 127.0.0.1:$desiredPort"
            Write-Host "[testlab] $nodeName WebGUI HTTP: $($nodeEntry.webGuiHttpUrl)"
            Write-Host "[testlab] $nodeName WebGUI HTTPS: $($nodeEntry.webGuiHttpsUrl)"
            Write-Host "[testlab] $nodeName WebGUI user: $($manualAccess.webGuiUser) (password from setup.manualAccess.rootPassword)"
        } else {
            Write-Host "[dry-run] Would start local node $nodeName on 127.0.0.1:$desiredPort from payload $payloadPath"
            $nodeEntry.sshReady = $true
            $nodeEntry.selectedHostSshPort = $desiredPort
            $nodeEntry.manualAccess = Invoke-NodeManualAccessSetup -Lab $lab -NodeName $nodeName -NodeConnection $nodeConnection -DoExecute:$false
            if ($applyBaseSetup) {
                $nodeEntry.baseSetupApplied = $true
                $nodeEntry.baseSetup = Invoke-NodeBaseSetup -Lab $lab -Node $node -NodeName $nodeName -NodeConnection $nodeConnection -PluginRequest $pluginRequest -PluginUrlTemplate $nodePluginUrlTemplate -DoExecute:$false
            }
        }

        $report.nodes += [pscustomobject]$nodeEntry
    }

    if ($Execute) {
        foreach ($nodeReport in @($report.nodes)) {
            $nodeName = [string]$nodeReport.node
            $node = Get-ObjectValue -Object $lab.nodes -Name $nodeName
            if (-not $node) {
                continue
            }

            $nodeConnection = Resolve-NodeConnection -Lab $lab -Node $node
            Write-Host "[testlab] Rechecking SSH stability on $nodeName"
            $postProvisionSshCheck = Invoke-PostProvisionNodeSshCheck -NodeName $nodeName -NodeConnection $nodeConnection -DoExecute
            $nodeReport.postProvisionSshCheck = $postProvisionSshCheck
            if ($postProvisionSshCheck.success) {
                Write-Host "[testlab] Node $nodeName remained reachable after local provisioning"
                continue
            }

            $attemptSummary = @($postProvisionSshCheck.attempts | ForEach-Object { "attempt=$($_.attempt) exit=$($_.exitCode)" }) -join '; '
            $probeOutput = (($postProvisionSshCheck.output | ForEach-Object { [string]$_ }) -join [Environment]::NewLine).Trim()
            if ([string]::IsNullOrWhiteSpace($probeOutput)) {
                throw "Node '$nodeName' did not remain reachable after local provisioning. $attemptSummary"
            }

            throw "Node '$nodeName' did not remain reachable after local provisioning. $attemptSummary`n$probeOutput"
        }
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