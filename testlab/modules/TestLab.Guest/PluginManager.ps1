<#
.SYNOPSIS
    Plugin packaging, source resolution, and installation management for BuddyBackup TestLab.
.DESCRIPTION
    Provides manifest display version parsing, workspace-build .txz compilation,
    remote dependency staging caching, and plugin installation runners.
#>

$ErrorActionPreference = "Stop"

$script:TestLabWorkspaceBuildInfoCache = @{}

function Invoke-TestLabGitCommand {
    param(
        [string]$WorkspaceRoot,
        [string[]]$Arguments,
        [switch]$AllowFailure
    )

    $output = (& git -C $WorkspaceRoot @Arguments 2>&1 | Out-String).TrimEnd()
    $exitCode = $LASTEXITCODE
    if (-not $AllowFailure -and $exitCode -ne 0) {
        throw "git $($Arguments -join ' ') failed with exit code $exitCode.`n$output"
    }

    return [pscustomobject]@{
        ExitCode = $exitCode
        Output   = $output
    }
}

function Get-TestLabPluginDisplayVersion {
    param([string]$WorkspaceRoot)

    if ([string]::IsNullOrWhiteSpace($WorkspaceRoot)) {
        $WorkspaceRoot = Get-TestLabWorkspaceRoot -ScriptRoot $PSScriptRoot
    }

    $pluginManifestPath = Join-Path $WorkspaceRoot "buddybackup.plg"
    if (-not (Test-Path -LiteralPath $pluginManifestPath)) {
        throw "Missing BuddyBackup manifest: $pluginManifestPath"
    }

    $resolvedManifestPath = (Resolve-Path -LiteralPath $pluginManifestPath).ProviderPath
    if ([string]::IsNullOrWhiteSpace($resolvedManifestPath)) {
        $resolvedManifestPath = $pluginManifestPath
    }

    $pluginManifestContent = [System.IO.File]::ReadAllText($resolvedManifestPath, [System.Text.Encoding]::UTF8)
    $match = [regex]::Match($pluginManifestContent, '<!ENTITY\s+version\s+"([^"]+)"')
    if (-not $match.Success) {
        throw "Failed to parse BuddyBackup version from $pluginManifestPath"
    }

    return $match.Groups[1].Value
}

function Get-TestLabBuildCacheRoot {
    param(
        [string]$WorkspaceRoot,
        [string]$ConfiguredBuildCacheRoot
    )

    if ([string]::IsNullOrWhiteSpace($WorkspaceRoot)) {
        $WorkspaceRoot = Get-TestLabWorkspaceRoot -ScriptRoot $PSScriptRoot
    }

    if ([string]::IsNullOrWhiteSpace($ConfiguredBuildCacheRoot)) {
        return Join-Path $WorkspaceRoot ".testlab/build-cache"
    }

    return Resolve-TestLabWorkspacePath -WorkspaceRoot $WorkspaceRoot -Path $ConfiguredBuildCacheRoot
}

function Get-TestLabDependencyPackagePaths {
    param([string]$WorkspaceRoot)

    if ([string]::IsNullOrWhiteSpace($WorkspaceRoot)) {
        $WorkspaceRoot = Get-TestLabWorkspaceRoot -ScriptRoot $PSScriptRoot
    }

    $depsRoot = Join-Path $WorkspaceRoot "deps"
    if (-not (Test-Path -LiteralPath $depsRoot)) {
        return @()
    }

    return @(
        Get-ChildItem -Path $depsRoot -File -ErrorAction SilentlyContinue |
            Sort-Object -Property Name |
            ForEach-Object { $_.FullName }
    )
}

function Get-TestLabWorkspaceBuildStagingRoot {
    if (-not [string]::IsNullOrWhiteSpace($env:LOCALAPPDATA) -and (Test-Path -LiteralPath $env:LOCALAPPDATA)) {
        return (Join-Path $env:LOCALAPPDATA "BuddyBackup\workspace-build-staging")
    }

    if (-not [string]::IsNullOrWhiteSpace($env:TEMP) -and (Test-Path -LiteralPath $env:TEMP)) {
        return (Join-Path $env:TEMP "BuddyBackup\workspace-build-staging")
    }

    throw "Could not determine a local staging root for workspace-build packaging."
}

