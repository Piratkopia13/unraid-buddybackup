<#
.SYNOPSIS
    Layer 5 Matrix Orchestrator for BuddyBackup testlab.
.DESCRIPTION
    Loads matrix configuration, validates Unraid baselines, iterates matrix cells,
    dispatches test execution to Layer 4 standalone scenarios, collects host artifacts,
    and publishes structured matrix results.
#>

[CmdletBinding()]
param(
    [Parameter(Mandatory = $false)]
    [string]$LabConfig = "testlab/config/lab.local.json",

    [Parameter(Mandatory = $false)]
    [string]$MatrixConfig = "testlab/config/matrix.small.json",

    [switch]$Execute,
    [switch]$SkipArtifacts
)

$ErrorActionPreference = "Stop"

$workspaceRoot = [System.IO.Path]::GetFullPath((Join-Path $PSScriptRoot "..\.."))
$modulesRoot = Join-Path $workspaceRoot "testlab\modules"
$scenariosRoot = Join-Path $workspaceRoot "testlab\scenarios"

Import-Module -Name (Resolve-Path -LiteralPath (Join-Path $modulesRoot "TestLab.Core\TestLab.Core.psm1")).ProviderPath -DisableNameChecking
Import-Module -Name (Resolve-Path -LiteralPath (Join-Path $modulesRoot "TestLab.Transport\TestLab.Transport.psm1")).ProviderPath -DisableNameChecking
Import-Module -Name (Resolve-Path -LiteralPath (Join-Path $modulesRoot "TestLab.Guest\TestLab.Guest.psm1")).ProviderPath -DisableNameChecking

# ---------------- Matrix Validation & Resolution Helpers ----------------

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

    $summary = @($resolvedNodeVersions.Keys | ForEach-Object { "$_=$($resolvedNodeVersions[$_])" }) -join ', '
    return [pscustomobject]@{
        Applied = $true
        Updated = $updated
        VersionSummary = $summary
    }
}

function Get-LatestLocalProviderReport {
    param($Lab)

    $logsRoot = if ($Lab.logsRoot) { [string]$Lab.logsRoot } else { ".testlab/logs" }
    $resolvedLogsRoot = Resolve-TestLabWorkspacePath -WorkspaceRoot $workspaceRoot -Path $logsRoot
    $reports = Get-ChildItem -Path $resolvedLogsRoot -Filter "local-provider-*.json" -ErrorAction SilentlyContinue | Sort-Object LastWriteTime -Descending
    if (-not $reports -or $reports.Count -eq 0) {
        return $null
    }

    return Read-TestLabJson -Path $reports[0].FullName
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

    $pluginInstall = @($actions | Where-Object { $_.label -in @("buddybackup-plugin-install", "workspace-build-install") }) | Select-Object -First 1
    if (-not $pluginInstall) {
        return [pscustomobject]@{ Success = $false; Error = "buddybackup-plugin-install action is missing for '$NodeName'." }
    }
    if (-not $pluginInstall.success) {
        return [pscustomobject]@{ Success = $false; Error = "$($pluginInstall.label) failed for '$NodeName'." }
    }
    if ($pluginInstall.warningsOrErrorsDetected) {
        return [pscustomobject]@{ Success = $false; Error = "$($pluginInstall.label) output contained warning/error text for '$NodeName'." }
    }

    return [pscustomobject]@{ Success = $true; Error = $null }
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
                (Wait-ForRemoteSuccess -NodeConnection $connection -Command $check.Command -Label $check.Label -TimeoutSeconds $baseSetupVerificationTimeout).Result
            } else {
                Invoke-RemoteBash -NodeConnection $connection -ScriptContent $check.Command -Label $check.Label -DoExecute:$DoExecute
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

function Collect-NodeArtifacts {
    param(
        $Lab,
        [string]$NodeName,
        $NodeConnection,
        [string]$CellDir,
        [switch]$DoExecute
    )

    $nodeDir = Join-Path -Path $CellDir -ChildPath $NodeName
    Ensure-TestLabDir -Path $nodeDir

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
        $result = Invoke-RemoteBash -NodeConnection $NodeConnection -ScriptContent $item.Cmd -Label $item.Name -DoExecute:$DoExecute
        $artifactPath = Join-Path -Path $nodeDir -ChildPath ("{0}.txt" -f $item.Name)
        $content = @(
            "label=$($result.Label)",
            "exitCode=$($result.ExitCode)",
            "command=$($result.Command)",
            "output:",
            $result.Output
        ) -join [Environment]::NewLine
        Set-TestLabTextFile -Path $artifactPath -Value $content
    }
}

