param(
    [string]$LabConfig = "testlab/config/lab.local.json",
    [string]$MatrixConfig = "testlab/config/matrix.small.json",
    [switch]$Execute,
    [switch]$SkipArtifacts
)

$ErrorActionPreference = "Stop"

. (Join-Path $PSScriptRoot "testlab-logging.ps1")

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
    return $cachedPath
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

function Get-ManualAccessVerifyCommand {
        return ((@'
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

if [ "$runtime_hash" != "$persistent_hash" ]; then
    echo "root password hash differs between /etc/shadow and /boot/config/shadow" >&2
    exit 1
fi

echo "root password hash persisted"
'@) -replace "`r`n", "`n").Trim()
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

    $resolvedIdentity = Get-LocalSshIdentityFile -IdentityFile $IdentityFile
    $sshArgs = @(
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
        $sshArgs += @("-i", $resolvedIdentity)
    }
    $sshArgs += @("$User@$TargetHost", $Command)

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
        [int]$SettleSeconds
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

    if ($SettleSeconds -gt 0) {
        Write-Host "[testlab] Allowing ${SettleSeconds}s for services to settle on $targetLabel"
        $settleStarted = Get-Date
        $settleHeartbeatAt = $settleStarted
        while ((New-TimeSpan -Start $settleStarted -End (Get-Date)).TotalSeconds -lt $SettleSeconds) {
            $remainingSeconds = [int][Math]::Ceiling($SettleSeconds - (New-TimeSpan -Start $settleStarted -End (Get-Date)).TotalSeconds)
            if ($remainingSeconds -le 0) {
                break
            }

            Start-Sleep -Seconds ([Math]::Min(5, $remainingSeconds))
            $settleHeartbeatAt = Write-TestLabHeartbeat -Message "Settling services on $targetLabel" -StartedAt $settleStarted -LastHeartbeatAt $settleHeartbeatAt -IntervalSeconds 15 -TimeoutSeconds $SettleSeconds
        }
    }

    $elapsedSeconds = [int](New-TimeSpan -Start $started -End (Get-Date)).TotalSeconds
    $remainingSeconds = [Math]::Max($TimeoutSeconds - $elapsedSeconds, 1)
    if (-not (Wait-SshStable -User $User -TargetHost $TargetHost -Port $Port -IdentityFile $IdentityFile -TimeoutSeconds $remainingSeconds)) {
        return [pscustomobject]@{
            Success = $false
            Error = "Host did not remain SSH-stable after reboot."
            BootId = $null
        }
    }

    $bootIdHeartbeatAt = Get-Date
    while ((New-TimeSpan -Start $started -End (Get-Date)).TotalSeconds -lt $TimeoutSeconds) {
        $bootIdInfo = Get-RemoteBootId -User $User -TargetHost $TargetHost -Port $Port -IdentityFile $IdentityFile -Label "boot-id-after-reboot" -DoExecute
        if ($bootIdInfo.Result.Success -and -not [string]::IsNullOrWhiteSpace($bootIdInfo.BootId)) {
            if ([string]::IsNullOrWhiteSpace($PreviousBootId) -or $bootIdInfo.BootId -ne $PreviousBootId) {
                Write-Host "[testlab] Reboot confirmed on $targetLabel with boot_id $($bootIdInfo.BootId)"
                return [pscustomobject]@{
                    Success = $true
                    Error = $null
                    BootId = $bootIdInfo.BootId
                }
            }
        }

        $bootIdHeartbeatAt = Write-TestLabHeartbeat -Message "Still waiting for a new boot_id on $targetLabel" -StartedAt $started -LastHeartbeatAt $bootIdHeartbeatAt -IntervalSeconds 15 -TimeoutSeconds $TimeoutSeconds
        Start-Sleep -Seconds 3
    }

    return [pscustomobject]@{
        Success = $false
        Error = "Host returned, but boot_id did not change after reboot."
        BootId = $null
    }
}

function Wait-ForRemoteSuccess {
    param(
        [string]$User,
        [string]$TargetHost,
        [int]$Port,
        [string]$IdentityFile,
        [string]$Command,
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
        $lastResult = Invoke-RemoteCommand -User $User -TargetHost $TargetHost -Port $Port -IdentityFile $IdentityFile -Command $Command -Label $Label -DoExecute
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

    Write-Warning "Remote check '$Label' did not succeed on $targetLabel within $TimeoutSeconds seconds"

    return [pscustomobject]@{
        Success = $false
        Result = $lastResult
    }
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
    $pluginVerifyCommand = Get-BuddyBackupPluginVerifyCommand

    foreach ($nodeName in @("sender", "receiver")) {
        $connection = Get-NodeConnection -Lab $Lab -NodeName $nodeName

        $results += Invoke-RemoteCommand -User $connection.User -TargetHost $connection.Host -Port $connection.Port -IdentityFile $connection.IdentityFile -Command $pluginVerifyCommand -Label "${nodeName}-buddybackup-plugin-check" -DoExecute:$DoExecute
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
    $cmd = "plugin install $url forced"
    $result = Invoke-RemoteCommand -User $NodeConnection.User -TargetHost $NodeConnection.Host -Port $NodeConnection.Port -IdentityFile $NodeConnection.IdentityFile -Command $cmd -Label "plugin-install" -DoExecute:$DoExecute

    if ($DoExecute -and -not $result.Success -and $result.Output -match '(?i)not reinstalling same version') {
        $result.ExitCode = 0
        $result.Success = $true
    }

    return $result
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
        [hashtable]$ScenarioCache,
        [switch]$DoExecute
    )

    $sender = Get-NodeConnection -Lab $Lab -NodeName "sender"
    $receiver = Get-NodeConnection -Lab $Lab -NodeName "receiver"

    $results = @()
    $pluginVerifyCommand = Get-BuddyBackupPluginVerifyCommand
    $manualAccessVerifyCommand = Get-ManualAccessVerifyCommand

    Write-Host "[testlab] Starting scenario '$Scenario' for cell $($Cell.id)"

    switch ($Scenario) {
        "fresh-install" {
            $results += Install-Plugin -Lab $Lab -NodeConnection $sender -Version $Cell.sender.plugin -DoExecute:$DoExecute
            $results += Install-Plugin -Lab $Lab -NodeConnection $receiver -Version $Cell.receiver.plugin -DoExecute:$DoExecute
        }
        "post-reboot" {
            $timeout = 300
            if ($Lab.timeouts -and $Lab.timeouts.sshReadySeconds) {
                $timeout = [int]$Lab.timeouts.sshReadySeconds
            }

            $zfsValues = Get-SetupZfsValues -Lab $Lab

            $rebootSettleSeconds = 0
            if ($Lab.timeouts -and $Lab.timeouts.rebootSettleSeconds) {
                $rebootSettleSeconds = [int]$Lab.timeouts.rebootSettleSeconds
            }

            foreach ($node in @(
                [pscustomobject]@{ Name = "sender"; Connection = $sender },
                [pscustomobject]@{ Name = "receiver"; Connection = $receiver }
            )) {
                Write-Host "[testlab] Scenario 'post-reboot': validating reboot persistence on $($node.Name)"
                $beforeBootId = Get-RemoteBootId -User $node.Connection.User -TargetHost $node.Connection.Host -Port $node.Connection.Port -IdentityFile $node.Connection.IdentityFile -Label "$($node.Name)-boot-id-before-reboot" -DoExecute:$DoExecute
                $results += $beforeBootId.Result
                if ($DoExecute -and (-not $beforeBootId.Result.Success -or [string]::IsNullOrWhiteSpace($beforeBootId.BootId))) {
                    throw "Failed to read boot_id before reboot for $($node.Name)."
                }

                $results += Invoke-RemoteCommand -User $node.Connection.User -TargetHost $node.Connection.Host -Port $node.Connection.Port -IdentityFile $node.Connection.IdentityFile -Command "reboot" -Label "$($node.Name)-reboot" -DoExecute:$DoExecute

                if ($DoExecute) {
                    $rebootCycle = Wait-ForRebootCycle -User $node.Connection.User -TargetHost $node.Connection.Host -Port $node.Connection.Port -IdentityFile $node.Connection.IdentityFile -PreviousBootId $beforeBootId.BootId -TimeoutSeconds $timeout -SettleSeconds $rebootSettleSeconds
                    if (-not $rebootCycle.Success) {
                        throw "$($node.Name) reboot validation failed: $($rebootCycle.Error)"
                    }

                    $pluginCheck = Wait-ForRemoteSuccess -User $node.Connection.User -TargetHost $node.Connection.Host -Port $node.Connection.Port -IdentityFile $node.Connection.IdentityFile -Command $pluginVerifyCommand -Label "$($node.Name)-plugin-check" -TimeoutSeconds $timeout
                    $results += $pluginCheck.Result

                    $manualAccessCheck = Wait-ForRemoteSuccess -User $node.Connection.User -TargetHost $node.Connection.Host -Port $node.Connection.Port -IdentityFile $node.Connection.IdentityFile -Command $manualAccessVerifyCommand -Label "$($node.Name)-manual-access-check" -TimeoutSeconds $timeout
                    $results += $manualAccessCheck.Result

                    $zpoolCheck = Wait-ForRemoteSuccess -User $node.Connection.User -TargetHost $node.Connection.Host -Port $node.Connection.Port -IdentityFile $node.Connection.IdentityFile -Command ("zpool list -H -o name {0}" -f $zfsValues.PoolName) -Label "$($node.Name)-zpool-check" -TimeoutSeconds $timeout
                    $results += $zpoolCheck.Result

                    $plainDatasetCheck = Wait-ForRemoteSuccess -User $node.Connection.User -TargetHost $node.Connection.Host -Port $node.Connection.Port -IdentityFile $node.Connection.IdentityFile -Command ("zfs list -H -o name {0}" -f $zfsValues.UnencryptedDataset) -Label "$($node.Name)-plain-dataset-check" -TimeoutSeconds $timeout
                    $results += $plainDatasetCheck.Result

                    $encryptedDatasetCheck = Wait-ForRemoteSuccess -User $node.Connection.User -TargetHost $node.Connection.Host -Port $node.Connection.Port -IdentityFile $node.Connection.IdentityFile -Command ("zfs get -H -o value encryption {0}" -f $zfsValues.EncryptedDataset) -Label "$($node.Name)-encrypted-dataset-check" -TimeoutSeconds $timeout
                    $results += $encryptedDatasetCheck.Result
                } else {
                    $results += Invoke-RemoteCommand -User $node.Connection.User -TargetHost $node.Connection.Host -Port $node.Connection.Port -IdentityFile $node.Connection.IdentityFile -Command $pluginVerifyCommand -Label "$($node.Name)-plugin-check" -DoExecute:$DoExecute
                    $results += Invoke-RemoteCommand -User $node.Connection.User -TargetHost $node.Connection.Host -Port $node.Connection.Port -IdentityFile $node.Connection.IdentityFile -Command $manualAccessVerifyCommand -Label "$($node.Name)-manual-access-check" -DoExecute:$DoExecute
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
$totalCells = $matrixCells.Count

$runId = Get-Date -Format "yyyyMMdd-HHmmss"
$artifactsRoot = $lab.artifactsRoot
if (-not $artifactsRoot) {
    $artifactsRoot = ".testlab/artifacts"
}
Ensure-Dir -Path $artifactsRoot
$runDir = Join-Path $artifactsRoot $runId
Ensure-Dir -Path $runDir


$result = @()
$cellIndex = 0

foreach ($cell in $matrixCells) {
    $cellIndex += 1
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
            Collect-NodeArtifacts -Lab $lab -NodeName "sender" -NodeConnection (Get-NodeConnection -Lab $lab -NodeName "sender") -CellDir $cellDir -DoExecute:$Execute
            Collect-NodeArtifacts -Lab $lab -NodeName "receiver" -NodeConnection (Get-NodeConnection -Lab $lab -NodeName "receiver") -CellDir $cellDir -DoExecute:$Execute
        } catch {
            $status = "fail"
            $errors += "Artifact collection failed: $($_.Exception.Message)"
            Write-Warning "Artifact collection failed for cell $($cell.id): $($_.Exception.Message)"
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
$passCount = @($result | Where-Object { ([string]$_.status).ToLowerInvariant() -eq 'pass' }).Count
$failCount = $result.Count - $passCount
Write-Host "[testlab] Summary: $passCount passed, $failCount failed"
Write-TestLabResultTable -Rows $result
Write-Host "[testlab] Results written to $outPath"