function New-TestLabWorkspacePackage {
    param(
        [string]$SrcRoot,
        [string]$PackagePath
    )

    $tarCommand = Get-Command tar -ErrorAction SilentlyContinue
    if ($null -eq $tarCommand) {
        throw "The 'tar' command is required to build a workspace BuddyBackup package on this host."
    }

    if (Test-Path -LiteralPath $PackagePath) {
        try {
            Remove-Item -LiteralPath $PackagePath -Force -ErrorAction Stop
        } catch {
            [System.IO.File]::Delete($PackagePath)
        }
    }

    if ($env:OS -ne 'Windows_NT') {
        $previousErrorActionPreference = $ErrorActionPreference
        try {
            $ErrorActionPreference = "Continue"
            $rawOutput = & $tarCommand.Source "-C" $SrcRoot "-cJf" $PackagePath "." 2>&1
            $exitCode = $LASTEXITCODE
        } finally {
            $ErrorActionPreference = $previousErrorActionPreference
        }

        if ($exitCode -ne 0 -or -not (Test-Path -LiteralPath $PackagePath)) {
            $details = (@($rawOutput | ForEach-Object { [string]$_ }) -join [Environment]::NewLine).Trim()
            throw "Failed to build workspace BuddyBackup package at $PackagePath.`n$details"
        }

        return
    }

    $stagingRoot = Get-TestLabWorkspaceBuildStagingRoot
    Ensure-TestLabDir -Path $stagingRoot | Out-Null

    $stageRoot = Join-Path $stagingRoot ([guid]::NewGuid().ToString("N"))
    $stageSrcRoot = Join-Path $stageRoot "src"
    $stagePackagePath = Join-Path $stageRoot "buddybackup.txz"

    Ensure-TestLabDir -Path $stageRoot | Out-Null
    try {
        Copy-Item -LiteralPath $SrcRoot -Destination $stageRoot -Recurse -Force

        $wslStageSrcRoot = Convert-WindowsPathToWslPath -WindowsPath $stageSrcRoot
        $wslStagePackagePath = Convert-WindowsPathToWslPath -WindowsPath $stagePackagePath -AllowMissing
        $buildScript = @'
stage_src_root="$1"
stage_package_path="$2"

set -euo pipefail

chmod -R 755 "$stage_src_root"
tar -C "$stage_src_root" -cJf "$stage_package_path" .
'@
        $buildResult = Invoke-WslRootBash -Distro "Ubuntu" -ScriptContent $buildScript -Arguments @($wslStageSrcRoot, $wslStagePackagePath)
        if ($buildResult.ExitCode -ne 0 -or -not (Test-Path -LiteralPath $stagePackagePath)) {
            $details = (@($buildResult.Output | ForEach-Object { [string]$_ }) -join [Environment]::NewLine).Trim()
            throw "Failed to build workspace BuddyBackup package at $PackagePath.`n$details"
        }

        $copied = $false
        for ($retry = 0; $retry -lt 5; $retry++) {
            try {
                Copy-Item -LiteralPath $stagePackagePath -Destination $PackagePath -Force
                $copied = $true
                break
            } catch {
                Start-Sleep -Milliseconds 250
            }
        }
        if (-not $copied) {
            Copy-Item -LiteralPath $stagePackagePath -Destination $PackagePath -Force
        }
    } finally {
        if (Test-Path -LiteralPath $stageRoot) {
            Remove-Item -LiteralPath $stageRoot -Recurse -Force -ErrorAction SilentlyContinue
        }
    }
}

