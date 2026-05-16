param(
    [string]$LabConfig = "testlab/config/lab.local.json",
    [switch]$Execute
)

$ErrorActionPreference = "Stop"

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
    nodeChecks = @()
}

switch ($provider) {
    "manual" {
        Write-Host "[testlab] Manual provider selected. Validating configured nodes."

        foreach ($nodeName in @("sender", "receiver")) {
            $node = $lab.nodes.$nodeName
            if (-not $node -or -not $node.host) {
                throw "Missing lab.nodes.$nodeName.host"
            }

            $probe = Invoke-NodeProbe -User $lab.ssh.user -TargetHost $node.host -Port $lab.ssh.port -IdentityFile $lab.ssh.identityFile -DoExecute:$Execute
            $report.nodeChecks += [pscustomobject]@{
                node = $nodeName
                host = $node.host
                success = $probe.success
                exitCode = $probe.exitCode
                output = $probe.output
            }

            if ($probe.success) {
                Write-Host "[testlab] Node $nodeName ($($node.host)) reachable"
            } else {
                Write-Host "[testlab] Node $nodeName ($($node.host)) probe failed"
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
