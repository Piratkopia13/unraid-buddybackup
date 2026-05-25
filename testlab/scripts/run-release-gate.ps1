param(
    [string]$LabConfig = "testlab/config/lab.local.json",
    [string]$MatrixConfig = "testlab/config/matrix.small.json",
    [string]$MatrixProfile,
    [string]$HistoryRoot,
    [string]$CurrentCandidatePlugin,
    [string]$PreviousReleaseVersion,
    [switch]$Execute,
    [switch]$AllowDirtyWorktree,
    [switch]$SkipProvision,
    [switch]$SkipArtifacts
)

$ErrorActionPreference = "Stop"

. (Join-Path $PSScriptRoot "testlab-logging.ps1")
. (Join-Path $PSScriptRoot "testlab-plugin-source.ps1")
. (Join-Path $PSScriptRoot "testlab-repository-history.ps1")
. (Join-Path $PSScriptRoot "testlab-release-matrix.ps1")

function Require-File {
    param([string]$Path)

    if (-not (Test-Path -LiteralPath $Path)) {
        throw "Missing file: $Path"
    }
}

function Ensure-Dir {
    param([string]$Path)

    if (-not (Test-Path -LiteralPath $Path)) {
        New-Item -ItemType Directory -Path $Path | Out-Null
    }
}

function Get-Json {
    param([string]$Path)

    return Get-Content -Raw -Path $Path | ConvertFrom-Json
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

function Get-TestLabLegacyName {
    param([string]$Name)

    switch ($Name) {
        "nodeA" { return "sender" }
        "nodeB" { return "receiver" }
        default { return $null }
    }
}

function Get-TestLabPropertyValue {
    param(
        $Object,
        [string]$Name
    )

    $value = Get-ObjectValue -Object $Object -Name $Name
    if ($null -ne $value) {
        return $value
    }

    if ($Name -like 'nodeA*') {
        return Get-ObjectValue -Object $Object -Name ($Name -replace '^nodeA', 'sender')
    }

    if ($Name -like 'nodeB*') {
        return Get-ObjectValue -Object $Object -Name ($Name -replace '^nodeB', 'receiver')
    }

    return $null
}

function Get-TestLabPropertyOrDefault {
    param(
        $Object,
        [string]$Name,
        $DefaultValue = $null
    )

    $value = Get-TestLabPropertyValue -Object $Object -Name $Name
    if ($null -ne $value) {
        return $value
    }

    return $DefaultValue
}

function Get-TestLabNodeValue {
    param(
        $Object,
        [string]$NodeName
    )

    $value = Get-ObjectValue -Object $Object -Name $NodeName
    if ($null -ne $value) {
        return $value
    }

    $legacyName = Get-TestLabLegacyName -Name $NodeName
    if (-not [string]::IsNullOrWhiteSpace($legacyName)) {
        return Get-ObjectValue -Object $Object -Name $legacyName
    }

    return $null
}

function Get-WorkspaceRoot {
    return [System.IO.Path]::GetFullPath((Join-Path $PSScriptRoot "..\.."))
}

function Get-SafeHostWorkingDirectory {
    if (-not [string]::IsNullOrWhiteSpace($env:TEMP) -and (Test-Path -LiteralPath $env:TEMP)) {
        return [System.IO.Path]::GetFullPath($env:TEMP)
    }

    if (-not [string]::IsNullOrWhiteSpace($env:LOCALAPPDATA) -and (Test-Path -LiteralPath $env:LOCALAPPDATA)) {
        return [System.IO.Path]::GetFullPath($env:LOCALAPPDATA)
    }

    return [System.IO.Path]::GetPathRoot($env:SystemRoot)
}

function Get-TestLabPerlPath {
    $perlCommand = Get-Command -Name "perl.exe" -ErrorAction SilentlyContinue
    if (-not $perlCommand) {
        $perlCommand = Get-Command -Name "perl" -ErrorAction SilentlyContinue
    }
    if ($perlCommand) {
        return [string]$perlCommand.Source
    }

    $gitPerlPath = Join-Path ${env:ProgramFiles} "Git\usr\bin\perl.exe"
    if (Test-Path -LiteralPath $gitPerlPath) {
        return $gitPerlPath
    }

    throw "Unable to find perl.exe. Install Perl or Git for Windows so t/restrict_zfs.t can run."
}

function Invoke-RestrictZfsPreflight {
    param([string]$WorkspaceRoot)

    $testPath = Join-Path $WorkspaceRoot "t/restrict_zfs.t"
    Require-File -Path $testPath

    $perlPath = Get-TestLabPerlPath
    $started = Get-Date
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

        $rawOutput = & $perlPath $testPath 2>&1
        $exitCode = $LASTEXITCODE
    } finally {
        $ErrorActionPreference = $previousErrorActionPreference
        if ($hadNativeCommandPreference) {
            $PSNativeCommandUseErrorActionPreference = $previousNativeCommandUseErrorActionPreference
        }
    }

    $completedAt = Get-Date
    $output = (@($rawOutput | ForEach-Object { [string]$_ }) -join [Environment]::NewLine).TrimEnd()

    return [pscustomobject]@{
        name = "restrict_zfs"
        testPath = $testPath
        perlPath = $perlPath
        startedAt = $started.ToString("o")
        completedAt = $completedAt.ToString("o")
        durationSeconds = [math]::Round((New-TimeSpan -Start $started -End $completedAt).TotalSeconds, 2)
        exitCode = $exitCode
        success = ($exitCode -eq 0)
        output = $output
    }
}

