$script:TestLabWorkspaceBuildInfoCache = @{}

function Ensure-TestLabDir {
    param([string]$Path)

    if (-not (Test-Path -LiteralPath $Path)) {
        New-Item -ItemType Directory -Path $Path -Force | Out-Null
    }
}

function Get-TestLabWorkspaceRoot {
    param([string]$ScriptRoot)

    if ([string]::IsNullOrWhiteSpace($ScriptRoot)) {
        throw "ScriptRoot is required to resolve the testlab workspace root."
    }

    return [System.IO.Path]::GetFullPath((Join-Path $ScriptRoot "..\.."))
}

function Resolve-TestLabWorkspacePath {
    param(
        [string]$WorkspaceRoot,
        [string]$Path
    )

    if ([string]::IsNullOrWhiteSpace($Path)) {
        return $Path
    }

    if ([System.IO.Path]::IsPathRooted($Path)) {
        return [System.IO.Path]::GetFullPath($Path)
    }

    return [System.IO.Path]::GetFullPath((Join-Path $WorkspaceRoot $Path))
}

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
        Output = $output
    }
}

function Get-TestLabPluginDisplayVersion {
    param([string]$WorkspaceRoot)

    $pluginManifestPath = Join-Path $WorkspaceRoot "buddybackup.plg"
    if (-not (Test-Path -LiteralPath $pluginManifestPath)) {
        throw "Missing BuddyBackup manifest: $pluginManifestPath"
    }

    $pluginManifestContent = Get-Content -Raw -Path $pluginManifestPath
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

    if ([string]::IsNullOrWhiteSpace($ConfiguredBuildCacheRoot)) {
        return Join-Path $WorkspaceRoot ".testlab/build-cache"
    }

    return Resolve-TestLabWorkspacePath -WorkspaceRoot $WorkspaceRoot -Path $ConfiguredBuildCacheRoot
}

function Get-TestLabDependencyPackagePaths {
    param([string]$WorkspaceRoot)

    $depsRoot = Join-Path $WorkspaceRoot "deps"
    if (-not (Test-Path -LiteralPath $depsRoot)) {
        return @()
    }

    return @(
        Get-ChildItem -Path $depsRoot -File -ErrorAction SilentlyContinue |
            Where-Object { $_.Name -notmatch '\.md5$' } |
            Sort-Object -Property Name |
            ForEach-Object { $_.FullName }
    )
}

function Get-TestLabWorkspaceBuildInfo {
    param(
        [string]$WorkspaceRoot,
        [string]$ConfiguredBuildCacheRoot,
        [switch]$ForceRebuild
    )

    $buildCacheRoot = Get-TestLabBuildCacheRoot -WorkspaceRoot $WorkspaceRoot -ConfiguredBuildCacheRoot $ConfiguredBuildCacheRoot
    $head = Invoke-TestLabGitCommand -WorkspaceRoot $WorkspaceRoot -Arguments @("rev-parse", "HEAD")
    $shortHead = Invoke-TestLabGitCommand -WorkspaceRoot $WorkspaceRoot -Arguments @("rev-parse", "--short", "HEAD")
    $describe = Invoke-TestLabGitCommand -WorkspaceRoot $WorkspaceRoot -Arguments @("describe", "--always")
    $displayVersion = Get-TestLabPluginDisplayVersion -WorkspaceRoot $WorkspaceRoot

    $cacheKey = "{0}|{1}" -f $WorkspaceRoot, $shortHead.Output.Trim()
    if (-not $ForceRebuild -and $script:TestLabWorkspaceBuildInfoCache.ContainsKey($cacheKey)) {
        return $script:TestLabWorkspaceBuildInfoCache[$cacheKey]
    }

    Ensure-TestLabDir -Path $buildCacheRoot
    $buildRoot = Join-Path $buildCacheRoot ("workspace-{0}" -f $shortHead.Output.Trim())
    Ensure-TestLabDir -Path $buildRoot

    $packagePath = Join-Path $buildRoot "buddybackup.txz"
    $metadataPath = Join-Path $buildRoot "workspace-build.json"
    $srcRoot = Join-Path $WorkspaceRoot "src"

    if (-not (Test-Path -LiteralPath $srcRoot)) {
        throw "Missing BuddyBackup package source directory: $srcRoot"
    }

    $tarCommand = Get-Command tar -ErrorAction SilentlyContinue
    if ($null -eq $tarCommand) {
        throw "The 'tar' command is required to build a workspace BuddyBackup package on this host."
    }

    if (Test-Path -LiteralPath $packagePath) {
        Remove-Item -LiteralPath $packagePath -Force
    }

    $previousErrorActionPreference = $ErrorActionPreference
    try {
        $ErrorActionPreference = "Continue"
        $rawOutput = & $tarCommand.Source "-C" $srcRoot "-cJf" $packagePath "." 2>&1
        $exitCode = $LASTEXITCODE
    } finally {
        $ErrorActionPreference = $previousErrorActionPreference
    }

    if ($exitCode -ne 0 -or -not (Test-Path -LiteralPath $packagePath)) {
        $details = (@($rawOutput | ForEach-Object { [string]$_ }) -join [Environment]::NewLine).Trim()
        throw "Failed to build workspace BuddyBackup package at $packagePath.`n$details"
    }

    $packageMd5 = (Get-FileHash -LiteralPath $packagePath -Algorithm MD5).Hash.ToLowerInvariant()
    $packageSha256 = (Get-FileHash -LiteralPath $packagePath -Algorithm SHA256).Hash.ToLowerInvariant()
    $dependencyPackagePaths = Get-TestLabDependencyPackagePaths -WorkspaceRoot $WorkspaceRoot

    $buildInfo = [pscustomobject]@{
        sourceType = "workspace-build"
        requestedValue = "workspace-build"
        displayVersion = $displayVersion
        commitSha = $head.Output.Trim()
        shortSha = $shortHead.Output.Trim()
        describe = $describe.Output.Trim()
        buildRoot = $buildRoot
        packagePath = $packagePath
        packageMd5 = $packageMd5
        packageSha256 = $packageSha256
        metadataPath = $metadataPath
        dependencyPackagePaths = $dependencyPackagePaths
        generatedAt = (Get-Date).ToString("o")
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

    if ($requested -match '^(?i)(workspace-build|current-commit)$') {
        $buildInfo = Get-TestLabWorkspaceBuildInfo -WorkspaceRoot $WorkspaceRoot -ConfiguredBuildCacheRoot $ConfiguredBuildCacheRoot -ForceRebuild:$ForceRebuild
        return [pscustomobject]@{
            requestedValue = $requested
            sourceType = "workspace-build"
            displayVersion = $buildInfo.displayVersion
            label = "workspace-build"
            buildInfo = $buildInfo
        }
    }

    return [pscustomobject]@{
        requestedValue = $requested
        sourceType = "release-tag"
        displayVersion = $requested
        label = $requested
        buildInfo = $null
    }
}