param(
    [string]$LabConfig = "testlab/config/lab.local.json",
    [switch]$Execute
)

$ErrorActionPreference = "Stop"

. (Join-Path $PSScriptRoot "testlab-logging.ps1")

if (-not (Test-Path $LabConfig)) {
    throw "Missing lab config: $LabConfig"
}

$lab = Get-Content -Raw -Path $LabConfig | ConvertFrom-Json
$provider = $lab.provider

if (-not $provider) {
    throw "lab.provider is required"
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

function Ensure-Dir {
    param([string]$Path)
    if (-not (Test-Path $Path)) {
        New-Item -ItemType Directory -Path $Path | Out-Null
    }
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

function Invoke-NodeProbe {
    param(
        [string]$User,
        [string]$TargetHost,
        [int]$Port,
        [string]$IdentityFile,
        [switch]$DoExecute
    )

    $resolvedIdentity = Resolve-IdentityPath -IdentityFile $IdentityFile
    $cmd = "echo probe-ok; uname -a"

    $sshArgs = @("-o", "BatchMode=yes", "-p", "$Port")
    if ($resolvedIdentity) {
        $sshArgs += @("-i", $resolvedIdentity)
    }
    $sshArgs += @("$User@$TargetHost", $cmd)

    if ($DoExecute) {
        $output = (& ssh @sshArgs 2>&1 | Out-String).Trim()
        $exitCode = $LASTEXITCODE
        return [pscustomobject]@{
            success = ($exitCode -eq 0)
            exitCode = $exitCode
            output = $output
        }
    }

    return [pscustomobject]@{
        success = $true
        exitCode = 0
        output = "dry-run"
    }
}

Write-Host "[testlab] Provider: $provider"

$runId = Get-Date -Format "yyyyMMdd-HHmmss"
$logsRoot = $lab.logsRoot
if (-not $logsRoot) {
    $logsRoot = ".testlab/logs"
}
Ensure-Dir -Path $logsRoot
$reportPath = Join-Path -Path $logsRoot -ChildPath ("provision-{0}.json" -f $runId)

$report = [pscustomobject]@{
    runId = $runId
    provider = $provider
    executeMode = [bool]$Execute
    providerReportPath = $null
    nodeChecks = @()
}

switch ($provider) {
    "windows-local" {
        Write-Host "[testlab] Windows-local provider selected. Booting local WSL/QEMU nodes."
        $providerScript = Join-Path -Path (Split-Path -Parent $PSCommandPath) -ChildPath "provision-wsl-qemu-lab.ps1"
        $providerStarted = Get-Date
        & $providerScript -LabConfig $LabConfig -Execute:$Execute
        $providerReport = Get-ChildItem -Path $logsRoot -Filter "local-provider-*.json" -ErrorAction SilentlyContinue |
            Where-Object { $_.LastWriteTime -ge $providerStarted.AddSeconds(-5) } |
            Sort-Object -Property LastWriteTime -Descending |
            Select-Object -First 1
        if ($providerReport) {
            $report.providerReportPath = $providerReport.FullName
        }
        break
    }
    "windows-wsl-qemu" {
        Write-Host "[testlab] Windows WSL/QEMU provider selected. Booting local nodes."
        $providerScript = Join-Path -Path (Split-Path -Parent $PSCommandPath) -ChildPath "provision-wsl-qemu-lab.ps1"
        $providerStarted = Get-Date
        & $providerScript -LabConfig $LabConfig -Execute:$Execute
        $providerReport = Get-ChildItem -Path $logsRoot -Filter "local-provider-*.json" -ErrorAction SilentlyContinue |
            Where-Object { $_.LastWriteTime -ge $providerStarted.AddSeconds(-5) } |
            Sort-Object -Property LastWriteTime -Descending |
            Select-Object -First 1
        if ($providerReport) {
            $report.providerReportPath = $providerReport.FullName
        }
        break
    }
    "manual" {
        Write-Host "[testlab] Manual provider selected. Validating configured nodes."

        foreach ($nodeName in @("sender", "receiver")) {
            $connection = Get-NodeConnection -Lab $lab -NodeName $nodeName

            $probe = Invoke-NodeProbe -User $connection.User -TargetHost $connection.Host -Port $connection.Port -IdentityFile $connection.IdentityFile -DoExecute:$Execute
            $report.nodeChecks += [pscustomobject]@{
                node = $nodeName
                host = $connection.Host
                port = $connection.Port
                success = $probe.success
                exitCode = $probe.exitCode
                output = $probe.output
            }

            if ($probe.success) {
                Write-Host "[testlab] Node $nodeName ($($connection.Host):$($connection.Port)) reachable"
            } else {
                Write-Host "[testlab] Node $nodeName ($($connection.Host):$($connection.Port)) probe failed"
            }
        }
    }
    "proxmox" {
        if ($Execute) {
            throw "Proxmox provisioning implementation is not added yet."
        }
        Write-Host "[dry-run] Proxmox provisioning would run here."
    }
    "vagrant" {
        if ($Execute) {
            throw "Vagrant provisioning implementation is not added yet."
        }
        Write-Host "[dry-run] Vagrant provisioning would run here."
    }
    default {
        throw "Unsupported provider: $provider"
    }
}

$report | ConvertTo-Json -Depth 8 | Set-Content -Path $reportPath
Write-Host "[testlab] Provision report written to $reportPath"
