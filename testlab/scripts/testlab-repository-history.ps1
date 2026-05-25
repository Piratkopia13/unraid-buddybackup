function Ensure-TestLabRepositoryHistoryDir {
    param([string]$Path)

    if (-not (Test-Path -LiteralPath $Path)) {
        New-Item -ItemType Directory -Path $Path -Force | Out-Null
    }
}

function Get-TestLabRepositoryHistoryRoot {
    param([string]$WorkspaceRoot)

    return Join-Path $WorkspaceRoot "testlab/release-history"
}

function Join-TestLabRepositoryHistoryValues {
    param([string[]]$Values)

    $items = @($Values | Where-Object { -not [string]::IsNullOrWhiteSpace($_) } | Select-Object -Unique)
    if ($items.Count -eq 0) {
        return "-"
    }

    return ($items -join "; ")
}

function Get-TestLabPropertyValue {
    param(
        $Object,
        [string]$Name
    )

    $property = $Object.PSObject.Properties[$Name]
    if ($property) {
        return $property.Value
    }

    if ($Name -like 'nodeA*') {
        $legacyProperty = $Object.PSObject.Properties[($Name -replace '^nodeA', 'sender')]
        if ($legacyProperty) {
            return $legacyProperty.Value
        }
    }

    if ($Name -like 'nodeB*') {
        $legacyProperty = $Object.PSObject.Properties[($Name -replace '^nodeB', 'receiver')]
        if ($legacyProperty) {
            return $legacyProperty.Value
        }
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

function ConvertTo-TestLabPublicHistoryCell {
    param($Cell)

    $nodeAPluginSource = [string](Get-TestLabPropertyOrDefault -Object $Cell -Name 'nodeAPluginSource' -DefaultValue 'release-tag')
    $nodeBPluginSource = [string](Get-TestLabPropertyOrDefault -Object $Cell -Name 'nodeBPluginSource' -DefaultValue 'release-tag')
    $nodeAPluginRequested = [string](Get-TestLabPropertyOrDefault -Object $Cell -Name 'nodeAPluginRequested' -DefaultValue (Get-TestLabPropertyValue -Object $Cell -Name 'nodeAPlugin'))
    $nodeBPluginRequested = [string](Get-TestLabPropertyOrDefault -Object $Cell -Name 'nodeBPluginRequested' -DefaultValue (Get-TestLabPropertyValue -Object $Cell -Name 'nodeBPlugin'))
    $nodeAPluginResolved = [string](Get-TestLabPropertyOrDefault -Object $Cell -Name 'nodeAPluginResolved' -DefaultValue (Get-TestLabPropertyValue -Object $Cell -Name 'nodeAPlugin'))
    $nodeBPluginResolved = [string](Get-TestLabPropertyOrDefault -Object $Cell -Name 'nodeBPluginResolved' -DefaultValue (Get-TestLabPropertyValue -Object $Cell -Name 'nodeBPlugin'))
    $nodeAUpgradeFromPluginRequested = [string](Get-TestLabPropertyValue -Object $Cell -Name 'nodeAUpgradeFromPluginRequested')
    $nodeBUpgradeFromPluginRequested = [string](Get-TestLabPropertyValue -Object $Cell -Name 'nodeBUpgradeFromPluginRequested')
    $nodeAUpgradeFromPluginResolved = [string](Get-TestLabPropertyValue -Object $Cell -Name 'nodeAUpgradeFromPluginResolved')
    $nodeBUpgradeFromPluginResolved = [string](Get-TestLabPropertyValue -Object $Cell -Name 'nodeBUpgradeFromPluginResolved')

    return [pscustomobject]@{
        cellId = [string]$Cell.cellId
        lifecycle = [string]$Cell.lifecycle
        status = [string]$Cell.status
        categories = if ($Cell.PSObject.Properties['categories']) { @($Cell.categories) } else { @() }
        purpose = if ($Cell.PSObject.Properties['purpose']) { [string]$Cell.purpose } else { $null }
        nodeA = [pscustomobject]@{
            unraid = [string](Get-TestLabPropertyValue -Object $Cell -Name 'nodeAUnraid')
            pluginRequested = $nodeAPluginRequested
            pluginResolved = $nodeAPluginResolved
            pluginSource = $nodeAPluginSource
            upgradeFromPluginRequested = $nodeAUpgradeFromPluginRequested
            upgradeFromPluginResolved = $nodeAUpgradeFromPluginResolved
        }
        nodeB = [pscustomobject]@{
            unraid = [string](Get-TestLabPropertyValue -Object $Cell -Name 'nodeBUnraid')
            pluginRequested = $nodeBPluginRequested
            pluginResolved = $nodeBPluginResolved
            pluginSource = $nodeBPluginSource
            upgradeFromPluginRequested = $nodeBUpgradeFromPluginRequested
            upgradeFromPluginResolved = $nodeBUpgradeFromPluginResolved
        }
    }
}

function ConvertTo-TestLabRepositoryHistoryEntry {
    param($Manifest)

    $cells = @($Manifest.summary.cells | ForEach-Object { ConvertTo-TestLabPublicHistoryCell -Cell $_ })
    $pluginCoverage = @($cells | ForEach-Object {
        "{0} ({1}) -> {2} ({3})" -f $_.nodeA.pluginResolved, $_.nodeA.pluginSource, $_.nodeB.pluginResolved, $_.nodeB.pluginSource
    } | Select-Object -Unique)
    $unraidCoverage = @($cells | ForEach-Object {
        "{0} -> {1}" -f $_.nodeA.unraid, $_.nodeB.unraid
    } | Select-Object -Unique)

    return [pscustomobject]@{
        releaseGateRunId = [string]$Manifest.releaseGateRunId
        startedAt = [string]$Manifest.startedAt
        completedAt = [string]$Manifest.completedAt
        matrixProfile = [string]$Manifest.matrixProfile
        pluginDisplayVersion = [string]$Manifest.plugin.displayVersion
        commitSha = [string]$Manifest.git.commitSha
        shortSha = [string]$Manifest.git.shortSha
        branch = [string]$Manifest.git.branch
        totalCells = [int]$Manifest.summary.totalCells
        passCells = [int]$Manifest.summary.passCells
        failCells = [int]$Manifest.summary.failCells
        categoryRollups = @($Manifest.categoryRollups)
        pluginCoverage = $pluginCoverage
        unraidCoverage = $unraidCoverage
        detailPath = ("runs/{0}.json" -f $Manifest.releaseGateRunId)
        cells = $cells
    }
}

function Get-TestLabRepositoryHistoryCategoryStatus {
    param(
        $Entry,
        [string]$CategoryName
    )

    foreach ($rollup in @($Entry.categoryRollups)) {
        if ([string]$rollup.category -eq $CategoryName) {
            return [string]$rollup.status
        }
    }

    return "-"
}

function Write-TestLabRepositoryHistoryReadme {
    param(
        [Alias("OutputPath")]
        [string]$ReadmePath,
        [object[]]$Entries
    )

    $sortedEntries = @($Entries | Sort-Object -Property completedAt -Descending)
    $lines = @(
        "# Release Test History",
        "",
        "Successful execute release-gate runs are recorded here when they either use a clean worktree or install published BuddyBackup releases only.",
        "Coverage columns record the version pairs assigned to the two fixed lab slots for each run. The functional smoke still exercises remote backup and restore in both directions within that slot pairing.",
        "",
        "## Runs",
        ""
    )

    if ($sortedEntries.Count -eq 0) {
        $lines += "No successful publishable execute release-gate runs have been recorded yet."
    } else {
        $lines += "| Run | Plugin | Commit | Matrix | Plugin Compat | Unraid Compat | BuddyBackup Pair Coverage | Unraid Pair Coverage | Detail |"
        $lines += "| --- | --- | --- | --- | --- | --- | --- | --- | --- |"
        foreach ($entry in $sortedEntries) {
            $detailPath = ([string]$entry.detailPath).Replace('\\', '/')
            $lines += "| {0} | {1} | {2} | {3} | {4} | {5} | {6} | {7} | [detail]({8}) |" -f `
                $entry.releaseGateRunId, `
                $entry.pluginDisplayVersion, `
                $entry.shortSha, `
                $entry.matrixProfile, `
                (Get-TestLabRepositoryHistoryCategoryStatus -Entry $entry -CategoryName "pluginCompatibility"), `
                (Get-TestLabRepositoryHistoryCategoryStatus -Entry $entry -CategoryName "unraidCompatibility"), `
                (Join-TestLabRepositoryHistoryValues -Values $entry.pluginCoverage), `
                (Join-TestLabRepositoryHistoryValues -Values $entry.unraidCoverage), `
                $detailPath
        }
    }

    Set-Content -Path $ReadmePath -Value $lines
}

function Write-TestLabRepositoryHistory {
    param(
        [string]$WorkspaceRoot,
        $Manifest
    )

    $historyRoot = Get-TestLabRepositoryHistoryRoot -WorkspaceRoot $WorkspaceRoot
    $runsRoot = Join-Path $historyRoot "runs"
    Ensure-TestLabRepositoryHistoryDir -Path $historyRoot
    Ensure-TestLabRepositoryHistoryDir -Path $runsRoot

    $entry = ConvertTo-TestLabRepositoryHistoryEntry -Manifest $Manifest
    $detailPath = Join-Path $runsRoot ("{0}.json" -f $Manifest.releaseGateRunId)
    $indexPath = Join-Path $historyRoot "index.json"
    $readmePath = Join-Path $historyRoot "README.md"

    $detail = [ordered]@{
        schemaVersion = 1
        releaseGateRunId = $entry.releaseGateRunId
        startedAt = $entry.startedAt
        completedAt = $entry.completedAt
        matrixProfile = $entry.matrixProfile
        pluginDisplayVersion = $entry.pluginDisplayVersion
        commitSha = $entry.commitSha
        shortSha = $entry.shortSha
        branch = $entry.branch
        summary = [ordered]@{
            totalCells = $entry.totalCells
            passCells = $entry.passCells
            failCells = $entry.failCells
            categoryRollups = $entry.categoryRollups
            pluginCoverage = $entry.pluginCoverage
            unraidCoverage = $entry.unraidCoverage
        }
        cells = $entry.cells
    }
    $detail | ConvertTo-Json -Depth 8 | Set-Content -Path $detailPath

    $existingEntries = @()
    if (Test-Path -LiteralPath $indexPath) {
        $indexContent = Get-Content -Raw -Path $indexPath | ConvertFrom-Json
        if ($indexContent -is [System.Array]) {
            $existingEntries = @($indexContent)
        } elseif ($null -ne $indexContent) {
            $existingEntries = @($indexContent)
        }
    }

    $entriesWithoutCurrent = @($existingEntries | Where-Object { ([string]$_.releaseGateRunId) -ne $entry.releaseGateRunId })
    $updatedEntries = @(($entriesWithoutCurrent + $entry) | Sort-Object -Property completedAt -Descending)
    $updatedEntries | ConvertTo-Json -Depth 8 | Set-Content -Path $indexPath
    Write-TestLabRepositoryHistoryReadme -ReadmePath $readmePath -Entries $updatedEntries

    return [pscustomobject]@{
        historyRoot = $historyRoot
        indexPath = $indexPath
        readmePath = $readmePath
        detailPath = $detailPath
    }
}