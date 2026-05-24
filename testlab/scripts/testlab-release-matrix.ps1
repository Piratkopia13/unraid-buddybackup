function Get-TestLabReleaseMatrixObjectValue {
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

function Ensure-TestLabReleaseMatrixDir {
    param([string]$Path)

    if (-not (Test-Path -LiteralPath $Path)) {
        New-Item -ItemType Directory -Path $Path -Force | Out-Null
    }
}

function Get-TestLabReleaseMatrixDefaultLab {
    if ($script:TestLabReleaseMatrixDefaultLabLoaded) {
        return $script:TestLabReleaseMatrixDefaultLab
    }

    $defaultLabPath = Join-Path $PSScriptRoot "..\config\lab.example.json"
    if (Test-Path -LiteralPath $defaultLabPath) {
        $script:TestLabReleaseMatrixDefaultLab = Get-Content -Raw -Path $defaultLabPath | ConvertFrom-Json
    } else {
        $script:TestLabReleaseMatrixDefaultLab = $null
    }

    $script:TestLabReleaseMatrixDefaultLabLoaded = $true
    return $script:TestLabReleaseMatrixDefaultLab
}

function Get-TestLabReleaseMatrixConfigValue {
    param(
        $Lab,
        [string]$Name
    )

    $releaseGateCfg = Get-TestLabReleaseMatrixObjectValue -Object $Lab -Name "releaseGate"
    $value = Get-TestLabReleaseMatrixObjectValue -Object $releaseGateCfg -Name $Name
    if ($null -ne $value -and (-not ($value -is [string]) -or -not [string]::IsNullOrWhiteSpace([string]$value))) {
        return $value
    }

    $defaultLab = Get-TestLabReleaseMatrixDefaultLab
    if ($null -eq $defaultLab) {
        return $value
    }

    $defaultReleaseGateCfg = Get-TestLabReleaseMatrixObjectValue -Object $defaultLab -Name "releaseGate"
    return Get-TestLabReleaseMatrixObjectValue -Object $defaultReleaseGateCfg -Name $Name
}

function New-TestLabReleaseMatrixCell {
    param(
        [string]$Id,
        [string]$SenderUnraid,
        [string]$SenderPlugin,
        [string]$SenderUpgradeFromPlugin,
        [string]$ReceiverUnraid,
        [string]$ReceiverPlugin,
        [string]$ReceiverUpgradeFromPlugin,
        [string]$Lifecycle,
        [string[]]$Scenarios,
        [string[]]$Categories,
        [string]$Purpose
    )

    $sender = [ordered]@{
        unraid = $SenderUnraid
        plugin = $SenderPlugin
    }
    if (-not [string]::IsNullOrWhiteSpace($SenderUpgradeFromPlugin)) {
        $sender.upgradeFromPlugin = $SenderUpgradeFromPlugin
    }

    $receiver = [ordered]@{
        unraid = $ReceiverUnraid
        plugin = $ReceiverPlugin
    }
    if (-not [string]::IsNullOrWhiteSpace($ReceiverUpgradeFromPlugin)) {
        $receiver.upgradeFromPlugin = $ReceiverUpgradeFromPlugin
    }

    return [ordered]@{
        id = $Id
        sender = $sender
        receiver = $receiver
        lifecycle = $Lifecycle
        scenarios = $Scenarios
        categories = $Categories
        purpose = $Purpose
    }
}

function Get-TestLabReleaseMatrixDefinition {
    param(
        $Lab,
        [string]$ProfileName
    )

    $normalizedProfile = ([string]$ProfileName).Trim().ToLowerInvariant()
    if ([string]::IsNullOrWhiteSpace($normalizedProfile)) {
        throw "A release matrix profile name is required."
    }

    $previousReleaseVersion = [string](Get-TestLabReleaseMatrixConfigValue -Lab $Lab -Name "previousReleaseVersion")
    $previousCertifiedUnraidVersion = [string](Get-TestLabReleaseMatrixConfigValue -Lab $Lab -Name "previousCertifiedUnraidVersion")
    $latestSupportedUnraidVersion = [string](Get-TestLabReleaseMatrixConfigValue -Lab $Lab -Name "latestSupportedUnraidVersion")
    $currentCandidatePlugin = [string](Get-TestLabReleaseMatrixConfigValue -Lab $Lab -Name "currentCandidatePlugin")
    if ([string]::IsNullOrWhiteSpace($currentCandidatePlugin)) {
        $currentCandidatePlugin = "workspace-build"
    }

    if ([string]::IsNullOrWhiteSpace($previousReleaseVersion)) {
        throw "lab.releaseGate.previousReleaseVersion is required for release matrix profile '$ProfileName'."
    }
    if ([string]::IsNullOrWhiteSpace($previousCertifiedUnraidVersion)) {
        throw "lab.releaseGate.previousCertifiedUnraidVersion is required for release matrix profile '$ProfileName'."
    }
    if ([string]::IsNullOrWhiteSpace($latestSupportedUnraidVersion)) {
        throw "lab.releaseGate.latestSupportedUnraidVersion is required for release matrix profile '$ProfileName'."
    }

    switch ($normalizedProfile) {
        { $_ -in @("release-default", "default") } {
            return [ordered]@{
                name = "release-default"
                description = "Required release gate covering previous certified Unraid and latest supported Unraid with previous-release vs current-candidate BuddyBackup interoperability in both directions plus in-place upgrade preservation on both baselines."
                mode = "report-only"
                cells = @(
                    (New-TestLabReleaseMatrixCell -Id "prev-certified-prev-to-current" -SenderUnraid $previousCertifiedUnraidVersion -SenderPlugin $previousReleaseVersion -ReceiverUnraid $previousCertifiedUnraidVersion -ReceiverPlugin $currentCandidatePlugin -Lifecycle "fresh-install" -Scenarios @("fresh-install", "backup-smoke") -Categories @("pluginCompatibility") -Purpose "Baseline plugin compatibility on the previous certified Unraid version with the current candidate receiving backups."),
                    (New-TestLabReleaseMatrixCell -Id "prev-certified-current-to-prev" -SenderUnraid $previousCertifiedUnraidVersion -SenderPlugin $currentCandidatePlugin -ReceiverUnraid $previousCertifiedUnraidVersion -ReceiverPlugin $previousReleaseVersion -Lifecycle "fresh-install" -Scenarios @("fresh-install", "backup-smoke") -Categories @("pluginCompatibility") -Purpose "Baseline plugin compatibility on the previous certified Unraid version with the previous release receiving backups."),
                    (New-TestLabReleaseMatrixCell -Id "latest-supported-prev-to-current" -SenderUnraid $latestSupportedUnraidVersion -SenderPlugin $previousReleaseVersion -ReceiverUnraid $latestSupportedUnraidVersion -ReceiverPlugin $currentCandidatePlugin -Lifecycle "fresh-install" -Scenarios @("fresh-install", "backup-smoke") -Categories @("pluginCompatibility", "unraidCompatibility") -Purpose "Plugin compatibility plus latest Unraid certification with the current candidate receiving backups."),
                    (New-TestLabReleaseMatrixCell -Id "latest-supported-current-to-prev" -SenderUnraid $latestSupportedUnraidVersion -SenderPlugin $currentCandidatePlugin -ReceiverUnraid $latestSupportedUnraidVersion -ReceiverPlugin $previousReleaseVersion -Lifecycle "fresh-install" -Scenarios @("fresh-install", "backup-smoke") -Categories @("pluginCompatibility", "unraidCompatibility") -Purpose "Plugin compatibility plus latest Unraid certification with the previous release receiving backups."),
                    (New-TestLabReleaseMatrixCell -Id "prev-certified-upgrade-preserves-config" -SenderUnraid $previousCertifiedUnraidVersion -SenderPlugin $currentCandidatePlugin -SenderUpgradeFromPlugin $previousReleaseVersion -ReceiverUnraid $previousCertifiedUnraidVersion -ReceiverPlugin $currentCandidatePlugin -ReceiverUpgradeFromPlugin $previousReleaseVersion -Lifecycle "upgrade-preserves-config" -Scenarios @("upgrade-preserves-config", "backup-smoke", "restore-smoke") -Categories @("pluginCompatibility") -Purpose "In-place upgrade from the previous release must preserve BuddyBackup configuration and still pass backup and restore smoke on the previous certified Unraid version."),
                    (New-TestLabReleaseMatrixCell -Id "latest-supported-upgrade-preserves-config" -SenderUnraid $latestSupportedUnraidVersion -SenderPlugin $currentCandidatePlugin -SenderUpgradeFromPlugin $previousReleaseVersion -ReceiverUnraid $latestSupportedUnraidVersion -ReceiverPlugin $currentCandidatePlugin -ReceiverUpgradeFromPlugin $previousReleaseVersion -Lifecycle "upgrade-preserves-config" -Scenarios @("upgrade-preserves-config", "backup-smoke", "restore-smoke") -Categories @("pluginCompatibility", "unraidCompatibility") -Purpose "In-place upgrade from the previous release must preserve BuddyBackup configuration and still pass backup and restore smoke on the latest supported Unraid version.")
                )
            }
        }
        { $_ -in @("release-latest-unraid-isolation", "latest-isolation") } {
            return [ordered]@{
                name = "release-latest-unraid-isolation"
                description = "Optional isolation profile for the current candidate on the latest supported Unraid version."
                mode = "report-only"
                cells = @(
                    (New-TestLabReleaseMatrixCell -Id "latest-supported-current-current" -SenderUnraid $latestSupportedUnraidVersion -SenderPlugin $currentCandidatePlugin -ReceiverUnraid $latestSupportedUnraidVersion -ReceiverPlugin $currentCandidatePlugin -Lifecycle "fresh-install" -Scenarios @("fresh-install", "backup-smoke", "restore-smoke") -Categories @("unraidCompatibility") -Purpose "Current candidate isolation run on the latest supported Unraid version.")
                )
            }
        }
        { $_ -in @("release-post-reboot", "post-reboot") } {
            return [ordered]@{
                name = "release-post-reboot"
                description = "Optional reboot persistence profile for the current candidate on the latest supported Unraid version."
                mode = "report-only"
                cells = @(
                    (New-TestLabReleaseMatrixCell -Id "latest-supported-current-current-post-reboot" -SenderUnraid $latestSupportedUnraidVersion -SenderPlugin $currentCandidatePlugin -ReceiverUnraid $latestSupportedUnraidVersion -ReceiverPlugin $currentCandidatePlugin -Lifecycle "post-reboot" -Scenarios @("post-reboot", "backup-smoke") -Categories @("unraidCompatibility") -Purpose "Current candidate reboot persistence on the latest supported Unraid version.")
                )
            }
        }
        { $_ -in @("release-extended", "extended") } {
            $defaultMatrix = Get-TestLabReleaseMatrixDefinition -Lab $Lab -ProfileName "release-default"
            $latestIsolationMatrix = Get-TestLabReleaseMatrixDefinition -Lab $Lab -ProfileName "release-latest-unraid-isolation"
            $postRebootMatrix = Get-TestLabReleaseMatrixDefinition -Lab $Lab -ProfileName "release-post-reboot"

            return [ordered]@{
                name = "release-extended"
                description = "Extended release gate combining the required compatibility cells with latest-Unraid isolation and reboot persistence coverage."
                mode = "report-only"
                cells = @($defaultMatrix.cells + $latestIsolationMatrix.cells + $postRebootMatrix.cells)
            }
        }
        default {
            throw "Unknown release matrix profile '$ProfileName'. Supported profiles: release-default, release-latest-unraid-isolation, release-post-reboot, release-extended."
        }
    }
}

function Write-TestLabReleaseMatrixFile {
    param(
        [string]$WorkspaceRoot,
        $Lab,
        [string]$ProfileName
    )

    $matrix = Get-TestLabReleaseMatrixDefinition -Lab $Lab -ProfileName $ProfileName
    $generatedRoot = Join-Path $WorkspaceRoot ".testlab/generated-matrices"
    Ensure-TestLabReleaseMatrixDir -Path $generatedRoot
    $filePath = Join-Path $generatedRoot ("{0}.json" -f $matrix.name)
    $matrix | ConvertTo-Json -Depth 8 | Set-Content -Path $filePath

    return [pscustomobject]@{
        profileName = [string]$matrix.name
        filePath = $filePath
        matrix = [pscustomobject]$matrix
    }
}