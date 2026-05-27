param(
    [string]$LabConfig = "testlab/config/lab.local.json",
    [string]$MatrixConfig = "testlab/config/matrix.small.json",
    [switch]$Execute,
    [switch]$SkipArtifacts
)

$ErrorActionPreference = "Stop"

. (Join-Path $PSScriptRoot "testlab-logging.ps1")
. (Join-Path $PSScriptRoot "testlab-plugin-source.ps1")

function Require-File {
    param([string]$Path)
    if (-not (Test-Path $Path)) {
        throw "Missing file: $Path"
    }
}

function Get-Json {
    param([string]$Path)
    return Get-Content -Raw -Path $Path | ConvertFrom-Json
}

function Test-LabSupportsMatrixUnraidVersions {
    param(
        $Lab,
        [object[]]$MatrixCells
    )

    $provider = [string](Get-ObjectValue -Object $Lab -Name 'provider')
    $supportedProviders = @('windows-local', 'windows-wsl-qemu', 'manual')
    if ($provider -notin $supportedProviders) {
        return [pscustomobject]@{
            Success = $true
            Error = $null
        }
    }

    $mismatches = @()
    foreach ($nodeName in @('nodeA', 'nodeB')) {
        $labNode = Get-TestLabNodeValue -Object (Get-ObjectValue -Object $Lab -Name 'nodes') -NodeName $nodeName
        $labVersion = [string](Get-ObjectValue -Object $labNode -Name 'unraidVersion')
        if ([string]::IsNullOrWhiteSpace($labVersion)) {
            continue
        }

        $cellVersions = @($MatrixCells | ForEach-Object { [string](Get-ObjectValue -Object (Get-TestLabNodeValue -Object $_ -NodeName $nodeName) -Name 'unraid') } |
            Where-Object { -not [string]::IsNullOrWhiteSpace($_) } |
            Select-Object -Unique)

        foreach ($cellVersion in $cellVersions) {
            if ($cellVersion -ne $labVersion) {
                $mismatches += [pscustomobject]@{
                    node = $nodeName
                    labVersion = $labVersion
                    matrixVersion = $cellVersion
                }
            }
        }
    }

    if ($mismatches.Count -eq 0) {
        return [pscustomobject]@{
            Success = $true
            Error = $null
        }
    }

    $details = @($mismatches | ForEach-Object {
        "node=$($_.node) lab=$($_.labVersion) matrix=$($_.matrixVersion)"
    }) -join '; '

    return [pscustomobject]@{
        Success = $false
        Error = "This testlab run cannot vary Unraid versions per matrix cell. The current provider '$provider' uses the already provisioned lab node versions from the lab config, but the matrix requests different Unraid versions: $details. Provision nodes that match the matrix, or run separate release-gate executions per Unraid baseline instead of mixing them in one run."
    }
}