function Resolve-WorkspacePath {
    param([string]$Path)

    if ([string]::IsNullOrWhiteSpace($Path)) {
        return $Path
    }

    if ([System.IO.Path]::IsPathRooted($Path)) {
        return [System.IO.Path]::GetFullPath($Path)
    }

    return [System.IO.Path]::GetFullPath((Join-Path (Get-WorkspaceRoot) $Path))
}

function Invoke-GitCommand {
    param(
        [string[]]$Arguments,
        [switch]$AllowFailure
    )

    $workspaceRoot = Get-WorkspaceRoot
    $output = (& git -C $workspaceRoot @Arguments 2>&1 | Out-String).TrimEnd()
    $exitCode = $LASTEXITCODE

    if (-not $AllowFailure -and $exitCode -ne 0) {
        throw "git $($Arguments -join ' ') failed with exit code $exitCode.`n$output"
    }

    return [pscustomobject]@{
        ExitCode = $exitCode
        Output = $output
    }
}

function Get-GitPreflight {
    param()

    $status = Invoke-GitCommand -Arguments @("status", "--porcelain", "--untracked-files=all")
    $statusLines = @($status.Output -split "`r?`n" | Where-Object { -not [string]::IsNullOrWhiteSpace($_) })

    $head = Invoke-GitCommand -Arguments @("rev-parse", "HEAD")
    $shortHead = Invoke-GitCommand -Arguments @("rev-parse", "--short", "HEAD")
    $branch = Invoke-GitCommand -Arguments @("branch", "--show-current") -AllowFailure
    $commitTimestamp = Invoke-GitCommand -Arguments @("show", "-s", "--format=%cI", "HEAD")
    $describe = Invoke-GitCommand -Arguments @("describe", "--always")

    $branchName = $branch.Output.Trim()
    if ([string]::IsNullOrWhiteSpace($branchName)) {
        $branchName = "(detached)"
    }

    return [pscustomobject]@{
        commitSha = $head.Output.Trim()
        shortSha = $shortHead.Output.Trim()
        branch = $branchName
        commitTimestamp = $commitTimestamp.Output.Trim()
        describe = $describe.Output.Trim()
        clean = ($statusLines.Count -eq 0)
        dirtyEntries = $statusLines
    }
}

function Get-DirtyWorktreeAssessment {
    param(
        $Matrix,
        $GitInfo,
        [switch]$AllowDirty
    )

    $usesWorkspaceBuild = Test-MatrixUsesWorkspaceBuild -Matrix $Matrix
    $assessment = [ordered]@{
        usesWorkspaceBuildCandidate = $usesWorkspaceBuild
        requiresCleanWorktree = $usesWorkspaceBuild
        shouldBlock = $false
        status = "pass"
        message = $null
    }

    if ($GitInfo.clean) {
        return [pscustomobject]$assessment
    }

    if ($AllowDirty) {
        $assessment.status = "warning"
        $assessment.message = "Dirty worktree override is enabled. This run should not be treated as release evidence."
        return [pscustomobject]$assessment
    }

    if ($usesWorkspaceBuild) {
        $details = @($GitInfo.dirtyEntries) -join [Environment]::NewLine
        $assessment.status = "fail"
        $assessment.shouldBlock = $true
        $assessment.message = "Release gate requires a clean worktree when the selected matrix includes workspace-build candidates. Commit, stash, or discard local changes before running tests.`n$details"
        return [pscustomobject]$assessment
    }

    $assessment.status = "warning"
    $assessment.message = "Dirty worktree detected, but the selected matrix installs published BuddyBackup releases only. The run will continue, and a successful execute run may still publish repository history because the installed BuddyBackup artifacts come from published release URLs."
    return [pscustomobject]$assessment
}