function Get-TestLabWorkspaceBuildInfo {
    param(
        [string]$WorkspaceRoot,
        [string]$ConfiguredBuildCacheRoot,
        [switch]$ForceRebuild
    )

    if ([string]::IsNullOrWhiteSpace($WorkspaceRoot)) {
        $WorkspaceRoot = Get-TestLabWorkspaceRoot -ScriptRoot $PSScriptRoot
    }

    $buildCacheRoot = Get-TestLabBuildCacheRoot -WorkspaceRoot $WorkspaceRoot -ConfiguredBuildCacheRoot $ConfiguredBuildCacheRoot
    $head = Invoke-TestLabGitCommand -WorkspaceRoot $WorkspaceRoot -Arguments @("rev-parse", "HEAD")
    $shortHead = Invoke-TestLabGitCommand -WorkspaceRoot $WorkspaceRoot -Arguments @("rev-parse", "--short", "HEAD")
    $describe = Invoke-TestLabGitCommand -WorkspaceRoot $WorkspaceRoot -Arguments @("describe", "--always")
    $displayVersion = Get-TestLabPluginDisplayVersion -WorkspaceRoot $WorkspaceRoot

    if ($null -eq $script:TestLabWorkspaceBuildInfoCache) {
        $script:TestLabWorkspaceBuildInfoCache = @{}
    }
    $cacheKey = "{0}|{1}" -f $WorkspaceRoot, $shortHead.Output.Trim()
    if (-not $ForceRebuild -and $script:TestLabWorkspaceBuildInfoCache.ContainsKey($cacheKey)) {
        return $script:TestLabWorkspaceBuildInfoCache[$cacheKey]
    }

    Ensure-TestLabDir -Path $buildCacheRoot | Out-Null
    $buildRoot = Join-Path $buildCacheRoot ("workspace-{0}" -f $shortHead.Output.Trim())
    Ensure-TestLabDir -Path $buildRoot | Out-Null

    $packagePath = Join-Path $buildRoot "buddybackup.txz"
    $metadataPath = Join-Path $buildRoot "workspace-build.json"
    $srcRoot = Join-Path $WorkspaceRoot "src"

    if (-not $ForceRebuild -and (Test-Path -LiteralPath $packagePath) -and (Test-Path -LiteralPath $metadataPath)) {
        try {
            $cachedInfo = Get-TestLabJson -Path $metadataPath
            if ($cachedInfo -and $cachedInfo.packageSha256) {
                $script:TestLabWorkspaceBuildInfoCache[$cacheKey] = $cachedInfo
                return $cachedInfo
            }
        } catch { }
    }

    if (-not (Test-Path -LiteralPath $srcRoot)) {
        throw "Missing BuddyBackup package source directory: $srcRoot"
    }

    New-TestLabWorkspacePackage -SrcRoot $srcRoot -PackagePath $packagePath

    $packageMd5 = (Get-FileHash -LiteralPath $packagePath -Algorithm MD5).Hash.ToLowerInvariant()
    $packageSha256 = (Get-FileHash -LiteralPath $packagePath -Algorithm SHA256).Hash.ToLowerInvariant()
    $dependencyPackagePaths = Get-TestLabDependencyPackagePaths -WorkspaceRoot $WorkspaceRoot

    $buildInfo = [pscustomobject]@{
        sourceType             = "workspace-build"
        requestedValue         = "workspace-build"
        displayVersion         = $displayVersion
        commitSha              = $head.Output.Trim()
        shortSha               = $shortHead.Output.Trim()
        describe               = $describe.Output.Trim()
        buildRoot              = $buildRoot
        packagePath            = $packagePath
        packageMd5             = $packageMd5
        packageSha256          = $packageSha256
        metadataPath           = $metadataPath
        dependencyPackagePaths = $dependencyPackagePaths
        generatedAt            = (Get-Date).ToString("o")
    }

    $buildInfo | ConvertTo-Json -Depth 8 | Set-Content -Path $metadataPath
    $script:TestLabWorkspaceBuildInfoCache[$cacheKey] = $buildInfo

    return $buildInfo
}