function Invoke-FunctionalSmokeScenario {
    param(
        [string]$LabConfigPath,
        [string]$OutputDir,
        [hashtable]$ScenarioCache,
        [switch]$DoExecute
    )

    if ($ScenarioCache.ContainsKey("functional-smoke")) {
        Write-Host "[testlab] Reusing cached functional smoke result"
        return $ScenarioCache["functional-smoke"]
    }

    $scenarioScript = Join-Path $scenariosRoot "Scenario-FunctionalSmoke.ps1"
    $res = & $scenarioScript -LabConfig $LabConfigPath -OutputDir $OutputDir -Execute:$DoExecute

    $ScenarioCache["functional-smoke"] = $res
    return $res
}

function Invoke-MultiDatasetScenario {
    param(
        [string]$LabConfigPath,
        [string]$OutputDir,
        [hashtable]$ScenarioCache,
        [switch]$DoExecute
    )

    if ($ScenarioCache.ContainsKey("multi-dataset")) {
        Write-Host "[testlab] Reusing cached multi-dataset scenario result"
        return $ScenarioCache["multi-dataset"]
    }

    $scenarioScript = Join-Path $scenariosRoot "Scenario-MultiDataset.ps1"
    $res = & $scenarioScript -LabConfig $LabConfigPath -OutputDir $OutputDir -Execute:$DoExecute

    $ScenarioCache["multi-dataset"] = $res
    return $res
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

    Write-Host "[testlab] Starting scenario '$Scenario' for cell $($Cell.id)"

    $scenarioResult = $null
    $senderUpgradeFromRequest = if ($Cell.PSObject.Properties['nodeAUpgradeFromPluginRequest']) { $Cell.nodeAUpgradeFromPluginRequest } else { $Cell.senderUpgradeFromPluginRequest }
    $receiverUpgradeFromRequest = if ($Cell.PSObject.Properties['nodeBUpgradeFromPluginRequest']) { $Cell.nodeBUpgradeFromPluginRequest } else { $Cell.receiverUpgradeFromPluginRequest }

    switch ($Scenario) {
        "fresh-install" {
            $scenarioScript = Join-Path $scenariosRoot "Scenario-FreshInstall.ps1"
            $scenarioResult = & $scenarioScript -LabConfig $LabConfig -NodeAPlugin $Cell.nodeAPluginRequest.requestedValue -NodeBPlugin $Cell.nodeBPluginRequest.requestedValue -CellId $Cell.id -OutputDir $CellDir -Execute:$DoExecute
        }
        "upgrade-preserves-config" {
            if ($null -eq $senderUpgradeFromRequest -or $null -eq $receiverUpgradeFromRequest) {
                throw "Scenario 'upgrade-preserves-config' requires nodeA.upgradeFromPlugin and nodeB.upgradeFromPlugin in cell $($Cell.id)."
            }
            $scenarioScript = Join-Path $scenariosRoot "Scenario-UpgradePreservesConfig.ps1"
            $scenarioResult = & $scenarioScript -LabConfig $LabConfig -UpgradeFrom $senderUpgradeFromRequest.requestedValue -UpgradeTo $Cell.nodeAPluginRequest.requestedValue -CellId $Cell.id -OutputDir $CellDir -Execute:$DoExecute
        }
        "post-reboot" {
            $scenarioScript = Join-Path $scenariosRoot "Scenario-PostReboot.ps1"
            $scenarioResult = & $scenarioScript -LabConfig $LabConfig -NodeAPlugin $Cell.nodeAPluginRequest.requestedValue -NodeBPlugin $Cell.nodeBPluginRequest.requestedValue -CellId $Cell.id -OutputDir $CellDir -Execute:$DoExecute
        }
        "backup-smoke" {
            $functionalSmoke = Invoke-FunctionalSmokeScenario -LabConfigPath $LabConfig -OutputDir $CellDir -ScenarioCache $ScenarioCache -DoExecute:$DoExecute
            $scenarioResult = [pscustomobject]@{
                Scenario = "backup-smoke"
                Success  = $functionalSmoke.Success
                Results  = @([pscustomobject]@{
                    Label    = "backup-smoke"
                    Command  = "Scenario-FunctionalSmoke.ps1"
                    ExitCode = if ($functionalSmoke.Success) { 0 } else { 1 }
                    Output   = if ($functionalSmoke.Success) { "Functional smoke completed successfully.`nreport=$($functionalSmoke.ReportPath)" } else { $functionalSmoke.Error }
                    Success  = $functionalSmoke.Success
                })
                Error    = if ($functionalSmoke.Success) { $null } else { $functionalSmoke.Error }
            }
        }
        "restore-smoke" {
            $functionalSmoke = Invoke-FunctionalSmokeScenario -LabConfigPath $LabConfig -OutputDir $CellDir -ScenarioCache $ScenarioCache -DoExecute:$DoExecute
            $scenarioResult = [pscustomobject]@{
                Scenario = "restore-smoke"
                Success  = $functionalSmoke.Success
                Results  = @([pscustomobject]@{
                    Label    = "restore-smoke"
                    Command  = "Scenario-FunctionalSmoke.ps1"
                    ExitCode = if ($functionalSmoke.Success) { 0 } else { 1 }
                    Output   = if ($functionalSmoke.Success) { "Functional smoke completed successfully.`nreport=$($functionalSmoke.ReportPath)" } else { $functionalSmoke.Error }
                    Success  = $functionalSmoke.Success
                })
                Error    = if ($functionalSmoke.Success) { $null } else { $functionalSmoke.Error }
            }
        }
        "multi-dataset" {
            $multiDataset = Invoke-MultiDatasetScenario -LabConfigPath $LabConfig -OutputDir $CellDir -ScenarioCache $ScenarioCache -DoExecute:$DoExecute
            $scenarioResult = [pscustomobject]@{
                Scenario = "multi-dataset"
                Success  = $multiDataset.Success
                Results  = @([pscustomobject]@{
                    Label    = "multi-dataset"
                    Command  = "Scenario-MultiDataset.ps1"
                    ExitCode = if ($multiDataset.Success) { 0 } else { 1 }
                    Output   = if ($multiDataset.Success) { "Multi-dataset scenario completed successfully.`nreport=$($multiDataset.ReportPath)" } else { $multiDataset.Error }
                    Success  = $multiDataset.Success
                })
                Error    = if ($multiDataset.Success) { $null } else { $multiDataset.Error }
            }
        }
        "generic-smoke" {
            $scenarioScript = Join-Path $scenariosRoot "Scenario-GenericSmoke.ps1"
            $scenarioResult = & $scenarioScript -LabConfig $LabConfig -OutputDir $CellDir -Execute:$DoExecute
        }
        default {
            throw "Unknown scenario: $Scenario"
        }
    }

    if ($null -ne $scenarioResult.Results -and (-not [string]::IsNullOrWhiteSpace($CellDir))) {
        $scenarioPath = Join-Path -Path $CellDir -ChildPath ("scenario-{0}.json" -f $Scenario)
        $scenarioResult.Results | ConvertTo-Json -Depth 8 | Set-Content -Path $scenarioPath
    }

    if (-not $scenarioResult.Success) {
        Write-Warning "Scenario '$Scenario' failed for cell $($Cell.id): $($scenarioResult.Error)"
        return [pscustomobject]@{
            Scenario = $Scenario
            Success  = $false
            Error    = $scenarioResult.Error
        }
    }

    Write-Host "[testlab] Scenario '$Scenario' completed successfully for cell $($Cell.id)"
    return [pscustomobject]@{
        Scenario = $Scenario
        Success  = $true
        Error    = $null
    }
}