function Get-HistoryRoot {
    param(
        [string]$ConfiguredHistoryRoot,
        $Lab
    )

    if (-not [string]::IsNullOrWhiteSpace($ConfiguredHistoryRoot)) {
        return [System.IO.Path]::GetFullPath($ConfiguredHistoryRoot)
    }

    $releaseGateCfg = Get-ObjectValue -Object $Lab -Name "releaseGate"
    $historyRootFromLab = [string](Get-ObjectValue -Object $releaseGateCfg -Name "historyRoot")
    if (-not [string]::IsNullOrWhiteSpace($historyRootFromLab)) {
        if ([System.IO.Path]::IsPathRooted($historyRootFromLab)) {
            return [System.IO.Path]::GetFullPath($historyRootFromLab)
        }

        return Resolve-WorkspacePath -Path $historyRootFromLab
    }

    return Join-Path $env:LOCALAPPDATA "BuddyBackup\TestlabHistory"
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

function Ensure-ReleaseGateConfig {
    param($Lab)

    $releaseGateCfg = Get-ObjectValue -Object $Lab -Name "releaseGate"
    if ($null -ne $releaseGateCfg) {
        return $releaseGateCfg
    }

    $releaseGateCfg = [pscustomobject]@{}
    Set-ObjectValue -Object $Lab -Name "releaseGate" -Value $releaseGateCfg
    return $releaseGateCfg
}

function Apply-ReleaseGateOverrides {
    param(
        $Lab,
        [string]$CurrentCandidatePlugin,
        [string]$PreviousReleaseVersion
    )

    $releaseGateCfg = Ensure-ReleaseGateConfig -Lab $Lab

    if (-not [string]::IsNullOrWhiteSpace($CurrentCandidatePlugin)) {
        Set-ObjectValue -Object $releaseGateCfg -Name "currentCandidatePlugin" -Value $CurrentCandidatePlugin
    }
    if (-not [string]::IsNullOrWhiteSpace($PreviousReleaseVersion)) {
        Set-ObjectValue -Object $releaseGateCfg -Name "previousReleaseVersion" -Value $PreviousReleaseVersion
    }
}

function Get-VersionPolicyMode {
    param($Lab)

    $releaseGateCfg = Get-ObjectValue -Object $Lab -Name "releaseGate"
    $versionPolicyCfg = Get-ObjectValue -Object $releaseGateCfg -Name "versionPolicy"
    $mode = [string](Get-ObjectValue -Object $versionPolicyCfg -Name "mode")
    if ([string]::IsNullOrWhiteSpace($mode)) {
        return "require"
    }

    return $mode.Trim().ToLowerInvariant()
}

function Test-MatrixUsesWorkspaceBuild {
    param($Matrix)

    $cells = @($Matrix.cells)
    foreach ($cell in $cells) {
        $nodeAPlugin = [string](Get-ObjectValue -Object (Get-TestLabNodeValue -Object $cell -NodeName "nodeA") -Name "plugin")
        $nodeBPlugin = [string](Get-ObjectValue -Object (Get-TestLabNodeValue -Object $cell -NodeName "nodeB") -Name "plugin")
        if ($nodeAPlugin -match '^(?i)(workspace-build|current-commit)$' -or $nodeBPlugin -match '^(?i)(workspace-build|current-commit)$') {
            return $true
        }
    }

    return $false
}

function Test-LabSupportsMatrixUnraidVersions {
    param(
        $Lab,
        $Matrix
    )

    $provider = [string](Get-ObjectValue -Object $Lab -Name 'provider')
    $supportedProviders = @('windows-local', 'windows-wsl-qemu', 'manual')
    if ($provider -notin $supportedProviders) {
        return [pscustomobject]@{
            Success = $true
            Error = $null
        }
    }

    $cells = @($Matrix.cells)
    $mismatches = @()
    foreach ($nodeName in @('nodeA', 'nodeB')) {
        $labNode = Get-TestLabNodeValue -Object (Get-ObjectValue -Object $Lab -Name 'nodes') -NodeName $nodeName
        $labVersion = [string](Get-ObjectValue -Object $labNode -Name 'unraidVersion')
        if ([string]::IsNullOrWhiteSpace($labVersion)) {
            continue
        }

        $cellVersions = @($cells | ForEach-Object { [string](Get-ObjectValue -Object (Get-TestLabNodeValue -Object $_ -NodeName $nodeName) -Name 'unraid') } |
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
        Error = "This release-gate run cannot vary Unraid versions per matrix cell. The current provider '$provider' uses the already provisioned lab node versions from the lab config, but the matrix requests different Unraid versions: $details. Provision nodes that match the matrix, or run separate release-gate executions per Unraid baseline instead of mixing them in one run."
    }
}

function Get-VersionPolicyAssessment {
    param(
        $Lab,
        $Matrix,
        [string]$PluginDisplayVersion,
        $GitInfo,
        [switch]$DoExecute,
        [switch]$AllowDirty
    )

    $releaseGateCfg = Get-ObjectValue -Object $Lab -Name "releaseGate"
    $previousReleaseVersion = [string](Get-ObjectValue -Object $releaseGateCfg -Name "previousReleaseVersion")
    $mode = Get-VersionPolicyMode -Lab $Lab
    $usesWorkspaceBuild = Test-MatrixUsesWorkspaceBuild -Matrix $Matrix
    $enforcementActive = ([bool]$DoExecute -and [bool]$GitInfo.clean -and -not [bool]$AllowDirty)

    $assessment = [ordered]@{
        mode = $mode
        enforcementActive = $enforcementActive
        usesWorkspaceBuildCandidate = $usesWorkspaceBuild
        previousReleaseVersion = $previousReleaseVersion
        currentDisplayVersion = $PluginDisplayVersion
        isVersionBumped = $null
        status = "not-applicable"
        message = $null
        shouldBlock = $false
    }

    if (-not $usesWorkspaceBuild) {
        $assessment.status = "not-applicable"
        $assessment.message = "Version bump policy is not applicable because the selected matrix does not include a workspace-build candidate."
        return [pscustomobject]$assessment
    }

    if ([string]::IsNullOrWhiteSpace($previousReleaseVersion)) {
        $assessment.status = "warning"
        $assessment.message = "Version bump policy could not compare the current candidate because lab.releaseGate.previousReleaseVersion is not configured."
        return [pscustomobject]$assessment
    }

    $isVersionBumped = ($PluginDisplayVersion -ne $previousReleaseVersion)
    $assessment.isVersionBumped = $isVersionBumped
    if ($isVersionBumped) {
        $assessment.status = "pass"
        $assessment.message = "Current candidate display version $PluginDisplayVersion differs from previous release version $previousReleaseVersion."
        return [pscustomobject]$assessment
    }

    switch ($mode) {
        "ignore" {
            $assessment.status = "ignored"
            $assessment.message = "Current candidate display version matches previous release version $previousReleaseVersion, but version policy mode is ignore."
        }
        "warn" {
            $assessment.status = "warning"
            $assessment.message = "Current candidate display version still matches previous release version $previousReleaseVersion. Bump buddybackup.plg before a real release if you want a distinct release identity."
        }
        default {
            $assessment.status = if ($enforcementActive) { "fail" } else { "warning" }
            $assessment.message = "Current candidate display version still matches previous release version $previousReleaseVersion. Clean execute release-gate runs require buddybackup.plg to be bumped or releaseGate.versionPolicy.mode to be relaxed."
            $assessment.shouldBlock = $enforcementActive
        }
    }

    return [pscustomobject]$assessment
}

function Get-LatestMatchingFile {
    param(
        [string]$Directory,
        [string]$Filter,
        [datetime]$StartedAt
    )

    if (-not (Test-Path -LiteralPath $Directory)) {
        return $null
    }

    return Get-ChildItem -Path $Directory -Filter $Filter -File -ErrorAction SilentlyContinue |
        Where-Object { $_.LastWriteTime -ge $StartedAt.AddSeconds(-5) } |
        Sort-Object -Property LastWriteTime -Descending |
        Select-Object -First 1
}

function Get-LatestMatchingDirectory {
    param(
        [string]$Directory,
        [datetime]$StartedAt
    )

    if (-not (Test-Path -LiteralPath $Directory)) {
        return $null
    }

    return Get-ChildItem -Path $Directory -Directory -ErrorAction SilentlyContinue |
        Where-Object { $_.LastWriteTime -ge $StartedAt.AddSeconds(-5) } |
        Sort-Object -Property LastWriteTime -Descending |
        Select-Object -First 1
}

function Copy-FileIfPresent {
    param(
        [string]$SourcePath,
        [string]$DestinationDirectory
    )

    if ([string]::IsNullOrWhiteSpace($SourcePath) -or -not (Test-Path -LiteralPath $SourcePath)) {
        return $null
    }

    Ensure-Dir -Path $DestinationDirectory
    $destinationPath = Join-Path $DestinationDirectory ([System.IO.Path]::GetFileName($SourcePath))
    Copy-Item -LiteralPath $SourcePath -Destination $destinationPath -Force
    return $destinationPath
}

function Get-ResultCellSummary {
    param([object[]]$MatrixResults)

    return @($MatrixResults | ForEach-Object {
        [pscustomobject]@{
            cellId = [string]$_.cellId
            status = [string]$_.status
            nodeAUnraid = [string](Get-TestLabPropertyValue -Object $_ -Name 'nodeAUnraid')
            nodeAPlugin = [string](Get-TestLabPropertyValue -Object $_ -Name 'nodeAPlugin')
            nodeAPluginRequested = [string](Get-TestLabPropertyOrDefault -Object $_ -Name 'nodeAPluginRequested' -DefaultValue (Get-TestLabPropertyValue -Object $_ -Name 'nodeAPlugin'))
            nodeAPluginResolved = [string](Get-TestLabPropertyOrDefault -Object $_ -Name 'nodeAPluginResolved' -DefaultValue (Get-TestLabPropertyValue -Object $_ -Name 'nodeAPlugin'))
            nodeAPluginSource = [string](Get-TestLabPropertyOrDefault -Object $_ -Name 'nodeAPluginSource' -DefaultValue 'release-tag')
            nodeAUpgradeFromPluginRequested = [string](Get-TestLabPropertyValue -Object $_ -Name 'nodeAUpgradeFromPluginRequested')
            nodeAUpgradeFromPluginResolved = [string](Get-TestLabPropertyValue -Object $_ -Name 'nodeAUpgradeFromPluginResolved')
            nodeBUnraid = [string](Get-TestLabPropertyValue -Object $_ -Name 'nodeBUnraid')
            nodeBPlugin = [string](Get-TestLabPropertyValue -Object $_ -Name 'nodeBPlugin')
            nodeBPluginRequested = [string](Get-TestLabPropertyOrDefault -Object $_ -Name 'nodeBPluginRequested' -DefaultValue (Get-TestLabPropertyValue -Object $_ -Name 'nodeBPlugin'))
            nodeBPluginResolved = [string](Get-TestLabPropertyOrDefault -Object $_ -Name 'nodeBPluginResolved' -DefaultValue (Get-TestLabPropertyValue -Object $_ -Name 'nodeBPlugin'))
            nodeBPluginSource = [string](Get-TestLabPropertyOrDefault -Object $_ -Name 'nodeBPluginSource' -DefaultValue 'release-tag')
            nodeBUpgradeFromPluginRequested = [string](Get-TestLabPropertyValue -Object $_ -Name 'nodeBUpgradeFromPluginRequested')
            nodeBUpgradeFromPluginResolved = [string](Get-TestLabPropertyValue -Object $_ -Name 'nodeBUpgradeFromPluginResolved')
            categories = if ($_.PSObject.Properties['categories']) { @($_.categories) } else { @() }
            purpose = if ($_.PSObject.Properties['purpose']) { [string]$_.purpose } else { $null }
            lifecycle = [string]$_.lifecycle
            artifactDir = [string]$_.artifactDir
        }
    })
}

function Get-CategoryRollups {
    param([object[]]$Cells)

    $categoryIndex = [ordered]@{}
    foreach ($cell in @($Cells)) {
        $cellCategories = @()
        if ($cell.PSObject.Properties['categories']) {
            $cellCategories = @($cell.categories | Where-Object { -not [string]::IsNullOrWhiteSpace([string]$_) })
        }

        foreach ($categoryName in $cellCategories) {
            $normalizedName = [string]$categoryName
            if (-not $categoryIndex.Contains($normalizedName)) {
                $categoryIndex[$normalizedName] = [ordered]@{
                    category = $normalizedName
                    totalCells = 0
                    passCells = 0
                    failCells = 0
                    status = "not-run"
                    cellIds = @()
                }
            }

            $entry = $categoryIndex[$normalizedName]
            $entry.totalCells += 1
            $entry.cellIds += [string]$cell.cellId
            if (([string]$cell.status).ToLowerInvariant() -eq "pass") {
                $entry.passCells += 1
            } else {
                $entry.failCells += 1
            }
        }
    }

    foreach ($entry in $categoryIndex.Values) {
        if ($entry.totalCells -eq 0) {
            $entry.status = "not-run"
        } elseif ($entry.failCells -gt 0) {
            $entry.status = "fail"
        } elseif ($entry.passCells -eq $entry.totalCells) {
            $entry.status = "pass"
        } else {
            $entry.status = "partial"
        }
    }

    return @($categoryIndex.Values | ForEach-Object { [pscustomobject]$_ })
}

function Update-HistoryIndex {
    param(
        [string]$HistoryRootPath,
        $Manifest,
        [string]$ManifestPath
    )

    $indexPath = Join-Path $HistoryRootPath "index.json"
    $latestPath = Join-Path $HistoryRootPath "latest.json"

    $entry = [pscustomobject]@{
        releaseGateRunId = $Manifest.releaseGateRunId
        startedAt = $Manifest.startedAt
        completedAt = $Manifest.completedAt
        overallStatus = $Manifest.overallStatus
        executeMode = $Manifest.executeMode
        allowDirtyWorktree = $Manifest.allowDirtyWorktree
        matrixProfile = $Manifest.matrixProfile
        commitSha = $Manifest.git.commitSha
        shortSha = $Manifest.git.shortSha
        branch = $Manifest.git.branch
        clean = $Manifest.git.clean
        pluginDisplayVersion = $Manifest.plugin.displayVersion
        historyDir = $Manifest.historyDir
        manifestPath = $ManifestPath
        totalCells = $Manifest.summary.totalCells
        passCells = $Manifest.summary.passCells
        failCells = $Manifest.summary.failCells
    }

    $existingEntries = @()
    if (Test-Path -LiteralPath $indexPath) {
        $indexContent = Get-Content -Raw -Path $indexPath | ConvertFrom-Json
        if ($indexContent -is [System.Array]) {
            $existingEntries = @($indexContent)
        } elseif ($null -ne $indexContent) {
            $existingEntries = @($indexContent)
        }
    }

    $updatedEntries = @($existingEntries + $entry)
    $updatedEntries | ConvertTo-Json -Depth 8 | Set-Content -Path $indexPath
    $entry | ConvertTo-Json -Depth 8 | Set-Content -Path $latestPath
}

$workspaceRoot = Get-WorkspaceRoot
$resolvedLabConfig = Resolve-WorkspacePath -Path $LabConfig
$resolvedMatrixConfig = $null
$provisionScript = Join-Path $PSScriptRoot "provision-lab.ps1"
$matrixScript = Join-Path $PSScriptRoot "run-matrix.ps1"

Require-File -Path $resolvedLabConfig
Require-File -Path $provisionScript
Require-File -Path $matrixScript

$lab = Get-Json -Path $resolvedLabConfig
Apply-ReleaseGateOverrides -Lab $lab -CurrentCandidatePlugin $CurrentCandidatePlugin -PreviousReleaseVersion $PreviousReleaseVersion
$resolvedMatrixProfile = $null
if (-not [string]::IsNullOrWhiteSpace($MatrixProfile)) {
    $generatedMatrix = Write-TestLabReleaseMatrixFile -WorkspaceRoot $workspaceRoot -Lab $lab -ProfileName $MatrixProfile
    $resolvedMatrixConfig = $generatedMatrix.filePath
    $resolvedMatrixProfile = $generatedMatrix.profileName
} else {
    $resolvedMatrixConfig = Resolve-WorkspacePath -Path $MatrixConfig
    Require-File -Path $resolvedMatrixConfig
}

$matrix = Get-Json -Path $resolvedMatrixConfig
$historyRootPath = $null
$historyDir = $null
$releaseGateRunId = $null
$manifestPath = $null

$safeWorkingDirectory = Get-SafeHostWorkingDirectory
Push-Location $safeWorkingDirectory
try {
    $startedAt = Get-Date
    $gitInfo = Get-GitPreflight
    $historyRootPath = Get-HistoryRoot -ConfiguredHistoryRoot $HistoryRoot -Lab $lab
    Ensure-Dir -Path $historyRootPath

    $releaseGateRunId = "{0}-{1}" -f ($startedAt.ToString("yyyyMMdd-HHmmss")), $gitInfo.shortSha
    $historyDir = Join-Path $historyRootPath $releaseGateRunId
    Ensure-Dir -Path $historyDir

    $pluginDisplayVersion = Get-TestLabPluginDisplayVersion -WorkspaceRoot $workspaceRoot
    $matrixProfile = [string](Get-ObjectValue -Object $matrix -Name "name")
    if ([string]::IsNullOrWhiteSpace($matrixProfile)) {
        $matrixProfile = [System.IO.Path]::GetFileNameWithoutExtension($resolvedMatrixConfig)
    }
    if ([string]::IsNullOrWhiteSpace($resolvedMatrixProfile)) {
        $resolvedMatrixProfile = $matrixProfile
    }
    $matrixUnraidSupport = Test-LabSupportsMatrixUnraidVersions -Lab $lab -Matrix $matrix
    if (-not $matrixUnraidSupport.Success) {
        throw $matrixUnraidSupport.Error
    }
    $dirtyWorktreeAssessment = Get-DirtyWorktreeAssessment -Matrix $matrix -GitInfo $gitInfo -AllowDirty:$AllowDirtyWorktree
    $versionPolicyAssessment = Get-VersionPolicyAssessment -Lab $lab -Matrix $matrix -PluginDisplayVersion $pluginDisplayVersion -GitInfo $gitInfo -DoExecute:$Execute -AllowDirty:$AllowDirtyWorktree

    Write-Host "[testlab] Release gate preflight passed for commit $($gitInfo.shortSha) on branch $($gitInfo.branch)"
    if ($dirtyWorktreeAssessment.status -eq "warning") {
        Write-Warning $dirtyWorktreeAssessment.message
    }
    if ($dirtyWorktreeAssessment.shouldBlock) {
        throw $dirtyWorktreeAssessment.message
    }
    if ($versionPolicyAssessment.status -eq "warning") {
        Write-Warning $versionPolicyAssessment.message
    }
    if ($versionPolicyAssessment.shouldBlock) {
        throw $versionPolicyAssessment.message
    }
    Write-Host "[testlab] History root: $historyRootPath"

    Write-Host "[testlab] Running restrict_zfs preflight"
    $restrictZfsPreflight = Invoke-RestrictZfsPreflight -WorkspaceRoot $workspaceRoot
    $restrictZfsPreflightPath = Join-Path $historyDir "restrict-zfs-preflight.json"
    $restrictZfsPreflight | ConvertTo-Json -Depth 6 | Set-Content -Path $restrictZfsPreflightPath
    if (-not $restrictZfsPreflight.success) {
        throw "restrict_zfs preflight failed. Review $restrictZfsPreflightPath"
    }

    $provisionStartedAt = $null
    $matrixStartedAt = $null
    $provisionReportPath = $null
    $matrixResultsPath = $null
    $provisionCopyPath = $null
    $matrixResultsCopyPath = $null
    $failureMessage = $null
    $overallStatus = "fail"
    $matrixResults = @()

    try {
        if (-not $SkipProvision) {
            $provisionStartedAt = Get-Date
            Write-Host "[testlab] Starting provision phase"
            & $provisionScript -LabConfig $resolvedLabConfig -Execute:$Execute
            $provisionReport = Get-LatestMatchingFile -Directory (Resolve-WorkspacePath -Path ([string](Get-ObjectValue -Object $lab -Name "logsRoot"))) -Filter "provision-*.json" -StartedAt $provisionStartedAt
            if ($null -eq $provisionReport) {
                $logsRoot = [string](Get-ObjectValue -Object $lab -Name "logsRoot")
                if ([string]::IsNullOrWhiteSpace($logsRoot)) {
                    $logsRoot = ".testlab/logs"
                }
                $provisionReport = Get-LatestMatchingFile -Directory (Resolve-WorkspacePath -Path $logsRoot) -Filter "provision-*.json" -StartedAt $provisionStartedAt
            }
            if ($provisionReport) {
                $provisionReportPath = $provisionReport.FullName
            }
        }

        $matrixStartedAt = Get-Date
        Write-Host "[testlab] Starting matrix phase"
        & $matrixScript -LabConfig $resolvedLabConfig -MatrixConfig $resolvedMatrixConfig -Execute:$Execute -SkipArtifacts:$SkipArtifacts

        $artifactsRoot = [string](Get-ObjectValue -Object $lab -Name "artifactsRoot")
        if ([string]::IsNullOrWhiteSpace($artifactsRoot)) {
            $artifactsRoot = ".testlab/artifacts"
        }

        $latestRunDir = Get-LatestMatchingDirectory -Directory (Resolve-WorkspacePath -Path $artifactsRoot) -StartedAt $matrixStartedAt
        if ($latestRunDir) {
            $candidateResultsPath = Join-Path $latestRunDir.FullName "results.json"
            if (Test-Path -LiteralPath $candidateResultsPath) {
                $matrixResultsPath = $candidateResultsPath
            }
        }

        if ([string]::IsNullOrWhiteSpace($matrixResultsPath)) {
            throw "Matrix run did not produce results.json under $artifactsRoot"
        }

        $loadedMatrixResults = Get-Json -Path $matrixResultsPath
        if ($loadedMatrixResults -is [System.Array]) {
            $matrixResults = @($loadedMatrixResults)
        } elseif ($null -ne $loadedMatrixResults) {
            $matrixResults = @($loadedMatrixResults)
        }

        $failedCells = @($matrixResults | Where-Object { ([string]$_.status).ToLowerInvariant() -ne "pass" })
        $overallStatus = if ($failedCells.Count -eq 0) { "pass" } else { "fail" }
    } catch {
        $failureMessage = $_.Exception.Message
        Write-Warning "Release gate execution failed: $failureMessage"

        if ([string]::IsNullOrWhiteSpace($provisionReportPath)) {
            $logsRoot = [string](Get-ObjectValue -Object $lab -Name "logsRoot")
            if ([string]::IsNullOrWhiteSpace($logsRoot)) {
                $logsRoot = ".testlab/logs"
            }
            $fallbackProvisionReport = Get-LatestMatchingFile -Directory (Resolve-WorkspacePath -Path $logsRoot) -Filter "provision-*.json" -StartedAt $(if ($null -ne $provisionStartedAt) { $provisionStartedAt } else { $startedAt })
            if ($fallbackProvisionReport) {
                $provisionReportPath = $fallbackProvisionReport.FullName
            }
        }

        if ([string]::IsNullOrWhiteSpace($matrixResultsPath)) {
            $artifactsRoot = [string](Get-ObjectValue -Object $lab -Name "artifactsRoot")
            if ([string]::IsNullOrWhiteSpace($artifactsRoot)) {
                $artifactsRoot = ".testlab/artifacts"
            }
            $fallbackRunDir = Get-LatestMatchingDirectory -Directory (Resolve-WorkspacePath -Path $artifactsRoot) -StartedAt $(if ($null -ne $matrixStartedAt) { $matrixStartedAt } else { $startedAt })
            if ($fallbackRunDir) {
                $fallbackResultsPath = Join-Path $fallbackRunDir.FullName "results.json"
                if (Test-Path -LiteralPath $fallbackResultsPath) {
                    $matrixResultsPath = $fallbackResultsPath
                }
            }
        }

        if (-not [string]::IsNullOrWhiteSpace($matrixResultsPath) -and (Test-Path -LiteralPath $matrixResultsPath)) {
            $loadedMatrixResults = Get-Json -Path $matrixResultsPath
            if ($loadedMatrixResults -is [System.Array]) {
                $matrixResults = @($loadedMatrixResults)
            } elseif ($null -ne $loadedMatrixResults) {
                $matrixResults = @($loadedMatrixResults)
            }
        }
    }

    $provisionCopyPath = Copy-FileIfPresent -SourcePath $provisionReportPath -DestinationDirectory $historyDir
    $matrixResultsCopyPath = Copy-FileIfPresent -SourcePath $matrixResultsPath -DestinationDirectory $historyDir

    $completedAt = Get-Date
    $passCount = @($matrixResults | Where-Object { ([string]$_.status).ToLowerInvariant() -eq "pass" }).Count
    $failCount = @($matrixResults | Where-Object { ([string]$_.status).ToLowerInvariant() -ne "pass" }).Count
    $totalCells = $matrixResults.Count
    $cellSummary = Get-ResultCellSummary -MatrixResults $matrixResults
    $categoryRollups = Get-CategoryRollups -Cells $cellSummary

    if ($totalCells -eq 0 -and [string]::IsNullOrWhiteSpace($failureMessage)) {
        $overallStatus = "unknown"
    }

    if (-not [string]::IsNullOrWhiteSpace($failureMessage)) {
        $overallStatus = "fail"
    }

    $publishRepositoryHistory = (
        $overallStatus -eq "pass" -and
        $Execute -and
        -not $AllowDirtyWorktree -and
        ($gitInfo.clean -or -not $dirtyWorktreeAssessment.requiresCleanWorktree)
    )
    $repositoryHistory = [ordered]@{
        published = $false
        reason = if ($publishRepositoryHistory) { $null } else { "Repository history is only published for successful execute runs that do not use the dirty-worktree override and either use a clean worktree or install published BuddyBackup releases only." }
        readmePath = $null
        indexPath = $null
        detailPath = $null
    }

    $manifest = [ordered]@{
        schemaVersion = 1
        releaseGateRunId = $releaseGateRunId
        startedAt = $startedAt.ToString("o")
        completedAt = $completedAt.ToString("o")
        durationSeconds = [math]::Round((New-TimeSpan -Start $startedAt -End $completedAt).TotalSeconds, 2)
        executeMode = [bool]$Execute
        allowDirtyWorktree = [bool]$AllowDirtyWorktree
        skipProvision = [bool]$SkipProvision
        skipArtifacts = [bool]$SkipArtifacts
        matrixProfile = $matrixProfile
        overallStatus = $overallStatus
        historyRoot = $historyRootPath
        historyDir = $historyDir
        failureMessage = $failureMessage
        git = $gitInfo
        plugin = [ordered]@{
            displayVersion = $pluginDisplayVersion
        }
        versionPolicy = $versionPolicyAssessment
        dirtyWorktreePolicy = $dirtyWorktreeAssessment
        preflight = [ordered]@{
            restrictZfs = $restrictZfsPreflight
            restrictZfsPath = $restrictZfsPreflightPath
        }
        inputs = [ordered]@{
            labConfig = $resolvedLabConfig
            matrixConfig = $resolvedMatrixConfig
            matrixProfile = $resolvedMatrixProfile
            releaseGateOverrides = [ordered]@{
                currentCandidatePlugin = $CurrentCandidatePlugin
                previousReleaseVersion = $PreviousReleaseVersion
            }
        }
        outputs = [ordered]@{
            provisionReportPath = $provisionReportPath
            matrixResultsPath = $matrixResultsPath
            copiedProvisionReportPath = $provisionCopyPath
            copiedMatrixResultsPath = $matrixResultsCopyPath
        }
        summary = [ordered]@{
            totalCells = $totalCells
            passCells = $passCount
            failCells = $failCount
            cells = $cellSummary
        }
        categoryRollups = $categoryRollups
        repositoryHistory = $repositoryHistory
    }

    if ($publishRepositoryHistory) {
        try {
            $repositoryHistoryResult = Write-TestLabRepositoryHistory -WorkspaceRoot $workspaceRoot -Manifest $manifest
            $repositoryHistory = [ordered]@{
                published = $true
                reason = $null
                readmePath = $repositoryHistoryResult.readmePath
                indexPath = $repositoryHistoryResult.indexPath
                detailPath = $repositoryHistoryResult.detailPath
            }
            $manifest.repositoryHistory = $repositoryHistory
        } catch {
            $overallStatus = "fail"
            $failureMessage = "Repository history publish failed: $($_.Exception.Message)"
            $repositoryHistory = [ordered]@{
                published = $false
                reason = $failureMessage
                readmePath = $null
                indexPath = $null
                detailPath = $null
            }
            $manifest.overallStatus = $overallStatus
            $manifest.failureMessage = $failureMessage
            $manifest.repositoryHistory = $repositoryHistory
        }
    }

    $manifestPath = Join-Path $historyDir "manifest.json"
    $manifest | ConvertTo-Json -Depth 10 | Set-Content -Path $manifestPath
    Update-HistoryIndex -HistoryRootPath $historyRootPath -Manifest $manifest -ManifestPath $manifestPath

    Write-Host "[testlab] Release gate status: $overallStatus"
    Write-Host "[testlab] Manifest written to $manifestPath"
    if ($repositoryHistory.published) {
        Write-Host "[testlab] Repository history updated at $($repositoryHistory.readmePath)"
    }

    if ($overallStatus -ne "pass") {
        throw "Release gate failed. Review $manifestPath"
    }
} finally {
    Pop-Location
}