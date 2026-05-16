param(
    [string]$LabConfig = "testlab/config/lab.local.json",
    [switch]$Execute
)

$ErrorActionPreference = "Stop"

. (Join-Path $PSScriptRoot "unraid-payload-cache.ps1")
. (Join-Path $PSScriptRoot "wsl-common.ps1")

function Get-Json {
    param([string]$Path)
    return Get-Content -Raw -Path $Path | ConvertFrom-Json
}

function Ensure-Dir {
    param([string]$Path)
    if (-not (Test-Path -LiteralPath $Path)) {
        New-Item -ItemType Directory -Path $Path -Force | Out-Null
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

function Stop-WslLabInstance {
    param(
        [string]$Distro,
        [string]$InstanceName,
        [switch]$DoExecute
    )

    $workRoot = "/tmp/buddybackup-qemu-$InstanceName"
    if (-not $DoExecute) {
        Write-Host "[dry-run] Would stop WSL/QEMU instance '$InstanceName' at $workRoot"
        return
    }

    $stopScript = @'
set -euo pipefail

work_root="$1"
pid_file="$work_root/qemu.pid"

if [ -f "$pid_file" ]; then
  kill "$(cat "$pid_file")" 2>/dev/null || true
fi

pkill -f "$work_root/unraid-boot.img" 2>/dev/null || true
rm -rf "$work_root"
'@

    $stopResult = Invoke-WslRootBash -Distro $Distro -ScriptContent $stopScript -Arguments @($workRoot)
    if ($stopResult.ExitCode -ne 0) {
        throw (("Failed to stop WSL/QEMU instance '{0}' with exit code {1}`n{2}" -f $InstanceName, $stopResult.ExitCode, (($stopResult.Output | ForEach-Object { [string]$_ }) -join [Environment]::NewLine)).Trim())
    }
}

if (-not (Test-Path -LiteralPath $LabConfig)) {
    throw "Missing lab config: $LabConfig"
}

$lab = Get-Json -Path $LabConfig
$wslCfg = $lab.wslQemu
$distro = if ($wslCfg -and $wslCfg.distro) { [string]$wslCfg.distro } else { "Ubuntu" }
$cacheRoot = if ($wslCfg -and $wslCfg.cacheRoot) { [string]$wslCfg.cacheRoot } else { ".testlab/cache" }
$imageSizeMB = if ($wslCfg -and $wslCfg.imageSizeMB) { [int]$wslCfg.imageSizeMB } else { 1024 }
$bootWaitSeconds = if ($wslCfg -and $wslCfg.bootWaitSeconds) { [int]$wslCfg.bootWaitSeconds } else { 120 }
$downloadUrlTemplate = if ($wslCfg -and $wslCfg.unraidDownloadUrlTemplate) { [string]$wslCfg.unraidDownloadUrlTemplate } else { $null }

$privateKeyPath = if ($wslCfg -and $wslCfg.sshPrivateKeyPath) {
    Resolve-TestLabPath ([string]$wslCfg.sshPrivateKeyPath)
} elseif ($lab.ssh -and $lab.ssh.identityFile) {
    Resolve-TestLabPath ([string]$lab.ssh.identityFile)
} else {
    Resolve-TestLabPath ".testlab/lab_key"
}

$publicKeyPath = if ($wslCfg -and $wslCfg.sshPublicKeyPath) {
    Resolve-TestLabPath ([string]$wslCfg.sshPublicKeyPath)
} else {
    "$privateKeyPath.pub"
}

$logsRoot = if ($lab.logsRoot) { Resolve-TestLabPath ([string]$lab.logsRoot) } else { Resolve-TestLabPath ".testlab/logs" }
$screenshotRoot = if ($wslCfg -and $wslCfg.screenshotRoot) {
    Resolve-TestLabPath ([string]$wslCfg.screenshotRoot)
} else {
    Join-Path $env:LOCALAPPDATA "BuddyBackup\screenshots"
}

Ensure-Dir $logsRoot
Ensure-Dir $screenshotRoot

$runId = Get-Date -Format "yyyyMMdd-HHmmss"
$reportPath = Join-Path $logsRoot ("local-provider-{0}.json" -f $runId)
$probeScript = Join-Path $PSScriptRoot "probe-wsl-qemu-unraid.ps1"

$report = [ordered]@{
    runId       = $runId
    provider    = "windows-local"
    executeMode = [bool]$Execute
    success     = $false
    error       = $null
    nodes       = @()
}

$startedInstances = @()

try {
    foreach ($entry in @(
        @{ NodeName = "sender"; DefaultPort = 2222 },
        @{ NodeName = "receiver"; DefaultPort = 2223 }
    )) {
        $nodeName = [string]$entry["NodeName"]
        $defaultPort = [int]$entry["DefaultPort"]
        $node = Get-ObjectValue -Object $lab.nodes -Name $nodeName
        if (-not $node) {
            continue
        }

        $nodeHost = Get-ObjectValue -Object $node -Name "host"
        if ($nodeHost -and ([string]$nodeHost) -notin @("127.0.0.1", "localhost")) {
            throw "lab.nodes.$nodeName.host must be 127.0.0.1 or localhost for the windows-local WSL/QEMU provider."
        }

        $version = [string](Get-ObjectValue -Object $node -Name "unraidVersion")
        if ([string]::IsNullOrWhiteSpace($version)) {
            throw "Missing lab.nodes.$nodeName.unraidVersion"
        }

        $desiredPortValue = Get-ObjectValue -Object $node -Name "port"
        $desiredPort = if ($desiredPortValue) { [int]$desiredPortValue } else { $defaultPort }
        $instanceNameValue = Get-ObjectValue -Object $node -Name "instanceName"
        $instanceName = if ($instanceNameValue) { [string]$instanceNameValue } else { "lab-$nodeName" }
        if ($instanceName -notmatch '^[A-Za-z0-9._-]+$') {
            throw "Invalid instance name '$instanceName' for node '$nodeName'. Use only letters, digits, dots, underscores, and hyphens."
        }

        $nodePayloadPath = Get-ObjectValue -Object $node -Name "payloadPath"
        $nodeNameValue = Get-ObjectValue -Object $node -Name "name"

        $payloadPath = if ($nodePayloadPath) {
            Resolve-TestLabPath ([string]$nodePayloadPath)
        } elseif ($wslCfg -and $wslCfg.payloadPath) {
            Resolve-TestLabPath ([string]$wslCfg.payloadPath)
        } else {
            Ensure-UnraidPayload -Version $version -CacheRoot $cacheRoot -UrlTemplate $downloadUrlTemplate -DoExecute:$Execute
        }

        if ($Execute) {
            if (-not (Test-Path -LiteralPath $privateKeyPath)) {
                throw "SSH private key not found: $privateKeyPath"
            }
            if (-not (Test-Path -LiteralPath $publicKeyPath)) {
                throw "SSH public key not found: $publicKeyPath"
            }
            if (-not (Test-UnraidPayloadRoot -Path $payloadPath)) {
                throw "Unraid payload is missing required files for node '$nodeName': $payloadPath"
            }
        }

        $outputPath = Join-Path $screenshotRoot ("qemu-unraid-{0}-{1}.png" -f $nodeName, $runId)
        $statusPath = [System.IO.Path]::ChangeExtension($outputPath, ".json")
        $nodeEntry = [ordered]@{
            node                = $nodeName
            name                = if ($nodeNameValue) { [string]$nodeNameValue } else { "buddybackup-$nodeName" }
            host                = "127.0.0.1"
            port                = $desiredPort
            unraidVersion       = $version
            payloadPath         = $payloadPath
            instanceName        = $instanceName
            outputPath          = $outputPath
            statusPath          = $statusPath
            sshReady            = $false
            selectedHostSshPort = $null
            monitorSocketPath   = "/tmp/buddybackup-qemu-$instanceName/qemu-monitor.sock"
            serialLogPath       = "/tmp/buddybackup-qemu-$instanceName/unraid-serial.log"
            wslWorkingRoot      = "/tmp/buddybackup-qemu-$instanceName"
        }

        if ($Execute) {
            Stop-WslLabInstance -Distro $distro -InstanceName $instanceName -DoExecute

            & $probeScript -Distro $distro -PayloadPath $payloadPath -SshPublicKeyPath $publicKeyPath -SshPrivateKeyPath $privateKeyPath -ImageSizeMB $imageSizeMB -BootWaitSeconds $bootWaitSeconds -HostSshPort $desiredPort -OutputPath $outputPath -StatusPath $statusPath -InstanceName $instanceName -LeaveRunning

            if (-not (Test-Path -LiteralPath $statusPath)) {
                throw "Probe status file was not written for node '$nodeName': $statusPath"
            }

            $nodeStatus = Get-Json -Path $statusPath
            $nodeEntry.sshReady = [bool]$nodeStatus.sshReady
            $nodeEntry.selectedHostSshPort = [int]$nodeStatus.selectedHostSshPort
            $nodeEntry.monitorSocketPath = [string]$nodeStatus.monitorSocketPath
            $nodeEntry.serialLogPath = [string]$nodeStatus.serialLogPath
            $nodeEntry.wslWorkingRoot = [string]$nodeStatus.wslWorkingRoot

            if (-not $nodeStatus.success) {
                throw "WSL/QEMU probe failed for node '$nodeName': $($nodeStatus.error)"
            }
            if (-not $nodeStatus.sshReady) {
                throw "WSL/QEMU probe did not reach SSH readiness for node '$nodeName'."
            }
            if ([int]$nodeStatus.selectedHostSshPort -ne $desiredPort) {
                throw "Configured host SSH port $desiredPort for node '$nodeName' is busy; the probe fell back to $($nodeStatus.selectedHostSshPort). Update the lab config or free the configured port."
            }

            $startedInstances += $instanceName
            Write-Host "[testlab] Local node $nodeName ready on 127.0.0.1:$desiredPort"
        } else {
            Write-Host "[dry-run] Would start local node $nodeName on 127.0.0.1:$desiredPort from payload $payloadPath"
            $nodeEntry.sshReady = $true
            $nodeEntry.selectedHostSshPort = $desiredPort
        }

        $report.nodes += [pscustomobject]$nodeEntry
    }

    $report.success = $true
} catch {
    $report.error = ($_ | Out-String).Trim()
    if ($Execute) {
        foreach ($instanceName in $startedInstances) {
            try {
                Stop-WslLabInstance -Distro $distro -InstanceName $instanceName -DoExecute
            } catch {
                Write-Host "[testlab] WARNING: failed to stop instance '$instanceName' during cleanup: $($_.Exception.Message)"
            }
        }
    }
    throw
} finally {
    $report.finishedAt = (Get-Date).ToString("o")
    $report | ConvertTo-Json -Depth 8 | Set-Content -Path $reportPath -Encoding UTF8
    Write-Host "[testlab] Local provider report written to $reportPath"
}