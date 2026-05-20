param(
    [string]$LabConfig = "testlab/config/lab.local.json",
    [string]$MatrixConfig = "testlab/config/matrix.small.json",
    [switch]$Execute,
    [switch]$SkipArtifacts
)

$ErrorActionPreference = "Stop"

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

function Resolve-IdentityPath {
    param([string]$IdentityFile)

    if (-not $IdentityFile) {
        return $IdentityFile
    }

    if ($IdentityFile.StartsWith("~/")) {
        return Join-Path -Path $HOME -ChildPath $IdentityFile.Substring(2)
    }

    return $IdentityFile
}

function Get-NodeConnection {
    param(
        $Lab,
        [string]$NodeName
    )

    $node = $Lab.nodes.$NodeName
    if (-not $node -or -not $node.host) {
        throw "Missing lab.nodes.$NodeName.host"
    }

    $defaultPort = if ($Lab.ssh -and $Lab.ssh.port) { [int]$Lab.ssh.port } else { 22 }
    $defaultUser = if ($Lab.ssh -and $Lab.ssh.user) { [string]$Lab.ssh.user } else { "root" }
    $defaultIdentityFile = if ($Lab.ssh -and $Lab.ssh.identityFile) { [string]$Lab.ssh.identityFile } else { $null }

    return [pscustomobject]@{
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
        [string]$Label = "remote",
        [switch]$DoExecute
    )

    $resolvedIdentity = Resolve-IdentityPath -IdentityFile $IdentityFile
    $sshArgs = @("-o", "BatchMode=yes", "-p", "$Port")
    if ($resolvedIdentity) {
        $sshArgs += @("-i", $resolvedIdentity)
    }
    $sshArgs += @("$User@$TargetHost", $Command)

    if ($DoExecute) {
        $output = (& ssh @sshArgs 2>&1 | Out-String).Trim()
        $exitCode = $LASTEXITCODE
        return [pscustomobject]@{
            Label = $Label
            Command = $Command
            ExitCode = $exitCode
            Output = $output
            Success = ($exitCode -eq 0)
        }
    } else {
        Write-Host "[dry-run][ssh][$Label] ssh $($sshArgs -join ' ')"
        return [pscustomobject]@{
            Label = $Label
            Command = $Command
            ExitCode = 0
            Output = "dry-run"
            Success = $true
        }
    }
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
    while ((New-TimeSpan -Start $started -End (Get-Date)).TotalSeconds -lt $TimeoutSeconds) {
        $probe = Invoke-RemoteCommand -User $User -TargetHost $TargetHost -Port $Port -IdentityFile $IdentityFile -Command "echo ready" -Label "ssh-ready-probe" -DoExecute
        if ($probe.Success) {
            return $true
        }
        Start-Sleep -Seconds 5
    }

    return $false
}

