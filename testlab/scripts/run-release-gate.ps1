param(
    [string]$LabConfig = "testlab/config/lab.local.json",
    [string]$MatrixConfig = "testlab/config/matrix.small.json",
    [string]$HistoryRoot,
    [switch]$Execute,
    [switch]$AllowDirtyWorktree,
    [switch]$SkipProvision,
    [switch]$SkipArtifacts
)

$ErrorActionPreference = "Stop"

. (Join-Path $PSScriptRoot "testlab-logging.ps1")
. (Join-Path $PSScriptRoot "testlab-plugin-source.ps1")
. (Join-Path $PSScriptRoot "testlab-repository-history.ps1")

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

function Get-WorkspaceRoot {
    return [System.IO.Path]::GetFullPath((Join-Path $PSScriptRoot "..\.."))
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

    $output = (& git @Arguments 2>&1 | Out-String).TrimEnd()
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
    param([switch]$AllowDirty)

    $status = Invoke-GitCommand -Arguments @("status", "--porcelain", "--untracked-files=all")
    $statusLines = @($status.Output -split "`r?`n" | Where-Object { -not [string]::IsNullOrWhiteSpace($_) })
    if ($statusLines.Count -gt 0 -and -not $AllowDirty) {
        $details = $statusLines -join [Environment]::NewLine
        throw "Release gate requires a clean worktree. Commit, stash, or discard local changes before running tests.`n$details"
    }

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
            senderUnraid = [string]$_.senderUnraid
            senderPlugin = [string]$_.senderPlugin
            senderPluginRequested = if ($_.PSObject.Properties['senderPluginRequested']) { [string]$_.senderPluginRequested } else { [string]$_.senderPlugin }
            senderPluginResolved = if ($_.PSObject.Properties['senderPluginResolved']) { [string]$_.senderPluginResolved } else { [string]$_.senderPlugin }
            senderPluginSource = if ($_.PSObject.Properties['senderPluginSource']) { [string]$_.senderPluginSource } else { "release-tag" }
            receiverUnraid = [string]$_.receiverUnraid
            receiverPlugin = [string]$_.receiverPlugin
            receiverPluginRequested = if ($_.PSObject.Properties['receiverPluginRequested']) { [string]$_.receiverPluginRequested } else { [string]$_.receiverPlugin }
            receiverPluginResolved = if ($_.PSObject.Properties['receiverPluginResolved']) { [string]$_.receiverPluginResolved } else { [string]$_.receiverPlugin }
            receiverPluginSource = if ($_.PSObject.Properties['receiverPluginSource']) { [string]$_.receiverPluginSource } else { "release-tag" }
            lifecycle = [string]$_.lifecycle
            artifactDir = [string]$_.artifactDir
        }
    })
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
$resolvedMatrixConfig = Resolve-WorkspacePath -Path $MatrixConfig
$provisionScript = Join-Path $PSScriptRoot "provision-lab.ps1"
$matrixScript = Join-Path $PSScriptRoot "run-matrix.ps1"

Require-File -Path $resolvedLabConfig
Require-File -Path $resolvedMatrixConfig
Require-File -Path $provisionScript
Require-File -Path $matrixScript

$lab = Get-Json -Path $resolvedLabConfig
$matrix = Get-Json -Path $resolvedMatrixConfig
$historyRootPath = $null
$historyDir = $null
$releaseGateRunId = $null
$manifestPath = $null

Push-Location $workspaceRoot
try {
    $startedAt = Get-Date
    $gitInfo = Get-GitPreflight -AllowDirty:$AllowDirtyWorktree
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

    Write-Host "[testlab] Release gate preflight passed for commit $($gitInfo.shortSha) on branch $($gitInfo.branch)"
    if (-not $gitInfo.clean) {
        Write-Warning "Dirty worktree override is enabled. This run should not be treated as a release candidate."
    }
    Write-Host "[testlab] History root: $historyRootPath"

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

    if ($totalCells -eq 0 -and [string]::IsNullOrWhiteSpace($failureMessage)) {
        $overallStatus = "unknown"
    }

    if (-not [string]::IsNullOrWhiteSpace($failureMessage)) {
        $overallStatus = "fail"
    }

    $publishRepositoryHistory = ($overallStatus -eq "pass" -and $Execute -and $gitInfo.clean -and -not $AllowDirtyWorktree)
    $repositoryHistory = [ordered]@{
        published = $false
        reason = if ($publishRepositoryHistory) { $null } else { "Repository history is only published for successful clean execute runs." }
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
        inputs = [ordered]@{
            labConfig = $resolvedLabConfig
            matrixConfig = $resolvedMatrixConfig
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
            cells = Get-ResultCellSummary -MatrixResults $matrixResults
        }
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