function Resolve-TestLabPluginRequest {
    param(
        [string]$RequestedValue,
        [string]$WorkspaceRoot,
        [string]$ConfiguredBuildCacheRoot,
        [switch]$ForceRebuild
    )

    $requested = [string]$RequestedValue
    if ([string]::IsNullOrWhiteSpace($requested)) {
        throw "A plugin request value is required."
    }

    if ([string]::IsNullOrWhiteSpace($WorkspaceRoot)) {
        $WorkspaceRoot = Get-TestLabWorkspaceRoot -ScriptRoot $PSScriptRoot
    }

    if ($requested -match '^(?i)(workspace-build|current-commit)$') {
        $buildInfo = Get-TestLabWorkspaceBuildInfo -WorkspaceRoot $WorkspaceRoot -ConfiguredBuildCacheRoot $ConfiguredBuildCacheRoot -ForceRebuild:$ForceRebuild
        return [pscustomobject]@{
            requestedValue = $requested
            sourceType     = "workspace-build"
            displayVersion = $buildInfo.displayVersion
            label          = "workspace-build"
            buildInfo      = $buildInfo
        }
    }

    return [pscustomobject]@{
        requestedValue = $requested
        sourceType     = "release-tag"
        displayVersion = $requested
        label          = $requested
        buildInfo      = $null
    }
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
        $result = Invoke-RemoteCommand -NodeConnection $NodeConnection -Command $command -LoggedCommand "write BuddyBackup plugin source metadata" -Label "plugin-source-metadata" -DoExecute:$DoExecute
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

    $workspaceRoot = Get-TestLabWorkspaceRoot -ScriptRoot $PSScriptRoot
    $pluginManifestPath = (Resolve-Path -LiteralPath (Join-Path $workspaceRoot "buddybackup.plg")).ProviderPath
    $stageTag = if ($buildInfo.shortSha) { $buildInfo.shortSha } elseif ($buildInfo.commitSha) { $buildInfo.commitSha } else { "latest" }
    $remoteStageRoot = "/boot/config/plugins/buddybackup-testlab-staging/{0}" -f $stageTag
    $remoteDepsRoot = "$remoteStageRoot/deps"
    $results = @()
    $commitSha = if ($buildInfo.commitSha) { [string]$buildInfo.commitSha } else { "" }
    $packageSha256 = if ($buildInfo.packageSha256) { [string]$buildInfo.packageSha256 } else { "" }
    $packageMd5 = if ($buildInfo.packageMd5) { [string]$buildInfo.packageMd5 } else { "" }

    $results += Invoke-RemoteUploadWithRetry -NodeConnection $NodeConnection -LocalPaths @($buildInfo.packagePath, $pluginManifestPath) -RemoteDirectory $remoteStageRoot -Label "workspace-build-package-upload" -DoExecute:$DoExecute

    if ($buildInfo.dependencyPackagePaths -and $buildInfo.dependencyPackagePaths.Count -gt 0) {
        $shouldUploadDeps = $true
        if ($DoExecute) {
            # Optimization #3: Check if guest dependency staging cache exists with matching file list
            $checkDepsCmd = "if [ -d '$remoteDepsRoot' ]; then ls -1 '$remoteDepsRoot' 2>/dev/null; fi"
            $depsCheckResult = Invoke-RemoteCommand -NodeConnection $NodeConnection -Command $checkDepsCmd -Label "check-deps-staging" -DoExecute:$DoExecute
            if ($depsCheckResult.Success -and -not [string]::IsNullOrWhiteSpace($depsCheckResult.Output)) {
                $remoteFiles = @($depsCheckResult.Output -split "`r?`n" | ForEach-Object { $_.Trim() } | Where-Object { -not [string]::IsNullOrWhiteSpace($_) } | Sort-Object)
                $localFiles = @($buildInfo.dependencyPackagePaths | ForEach-Object { [System.IO.Path]::GetFileName($_) } | Sort-Object)
                if ($remoteFiles.Count -eq $localFiles.Count) {
                    $mismatch = $false
                    for ($i = 0; $i -lt $localFiles.Count; $i++) {
                        if ($remoteFiles[$i] -ne $localFiles[$i]) {
                            $mismatch = $true
                            break
                        }
                    }
                    if (-not $mismatch) {
                        $shouldUploadDeps = $false
                        Write-Host "[testlab] Guest dependency staging cache hit for $remoteDepsRoot ($($localFiles.Count) packages already staged, skipping upload)"
                        $results += [pscustomobject]@{
                            Label    = 'workspace-build-deps-upload'
                            Command  = "check guest dependency cache: $remoteDepsRoot"
                            ExitCode = 0
                            Output   = "cached ($($localFiles.Count) packages)"
                            Success  = $true
                        }
                    }
                }
            }
        }

        if ($shouldUploadDeps) {
            $results += Invoke-RemoteUploadWithRetry -NodeConnection $NodeConnection -LocalPaths @($buildInfo.dependencyPackagePaths) -RemoteDirectory $remoteDepsRoot -Label "workspace-build-deps-upload" -DoExecute:$DoExecute
        }
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

if [ -d "$stage_root/deps" ]; then
    mkdir -p "$plugin_root/deps"
    cp -a "$stage_root/deps/"* "$plugin_root/deps/"
fi

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
    $results += Invoke-RemoteCommand -NodeConnection $NodeConnection -Command $installCommand -LoggedCommand "install BuddyBackup workspace-build package" -Label "workspace-build-install" -DoExecute:$DoExecute
    if ($results[-1].Success) {
        $results += [pscustomobject]@{
            Label    = 'plugin-source-metadata'
            Command  = 'write BuddyBackup plugin source metadata'
            ExitCode = 0
            Output   = 'plugin source metadata written to /boot/config/plugins/buddybackup/testlab-plugin-source.json'
            Success  = $true
        }
    }

    return $results
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
    $maxPluginInstallAttempts = 8
    $attempts = @()
    $result = $null

    for ($pluginInstallAttempt = 1; $pluginInstallAttempt -le $maxPluginInstallAttempts; $pluginInstallAttempt++) {
        $result = Invoke-RemoteCommand -NodeConnection $NodeConnection -Command $cmd -Label "plugin-install" -DoExecute:$DoExecute

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
            Label    = 'plugin-source-metadata'
            Command  = 'write BuddyBackup plugin source metadata'
            ExitCode = 0
            Output   = 'plugin source metadata written to /boot/config/plugins/buddybackup/testlab-plugin-source.json'
            Success  = $true
        }
    }

    return $results
}