function Ensure-Dir {
    param([string]$Path)
    if (-not (Test-Path $Path)) {
        New-Item -ItemType Directory -Path $Path | Out-Null
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

function Set-ObjectValue {
    param(
        $Object,
        [string]$Name,
        $Value
    )

    if ($null -eq $Object -or [string]::IsNullOrWhiteSpace($Name)) {
        return
    }

    if ($Object -is [System.Collections.IDictionary]) {
        $Object[$Name] = $Value
        return
    }

    $property = $Object.PSObject.Properties[$Name]
    if ($property) {
        $property.Value = $Value
        return
    }

    $Object | Add-Member -NotePropertyName $Name -NotePropertyValue $Value -Force
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

function Use-ProvisionedMatrixUnraidVersions {
    param(
        $Lab,
        [object[]]$MatrixCells,
        $Matrix = $null
    )

    $provider = [string](Get-ObjectValue -Object $Lab -Name 'provider')
    $supportedProviders = @('windows-local', 'windows-wsl-qemu', 'manual')
    if ($provider -notin $supportedProviders) {
        return [pscustomobject]@{
            Applied = $false
            Updated = $false
            VersionSummary = $null
        }
    }

    $labNodes = Get-ObjectValue -Object $Lab -Name 'nodes'
    $resolvedNodeVersions = [ordered]@{}
    $updated = $false

    foreach ($nodeName in @('nodeA', 'nodeB')) {
        $labNode = Get-TestLabNodeValue -Object $labNodes -NodeName $nodeName
        $labVersion = [string](Get-ObjectValue -Object $labNode -Name 'unraidVersion')
        if ([string]::IsNullOrWhiteSpace($labVersion)) {
            continue
        }

        $resolvedNodeVersions[$nodeName] = $labVersion

        foreach ($cell in $MatrixCells) {
            $cellNode = Get-TestLabNodeValue -Object $cell -NodeName $nodeName
            if ($null -eq $cellNode) {
                continue
            }

            $cellVersion = [string](Get-ObjectValue -Object $cellNode -Name 'unraid')
            if ($cellVersion -ne $labVersion) {
                Set-ObjectValue -Object $cellNode -Name 'unraid' -Value $labVersion
                $updated = $true
            }
        }
    }

    if ($resolvedNodeVersions.Count -eq 0) {
        return [pscustomobject]@{
            Applied = $false
            Updated = $false
            VersionSummary = $null
        }
    }

    if ($null -ne $Matrix) {
        Set-ObjectValue -Object $Matrix -Name 'unraidVersionSource' -Value 'provisioned-lab-nodes'
        Set-ObjectValue -Object $Matrix -Name 'provisionedNodeVersions' -Value $resolvedNodeVersions
    }

    $versionSummary = @(
        foreach ($nodeName in @('nodeA', 'nodeB')) {
            if ($resolvedNodeVersions.Contains($nodeName)) {
                "${nodeName}=$($resolvedNodeVersions[$nodeName])"
            }
        }
    ) -join ', '

    return [pscustomobject]@{
        Applied = $true
        Updated = $updated
        VersionSummary = $versionSummary
    }
}

function Resolve-IdentityPath {
    param([string]$IdentityFile)

    if (-not $IdentityFile) {
        return $IdentityFile
    }

    if ($IdentityFile.StartsWith("~/") -or $IdentityFile.StartsWith("~\")) {
        return Join-Path -Path $HOME -ChildPath $IdentityFile.Substring(2)
    }

    if ([System.IO.Path]::IsPathRooted($IdentityFile)) {
        return [System.IO.Path]::GetFullPath($IdentityFile)
    }

    $workspaceRoot = [System.IO.Path]::GetFullPath((Join-Path $PSScriptRoot "..\.."))
    return [System.IO.Path]::GetFullPath((Join-Path $workspaceRoot $IdentityFile))
}

function Get-LocalSshIdentityFile {
    param([string]$IdentityFile)

    if ([string]::IsNullOrWhiteSpace($IdentityFile)) {
        return $IdentityFile
    }

    $resolvedPath = Resolve-IdentityPath -IdentityFile $IdentityFile
    if (-not (Test-Path -LiteralPath $resolvedPath)) {
        throw "SSH identity file not found: $resolvedPath"
    }

    $cacheRoot = Join-Path $env:LOCALAPPDATA "BuddyBackup\ssh-cache"
    Ensure-Dir -Path $cacheRoot

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

function Get-PluginBuildCacheRoot {
    param($Lab)

    $pluginCfg = Get-ObjectValue -Object $Lab -Name "plugin"
    return [string](Get-ObjectValue -Object $pluginCfg -Name "buildCacheRoot")
}

function Resolve-LabPluginRequest {
    param(
        $Lab,
        [string]$RequestedValue
    )

    $workspaceRoot = Get-TestLabWorkspaceRoot -ScriptRoot $PSScriptRoot
    $buildCacheRoot = Get-PluginBuildCacheRoot -Lab $Lab
    return Resolve-TestLabPluginRequest -RequestedValue $RequestedValue -WorkspaceRoot $workspaceRoot -ConfiguredBuildCacheRoot $buildCacheRoot
}

function Get-BuddyBackupPluginVerifyCommand {
    return ((@'
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

function Get-ManualAccessVerifyCommand {
    param($Lab)

    $manualAccess = Get-ManualAccessConfig -Lab $Lab
    $passwordB64 = [Convert]::ToBase64String([System.Text.Encoding]::UTF8.GetBytes([string]$manualAccess.webGuiPassword))

    return (((@'
set -eu

if [ ! -f /boot/config/shadow ]; then
    echo "/boot/config/shadow is missing" >&2
    exit 1
fi

runtime_hash="$(awk -F: '$1=="root" { print $2 }' /etc/shadow)"
persistent_hash="$(awk -F: '$1=="root" { print $2 }' /boot/config/shadow)"

case "$runtime_hash" in
    ""|\!*|\**)
        echo "root password hash is not configured in /etc/shadow" >&2
        exit 1
        ;;
esac

case "$persistent_hash" in
    ""|\!*|\**)
        echo "root password hash is not configured in /boot/config/shadow" >&2
        exit 1
        ;;
esac

if ! command -v php >/dev/null 2>&1; then
    if [ "$runtime_hash" = "$persistent_hash" ]; then
        echo "root password hash persisted"
        exit 0
    fi

    echo "php is unavailable and runtime/persistent hashes differ" >&2
    exit 1
fi

if ! BUDDYBACKUP_PASSWORD_B64="__BUDDYBACKUP_PASSWORD_B64__" BUDDYBACKUP_HASH_TO_CHECK="$runtime_hash" php -r '$password=base64_decode(getenv("BUDDYBACKUP_PASSWORD_B64")); $hash=getenv("BUDDYBACKUP_HASH_TO_CHECK"); exit(($hash !== false && $hash !== "" && crypt($password, $hash) === $hash) ? 0 : 1);'; then
    echo "configured root password does not match /etc/shadow" >&2
    exit 1
fi

if ! BUDDYBACKUP_PASSWORD_B64="__BUDDYBACKUP_PASSWORD_B64__" BUDDYBACKUP_HASH_TO_CHECK="$persistent_hash" php -r '$password=base64_decode(getenv("BUDDYBACKUP_PASSWORD_B64")); $hash=getenv("BUDDYBACKUP_HASH_TO_CHECK"); exit(($hash !== false && $hash !== "" && crypt($password, $hash) === $hash) ? 0 : 1);'; then
    echo "configured root password does not match /boot/config/shadow" >&2
    exit 1
fi

if [ "$runtime_hash" != "$persistent_hash" ]; then
    echo "root password persisted (runtime hash differs but matches configured password)"
    exit 0
fi

echo "root password hash persisted"
'@).Replace("__BUDDYBACKUP_PASSWORD_B64__", $passwordB64)) -replace "`r`n", "`n").Trim()
}

function Get-ManualAccessVerifyLoggedCommand {
    return "verify manual WebGUI password persistence (password redacted)"
}

function Invoke-FunctionalSmokeScenario {
    param(
        [string]$LabConfigPath,
        $Lab,
        [hashtable]$ScenarioCache,
        [switch]$DoExecute
    )

    if ($ScenarioCache.ContainsKey("functional-smoke")) {
        Write-Host "[testlab] Reusing cached functional smoke result"
        return $ScenarioCache["functional-smoke"]
    }

    $functionalSmokeScript = Join-Path -Path $PSScriptRoot -ChildPath "run-functional-smoke.ps1"
    $logsRoot = if ($Lab.logsRoot) { Resolve-IdentityPath -IdentityFile ([string]$Lab.logsRoot) } else { Resolve-IdentityPath -IdentityFile ".testlab/logs" }
    $started = Get-Date
    $runError = $null

    try {
        Write-Host "[testlab] Running functional smoke scenario"
        & $functionalSmokeScript -LabConfig $LabConfigPath -Execute:$DoExecute
    } catch {
        $runError = ($_ | Out-String).Trim()
    }

    $reportFile = Get-ChildItem -Path $logsRoot -Filter "functional-smoke-*.json" -ErrorAction SilentlyContinue |
        Where-Object { $_.LastWriteTime -ge $started.AddSeconds(-5) } |
        Sort-Object LastWriteTime -Descending |
        Select-Object -First 1

    if (-not $reportFile) {
        if ($runError) {
            throw "Functional smoke run did not produce a report.`n$runError"
        }

        throw "Functional smoke run did not produce a report."
    }

    $report = Get-Content -Raw -Path $reportFile.FullName | ConvertFrom-Json
    $result = [pscustomobject]@{
        Success = [bool]$report.success
        Error = if ($report.success) { $null } elseif ($report.error) { [string]$report.error } else { $runError }
        ReportPath = $reportFile.FullName
    }

    $ScenarioCache["functional-smoke"] = $result

    if ($result.Success) {
        Write-Host "[testlab] Functional smoke scenario completed"
    } else {
        Write-Warning "Functional smoke scenario failed: $($result.Error)"
    }

    if (-not $result.Success -and $runError) {
        return [pscustomobject]@{
            Success = $false
            Error = $result.Error
            ReportPath = $result.ReportPath
        }
    }

    return $result
}

function Get-NodeConnection {
    param(
        $Lab,
        [string]$NodeName
    )

    $canonicalNodeName = Get-TestLabCanonicalNodeName -NodeName $NodeName
    $node = Get-TestLabNodeValue -Object (Get-ObjectValue -Object $Lab -Name 'nodes') -NodeName $canonicalNodeName
    if (-not $node -or -not $node.host) {
        throw "Missing lab.nodes.$canonicalNodeName.host"
    }

    $defaultPort = if ($Lab.ssh -and $Lab.ssh.port) { [int]$Lab.ssh.port } else { 22 }
    $defaultUser = if ($Lab.ssh -and $Lab.ssh.user) { [string]$Lab.ssh.user } else { "root" }
    $defaultIdentityFile = if ($Lab.ssh -and $Lab.ssh.identityFile) { [string]$Lab.ssh.identityFile } else { $null }

    return [pscustomobject]@{
        NodeName = $canonicalNodeName
        User = if ($node.user) { [string]$node.user } else { $defaultUser }
        Host = [string]$node.host
        Port = if ($node.port) { [int]$node.port } else { $defaultPort }
        IdentityFile = if ($node.identityFile) { [string]$node.identityFile } else { $defaultIdentityFile }
    }
}

function Invoke-RemoteCommand {
    param(
        [string]$User,
        [string]$TargetHost,
        [int]$Port,
        [string]$IdentityFile,
        [string]$Command,
        [string]$LoggedCommand = $null,
        [string]$Label = "remote",
        [switch]$DoExecute
    )

    $resolvedIdentity = Get-LocalSshIdentityFile -IdentityFile $IdentityFile
    $sshBaseArgs = @(
        "-F", "NUL",
        "-o", "BatchMode=yes",
        "-o", "ConnectTimeout=8",
        "-o", "IdentitiesOnly=yes",
        "-o", "LogLevel=ERROR",
        "-o", "StrictHostKeyChecking=no",
        "-o", "UserKnownHostsFile=NUL",
        "-o", "GlobalKnownHostsFile=NUL",
        "-p", "$Port"
    )
    if ($resolvedIdentity) {
        $sshBaseArgs += @("-i", $resolvedIdentity)
    }
    $sshTarget = "$User@$TargetHost"
    $remoteCommand = Convert-ToRemoteShellCommand -Command $Command
    $commandForLogs = if ([string]::IsNullOrWhiteSpace($LoggedCommand)) { $Command } else { $LoggedCommand }
    $sshArgs = @($sshBaseArgs + @($sshTarget, $remoteCommand))

    if ($DoExecute) {
        $previousErrorActionPreference = $ErrorActionPreference
        $hadNativeCommandPreference = Test-Path Variable:\PSNativeCommandUseErrorActionPreference
        if ($hadNativeCommandPreference) {
            $previousNativeCommandUseErrorActionPreference = $PSNativeCommandUseErrorActionPreference
        }

        try {
            $ErrorActionPreference = "Continue"
            if ($hadNativeCommandPreference) {
                $PSNativeCommandUseErrorActionPreference = $false
            }

            $rawOutput = & ssh @sshArgs 2>&1
            $exitCode = $LASTEXITCODE
        } finally {
            $ErrorActionPreference = $previousErrorActionPreference
            if ($hadNativeCommandPreference) {
                $PSNativeCommandUseErrorActionPreference = $previousNativeCommandUseErrorActionPreference
            }
        }

        $output = (@($rawOutput | ForEach-Object { [string]$_ }) -join [Environment]::NewLine).Trim()
        return [pscustomobject]@{
            Label = $Label
            Command = $commandForLogs
            ExitCode = $exitCode
            Output = $output
            Success = ($exitCode -eq 0)
        }
    } else {
        $previewArgs = @($sshBaseArgs + @($sshTarget, $commandForLogs))
        Write-Host "[dry-run][ssh][$Label] ssh $($previewArgs -join ' ')"
        return [pscustomobject]@{
            Label = $Label
            Command = $commandForLogs
            ExitCode = 0
            Output = "dry-run"
            Success = $true
        }
    }
}

function Invoke-RemoteUpload {
    param(
        [string]$User,
        [string]$TargetHost,
        [int]$Port,
        [string]$IdentityFile,
        [string[]]$LocalPaths,
        [string]$RemoteDirectory,
        [string]$Label,
        [switch]$DoExecute
    )

    $resolvedIdentity = Get-LocalSshIdentityFile -IdentityFile $IdentityFile
    $scpBaseArgs = @(
        "-F", "NUL",
        "-o", "BatchMode=yes",
        "-o", "ConnectTimeout=8",
        "-o", "IdentitiesOnly=yes",
        "-o", "LogLevel=ERROR",
        "-o", "StrictHostKeyChecking=no",
        "-o", "UserKnownHostsFile=NUL",
        "-o", "GlobalKnownHostsFile=NUL",
        "-P", "$Port"
    )
    if ($resolvedIdentity) {
        $scpBaseArgs += @("-i", $resolvedIdentity)
    }

    $pathsToUpload = @($LocalPaths | Where-Object { -not [string]::IsNullOrWhiteSpace($_) })
    if ($pathsToUpload.Count -eq 0) {
        throw "Remote upload '$Label' was called without any local paths."
    }

    $target = "{0}@{1}:{2}/" -f $User, $TargetHost, $RemoteDirectory
    if (-not $DoExecute) {
        $previewArgs = @($scpBaseArgs + $pathsToUpload + @($target))
        Write-Host "[dry-run][upload][$Label] scp $($previewArgs -join ' ')"
        return [pscustomobject]@{
            Label = $Label
            Command = "scp upload"
            ExitCode = 0
            Output = "dry-run"
            Success = $true
        }
    }

    $ensureDirResult = Invoke-RemoteCommand -User $User -TargetHost $TargetHost -Port $Port -IdentityFile $IdentityFile -Command ("mkdir -p {0}" -f $RemoteDirectory) -Label ("{0}-mkdir" -f $Label) -DoExecute
    if (-not $ensureDirResult.Success) {
        return [pscustomobject]@{
            Label = $Label
            Command = "scp upload"
            ExitCode = $ensureDirResult.ExitCode
            Output = $ensureDirResult.Output
            Success = $false
        }
    }

    $scpArgs = @($scpBaseArgs + $pathsToUpload + @($target))
    $previousErrorActionPreference = $ErrorActionPreference
    $hadNativeCommandPreference = Test-Path Variable:\PSNativeCommandUseErrorActionPreference
    if ($hadNativeCommandPreference) {
        $previousNativeCommandUseErrorActionPreference = $PSNativeCommandUseErrorActionPreference
    }

    try {
        $ErrorActionPreference = "Continue"
        if ($hadNativeCommandPreference) {
            $PSNativeCommandUseErrorActionPreference = $false
        }

        $rawOutput = & scp @scpArgs 2>&1
        $exitCode = $LASTEXITCODE
    } finally {
        $ErrorActionPreference = $previousErrorActionPreference
        if ($hadNativeCommandPreference) {
            $PSNativeCommandUseErrorActionPreference = $previousNativeCommandUseErrorActionPreference
        }
    }

    $output = (@($rawOutput | ForEach-Object { [string]$_ }) -join [Environment]::NewLine).Trim()
    return [pscustomobject]@{
        Label = $Label
        Command = "scp upload"
        ExitCode = $exitCode
        Output = $output
        Success = ($exitCode -eq 0)
    }
}

function New-RetrySummaryResult {
    param(
        $Result,
        [object[]]$Attempts
    )

    if ($null -eq $Result) {
        return $null
    }

    $attemptList = @($Attempts | Where-Object { $null -ne $_ })
    if ($attemptList.Count -le 1) {
        return $Result
    }

    $Result | Add-Member -NotePropertyName AttemptCount -NotePropertyValue $attemptList.Count -Force
    $Result | Add-Member -NotePropertyName Attempts -NotePropertyValue @($attemptList) -Force
    return $Result
}

function Invoke-RemoteUploadWithRetry {
    param(
        [string]$User,
        [string]$TargetHost,
        [int]$Port,
        [string]$IdentityFile,
        [string[]]$LocalPaths,
        [string]$RemoteDirectory,
        [string]$Label,
        [int]$MaxAttempts = 3,
        [switch]$DoExecute
    )

    $attempts = @()
    $result = $null

    for ($attempt = 1; $attempt -le $MaxAttempts; $attempt++) {
        $result = Invoke-RemoteUpload -User $User -TargetHost $TargetHost -Port $Port -IdentityFile $IdentityFile -LocalPaths $LocalPaths -RemoteDirectory $RemoteDirectory -Label $Label -DoExecute:$DoExecute
        $attempts += $result
        if ($result.Success) {
            break
        }

        if ($DoExecute -and $attempt -lt $MaxAttempts) {
            Start-Sleep -Seconds 5
        }
    }

    return New-RetrySummaryResult -Result $result -Attempts $attempts
}

function Set-RemotePluginSourceMetadata {
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

    $maxMetadataAttempts = 3
    $result = $null
    for ($metadataAttempt = 1; $metadataAttempt -le $maxMetadataAttempts; $metadataAttempt++) {
        $result = Invoke-RemoteCommand -User $NodeConnection.User -TargetHost $NodeConnection.Host -Port $NodeConnection.Port -IdentityFile $NodeConnection.IdentityFile -Command $command -LoggedCommand "write BuddyBackup plugin source metadata" -Label "plugin-source-metadata" -DoExecute:$DoExecute
        if ($result.Success) {
            break
        }

        if ($DoExecute -and $metadataAttempt -lt $maxMetadataAttempts) {
            Start-Sleep -Seconds 5
        }
    }

    return $result
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

    $pluginManifestPath = (Resolve-Path (Join-Path $PSScriptRoot "..\..\buddybackup.plg")).ProviderPath
    $remoteStageRoot = "/boot/config/plugins/buddybackup-testlab-staging/{0}" -f $buildInfo.shortSha
    $remoteDepsRoot = "$remoteStageRoot/deps"
    $results = @()
    $commitSha = if ($buildInfo.commitSha) { [string]$buildInfo.commitSha } else { "" }
    $packageSha256 = if ($buildInfo.packageSha256) { [string]$buildInfo.packageSha256 } else { "" }
    $packageMd5 = if ($buildInfo.packageMd5) { [string]$buildInfo.packageMd5 } else { "" }

    $results += Invoke-RemoteUploadWithRetry -User $NodeConnection.User -TargetHost $NodeConnection.Host -Port $NodeConnection.Port -IdentityFile $NodeConnection.IdentityFile -LocalPaths @($buildInfo.packagePath, $pluginManifestPath) -RemoteDirectory $remoteStageRoot -Label "workspace-build-package-upload" -DoExecute:$DoExecute

    if ($buildInfo.dependencyPackagePaths -and $buildInfo.dependencyPackagePaths.Count -gt 0) {
        $results += Invoke-RemoteUploadWithRetry -User $NodeConnection.User -TargetHost $NodeConnection.Host -Port $NodeConnection.Port -IdentityFile $NodeConnection.IdentityFile -LocalPaths @($buildInfo.dependencyPackagePaths) -RemoteDirectory $remoteDepsRoot -Label "workspace-build-deps-upload" -DoExecute:$DoExecute
    }

    $failedUpload = @($results | Where-Object { -not $_.Success })
    if ($failedUpload.Count -gt 0) {
        return $results
    }

    $installScript = @'
stage_root="$1"
manifest_package_md5="$2"
source_type="$3"
requested_value="$4"
display_version="$5"
commit_sha="$6"
package_sha256="$7"
metadata_package_md5="$8"

set -euo pipefail

template_path="$stage_root/buddybackup.plg"
plg_path="$stage_root/buddybackup.plg"
package_path="$stage_root/buddybackup.txz"
plugin_root="/boot/config/plugins/buddybackup"
marker_path="$plugin_root/testlab-plugin-source.json"

if [ ! -f "$template_path" ]; then
    echo "Missing staged plugin manifest: $template_path" >&2
    exit 1
fi

if [ ! -f "$package_path" ]; then
    echo "Missing staged workspace package: $package_path" >&2
    exit 1
fi

for legacy_path in \
    /boot/config/plugins/buddybackup-workspace.plg \
    /boot/config/plugins-error/buddybackup-workspace.plg \
    /boot/config/plugins-stale/buddybackup-workspace.plg \
    /boot/config/plugins-removed/buddybackup-workspace.plg; do
    if [ -e "$legacy_path" ]; then
        rm -f "$legacy_path"
    fi
done

sed -i \
    -e "s#<!ENTITY pkgMD5        \".*\">#<!ENTITY pkgMD5        \"$manifest_package_md5\">#" \
    -e "s#<URL>&gitRelURL;/&pkgName;</URL>#<LOCAL>$package_path</LOCAL>#" \
    "$plg_path"

plugin install "$plg_path" forced

mkdir -p "$plugin_root"
cat > "$marker_path" <<EOF
{
  "sourceType": "$source_type",
  "requestedValue": "$requested_value",
  "displayVersion": "$display_version",
  "commitSha": "$commit_sha",
  "packageSha256": "$package_sha256",
  "packageMd5": "$metadata_package_md5"
}
EOF

echo "plugin source metadata written to $marker_path"
echo "workspace-build package installed from $package_path via localized $template_path"
'@
    $installCommand = Convert-ToRemoteBashScriptCommand -Script $installScript -Arguments @(
        $remoteStageRoot,
        $packageMd5,
        [string]$PluginRequest.sourceType,
        [string]$PluginRequest.requestedValue,
        [string]$PluginRequest.displayVersion,
        $commitSha,
        $packageSha256,
        $packageMd5
    )
    $results += Invoke-RemoteCommand -User $NodeConnection.User -TargetHost $NodeConnection.Host -Port $NodeConnection.Port -IdentityFile $NodeConnection.IdentityFile -Command $installCommand -LoggedCommand "install BuddyBackup workspace-build package" -Label "workspace-build-install" -DoExecute:$DoExecute
    if ($results[-1].Success) {
        $results += [pscustomobject]@{
            Label = 'plugin-source-metadata'
            Command = 'write BuddyBackup plugin source metadata'
            ExitCode = 0
            Output = 'plugin source metadata written to /boot/config/plugins/buddybackup/testlab-plugin-source.json'
            Success = $true
        }
    }

    return $results
}

function Wait-SshReady {
    param(
        [string]$User,
        [string]$TargetHost,
        [int]$Port,
        [string]$IdentityFile,
        [int]$TimeoutSeconds
    )

    $started = Get-Date
    $targetLabel = "{0}:{1}" -f $TargetHost, $Port
    Write-Host "[testlab] Waiting for SSH readiness on $targetLabel"
    $lastHeartbeatAt = $started
    while ((New-TimeSpan -Start $started -End (Get-Date)).TotalSeconds -lt $TimeoutSeconds) {
        $probe = Invoke-RemoteCommand -User $User -TargetHost $TargetHost -Port $Port -IdentityFile $IdentityFile -Command "echo ready" -Label "ssh-ready-probe" -DoExecute
        if ($probe.Success) {
            $elapsedSeconds = [int](New-TimeSpan -Start $started -End (Get-Date)).TotalSeconds
            Write-Host "[testlab] SSH ready on $targetLabel after ${elapsedSeconds}s"
            return $true
        }

        $lastHeartbeatAt = Write-TestLabHeartbeat -Message "Still waiting for SSH readiness on $targetLabel" -StartedAt $started -LastHeartbeatAt $lastHeartbeatAt -IntervalSeconds 15 -TimeoutSeconds $TimeoutSeconds
        Start-Sleep -Seconds 5
    }

    Write-Warning "SSH did not become ready on $targetLabel within $TimeoutSeconds seconds"

    return $false
}

function Wait-SshUnavailable {
    param(
        [string]$User,
        [string]$TargetHost,
        [int]$Port,
        [string]$IdentityFile,
        [int]$TimeoutSeconds
    )

    $started = Get-Date
    $targetLabel = "{0}:{1}" -f $TargetHost, $Port
    Write-Host "[testlab] Waiting for SSH to drop on $targetLabel"
    $lastHeartbeatAt = $started
    while ((New-TimeSpan -Start $started -End (Get-Date)).TotalSeconds -lt $TimeoutSeconds) {
        $probe = Invoke-RemoteCommand -User $User -TargetHost $TargetHost -Port $Port -IdentityFile $IdentityFile -Command "echo ready" -Label "ssh-unavailable-probe" -DoExecute
        if (-not $probe.Success) {
            $elapsedSeconds = [int](New-TimeSpan -Start $started -End (Get-Date)).TotalSeconds
            Write-Host "[testlab] SSH became unavailable on $targetLabel after ${elapsedSeconds}s"
            return $true
        }

        $lastHeartbeatAt = Write-TestLabHeartbeat -Message "Still waiting for SSH to drop on $targetLabel" -StartedAt $started -LastHeartbeatAt $lastHeartbeatAt -IntervalSeconds 15 -TimeoutSeconds $TimeoutSeconds
        Start-Sleep -Seconds 2
    }

    Write-Warning "SSH never dropped on $targetLabel within $TimeoutSeconds seconds"

    return $false
}

function Wait-SshStable {
    param(
        [string]$User,
        [string]$TargetHost,
        [int]$Port,
        [string]$IdentityFile,
        [int]$TimeoutSeconds,
        [int]$RequiredSuccesses = 3
    )

    $started = Get-Date
    $successCount = 0
    $targetLabel = "{0}:{1}" -f $TargetHost, $Port
    Write-Host "[testlab] Verifying SSH stability on $targetLabel"
    $lastHeartbeatAt = $started

    while ((New-TimeSpan -Start $started -End (Get-Date)).TotalSeconds -lt $TimeoutSeconds) {
        $probe = Invoke-RemoteCommand -User $User -TargetHost $TargetHost -Port $Port -IdentityFile $IdentityFile -Command "echo ready" -Label "ssh-stability-probe" -DoExecute
        if ($probe.Success) {
            $successCount += 1
            if ($successCount -ge $RequiredSuccesses) {
                $elapsedSeconds = [int](New-TimeSpan -Start $started -End (Get-Date)).TotalSeconds
                Write-Host "[testlab] SSH remained stable on $targetLabel after ${elapsedSeconds}s"
                return $true
            }
        } else {
            $successCount = 0
        }

        $lastHeartbeatAt = Write-TestLabHeartbeat -Message "Still checking SSH stability on $targetLabel" -StartedAt $started -LastHeartbeatAt $lastHeartbeatAt -IntervalSeconds 15 -TimeoutSeconds $TimeoutSeconds
        Start-Sleep -Seconds 3
    }

    Write-Warning "SSH did not remain stable on $targetLabel within $TimeoutSeconds seconds"

    return $false
}

function Get-RemoteBootId {
    param(
        [string]$User,
        [string]$TargetHost,
        [int]$Port,
        [string]$IdentityFile,
        [string]$Label = "boot-id",
        [switch]$DoExecute
    )

    $result = Invoke-RemoteCommand -User $User -TargetHost $TargetHost -Port $Port -IdentityFile $IdentityFile -Command "cat /proc/sys/kernel/random/boot_id" -Label $Label -DoExecute:$DoExecute
    return [pscustomobject]@{
        Result = $result
        BootId = if ($result.Output) { [string]$result.Output.Trim() } else { $null }
    }
}

function Wait-ForRebootCycle {
    param(
        [string]$User,
        [string]$TargetHost,
        [int]$Port,
        [string]$IdentityFile,
        [string]$PreviousBootId,
        [int]$TimeoutSeconds,
        [int]$SettleSeconds,
        [string]$ReadyCommand = $null,
        [string]$ReadyLoggedCommand = $null,
        [string]$ReadyLabel = "post-reboot-ready"
    )

    $started = Get-Date
    $targetLabel = "{0}:{1}" -f $TargetHost, $Port
    Write-Host "[testlab] Waiting for reboot cycle to complete on $targetLabel"

    if (-not (Wait-SshUnavailable -User $User -TargetHost $TargetHost -Port $Port -IdentityFile $IdentityFile -TimeoutSeconds $TimeoutSeconds)) {
        return [pscustomobject]@{
            Success = $false
            Error = "Host never became unavailable after reboot request."
            BootId = $null
        }
    }

    $elapsedSeconds = [int](New-TimeSpan -Start $started -End (Get-Date)).TotalSeconds
    $remainingSeconds = [Math]::Max($TimeoutSeconds - $elapsedSeconds, 1)
    if (-not (Wait-SshReady -User $User -TargetHost $TargetHost -Port $Port -IdentityFile $IdentityFile -TimeoutSeconds $remainingSeconds)) {
        return [pscustomobject]@{
            Success = $false
            Error = "Host did not return after reboot within $TimeoutSeconds seconds."
            BootId = $null
        }
    }

    $elapsedSeconds = [int](New-TimeSpan -Start $started -End (Get-Date)).TotalSeconds
    $remainingSeconds = [Math]::Max($TimeoutSeconds - $elapsedSeconds, 1)
    if (-not (Wait-SshStable -User $User -TargetHost $TargetHost -Port $Port -IdentityFile $IdentityFile -TimeoutSeconds $remainingSeconds)) {
        return [pscustomobject]@{
            Success = $false
            Error = "Host did not remain SSH-stable after reboot."
            BootId = $null
            ReadyResult = $null
        }
    }

    $confirmedBootId = $null
    $bootIdHeartbeatAt = Get-Date
    while ((New-TimeSpan -Start $started -End (Get-Date)).TotalSeconds -lt $TimeoutSeconds) {
        $bootIdInfo = Get-RemoteBootId -User $User -TargetHost $TargetHost -Port $Port -IdentityFile $IdentityFile -Label "boot-id-after-reboot" -DoExecute
        if ($bootIdInfo.Result.Success -and -not [string]::IsNullOrWhiteSpace($bootIdInfo.BootId)) {
            if ([string]::IsNullOrWhiteSpace($PreviousBootId) -or $bootIdInfo.BootId -ne $PreviousBootId) {
                Write-Host "[testlab] Reboot confirmed on $targetLabel with boot_id $($bootIdInfo.BootId)"
                $confirmedBootId = $bootIdInfo.BootId
                break
            }
        }

        $bootIdHeartbeatAt = Write-TestLabHeartbeat -Message "Still waiting for a new boot_id on $targetLabel" -StartedAt $started -LastHeartbeatAt $bootIdHeartbeatAt -IntervalSeconds 15 -TimeoutSeconds $TimeoutSeconds
        Start-Sleep -Seconds 3
    }

    if ([string]::IsNullOrWhiteSpace($confirmedBootId)) {
        return [pscustomobject]@{
            Success = $false
            Error = "Host returned, but boot_id did not change after reboot."
            BootId = $null
            ReadyResult = $null
        }
    }

    if (-not [string]::IsNullOrWhiteSpace($ReadyCommand)) {
        $elapsedSeconds = [int](New-TimeSpan -Start $started -End (Get-Date)).TotalSeconds
        $remainingSeconds = [Math]::Max($TimeoutSeconds - $elapsedSeconds, 1)
        $readyResult = Wait-ForRemoteSuccess -User $User -TargetHost $TargetHost -Port $Port -IdentityFile $IdentityFile -Command $ReadyCommand -LoggedCommand $ReadyLoggedCommand -Label $ReadyLabel -TimeoutSeconds $remainingSeconds -IntervalSeconds 5
        if (-not $readyResult.Success) {
            $readyOutputText = if ($readyResult.Result -and $null -ne $readyResult.Result.Output) {
                ([string]$readyResult.Result.Output).Trim()
            } else {
                ""
            }

            $readyError = if ([string]::IsNullOrWhiteSpace($readyOutputText)) {
                "Remote check '$ReadyLabel' did not succeed after reboot."
            } else {
                "Remote check '$ReadyLabel' did not succeed after reboot. Last output: $readyOutputText"
            }

            return [pscustomobject]@{
                Success = $false
                Error = $readyError
                BootId = $null
                ReadyResult = $readyResult.Result
            }
        }

        return [pscustomobject]@{
            Success = $true
            Error = $null
            BootId = $confirmedBootId
            ReadyResult = $readyResult.Result
        }
    }

    return [pscustomobject]@{
        Success = $true
        Error = $null
        BootId = $confirmedBootId
        ReadyResult = $null
    }
}

function Wait-ForRemoteSuccess {
    param(
        [string]$User,
        [string]$TargetHost,
        [int]$Port,
        [string]$IdentityFile,
        [string]$Command,
        [string]$LoggedCommand = $null,
        [string]$Label,
        [int]$TimeoutSeconds,
        [int]$IntervalSeconds = 5
    )

    $started = Get-Date
    $lastResult = $null
    $targetLabel = "{0}:{1}" -f $TargetHost, $Port
    Write-Host "[testlab] Waiting for remote check '$Label' on $targetLabel"
    $lastHeartbeatAt = $started

    while ((New-TimeSpan -Start $started -End (Get-Date)).TotalSeconds -lt $TimeoutSeconds) {
        $lastResult = Invoke-RemoteCommand -User $User -TargetHost $TargetHost -Port $Port -IdentityFile $IdentityFile -Command $Command -LoggedCommand $LoggedCommand -Label $Label -DoExecute
        if ($lastResult.Success) {
            $elapsedSeconds = [int](New-TimeSpan -Start $started -End (Get-Date)).TotalSeconds
            Write-Host "[testlab] Remote check '$Label' passed on $targetLabel after ${elapsedSeconds}s"
            return [pscustomobject]@{
                Success = $true
                Result = $lastResult
            }
        }

        $lastHeartbeatAt = Write-TestLabHeartbeat -Message "Still waiting for remote check '$Label' on $targetLabel" -StartedAt $started -LastHeartbeatAt $lastHeartbeatAt -IntervalSeconds 15 -TimeoutSeconds $TimeoutSeconds
        Start-Sleep -Seconds $IntervalSeconds
    }

    $lastOutputText = if ($lastResult -and $null -ne $lastResult.Output) {
        ([string]$lastResult.Output).Trim()
    } else {
        ""
    }

    if ([string]::IsNullOrWhiteSpace($lastOutputText)) {
        Write-Warning "Remote check '$Label' did not succeed on $targetLabel within $TimeoutSeconds seconds"
    } else {
        Write-Warning "Remote check '$Label' did not succeed on $targetLabel within $TimeoutSeconds seconds. Last output: $lastOutputText"
    }

    return [pscustomobject]@{
        Success = $false
        Result = $lastResult
    }
}

function Get-LatestLocalProviderReport {
    param($Lab)

    $logsRoot = if ($Lab.logsRoot) { [string]$Lab.logsRoot } else { ".testlab/logs" }
    $workspaceRoot = Get-TestLabWorkspaceRoot -ScriptRoot $PSScriptRoot
    if ([System.IO.Path]::IsPathRooted($logsRoot)) {
        $logsRoot = [System.IO.Path]::GetFullPath($logsRoot)
    } else {
        $logsRoot = [System.IO.Path]::GetFullPath((Join-Path $workspaceRoot $logsRoot))
    }
    $reports = Get-ChildItem -Path $logsRoot -Filter "local-provider-*.json" -ErrorAction SilentlyContinue | Sort-Object LastWriteTime -Descending
    if (-not $reports -or $reports.Count -eq 0) {
        return $null
    }

    return Get-Content -Raw -Path $reports[0].FullName | ConvertFrom-Json
}

function Test-NodeBaseSetupFromProviderReport {
    param(
        $NodeReport,
        [string]$NodeName
    )

    if (-not $NodeReport) {
        return [pscustomobject]@{ Success = $false; Error = "No local-provider node report entry found for '$NodeName'." }
    }

    if (-not $NodeReport.baseSetupApplied) {
        return [pscustomobject]@{ Success = $false; Error = "baseSetupApplied is false for '$NodeName'." }
    }

    $actions = @($NodeReport.baseSetup.actions)
    if ($actions.Count -eq 0) {
        return [pscustomobject]@{ Success = $false; Error = "No base setup actions were recorded for '$NodeName'." }
    }

    $pluginInstall = @($actions | Where-Object { $_.label -eq "buddybackup-plugin-install" }) | Select-Object -First 1
    if (-not $pluginInstall) {
        return [pscustomobject]@{ Success = $false; Error = "buddybackup-plugin-install action is missing for '$NodeName'." }
    }
    if (-not $pluginInstall.success) {
        return [pscustomobject]@{ Success = $false; Error = "buddybackup-plugin-install failed for '$NodeName'." }
    }
    if ($pluginInstall.warningsOrErrorsDetected) {
        return [pscustomobject]@{ Success = $false; Error = "buddybackup-plugin-install output contained warning/error text for '$NodeName'." }
    }

    return [pscustomobject]@{ Success = $true; Error = $null }
}

function Get-SetupZfsValues {
    param($Lab)

    $setupCfg = Get-ObjectValue -Object $Lab -Name "setup"
    $zfsCfg = Get-ObjectValue -Object $setupCfg -Name "zfs"

    $poolName = [string](Get-ObjectValue -Object $zfsCfg -Name "poolName")
    if ([string]::IsNullOrWhiteSpace($poolName)) { $poolName = "bbpool" }

    $datasetRootName = [string](Get-ObjectValue -Object $zfsCfg -Name "datasetRoot")
    if ([string]::IsNullOrWhiteSpace($datasetRootName)) { $datasetRootName = "buddybackup" }

    $plainDatasetName = [string](Get-ObjectValue -Object $zfsCfg -Name "unencryptedDatasetName")
    if ([string]::IsNullOrWhiteSpace($plainDatasetName)) { $plainDatasetName = "plain" }

    $encDatasetName = [string](Get-ObjectValue -Object $zfsCfg -Name "encryptedDatasetName")
    if ([string]::IsNullOrWhiteSpace($encDatasetName)) { $encDatasetName = "secure" }

    $root = "$poolName/$datasetRootName"
    return [pscustomobject]@{
        PoolName = $poolName
        DatasetRoot = $root
        UnencryptedDataset = "$root/$plainDatasetName"
        EncryptedDataset = "$root/$encDatasetName"
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
        nodeAAliasIp = $nodeAAliasIp
        nodeBAliasIp = $nodeBAliasIp
        allowUnencryptedRemoteBackups = $allowUnencryptedRemoteBackups
    }
}

function Get-UpgradeScenarioNodePlan {
    param(
        [string]$NodeName,
        $Connection,
        $ZfsValues,
        $FunctionalCfg
    )

    $canonicalNodeName = Get-TestLabCanonicalNodeName -NodeName $NodeName
    $uidPrefix = if ($canonicalNodeName -eq "nodeA") { "a" } else { "b" }
    $aliasIp = if ($canonicalNodeName -eq "nodeA") { $FunctionalCfg.nodeAAliasIp } else { $FunctionalCfg.nodeBAliasIp }
    $root = "$($ZfsValues.DatasetRoot)/upgrade/$canonicalNodeName"

    return [pscustomobject]@{
        NodeName = $canonicalNodeName
        SourceDataset = "$root/source"
        SourceMountpoint = "/mnt/buddybackup-upgrade/$canonicalNodeName-source"
        LocalBackupDataset = "$root/local-backup"
        ReceiveRootDataset = "$($ZfsValues.DatasetRoot)/upgrade/receive-$canonicalNodeName"
        RemoteBackupUid = "${uidPrefix}upgrm01"
        LocalBackupUid = "${uidPrefix}upglc01"
        SnapshotUid = "${uidPrefix}upgsn01"
        AliasIp = $aliasIp
        Port = [int]$Connection.Port
    }
}

function Run-BaseSetupVerification {
    param(
        $Lab,
        [string]$CellDir,
        [switch]$DoExecute
    )

    $results = @()
    $providerReport = $null

    if (($Lab.provider -eq "windows-local" -or $Lab.provider -eq "windows-wsl-qemu") -and $DoExecute) {
        $providerReport = Get-LatestLocalProviderReport -Lab $Lab
        if (-not $providerReport) {
            throw "No local-provider report found for base setup verification."
        }

        foreach ($nodeName in @("nodeA", "nodeB")) {
            $nodeReport = @($providerReport.nodes | Where-Object { $_.node -eq $nodeName }) | Select-Object -First 1
            $nodeCheck = Test-NodeBaseSetupFromProviderReport -NodeReport $nodeReport -NodeName $nodeName
            $results += [pscustomobject]@{
                Label = "${nodeName}-provider-base-setup"
                Command = "provider report base setup validation"
                ExitCode = if ($nodeCheck.Success) { 0 } else { 1 }
                Output = if ($nodeCheck.Success) { "ok" } else { $nodeCheck.Error }
                Success = $nodeCheck.Success
            }
            if (-not $nodeCheck.Success) {
                throw $nodeCheck.Error
            }
        }
    }

    $zfsValues = Get-SetupZfsValues -Lab $Lab
    $pluginVerifyCommand = Get-BuddyBackupPluginVerifyCommand

    $baseSetupVerificationTimeout = 30
    foreach ($nodeName in @("nodeA", "nodeB")) {
        $connection = Get-NodeConnection -Lab $Lab -NodeName $nodeName

        $checks = @(
            @{ Label = "${nodeName}-buddybackup-plugin-check"; Command = $pluginVerifyCommand; RequireEncrypted = $false },
            @{ Label = "${nodeName}-zpool-check"; Command = ("zpool list -H -o name {0}" -f $zfsValues.PoolName); RequireEncrypted = $false },
            @{ Label = "${nodeName}-plain-dataset-check"; Command = ("zfs list -H -o name {0}" -f $zfsValues.UnencryptedDataset); RequireEncrypted = $false },
            @{ Label = "${nodeName}-encrypted-dataset-check"; Command = ("zfs get -H -o value encryption {0}" -f $zfsValues.EncryptedDataset); RequireEncrypted = $true }
        )

        foreach ($check in $checks) {
            $checkResult = if ($DoExecute) {
                (Wait-ForRemoteSuccess -User $connection.User -TargetHost $connection.Host -Port $connection.Port -IdentityFile $connection.IdentityFile -Command $check.Command -Label $check.Label -TimeoutSeconds $baseSetupVerificationTimeout).Result
            } else {
                Invoke-RemoteCommand -User $connection.User -TargetHost $connection.Host -Port $connection.Port -IdentityFile $connection.IdentityFile -Command $check.Command -Label $check.Label -DoExecute:$DoExecute
            }

            if ($DoExecute -and $check.RequireEncrypted -and $checkResult.Success -and $checkResult.Output -match '(?i)^off\s*$') {
                $checkResult.Success = $false
                $checkResult.ExitCode = 1
                $checkResult.Output = "encryption=off"
            }

            $results += $checkResult
        }
    }

    $verificationPath = Join-Path -Path $CellDir -ChildPath "scenario-base-setup-verify.json"
    $results | ConvertTo-Json -Depth 8 | Set-Content -Path $verificationPath

    $failed = @($results | Where-Object { -not $_.Success })
    if ($failed.Count -gt 0) {
        $labels = @($failed | ForEach-Object { $_.Label }) -join ","
        return [pscustomobject]@{
            Scenario = "base-setup-verify"
            Success = $false
            Error = "Failed command labels: $labels"
        }
    }

    return [pscustomobject]@{
        Scenario = "base-setup-verify"
        Success = $true
        Error = $null
    }
}

function Get-RemoteFileValue {
        param(
                $NodeConnection,
                [string]$Path,
                [string]$Label,
                [switch]$DoExecute
        )

        $result = Invoke-RemoteCommand -User $NodeConnection.User -TargetHost $NodeConnection.Host -Port $NodeConnection.Port -IdentityFile $NodeConnection.IdentityFile -Command ("cat {0}" -f $Path) -Label $Label -DoExecute:$DoExecute
        return [pscustomobject]@{
                Result = $result
                Value = if ($result.Success -and -not [string]::IsNullOrWhiteSpace($result.Output)) { [string]$result.Output.Trim() } else { $null }
        }
}

function New-UpgradePreservesConfigSetupScript {
        $script = @'
node_name="$1"
source_dataset="$2"
source_mountpoint="$3"
local_backup_dataset="$4"
receive_root_dataset="$5"
remote_uid="$6"
local_uid="$7"
snapshot_uid="$8"
remote_host="$9"
remote_destination_dataset="${10}"
allow_unencrypted="${11}"
peer_public_key="${12}"
host_gateway_ip="${13}"
peer_port="${14}"
peer_alias_ip="${15}"

set -euo pipefail

plugin_root="/boot/config/plugins/buddybackup"
plugin_cfg="$plugin_root/buddybackup.cfg"
backups_cfg="$plugin_root/backups.cfg"
snapshots_cfg="$plugin_root/snapshots.cfg"

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

mkdir -p "$plugin_root"
ensure_dataset_absent "$source_dataset"
ensure_dataset_absent "$local_backup_dataset"
ensure_dataset_absent "$receive_root_dataset"

mkdir -p "$(dirname "$source_mountpoint")"
zfs create -p -o mountpoint="$source_mountpoint" "$source_dataset"
zfs create -p -o mountpoint=none "$local_backup_dataset"
zfs create -p -o mountpoint=none "$receive_root_dataset"
printf 'node=%s\nstage=upgrade-preserves-config\n' "$node_name" > "$source_mountpoint/payload.txt"
sync || true

touch "$plugin_cfg"
set_ini_value "ReceiveBackups" "enable" "$plugin_cfg"
set_ini_value "ReceiveDestinationDataset" "$receive_root_dataset" "$plugin_cfg"
set_ini_value "DestinationPubSSHKey" "$peer_public_key" "$plugin_cfg"
set_ini_value "ReceiveDestinationRententionHourly" "4" "$plugin_cfg"
set_ini_value "ReceiveDestinationRententionDaily" "8" "$plugin_cfg"
set_ini_value "ReceiveDestinationRententionWeekly" "5" "$plugin_cfg"
set_ini_value "ReceiveDestinationRententionMonthly" "6" "$plugin_cfg"
set_ini_value "ReceiveDestinationRententionYearly" "2" "$plugin_cfg"
set_ini_value "BackupDaysAgoWarning" "5" "$plugin_cfg"
set_ini_value "BackupDaysAgoCritical" "11" "$plugin_cfg"
set_ini_value "BuddysBackupDaysAgoWarning" "9" "$plugin_cfg"
set_ini_value "BuddysBackupDaysAgoCritical" "19" "$plugin_cfg"
set_ini_value "UtcTimezone" "yes" "$plugin_cfg"
set_ini_value "AllowUnencryptedRemoteBackups" "$allow_unencrypted" "$plugin_cfg"

cat > "$backups_cfg" <<EOF
[${remote_uid}]
enable="yes"
source_dataset="${source_dataset}"
recursive="yes"
backup_cron="17 3 * * *"
type="remote"
destination_host="${remote_host}"
destination_dataset="${remote_destination_dataset}"

[${local_uid}]
enable="yes"
source_dataset="${source_dataset}"
recursive="no"
backup_cron="43 5 * * 1"
type="local"
destination_host=""
destination_dataset="${local_backup_dataset}"
EOF

cat > "$snapshots_cfg" <<EOF
[${snapshot_uid}]
dataset="${source_dataset}"
hourly="6"
daily="4"
weekly="3"
monthly="2"
yearly="1"
autosnap="yes"
autoprune="yes"
recursive="yes"
process_children_only="no"
trigger="${remote_uid}"
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

echo "seeded_node=${node_name}"
echo "seeded_remote_host=${remote_host}"
echo "seeded_receive_root=${receive_root_dataset}"
'@

        return $script
}

function Get-UpgradeStateSummaryScript {
        $script = @'
set -euo pipefail

plugin_root="/boot/config/plugins/buddybackup"
plugin_cfg="$plugin_root/buddybackup.cfg"
backups_cfg="$plugin_root/backups.cfg"
snapshots_cfg="$plugin_root/snapshots.cfg"
managed_known_hosts="$plugin_root/buddybackup_known_hosts"
sender_key="$plugin_root/buddybackup_sender_key"
authorized_keys="/home/buddybackup/.ssh/authorized_keys"
sanoid_conf="$plugin_root/sanoid.conf"
sshd_config="/etc/ssh/sshd_config"
if [ -f /boot/config/ssh/sshd_config ]; then
    sshd_config="/boot/config/ssh/sshd_config"
fi

hash_or_empty() {
    local path="$1"
    if [ -f "$path" ]; then
        sha256sum "$path" | awk '{print $1}'
    fi
}

known_hosts_key_material_hash_or_empty() {
    local path="$1"
    if [ -f "$path" ]; then
        awk '
            /^[[:space:]]*$/ { next }
            /^[[:space:]]*#/ { next }
            NF >= 3 { print $2 " " $3 }
        ' "$path" | LC_ALL=C sort | sha256sum | awk '{print $1}'
    fi
}

line_or_empty() {
    local key="$1"
    local path="$2"
    if [ -f "$path" ]; then
        awk -F= -v expected="$key" '$1==expected {print $0}' "$path" | tail -n 1
    fi
}

emit_sections() {
    local path="$1"
    local label="$2"
    if [ -f "$path" ]; then
        awk '/^\[.*\]$/{gsub(/^\[|\]$/, "", $0); print}' "$path" | sort | while IFS= read -r value; do
            [ -n "$value" ] && echo "${label}=${value}"
        done
    fi
}

echo "plugin_cfg_sha256=$(hash_or_empty "$plugin_cfg")"
echo "backups_cfg_sha256=$(hash_or_empty "$backups_cfg")"
echo "snapshots_cfg_sha256=$(hash_or_empty "$snapshots_cfg")"
echo "sender_key_sha256=$(hash_or_empty "$sender_key")"
echo "known_hosts_sha256=$(hash_or_empty "$managed_known_hosts")"
echo "known_hosts_key_material_sha256=$(known_hosts_key_material_hash_or_empty "$managed_known_hosts")"
echo "authorized_keys_sha256=$(hash_or_empty "$authorized_keys")"
echo "sanoid_conf_sha256=$(hash_or_empty "$sanoid_conf")"

for key in \
    ReceiveBackups \
    ReceiveDestinationDataset \
    ReceiveDestinationRententionHourly \
    ReceiveDestinationRententionDaily \
    ReceiveDestinationRententionWeekly \
    ReceiveDestinationRententionMonthly \
    ReceiveDestinationRententionYearly \
    BackupDaysAgoWarning \
    BackupDaysAgoCritical \
    BuddysBackupDaysAgoWarning \
    BuddysBackupDaysAgoCritical \
    UtcTimezone \
    AllowUnencryptedRemoteBackups; do
    line=$(line_or_empty "$key" "$plugin_cfg")
    if [ -n "$line" ]; then
        echo "plugin_cfg_line=$line"
    fi
done

emit_sections "$backups_cfg" "backup_section"
emit_sections "$snapshots_cfg" "snapshot_section"

shopt -s nullglob
backup_crons=("$plugin_root"/backup-*.cron)
shopt -u nullglob

for cron in "${backup_crons[@]}"; do
    basename "$cron"
done | sort | while IFS= read -r value; do
    [ -n "$value" ] && echo "backup_cron=$value"
done

known_hosts_lines=0
if [ -f "$managed_known_hosts" ]; then
    known_hosts_lines=$(grep -cve '^[[:space:]]*$' "$managed_known_hosts" || true)
fi
echo "known_hosts_line_count=$known_hosts_lines"

buddybackup_user_present=no
if id buddybackup >/dev/null 2>&1; then
    buddybackup_user_present=yes
fi
echo "buddybackup_user_present=$buddybackup_user_present"

allow_users_contains_buddybackup=no
if [ -f "$sshd_config" ] && grep -Eq '^AllowUsers .*buddybackup([[:space:]]|$)' "$sshd_config"; then
    allow_users_contains_buddybackup=yes
fi
echo "allow_users_contains_buddybackup=$allow_users_contains_buddybackup"

match_user_buddybackup=no
if [ -f "$sshd_config" ] && grep -Fq 'Match User buddybackup' "$sshd_config"; then
    match_user_buddybackup=yes
fi
echo "match_user_buddybackup=$match_user_buddybackup"

receive_dataset=""
if [ -f "$plugin_cfg" ]; then
    receive_dataset=$(awk -F= '$1=="ReceiveDestinationDataset" {value=$2; gsub(/^"|"$/, "", value); print value}' "$plugin_cfg" | tail -n 1)
fi

sanoid_conf_contains_receive_dataset=no
if [ -n "$receive_dataset" ] && [ -f "$sanoid_conf" ] && grep -Fq "[$receive_dataset]" "$sanoid_conf"; then
    sanoid_conf_contains_receive_dataset=yes
fi
echo "sanoid_conf_contains_receive_dataset=$sanoid_conf_contains_receive_dataset"
'@

        return $script
}

function ConvertFrom-UpgradeStateOutput {
        param([string]$Output)

        $snapshot = [ordered]@{
                pluginCfgSha256 = ""
                backupsCfgSha256 = ""
                snapshotsCfgSha256 = ""
                senderKeySha256 = ""
                knownHostsSha256 = ""
                knownHostsKeyMaterialSha256 = ""
                knownHostsLineCount = 0
                authorizedKeysSha256 = ""
                sanoidConfSha256 = ""
                sanoidConfContainsReceiveDataset = "no"
                buddybackupUserPresent = "no"
                allowUsersContainsBuddybackup = "no"
                matchUserBuddybackup = "no"
                pluginCfgLines = @()
                backupSections = @()
                snapshotSections = @()
                backupCrons = @()
        }

        $lines = @($Output -split "`r?`n" | Where-Object { -not [string]::IsNullOrWhiteSpace($_) })
        foreach ($line in $lines) {
                $parts = $line -split '=', 2
                $name = [string]$parts[0]
                $value = if ($parts.Count -gt 1) { [string]$parts[1] } else { "" }

                switch ($name) {
                        "plugin_cfg_sha256" { $snapshot.pluginCfgSha256 = $value }
                        "backups_cfg_sha256" { $snapshot.backupsCfgSha256 = $value }
                        "snapshots_cfg_sha256" { $snapshot.snapshotsCfgSha256 = $value }
                        "sender_key_sha256" { $snapshot.senderKeySha256 = $value }
                        "known_hosts_sha256" { $snapshot.knownHostsSha256 = $value }
                        "known_hosts_key_material_sha256" { $snapshot.knownHostsKeyMaterialSha256 = $value }
                        "known_hosts_line_count" { $snapshot.knownHostsLineCount = if ([string]::IsNullOrWhiteSpace($value)) { 0 } else { [int]$value } }
                        "authorized_keys_sha256" { $snapshot.authorizedKeysSha256 = $value }
                        "sanoid_conf_sha256" { $snapshot.sanoidConfSha256 = $value }
                        "sanoid_conf_contains_receive_dataset" { $snapshot.sanoidConfContainsReceiveDataset = $value }
                        "buddybackup_user_present" { $snapshot.buddybackupUserPresent = $value }
                        "allow_users_contains_buddybackup" { $snapshot.allowUsersContainsBuddybackup = $value }
                        "match_user_buddybackup" { $snapshot.matchUserBuddybackup = $value }
                        "plugin_cfg_line" { $snapshot.pluginCfgLines += $value }
                        "backup_section" { $snapshot.backupSections += $value }
                        "snapshot_section" { $snapshot.snapshotSections += $value }
                        "backup_cron" { $snapshot.backupCrons += $value }
                }
        }

        $snapshot.pluginCfgLines = @($snapshot.pluginCfgLines | Sort-Object -Unique)
        $snapshot.backupSections = @($snapshot.backupSections | Sort-Object -Unique)
        $snapshot.snapshotSections = @($snapshot.snapshotSections | Sort-Object -Unique)
        $snapshot.backupCrons = @($snapshot.backupCrons | Sort-Object -Unique)

        return [pscustomobject]$snapshot
}

function Get-UpgradeStateSnapshot {
        param(
                [string]$NodeName,
                $NodeConnection,
                [switch]$DoExecute
        )

        $script = Get-UpgradeStateSummaryScript
        $command = Convert-ToRemoteBashScriptCommand -Script $script -Arguments @()
    $maxSnapshotAttempts = 3
    $attempts = @()
    $result = $null

    for ($snapshotAttempt = 1; $snapshotAttempt -le $maxSnapshotAttempts; $snapshotAttempt++) {
        $result = Invoke-RemoteCommand -User $NodeConnection.User -TargetHost $NodeConnection.Host -Port $NodeConnection.Port -IdentityFile $NodeConnection.IdentityFile -Command $command -LoggedCommand "capture BuddyBackup upgrade state summary" -Label "${NodeName}-upgrade-state-snapshot" -DoExecute:$DoExecute
        $attempts += $result
        if ($result.Success) {
            break
        }

        if ($DoExecute -and $snapshotAttempt -lt $maxSnapshotAttempts) {
            Start-Sleep -Seconds 5
        }
    }

    if ($result) {
        $result = New-RetrySummaryResult -Result $result -Attempts $attempts
    }

        return [pscustomobject]@{
                Result = $result
                Snapshot = if ($result.Success -and $DoExecute) { ConvertFrom-UpgradeStateOutput -Output $result.Output } elseif (-not $DoExecute) { [pscustomobject]@{ dryRun = $true } } else { $null }
        }
}

function Test-UpgradeStateSnapshot {
        param(
                [string]$NodeName,
                $Snapshot,
                $Plan,
                [string]$AllowUnencryptedRemoteBackups
        )

        $errors = @()
        if ([string]::IsNullOrWhiteSpace([string]$Snapshot.pluginCfgSha256)) {
                $errors += "plugin cfg hash is missing"
        }
        if ([string]::IsNullOrWhiteSpace([string]$Snapshot.backupsCfgSha256)) {
                $errors += "backups cfg hash is missing"
        }
        if ([string]::IsNullOrWhiteSpace([string]$Snapshot.snapshotsCfgSha256)) {
                $errors += "snapshots cfg hash is missing"
        }
        if ([string]::IsNullOrWhiteSpace([string]$Snapshot.senderKeySha256)) {
                $errors += "sender key hash is missing"
        }
        if ($Snapshot.buddybackupUserPresent -ne "yes") {
                $errors += "buddybackup user is missing"
        }
        if ($Snapshot.allowUsersContainsBuddybackup -ne "yes") {
                $errors += "sshd_config AllowUsers does not include buddybackup"
        }
        if ($Snapshot.matchUserBuddybackup -ne "yes") {
                $errors += "sshd_config Match User buddybackup block is missing"
        }
        if ($Snapshot.sanoidConfContainsReceiveDataset -ne "yes") {
                $errors += "sanoid.conf does not contain the receive dataset"
        }

        $expectedPluginLines = @(
                'ReceiveBackups="enable"',
                ('ReceiveDestinationDataset="{0}"' -f $Plan.ReceiveRootDataset),
                'UtcTimezone="yes"',
                ('AllowUnencryptedRemoteBackups="{0}"' -f $AllowUnencryptedRemoteBackups)
        )
        foreach ($expectedLine in $expectedPluginLines) {
                if ($Snapshot.pluginCfgLines -notcontains $expectedLine) {
                        $errors += "missing plugin cfg line $expectedLine"
                }
        }

        foreach ($expectedSection in @($Plan.RemoteBackupUid, $Plan.LocalBackupUid)) {
                if ($Snapshot.backupSections -notcontains $expectedSection) {
                        $errors += "missing backup section $expectedSection"
                }
        }
        if ($Snapshot.snapshotSections -notcontains $Plan.SnapshotUid) {
                $errors += "missing snapshot section $($Plan.SnapshotUid)"
        }

        foreach ($expectedCron in @("backup-$($Plan.RemoteBackupUid).cron", "backup-$($Plan.LocalBackupUid).cron")) {
                if ($Snapshot.backupCrons -notcontains $expectedCron) {
                        $errors += "missing cron file $expectedCron"
                }
        }

        return [pscustomobject]@{
                Success = ($errors.Count -eq 0)
                Error = if ($errors.Count -eq 0) { $null } else { $errors -join '; ' }
        }
}

function Compare-UpgradeStateSnapshots {
        param(
                [string]$NodeName,
                $Before,
                $After
        )

        $differences = @()
        $properties = @(
                'pluginCfgSha256',
                'backupsCfgSha256',
                'snapshotsCfgSha256',
                'senderKeySha256',
                'knownHostsKeyMaterialSha256',
                'knownHostsLineCount',
                'authorizedKeysSha256',
                'sanoidConfSha256',
                'sanoidConfContainsReceiveDataset',
                'buddybackupUserPresent',
                'allowUsersContainsBuddybackup',
                'matchUserBuddybackup',
                'pluginCfgLines',
                'backupSections',
                'snapshotSections',
                'backupCrons'
        )

        foreach ($propertyName in $properties) {
                $beforeValue = $Before.$propertyName
                $afterValue = $After.$propertyName

                if ($beforeValue -is [System.Array] -or $afterValue -is [System.Array]) {
                        $beforeText = (@($beforeValue) | Sort-Object) -join ', '
                        $afterText = (@($afterValue) | Sort-Object) -join ', '
                        if ($beforeText -ne $afterText) {
                                $differences += "${propertyName}: before=[$beforeText] after=[$afterText]"
                        }
                        continue
                }

                $beforeText = [string]$beforeValue
                $afterText = [string]$afterValue
                if ($beforeText -ne $afterText) {
                        $differences += "${propertyName}: before=[$beforeText] after=[$afterText]"
                }
        }

        return [pscustomobject]@{
                Success = ($differences.Count -eq 0)
                Error = if ($differences.Count -eq 0) { $null } else { $differences -join '; ' }
        }
}

function Install-Plugin {
    param(
        $Lab,
        $NodeConnection,
        $PluginRequest,
        [switch]$DoExecute
    )

    if ($PluginRequest.sourceType -eq "workspace-build") {
        return Install-WorkspaceBuildPlugin -NodeConnection $NodeConnection -PluginRequest $PluginRequest -DoExecute:$DoExecute
    }

    $urlTemplate = [string]$Lab.plugin.plgUrlTemplate
    if ([string]::IsNullOrWhiteSpace($urlTemplate)) {
        throw "lab.plugin.plgUrlTemplate is required for release-tag plugin installs."
    }

    $url = $urlTemplate.Replace("{version}", [string]$PluginRequest.requestedValue)
    $commitSha = if ($PluginRequest.buildInfo) { [string]$PluginRequest.buildInfo.commitSha } else { "" }
    $packageSha256 = if ($PluginRequest.buildInfo) { [string]$PluginRequest.buildInfo.packageSha256 } else { "" }
    $packageMd5 = if ($PluginRequest.buildInfo) { [string]$PluginRequest.buildInfo.packageMd5 } else { "" }
    $installScript = @'
plugin_url="$1"
source_type="$2"
requested_value="$3"
display_version="$4"
commit_sha="$5"
package_sha256="$6"
package_md5="$7"

set -euo pipefail

plugin_root="/boot/config/plugins/buddybackup"
marker_path="$plugin_root/testlab-plugin-source.json"

plugin install "$plugin_url" forced

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
    $cmd = Convert-ToRemoteBashScriptCommand -Script $installScript -Arguments @(
        $url,
        [string]$PluginRequest.sourceType,
        [string]$PluginRequest.requestedValue,
        [string]$PluginRequest.displayVersion,
        $commitSha,
        $packageSha256,
        $packageMd5
    )
    $maxPluginInstallAttempts = 3
    $attempts = @()
    $result = $null

    for ($pluginInstallAttempt = 1; $pluginInstallAttempt -le $maxPluginInstallAttempts; $pluginInstallAttempt++) {
        $result = Invoke-RemoteCommand -User $NodeConnection.User -TargetHost $NodeConnection.Host -Port $NodeConnection.Port -IdentityFile $NodeConnection.IdentityFile -Command $cmd -Label "plugin-install" -DoExecute:$DoExecute

        if ($DoExecute -and -not $result.Success -and $result.Output -match '(?i)not reinstalling same version') {
            $result.ExitCode = 0
            $result.Success = $true
        }

        $attempts += $result
        if ($result.Success) {
            break
        }

        if ($DoExecute -and $pluginInstallAttempt -lt $maxPluginInstallAttempts) {
            Start-Sleep -Seconds 5
        }
    }

    $results = @()
    if ($result) {
        $results += (New-RetrySummaryResult -Result $result -Attempts $attempts)
    }

    if ($result -and $result.Success) {
        $results += [pscustomobject]@{
            Label = 'plugin-source-metadata'
            Command = 'write BuddyBackup plugin source metadata'
            ExitCode = 0
            Output = 'plugin source metadata written to /boot/config/plugins/buddybackup/testlab-plugin-source.json'
            Success = $true
        }
    }

    return $results
}

function Collect-NodeArtifacts {
    param(
        $Lab,
        [string]$NodeName,
        $NodeConnection,
        [string]$CellDir,
        [switch]$DoExecute
    )

    $nodeDir = Join-Path -Path $CellDir -ChildPath $NodeName
    Ensure-Dir -Path $nodeDir

    $commands = @(
        @{ Name = "plugin-list"; Cmd = "plugin list" },
        @{ Name = "plugin-source"; Cmd = "test -f /boot/config/plugins/buddybackup/testlab-plugin-source.json && cat /boot/config/plugins/buddybackup/testlab-plugin-source.json || echo '(missing testlab-plugin-source.json)'" },
        @{ Name = "buddybackup-log"; Cmd = "test -f /var/log/buddybackup.log && cat /var/log/buddybackup.log || echo '(missing /var/log/buddybackup.log)'" },
        @{ Name = "buddybackup-cfg"; Cmd = "test -f /boot/config/plugins/buddybackup/buddybackup.cfg && cat /boot/config/plugins/buddybackup/buddybackup.cfg || echo '(missing buddybackup.cfg)'" },
        @{ Name = "backups-cfg"; Cmd = "test -f /boot/config/plugins/buddybackup/backups.cfg && cat /boot/config/plugins/buddybackup/backups.cfg || echo '(missing backups.cfg)'" },
        @{ Name = "snapshots-cfg"; Cmd = "test -f /boot/config/plugins/buddybackup/snapshots.cfg && cat /boot/config/plugins/buddybackup/snapshots.cfg || echo '(missing snapshots.cfg)'" },
        @{ Name = "sanoid-cfg"; Cmd = "test -f /boot/config/plugins/buddybackup/sanoid.conf && cat /boot/config/plugins/buddybackup/sanoid.conf || echo '(missing sanoid.conf)'" },
        @{ Name = "uname"; Cmd = "uname -a" },
        @{ Name = "uptime"; Cmd = "uptime" }
    )

    foreach ($item in $commands) {
        $result = Invoke-RemoteCommand -User $NodeConnection.User -TargetHost $NodeConnection.Host -Port $NodeConnection.Port -IdentityFile $NodeConnection.IdentityFile -Command $item.Cmd -Label $item.Name -DoExecute:$DoExecute
        $artifactPath = Join-Path -Path $nodeDir -ChildPath ("{0}.txt" -f $item.Name)
        $content = @(
            "label=$($result.Label)",
            "exitCode=$($result.ExitCode)",
            "command=$($result.Command)",
            "output:",
            $result.Output
        ) -join [Environment]::NewLine
        Set-Content -Path $artifactPath -Value $content
    }
}

function Run-Scenario {
    param(
        [string]$Scenario,
        $Lab,
        $Cell,
        [string]$CellDir,
        [hashtable]$ScenarioCache,
        [switch]$DoExecute
    )

    $sender = Get-NodeConnection -Lab $Lab -NodeName "nodeA"
    $receiver = Get-NodeConnection -Lab $Lab -NodeName "nodeB"

    $results = @()
    $pluginVerifyCommand = Get-BuddyBackupPluginVerifyCommand
    $manualAccessVerifyCommand = Get-ManualAccessVerifyCommand -Lab $Lab
    $manualAccessVerifyLoggedCommand = Get-ManualAccessVerifyLoggedCommand

    Write-Host "[testlab] Starting scenario '$Scenario' for cell $($Cell.id)"

    switch ($Scenario) {
        "fresh-install" {
            $results += Install-Plugin -Lab $Lab -NodeConnection $sender -PluginRequest $Cell.nodeAPluginRequest -DoExecute:$DoExecute
            $results += Install-Plugin -Lab $Lab -NodeConnection $receiver -PluginRequest $Cell.nodeBPluginRequest -DoExecute:$DoExecute
        }
        "upgrade-preserves-config" {
            $senderUpgradeFromRequest = if ($Cell.PSObject.Properties['nodeAUpgradeFromPluginRequest']) { $Cell.nodeAUpgradeFromPluginRequest } else { $Cell.senderUpgradeFromPluginRequest }
            $receiverUpgradeFromRequest = if ($Cell.PSObject.Properties['nodeBUpgradeFromPluginRequest']) { $Cell.nodeBUpgradeFromPluginRequest } else { $Cell.receiverUpgradeFromPluginRequest }
            if ($null -eq $senderUpgradeFromRequest -or $null -eq $receiverUpgradeFromRequest) {
                throw "Scenario 'upgrade-preserves-config' requires nodeA.upgradeFromPlugin and nodeB.upgradeFromPlugin in cell $($Cell.id)."
            }

            $functionalCfg = Get-FunctionalTestConfig -Lab $Lab
            $zfsValues = Get-SetupZfsValues -Lab $Lab
            $senderPlan = Get-UpgradeScenarioNodePlan -NodeName "nodeA" -Connection $sender -ZfsValues $zfsValues -FunctionalCfg $functionalCfg
            $receiverPlan = Get-UpgradeScenarioNodePlan -NodeName "nodeB" -Connection $receiver -ZfsValues $zfsValues -FunctionalCfg $functionalCfg
            $senderPlan | Add-Member -NotePropertyName RemoteDestinationDataset -NotePropertyValue "$($receiverPlan.ReceiveRootDataset)/from-nodeA" -Force
            $senderPlan | Add-Member -NotePropertyName RemoteHost -NotePropertyValue $(if ($receiver.Port -eq 22) { $receiver.Host } else { $receiverPlan.AliasIp }) -Force
            $senderPlan | Add-Member -NotePropertyName PeerAliasIp -NotePropertyValue $receiverPlan.AliasIp -Force
            $receiverPlan | Add-Member -NotePropertyName RemoteDestinationDataset -NotePropertyValue "$($senderPlan.ReceiveRootDataset)/from-nodeB" -Force
            $receiverPlan | Add-Member -NotePropertyName RemoteHost -NotePropertyValue $(if ($sender.Port -eq 22) { $sender.Host } else { $senderPlan.AliasIp }) -Force
            $receiverPlan | Add-Member -NotePropertyName PeerAliasIp -NotePropertyValue $senderPlan.AliasIp -Force

            $results += Install-Plugin -Lab $Lab -NodeConnection $sender -PluginRequest $senderUpgradeFromRequest -DoExecute:$DoExecute
            $results += Install-Plugin -Lab $Lab -NodeConnection $receiver -PluginRequest $receiverUpgradeFromRequest -DoExecute:$DoExecute

            $senderKeyInfo = Get-RemoteFileValue -NodeConnection $sender -Path "/boot/config/plugins/buddybackup/buddybackup_sender_key.pub" -Label "nodeA-upgrade-public-key" -DoExecute:$DoExecute
            $receiverKeyInfo = Get-RemoteFileValue -NodeConnection $receiver -Path "/boot/config/plugins/buddybackup/buddybackup_sender_key.pub" -Label "nodeB-upgrade-public-key" -DoExecute:$DoExecute
            $results += $senderKeyInfo.Result
            $results += $receiverKeyInfo.Result

            $setupScript = New-UpgradePreservesConfigSetupScript
            if (-not $DoExecute -or (($senderKeyInfo.Result.Success -and $senderKeyInfo.Value) -and ($receiverKeyInfo.Result.Success -and $receiverKeyInfo.Value))) {
                $senderSetupCommand = Convert-ToRemoteBashScriptCommand -Script $setupScript -Arguments @(
                    'nodeA',
                    [string]$senderPlan.SourceDataset,
                    [string]$senderPlan.SourceMountpoint,
                    [string]$senderPlan.LocalBackupDataset,
                    [string]$senderPlan.ReceiveRootDataset,
                    [string]$senderPlan.RemoteBackupUid,
                    [string]$senderPlan.LocalBackupUid,
                    [string]$senderPlan.SnapshotUid,
                    [string]$senderPlan.RemoteHost,
                    [string]$senderPlan.RemoteDestinationDataset,
                    [string]$functionalCfg.allowUnencryptedRemoteBackups,
                    [string]$(if ($receiverKeyInfo.Value) { $receiverKeyInfo.Value } else { 'dry-run' }),
                    [string]$functionalCfg.hostGatewayIp,
                    [string]$receiver.Port,
                    [string]$senderPlan.PeerAliasIp
                )
                $receiverSetupCommand = Convert-ToRemoteBashScriptCommand -Script $setupScript -Arguments @(
                    'nodeB',
                    [string]$receiverPlan.SourceDataset,
                    [string]$receiverPlan.SourceMountpoint,
                    [string]$receiverPlan.LocalBackupDataset,
                    [string]$receiverPlan.ReceiveRootDataset,
                    [string]$receiverPlan.RemoteBackupUid,
                    [string]$receiverPlan.LocalBackupUid,
                    [string]$receiverPlan.SnapshotUid,
                    [string]$receiverPlan.RemoteHost,
                    [string]$receiverPlan.RemoteDestinationDataset,
                    [string]$functionalCfg.allowUnencryptedRemoteBackups,
                    [string]$(if ($senderKeyInfo.Value) { $senderKeyInfo.Value } else { 'dry-run' }),
                    [string]$functionalCfg.hostGatewayIp,
                    [string]$sender.Port,
                    [string]$receiverPlan.PeerAliasIp
                )
                $results += Invoke-RemoteCommand -User $sender.User -TargetHost $sender.Host -Port $sender.Port -IdentityFile $sender.IdentityFile -Command $senderSetupCommand -LoggedCommand "seed pre-upgrade BuddyBackup state on nodeA" -Label "nodeA-upgrade-seed" -DoExecute:$DoExecute
                $results += Invoke-RemoteCommand -User $receiver.User -TargetHost $receiver.Host -Port $receiver.Port -IdentityFile $receiver.IdentityFile -Command $receiverSetupCommand -LoggedCommand "seed pre-upgrade BuddyBackup state on nodeB" -Label "nodeB-upgrade-seed" -DoExecute:$DoExecute
            } else {
                $results += [pscustomobject]@{
                    Label = 'upgrade-seed-prerequisites'
                    Command = 'read BuddyBackup public keys'
                    ExitCode = 1
                    Output = 'Failed to read the BuddyBackup public keys needed to seed pre-upgrade state.'
                    Success = $false
                }
            }

            $senderBefore = Get-UpgradeStateSnapshot -NodeName 'nodeA' -NodeConnection $sender -DoExecute:$DoExecute
            $receiverBefore = Get-UpgradeStateSnapshot -NodeName 'nodeB' -NodeConnection $receiver -DoExecute:$DoExecute
            $results += $senderBefore.Result
            $results += $receiverBefore.Result

            if ($DoExecute) {
                if ($senderBefore.Snapshot) {
                    $senderBefore.Snapshot | ConvertTo-Json -Depth 6 | Set-Content -Path (Join-Path $CellDir 'nodeA-upgrade-state-before.json')
                    $senderBeforeCheck = Test-UpgradeStateSnapshot -NodeName 'nodeA' -Snapshot $senderBefore.Snapshot -Plan $senderPlan -AllowUnencryptedRemoteBackups $functionalCfg.allowUnencryptedRemoteBackups
                    $results += [pscustomobject]@{
                        Label = 'nodeA-upgrade-before-sanity'
                        Command = 'verify seeded pre-upgrade BuddyBackup state'
                        ExitCode = if ($senderBeforeCheck.Success) { 0 } else { 1 }
                        Output = if ($senderBeforeCheck.Success) { 'Seeded pre-upgrade state is present.' } else { $senderBeforeCheck.Error }
                        Success = $senderBeforeCheck.Success
                    }
                }

                if ($receiverBefore.Snapshot) {
                    $receiverBefore.Snapshot | ConvertTo-Json -Depth 6 | Set-Content -Path (Join-Path $CellDir 'nodeB-upgrade-state-before.json')
                    $receiverBeforeCheck = Test-UpgradeStateSnapshot -NodeName 'nodeB' -Snapshot $receiverBefore.Snapshot -Plan $receiverPlan -AllowUnencryptedRemoteBackups $functionalCfg.allowUnencryptedRemoteBackups
                    $results += [pscustomobject]@{
                        Label = 'nodeB-upgrade-before-sanity'
                        Command = 'verify seeded pre-upgrade BuddyBackup state'
                        ExitCode = if ($receiverBeforeCheck.Success) { 0 } else { 1 }
                        Output = if ($receiverBeforeCheck.Success) { 'Seeded pre-upgrade state is present.' } else { $receiverBeforeCheck.Error }
                        Success = $receiverBeforeCheck.Success
                    }
                }
            } else {
                $results += [pscustomobject]@{
                    Label = 'nodeA-upgrade-before-sanity'
                    Command = 'verify seeded pre-upgrade BuddyBackup state'
                    ExitCode = 0
                    Output = 'dry-run'
                    Success = $true
                }
                $results += [pscustomobject]@{
                    Label = 'nodeB-upgrade-before-sanity'
                    Command = 'verify seeded pre-upgrade BuddyBackup state'
                    ExitCode = 0
                    Output = 'dry-run'
                    Success = $true
                }
            }

            $results += Install-Plugin -Lab $Lab -NodeConnection $sender -PluginRequest $Cell.nodeAPluginRequest -DoExecute:$DoExecute
            $results += Install-Plugin -Lab $Lab -NodeConnection $receiver -PluginRequest $Cell.nodeBPluginRequest -DoExecute:$DoExecute

            $senderAfter = Get-UpgradeStateSnapshot -NodeName 'nodeA' -NodeConnection $sender -DoExecute:$DoExecute
            $receiverAfter = Get-UpgradeStateSnapshot -NodeName 'nodeB' -NodeConnection $receiver -DoExecute:$DoExecute
            $results += $senderAfter.Result
            $results += $receiverAfter.Result

            if ($DoExecute) {
                if ($senderAfter.Snapshot) {
                    $senderAfter.Snapshot | ConvertTo-Json -Depth 6 | Set-Content -Path (Join-Path $CellDir 'nodeA-upgrade-state-after.json')
                }
                if ($receiverAfter.Snapshot) {
                    $receiverAfter.Snapshot | ConvertTo-Json -Depth 6 | Set-Content -Path (Join-Path $CellDir 'nodeB-upgrade-state-after.json')
                }

                if ($senderBefore.Snapshot -and $senderAfter.Snapshot) {
                    $senderCompare = Compare-UpgradeStateSnapshots -NodeName 'nodeA' -Before $senderBefore.Snapshot -After $senderAfter.Snapshot
                    $results += [pscustomobject]@{
                        Label = 'nodeA-upgrade-state-compare'
                        Command = 'compare pre-upgrade and post-upgrade BuddyBackup state'
                        ExitCode = if ($senderCompare.Success) { 0 } else { 1 }
                        Output = if ($senderCompare.Success) { 'BuddyBackup state was preserved across the upgrade.' } else { $senderCompare.Error }
                        Success = $senderCompare.Success
                    }
                }

                if ($receiverBefore.Snapshot -and $receiverAfter.Snapshot) {
                    $receiverCompare = Compare-UpgradeStateSnapshots -NodeName 'nodeB' -Before $receiverBefore.Snapshot -After $receiverAfter.Snapshot
                    $results += [pscustomobject]@{
                        Label = 'nodeB-upgrade-state-compare'
                        Command = 'compare pre-upgrade and post-upgrade BuddyBackup state'
                        ExitCode = if ($receiverCompare.Success) { 0 } else { 1 }
                        Output = if ($receiverCompare.Success) { 'BuddyBackup state was preserved across the upgrade.' } else { $receiverCompare.Error }
                        Success = $receiverCompare.Success
                    }
                }
            } else {
                $results += [pscustomobject]@{
                    Label = 'nodeA-upgrade-state-compare'
                    Command = 'compare pre-upgrade and post-upgrade BuddyBackup state'
                    ExitCode = 0
                    Output = 'dry-run'
                    Success = $true
                }
                $results += [pscustomobject]@{
                    Label = 'nodeB-upgrade-state-compare'
                    Command = 'compare pre-upgrade and post-upgrade BuddyBackup state'
                    ExitCode = 0
                    Output = 'dry-run'
                    Success = $true
                }
            }
        }
        "post-reboot" {
            $results += Install-Plugin -Lab $Lab -NodeConnection $sender -PluginRequest $Cell.nodeAPluginRequest -DoExecute:$DoExecute
            $results += Install-Plugin -Lab $Lab -NodeConnection $receiver -PluginRequest $Cell.nodeBPluginRequest -DoExecute:$DoExecute

            $timeout = 300
            if ($Lab.timeouts -and $Lab.timeouts.sshReadySeconds) {
                $timeout = [int]$Lab.timeouts.sshReadySeconds
            }

            $zfsValues = Get-SetupZfsValues -Lab $Lab

            $rebootSettleSeconds = 0
            if ($Lab.timeouts -and $Lab.timeouts.rebootSettleSeconds) {
                $rebootSettleSeconds = [int]$Lab.timeouts.rebootSettleSeconds
            }

            $nodeSnapshots = @{}

            foreach ($node in @(
                [pscustomobject]@{ Name = "nodeA"; Connection = $sender },
                [pscustomobject]@{ Name = "nodeB"; Connection = $receiver }
            )) {
                Write-Host "[testlab] Scenario 'post-reboot': validating reboot persistence on $($node.Name)"
                $manualAccessLabel = "$($node.Name)-manual-access-check"

                $beforeSnapshot = Get-UpgradeStateSnapshot -NodeName $node.Name -NodeConnection $node.Connection -DoExecute:$DoExecute
                $results += $beforeSnapshot.Result
                if ($DoExecute -and (-not $beforeSnapshot.Result.Success -or $null -eq $beforeSnapshot.Snapshot)) {
                    throw "Failed to capture BuddyBackup state before reboot for $($node.Name)."
                }
                if ($DoExecute) {
                    $nodeSnapshots[$node.Name] = [ordered]@{
                        Before = $beforeSnapshot.Snapshot
                    }
                }

                $beforeBootId = Get-RemoteBootId -User $node.Connection.User -TargetHost $node.Connection.Host -Port $node.Connection.Port -IdentityFile $node.Connection.IdentityFile -Label "$($node.Name)-boot-id-before-reboot" -DoExecute:$DoExecute
                $results += $beforeBootId.Result
                if ($DoExecute -and (-not $beforeBootId.Result.Success -or [string]::IsNullOrWhiteSpace($beforeBootId.BootId))) {
                    throw "Failed to read boot_id before reboot for $($node.Name)."
                }

                $results += Invoke-RemoteCommand -User $node.Connection.User -TargetHost $node.Connection.Host -Port $node.Connection.Port -IdentityFile $node.Connection.IdentityFile -Command "reboot" -Label "$($node.Name)-reboot" -DoExecute:$DoExecute

                if ($DoExecute) {
                    $rebootCycle = Wait-ForRebootCycle -User $node.Connection.User -TargetHost $node.Connection.Host -Port $node.Connection.Port -IdentityFile $node.Connection.IdentityFile -PreviousBootId $beforeBootId.BootId -TimeoutSeconds $timeout -SettleSeconds $rebootSettleSeconds -ReadyCommand $manualAccessVerifyCommand -ReadyLoggedCommand $manualAccessVerifyLoggedCommand -ReadyLabel $manualAccessLabel
                    if (-not $rebootCycle.Success) {
                        throw "$($node.Name) reboot validation failed: $($rebootCycle.Error)"
                    }

                    if ($rebootCycle.ReadyResult) {
                        $results += $rebootCycle.ReadyResult
                    }

                    $pluginCheck = Wait-ForRemoteSuccess -User $node.Connection.User -TargetHost $node.Connection.Host -Port $node.Connection.Port -IdentityFile $node.Connection.IdentityFile -Command $pluginVerifyCommand -Label "$($node.Name)-plugin-check" -TimeoutSeconds $timeout
                    $results += $pluginCheck.Result

                    $zpoolCheck = Wait-ForRemoteSuccess -User $node.Connection.User -TargetHost $node.Connection.Host -Port $node.Connection.Port -IdentityFile $node.Connection.IdentityFile -Command ("zpool list -H -o name {0}" -f $zfsValues.PoolName) -Label "$($node.Name)-zpool-check" -TimeoutSeconds $timeout
                    $results += $zpoolCheck.Result

                    $plainDatasetCheck = Wait-ForRemoteSuccess -User $node.Connection.User -TargetHost $node.Connection.Host -Port $node.Connection.Port -IdentityFile $node.Connection.IdentityFile -Command ("zfs list -H -o name {0}" -f $zfsValues.UnencryptedDataset) -Label "$($node.Name)-plain-dataset-check" -TimeoutSeconds $timeout
                    $results += $plainDatasetCheck.Result

                    $encryptedDatasetCheck = Wait-ForRemoteSuccess -User $node.Connection.User -TargetHost $node.Connection.Host -Port $node.Connection.Port -IdentityFile $node.Connection.IdentityFile -Command ("zfs get -H -o value encryption {0}" -f $zfsValues.EncryptedDataset) -Label "$($node.Name)-encrypted-dataset-check" -TimeoutSeconds $timeout
                    $results += $encryptedDatasetCheck.Result

                    $afterSnapshot = Get-UpgradeStateSnapshot -NodeName $node.Name -NodeConnection $node.Connection -DoExecute:$DoExecute
                    $results += $afterSnapshot.Result
                    if (-not $afterSnapshot.Result.Success -or $null -eq $afterSnapshot.Snapshot) {
                        throw "Failed to capture BuddyBackup state after reboot for $($node.Name)."
                    }

                    $stateCompare = Compare-UpgradeStateSnapshots -NodeName $node.Name -Before $nodeSnapshots[$node.Name].Before -After $afterSnapshot.Snapshot
                    $results += [pscustomobject]@{
                        Label = "$($node.Name)-post-reboot-state-compare"
                        Command = "compare pre-reboot and post-reboot BuddyBackup state"
                        ExitCode = if ($stateCompare.Success) { 0 } else { 1 }
                        Output = if ($stateCompare.Success) { "State persisted across reboot." } else { $stateCompare.Error }
                        Success = $stateCompare.Success
                    }
                    if (-not $stateCompare.Success) {
                        throw "$($node.Name) BuddyBackup state changed across reboot: $($stateCompare.Error)"
                    }
                } else {
                    $results += [pscustomobject]@{
                        Label = "$($node.Name)-post-reboot-state-compare"
                        Command = "compare pre-reboot and post-reboot BuddyBackup state"
                        ExitCode = 0
                        Output = 'dry-run'
                        Success = $true
                    }
                    $results += Invoke-RemoteCommand -User $node.Connection.User -TargetHost $node.Connection.Host -Port $node.Connection.Port -IdentityFile $node.Connection.IdentityFile -Command $pluginVerifyCommand -Label "$($node.Name)-plugin-check" -DoExecute:$DoExecute
                    $results += Invoke-RemoteCommand -User $node.Connection.User -TargetHost $node.Connection.Host -Port $node.Connection.Port -IdentityFile $node.Connection.IdentityFile -Command $manualAccessVerifyCommand -LoggedCommand $manualAccessVerifyLoggedCommand -Label "$($node.Name)-manual-access-check" -DoExecute:$DoExecute
                    $results += Invoke-RemoteCommand -User $node.Connection.User -TargetHost $node.Connection.Host -Port $node.Connection.Port -IdentityFile $node.Connection.IdentityFile -Command ("zpool list -H -o name {0}" -f $zfsValues.PoolName) -Label "$($node.Name)-zpool-check" -DoExecute:$DoExecute
                    $results += Invoke-RemoteCommand -User $node.Connection.User -TargetHost $node.Connection.Host -Port $node.Connection.Port -IdentityFile $node.Connection.IdentityFile -Command ("zfs list -H -o name {0}" -f $zfsValues.UnencryptedDataset) -Label "$($node.Name)-plain-dataset-check" -DoExecute:$DoExecute
                    $results += Invoke-RemoteCommand -User $node.Connection.User -TargetHost $node.Connection.Host -Port $node.Connection.Port -IdentityFile $node.Connection.IdentityFile -Command ("zfs get -H -o value encryption {0}" -f $zfsValues.EncryptedDataset) -Label "$($node.Name)-encrypted-dataset-check" -DoExecute:$DoExecute
                }
            }
        }
        "backup-smoke" {
            $functionalSmoke = Invoke-FunctionalSmokeScenario -LabConfigPath $LabConfig -Lab $Lab -ScenarioCache $ScenarioCache -DoExecute:$DoExecute
            $results += [pscustomobject]@{
                Label = "backup-smoke"
                Command = "run-functional-smoke.ps1"
                ExitCode = if ($functionalSmoke.Success) { 0 } else { 1 }
                Output = if ($functionalSmoke.Success) { "Functional smoke completed successfully.`nreport=$($functionalSmoke.ReportPath)" } else { $functionalSmoke.Error }
                Success = $functionalSmoke.Success
            }
        }
        "restore-smoke" {
            $functionalSmoke = Invoke-FunctionalSmokeScenario -LabConfigPath $LabConfig -Lab $Lab -ScenarioCache $ScenarioCache -DoExecute:$DoExecute
            $results += [pscustomobject]@{
                Label = "restore-smoke"
                Command = "run-functional-smoke.ps1"
                ExitCode = if ($functionalSmoke.Success) { 0 } else { 1 }
                Output = if ($functionalSmoke.Success) { "Functional smoke completed successfully.`nreport=$($functionalSmoke.ReportPath)" } else { $functionalSmoke.Error }
                Success = $functionalSmoke.Success
            }
        }
        default {
            throw "Unknown scenario: $Scenario"
        }
    }

    $scenarioPath = Join-Path -Path $CellDir -ChildPath ("scenario-{0}.json" -f $Scenario)
    $results | ConvertTo-Json -Depth 8 | Set-Content -Path $scenarioPath

    $failed = @($results | Where-Object { -not $_.Success })
    if ($failed.Count -gt 0) {
        $labels = @($failed | ForEach-Object { $_.Label }) -join ","
        return [pscustomobject]@{
            Scenario = $Scenario
            Success = $false
            Error = "Failed command labels: $labels"
        }
    }

    Write-Host "[testlab] Scenario '$Scenario' completed successfully for cell $($Cell.id)"

    return [pscustomobject]@{
        Scenario = $Scenario
        Success = $true
        Error = $null
    }
}

Require-File $LabConfig
Require-File $MatrixConfig

$lab = Get-Json -Path $LabConfig
$matrix = Get-Json -Path $MatrixConfig
$matrixCells = @($matrix.cells)
$matrixVersionResolution = Use-ProvisionedMatrixUnraidVersions -Lab $lab -MatrixCells $matrixCells -Matrix $matrix
$totalCells = $matrixCells.Count

if ($matrixVersionResolution.Applied) {
    Write-Host "[testlab] Matrix will use provisioned lab node Unraid versions: $($matrixVersionResolution.VersionSummary)"
}

$matrixUnraidSupport = Test-LabSupportsMatrixUnraidVersions -Lab $lab -MatrixCells $matrixCells
if (-not $matrixUnraidSupport.Success) {
    throw $matrixUnraidSupport.Error
}

$runId = Get-Date -Format "yyyyMMdd-HHmmss"
$artifactsRoot = $lab.artifactsRoot
if (-not $artifactsRoot) {
    $artifactsRoot = ".testlab/artifacts"
}
$workspaceRoot = Get-TestLabWorkspaceRoot -ScriptRoot $PSScriptRoot
if ([System.IO.Path]::IsPathRooted([string]$artifactsRoot)) {
    $artifactsRoot = [System.IO.Path]::GetFullPath([string]$artifactsRoot)
} else {
    $artifactsRoot = [System.IO.Path]::GetFullPath((Join-Path $workspaceRoot ([string]$artifactsRoot)))
}
Ensure-Dir -Path $artifactsRoot
$runDir = Join-Path $artifactsRoot $runId
Ensure-Dir -Path $runDir


$result = @()
$cellIndex = 0

foreach ($cell in $matrixCells) {
    $cellIndex += 1
    $nodeA = Get-TestLabNodeValue -Object $cell -NodeName 'nodeA'
    $nodeB = Get-TestLabNodeValue -Object $cell -NodeName 'nodeB'
    $nodeAPluginRequest = Resolve-LabPluginRequest -Lab $lab -RequestedValue ([string](Get-ObjectValue -Object $nodeA -Name 'plugin'))
    $nodeBPluginRequest = Resolve-LabPluginRequest -Lab $lab -RequestedValue ([string](Get-ObjectValue -Object $nodeB -Name 'plugin'))
    $cell | Add-Member -NotePropertyName nodeAPluginRequest -NotePropertyValue $nodeAPluginRequest -Force
    $cell | Add-Member -NotePropertyName nodeBPluginRequest -NotePropertyValue $nodeBPluginRequest -Force
    $cell | Add-Member -NotePropertyName senderPluginRequest -NotePropertyValue $nodeAPluginRequest -Force
    $cell | Add-Member -NotePropertyName receiverPluginRequest -NotePropertyValue $nodeBPluginRequest -Force
    $nodeAUpgradeFromPlugin = [string](Get-ObjectValue -Object $nodeA -Name 'upgradeFromPlugin')
    if (-not [string]::IsNullOrWhiteSpace($nodeAUpgradeFromPlugin)) {
        $resolvedNodeAUpgradeFromPlugin = Resolve-LabPluginRequest -Lab $lab -RequestedValue $nodeAUpgradeFromPlugin
        $cell | Add-Member -NotePropertyName nodeAUpgradeFromPluginRequest -NotePropertyValue $resolvedNodeAUpgradeFromPlugin -Force
        $cell | Add-Member -NotePropertyName senderUpgradeFromPluginRequest -NotePropertyValue $resolvedNodeAUpgradeFromPlugin -Force
    }
    $nodeBUpgradeFromPlugin = [string](Get-ObjectValue -Object $nodeB -Name 'upgradeFromPlugin')
    if (-not [string]::IsNullOrWhiteSpace($nodeBUpgradeFromPlugin)) {
        $resolvedNodeBUpgradeFromPlugin = Resolve-LabPluginRequest -Lab $lab -RequestedValue $nodeBUpgradeFromPlugin
        $cell | Add-Member -NotePropertyName nodeBUpgradeFromPluginRequest -NotePropertyValue $resolvedNodeBUpgradeFromPlugin -Force
        $cell | Add-Member -NotePropertyName receiverUpgradeFromPluginRequest -NotePropertyValue $resolvedNodeBUpgradeFromPlugin -Force
    }
    Write-Host "[testlab] Running cell $($cell.id) ($cellIndex/$totalCells) lifecycle=$($cell.lifecycle)"
    $status = "pass"
    $errors = @()
    $scenarioResults = @()
    $scenarioCache = @{}
    $cellDir = Join-Path -Path $runDir -ChildPath $cell.id
    Ensure-Dir -Path $cellDir

    $setupCfg = Get-ObjectValue -Object $lab -Name "setup"
    $runBaseSetupVerification = $true
    $runBaseSetupVerificationValue = Get-ObjectValue -Object $setupCfg -Name "verifyBaseConfigInMatrix"
    if ($null -ne $runBaseSetupVerificationValue) {
        $runBaseSetupVerification = [bool]$runBaseSetupVerificationValue
    }

    if ($runBaseSetupVerification) {
        try {
            Write-Host "[testlab] Running base setup verification for cell $($cell.id)"
            $baseSetupRun = Run-BaseSetupVerification -Lab $lab -CellDir $cellDir -DoExecute:$Execute
            $scenarioResults += $baseSetupRun
            if (-not $baseSetupRun.Success) {
                $status = "fail"
                $errors += "Scenario 'base-setup-verify' failed: $($baseSetupRun.Error)"
                Write-Warning "Base setup verification failed for cell $($cell.id): $($baseSetupRun.Error)"
            } else {
                Write-Host "[testlab] Base setup verification passed for cell $($cell.id)"
            }
        } catch {
            $status = "fail"
            $errors += "Scenario 'base-setup-verify' failed: $($_.Exception.Message)"
            Write-Warning "Base setup verification failed for cell $($cell.id): $($_.Exception.Message)"
            $scenarioResults += [pscustomobject]@{
                Scenario = "base-setup-verify"
                Success = $false
                Error = $_.Exception.Message
            }
        }
    }

    foreach ($scenario in $cell.scenarios) {
        try {
            $scenarioRun = Run-Scenario -Scenario $scenario -Lab $lab -Cell $cell -CellDir $cellDir -ScenarioCache $scenarioCache -DoExecute:$Execute
            $scenarioResults += $scenarioRun
            if (-not $scenarioRun.Success) {
                $status = "fail"
                $errors += "Scenario '$scenario' failed: $($scenarioRun.Error)"
                Write-Warning "Scenario '$scenario' failed for cell $($cell.id): $($scenarioRun.Error)"
            } else {
                Write-Host "[testlab] Scenario '$scenario' passed for cell $($cell.id)"
            }
        } catch {
            $status = "fail"
            $errors += "Scenario '$scenario' failed: $($_.Exception.Message)"
            Write-Warning "Scenario '$scenario' failed for cell $($cell.id): $($_.Exception.Message)"
            $scenarioResults += [pscustomobject]@{
                Scenario = $scenario
                Success = $false
                Error = $_.Exception.Message
            }
        }
    }

    if (-not $SkipArtifacts) {
        try {
            Write-Host "[testlab] Collecting artifacts for cell $($cell.id)"
            Collect-NodeArtifacts -Lab $lab -NodeName "nodeA" -NodeConnection (Get-NodeConnection -Lab $lab -NodeName "nodeA") -CellDir $cellDir -DoExecute:$Execute
            Collect-NodeArtifacts -Lab $lab -NodeName "nodeB" -NodeConnection (Get-NodeConnection -Lab $lab -NodeName "nodeB") -CellDir $cellDir -DoExecute:$Execute
        } catch {
            $status = "fail"
            $errors += "Artifact collection failed: $($_.Exception.Message)"
            Write-Warning "Artifact collection failed for cell $($cell.id): $($_.Exception.Message)"
        }
    }

    $result += [pscustomobject]@{
        runId = $runId
        cellId = $cell.id
        nodeAUnraid = [string](Get-ObjectValue -Object $nodeA -Name 'unraid')
        nodeBUnraid = [string](Get-ObjectValue -Object $nodeB -Name 'unraid')
        nodeAPlugin = $nodeAPluginRequest.displayVersion
        nodeAPluginRequested = $nodeAPluginRequest.requestedValue
        nodeAPluginResolved = $nodeAPluginRequest.displayVersion
        nodeAPluginSource = $nodeAPluginRequest.sourceType
        nodeAUpgradeFromPluginRequested = if ($cell.PSObject.Properties['nodeAUpgradeFromPluginRequest']) { [string]$cell.nodeAUpgradeFromPluginRequest.requestedValue } else { $null }
        nodeAUpgradeFromPluginResolved = if ($cell.PSObject.Properties['nodeAUpgradeFromPluginRequest']) { [string]$cell.nodeAUpgradeFromPluginRequest.displayVersion } else { $null }
        nodeBPlugin = $nodeBPluginRequest.displayVersion
        nodeBPluginRequested = $nodeBPluginRequest.requestedValue
        nodeBPluginResolved = $nodeBPluginRequest.displayVersion
        nodeBPluginSource = $nodeBPluginRequest.sourceType
        nodeBUpgradeFromPluginRequested = if ($cell.PSObject.Properties['nodeBUpgradeFromPluginRequest']) { [string]$cell.nodeBUpgradeFromPluginRequest.requestedValue } else { $null }
        nodeBUpgradeFromPluginResolved = if ($cell.PSObject.Properties['nodeBUpgradeFromPluginRequest']) { [string]$cell.nodeBUpgradeFromPluginRequest.displayVersion } else { $null }
        categories = @((Get-ObjectValue -Object $cell -Name "categories") | Where-Object { $null -ne $_ })
        purpose = [string](Get-ObjectValue -Object $cell -Name "purpose")
        lifecycle = $cell.lifecycle
        status = $status
        errors = $errors
        scenarioResults = $scenarioResults
        artifactDir = $cellDir
        executeMode = [bool]$Execute
    }
}

$outPath = Join-Path $runDir "results.json"
$result | ConvertTo-Json -Depth 8 | Set-Content -Path $outPath
$passCount = @($result | Where-Object { ([string]$_.status).ToLowerInvariant() -eq 'pass' }).Count
$failCount = $result.Count - $passCount
Write-Host "[testlab] Summary: $passCount passed, $failCount failed"
Write-TestLabResultTable -Rows $result
Write-Host "[testlab] Results written to $outPath"