function Get-LatestLocalProviderReport {
    param($Lab)

    $logsRoot = if ($Lab.logsRoot) { [string]$Lab.logsRoot } else { ".testlab/logs" }
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

        foreach ($nodeName in @("sender", "receiver")) {
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

    foreach ($nodeName in @("sender", "receiver")) {
        $connection = Get-NodeConnection -Lab $Lab -NodeName $nodeName

        $results += Invoke-RemoteCommand -User $connection.User -TargetHost $connection.Host -Port $connection.Port -IdentityFile $connection.IdentityFile -Command "plugin list | grep -i buddybackup" -Label "${nodeName}-buddybackup-plugin-check" -DoExecute:$DoExecute
        $results += Invoke-RemoteCommand -User $connection.User -TargetHost $connection.Host -Port $connection.Port -IdentityFile $connection.IdentityFile -Command ("zpool list -H -o name {0}" -f $zfsValues.PoolName) -Label "${nodeName}-zpool-check" -DoExecute:$DoExecute
        $results += Invoke-RemoteCommand -User $connection.User -TargetHost $connection.Host -Port $connection.Port -IdentityFile $connection.IdentityFile -Command ("zfs list -H -o name {0}" -f $zfsValues.UnencryptedDataset) -Label "${nodeName}-plain-dataset-check" -DoExecute:$DoExecute
        $encResult = Invoke-RemoteCommand -User $connection.User -TargetHost $connection.Host -Port $connection.Port -IdentityFile $connection.IdentityFile -Command ("zfs get -H -o value encryption {0}" -f $zfsValues.EncryptedDataset) -Label "${nodeName}-encrypted-dataset-check" -DoExecute:$DoExecute
        $results += $encResult

        if ($DoExecute -and $encResult.Success -and $encResult.Output -match '(?i)^off\s*$') {
            $encResult.Success = $false
            $encResult.ExitCode = 1
            $encResult.Output = "encryption=off"
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

function Install-Plugin {
    param(
        $NodeConnection,
        [string]$Version,
        [switch]$DoExecute
    )

    $url = $Lab.plugin.plgUrlTemplate.Replace("{version}", $Version)
    $cmd = "plugin install $url"
    Invoke-RemoteCommand -User $NodeConnection.User -TargetHost $NodeConnection.Host -Port $NodeConnection.Port -IdentityFile $NodeConnection.IdentityFile -Command $cmd -Label "plugin-install" -DoExecute:$DoExecute
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
        [switch]$DoExecute
    )

    $sender = Get-NodeConnection -Lab $Lab -NodeName "sender"
    $receiver = Get-NodeConnection -Lab $Lab -NodeName "receiver"

    $results = @()

    switch ($Scenario) {
        "fresh-install" {
            $results += Install-Plugin -Lab $Lab -NodeConnection $sender -Version $Cell.sender.plugin -DoExecute:$DoExecute
            $results += Install-Plugin -Lab $Lab -NodeConnection $receiver -Version $Cell.receiver.plugin -DoExecute:$DoExecute
        }
        "post-reboot" {
            $results += Invoke-RemoteCommand -User $sender.User -TargetHost $sender.Host -Port $sender.Port -IdentityFile $sender.IdentityFile -Command "reboot" -Label "sender-reboot" -DoExecute:$DoExecute
            $results += Invoke-RemoteCommand -User $receiver.User -TargetHost $receiver.Host -Port $receiver.Port -IdentityFile $receiver.IdentityFile -Command "reboot" -Label "receiver-reboot" -DoExecute:$DoExecute

            if ($DoExecute) {
                $timeout = 300
                if ($Lab.timeouts -and $Lab.timeouts.sshReadySeconds) {
                    $timeout = [int]$Lab.timeouts.sshReadySeconds
                }

                if (-not (Wait-SshReady -User $sender.User -TargetHost $sender.Host -Port $sender.Port -IdentityFile $sender.IdentityFile -TimeoutSeconds $timeout)) {
                    throw "Sender did not return after reboot in $timeout seconds"
                }
                if (-not (Wait-SshReady -User $receiver.User -TargetHost $receiver.Host -Port $receiver.Port -IdentityFile $receiver.IdentityFile -TimeoutSeconds $timeout)) {
                    throw "Receiver did not return after reboot in $timeout seconds"
                }
            }

            $results += Invoke-RemoteCommand -User $sender.User -TargetHost $sender.Host -Port $sender.Port -IdentityFile $sender.IdentityFile -Command "plugin list | grep buddybackup" -Label "sender-plugin-check" -DoExecute:$DoExecute
            $results += Invoke-RemoteCommand -User $receiver.User -TargetHost $receiver.Host -Port $receiver.Port -IdentityFile $receiver.IdentityFile -Command "plugin list | grep buddybackup" -Label "receiver-plugin-check" -DoExecute:$DoExecute
        }
        "backup-smoke" {
            $cmd = "/usr/local/emhttp/plugins/buddybackup/scripts/rc.buddybackup.php send_backup smoke"
            $results += Invoke-RemoteCommand -User $sender.User -TargetHost $sender.Host -Port $sender.Port -IdentityFile $sender.IdentityFile -Command $cmd -Label "backup-smoke" -DoExecute:$DoExecute
        }
        "restore-smoke" {
            $cmd = "/usr/local/emhttp/plugins/buddybackup/scripts/rc.buddybackup.php restore_snapshot smoke restore_last"
            $results += Invoke-RemoteCommand -User $sender.User -TargetHost $sender.Host -Port $sender.Port -IdentityFile $sender.IdentityFile -Command $cmd -Label "restore-smoke" -DoExecute:$DoExecute
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

$runId = Get-Date -Format "yyyyMMdd-HHmmss"
$artifactsRoot = $lab.artifactsRoot
if (-not $artifactsRoot) {
    $artifactsRoot = ".testlab/artifacts"
}
Ensure-Dir -Path $artifactsRoot
$runDir = Join-Path $artifactsRoot $runId
Ensure-Dir -Path $runDir

$result = @()

foreach ($cell in $matrix.cells) {
    Write-Host "[testlab] Running cell $($cell.id) lifecycle=$($cell.lifecycle)"
    $status = "pass"
    $errors = @()
    $scenarioResults = @()
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
            $baseSetupRun = Run-BaseSetupVerification -Lab $lab -CellDir $cellDir -DoExecute:$Execute
            $scenarioResults += $baseSetupRun
            if (-not $baseSetupRun.Success) {
                $status = "fail"
                $errors += "Scenario 'base-setup-verify' failed: $($baseSetupRun.Error)"
            }
        } catch {
            $status = "fail"
            $errors += "Scenario 'base-setup-verify' failed: $($_.Exception.Message)"
            $scenarioResults += [pscustomobject]@{
                Scenario = "base-setup-verify"
                Success = $false
                Error = $_.Exception.Message
            }
        }
    }

    foreach ($scenario in $cell.scenarios) {
        try {
            $scenarioRun = Run-Scenario -Scenario $scenario -Lab $lab -Cell $cell -CellDir $cellDir -DoExecute:$Execute
            $scenarioResults += $scenarioRun
            if (-not $scenarioRun.Success) {
                $status = "fail"
                $errors += "Scenario '$scenario' failed: $($scenarioRun.Error)"
            }
        } catch {
            $status = "fail"
            $errors += "Scenario '$scenario' failed: $($_.Exception.Message)"
            $scenarioResults += [pscustomobject]@{
                Scenario = $scenario
                Success = $false
                Error = $_.Exception.Message
            }
        }
    }

    if (-not $SkipArtifacts) {
        try {
            Collect-NodeArtifacts -Lab $lab -NodeName "sender" -NodeConnection (Get-NodeConnection -Lab $lab -NodeName "sender") -CellDir $cellDir -DoExecute:$Execute
            Collect-NodeArtifacts -Lab $lab -NodeName "receiver" -NodeConnection (Get-NodeConnection -Lab $lab -NodeName "receiver") -CellDir $cellDir -DoExecute:$Execute
        } catch {
            $status = "fail"
            $errors += "Artifact collection failed: $($_.Exception.Message)"
        }
    }

    $result += [pscustomobject]@{
        runId = $runId
        cellId = $cell.id
        senderUnraid = $cell.sender.unraid
        receiverUnraid = $cell.receiver.unraid
        senderPlugin = $cell.sender.plugin
        receiverPlugin = $cell.receiver.plugin
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
Write-Host "[testlab] Results written to $outPath"