# ---------------- Main Orchestrator Execution ----------------

if ($MyInvocation.InvocationName -ne '.') {
    if (-not (Test-Path -LiteralPath $LabConfig)) { throw "Missing file: $LabConfig" }
    if (-not (Test-Path -LiteralPath $MatrixConfig)) { throw "Missing file: $MatrixConfig" }

    $lab = Read-TestLabJson -Path $LabConfig
    $matrix = Read-TestLabJson -Path $MatrixConfig
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
    $resolvedArtifactsRoot = Resolve-TestLabWorkspacePath -WorkspaceRoot $workspaceRoot -Path ([string]$artifactsRoot)
    Ensure-TestLabDir -Path $resolvedArtifactsRoot
    $runDir = Join-Path $resolvedArtifactsRoot $runId
    Ensure-TestLabDir -Path $runDir

    $result = @()
    $cellIndex = 0
    $configuredBuildCacheRoot = Get-ObjectValue -Object (Get-ObjectValue -Object $lab -Name "plugin") -Name "buildCacheRoot"

    foreach ($cell in $matrixCells) {
        $cellIndex += 1
        $nodeA = Get-TestLabNodeValue -Object $cell -NodeName 'nodeA'
        $nodeB = Get-TestLabNodeValue -Object $cell -NodeName 'nodeB'
        $nodeAPluginRequest = Resolve-TestLabPluginRequest -RequestedValue ([string](Get-ObjectValue -Object $nodeA -Name 'plugin')) -WorkspaceRoot $workspaceRoot -ConfiguredBuildCacheRoot $configuredBuildCacheRoot
        $nodeBPluginRequest = Resolve-TestLabPluginRequest -RequestedValue ([string](Get-ObjectValue -Object $nodeB -Name 'plugin')) -WorkspaceRoot $workspaceRoot -ConfiguredBuildCacheRoot $configuredBuildCacheRoot
        $cell | Add-Member -NotePropertyName nodeAPluginRequest -NotePropertyValue $nodeAPluginRequest -Force
        $cell | Add-Member -NotePropertyName nodeBPluginRequest -NotePropertyValue $nodeBPluginRequest -Force
        $cell | Add-Member -NotePropertyName senderPluginRequest -NotePropertyValue $nodeAPluginRequest -Force
        $cell | Add-Member -NotePropertyName receiverPluginRequest -NotePropertyValue $nodeBPluginRequest -Force

        $nodeAUpgradeFromPlugin = [string](Get-ObjectValue -Object $nodeA -Name 'upgradeFromPlugin')
        if (-not [string]::IsNullOrWhiteSpace($nodeAUpgradeFromPlugin)) {
            $resolvedNodeAUpgradeFromPlugin = Resolve-TestLabPluginRequest -RequestedValue $nodeAUpgradeFromPlugin -WorkspaceRoot $workspaceRoot -ConfiguredBuildCacheRoot $configuredBuildCacheRoot
            $cell | Add-Member -NotePropertyName nodeAUpgradeFromPluginRequest -NotePropertyValue $resolvedNodeAUpgradeFromPlugin -Force
            $cell | Add-Member -NotePropertyName senderUpgradeFromPluginRequest -NotePropertyValue $resolvedNodeAUpgradeFromPlugin -Force
        }
        $nodeBUpgradeFromPlugin = [string](Get-ObjectValue -Object $nodeB -Name 'upgradeFromPlugin')
        if (-not [string]::IsNullOrWhiteSpace($nodeBUpgradeFromPlugin)) {
            $resolvedNodeBUpgradeFromPlugin = Resolve-TestLabPluginRequest -RequestedValue $nodeBUpgradeFromPlugin -WorkspaceRoot $workspaceRoot -ConfiguredBuildCacheRoot $configuredBuildCacheRoot
            $cell | Add-Member -NotePropertyName nodeBUpgradeFromPluginRequest -NotePropertyValue $resolvedNodeBUpgradeFromPlugin -Force
            $cell | Add-Member -NotePropertyName receiverUpgradeFromPluginRequest -NotePropertyValue $resolvedNodeBUpgradeFromPlugin -Force
        }

        Write-Host "[testlab] Running cell $($cell.id) ($cellIndex/$totalCells) lifecycle=$($cell.lifecycle)"
        $status = "pass"
        $errors = @()
        $scenarioResults = @()
        $scenarioCache = @{}
        $cellDir = Join-Path -Path $runDir -ChildPath $cell.id
        Ensure-TestLabDir -Path $cellDir

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
            runId                           = $runId
            cellId                          = $cell.id
            nodeAUnraid                     = [string](Get-ObjectValue -Object $nodeA -Name 'unraid')
            nodeBUnraid                     = [string](Get-ObjectValue -Object $nodeB -Name 'unraid')
            nodeAPlugin                     = $nodeAPluginRequest.displayVersion
            nodeAPluginRequested            = $nodeAPluginRequest.requestedValue
            nodeAPluginResolved             = $nodeAPluginRequest.displayVersion
            nodeAPluginSource               = $nodeAPluginRequest.sourceType
            nodeAUpgradeFromPluginRequested = if ($cell.PSObject.Properties['nodeAUpgradeFromPluginRequest']) { [string]$cell.nodeAUpgradeFromPluginRequest.requestedValue } else { $null }
            nodeAUpgradeFromPluginResolved  = if ($cell.PSObject.Properties['nodeAUpgradeFromPluginRequest']) { [string]$cell.nodeAUpgradeFromPluginRequest.displayVersion } else { $null }
            nodeBPlugin                     = $nodeBPluginRequest.displayVersion
            nodeBPluginRequested            = $nodeBPluginRequest.requestedValue
            nodeBPluginResolved             = $nodeBPluginRequest.displayVersion
            nodeBPluginSource               = $nodeBPluginRequest.sourceType
            nodeBUpgradeFromPluginRequested = if ($cell.PSObject.Properties['nodeBUpgradeFromPluginRequest']) { [string]$cell.nodeBUpgradeFromPluginRequest.requestedValue } else { $null }
            nodeBUpgradeFromPluginResolved  = if ($cell.PSObject.Properties['nodeBUpgradeFromPluginRequest']) { [string]$cell.nodeBUpgradeFromPluginRequest.displayVersion } else { $null }
            categories                      = @((Get-ObjectValue -Object $cell -Name "categories") | Where-Object { $null -ne $_ })
            purpose                         = [string](Get-ObjectValue -Object $cell -Name "purpose")
            lifecycle                       = $cell.lifecycle
            status                          = $status
            errors                          = $errors
            scenarioResults                 = $scenarioResults
            artifactDir                     = $cellDir
            executeMode                     = [bool]$Execute
        }
    }

    $outPath = Join-Path $runDir "results.json"
    $result | ConvertTo-Json -Depth 8 | Set-Content -Path $outPath
    $passCount = @($result | Where-Object { ([string]$_.status).ToLowerInvariant() -eq 'pass' }).Count
    $failCount = $result.Count - $passCount
    Write-Host "[testlab] Summary: $passCount passed, $failCount failed"
    Write-TestLabResultTable -Rows $result
    Write-Host "[testlab] Results written to $outPath"
}
