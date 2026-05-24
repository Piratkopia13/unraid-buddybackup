param(
    [string]$LabConfig = "testlab/config/lab.local.json",
    [switch]$Execute
)

$ErrorActionPreference = "Stop"

. (Join-Path $PSScriptRoot "testlab-logging.ps1")

function Resolve-WorkspacePath {
    param([string]$Path)

    if ([string]::IsNullOrWhiteSpace($Path)) {
        return $Path
    }

    if ($Path.StartsWith("~/")) {
        return Join-Path -Path $HOME -ChildPath $Path.Substring(2)
    }

    if ([System.IO.Path]::IsPathRooted($Path)) {
        return [System.IO.Path]::GetFullPath($Path)
    }

    $workspaceRoot = [System.IO.Path]::GetFullPath((Join-Path $PSScriptRoot "..\.."))
    return [System.IO.Path]::GetFullPath((Join-Path $workspaceRoot $Path))
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

$resolvedLabConfig = Resolve-WorkspacePath -Path $LabConfig
if (-not (Test-Path -LiteralPath $resolvedLabConfig)) {
    throw "Missing lab config: $resolvedLabConfig"
}

$lab = Get-Content -Raw -Path $resolvedLabConfig | ConvertFrom-Json
$provider = $lab.provider

if (-not $provider) {
    throw "lab.provider is required"
}

function Ensure-Dir {
    param([string]$Path)
    if (-not (Test-Path $Path)) {
        New-Item -ItemType Directory -Path $Path | Out-Null
    }
}

function Protect-LocalSshIdentityFile {
    param([string]$Path)

    if ([string]::IsNullOrWhiteSpace($Path) -or $env:OS -ne 'Windows_NT' -or -not (Test-Path -LiteralPath $Path)) {
        return
    }

    $currentUser = [System.Security.Principal.WindowsIdentity]::GetCurrent().Name
    & icacls $Path /inheritance:r /grant:r "${currentUser}:(F)" | Out-Null
}

function Get-LocalSshIdentityFile {
    param([string]$IdentityFile)

    if ([string]::IsNullOrWhiteSpace($IdentityFile)) {
        return $IdentityFile
    }

    $resolvedPath = Resolve-WorkspacePath -Path $IdentityFile

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
    Protect-LocalSshIdentityFile -Path $cachedPath

    return $cachedPath
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
        [int]$Attempts = 5,
        [int]$RetryDelayMilliseconds = 2000,
        [switch]$DoExecute
    )

    $resolvedIdentity = Get-LocalSshIdentityFile -IdentityFile $IdentityFile
    $cmd = "echo probe-ok; uname -a"

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
    $sshArgs += @("$User@$TargetHost", $cmd)

    if ($DoExecute) {
        $attemptCount = [Math]::Max($Attempts, 1)
        $attemptOutputs = @()
        $output = ""
        $exitCode = 255
        for ($attempt = 1; $attempt -le $attemptCount; $attempt++) {
            $previousErrorActionPreference = $ErrorActionPreference
            try {
                $ErrorActionPreference = "Continue"
                $rawOutput = & ssh @sshArgs 2>&1
                $exitCode = $LASTEXITCODE
            } catch {
                $rawOutput = @($_.Exception.Message)
                $exitCode = if ($LASTEXITCODE) { $LASTEXITCODE } else { 255 }
            } finally {
                $ErrorActionPreference = $previousErrorActionPreference
            }

            $output = (@($rawOutput | ForEach-Object { [string]$_ }) -join [Environment]::NewLine).Trim()
            if ($attemptCount -gt 1) {
                if ([string]::IsNullOrWhiteSpace($output)) {
                    $attemptOutputs += "attempt=$attempt exit=$exitCode"
                } else {
                    $attemptOutputs += "attempt=$attempt exit=$exitCode`n$output"
                }
            }

            if ($exitCode -eq 0) {
                break
            }

            if ($attempt -lt $attemptCount) {
                Start-Sleep -Milliseconds $RetryDelayMilliseconds
            }
        }

        if ($attemptCount -gt 1 -and $exitCode -ne 0) {
            $output = ($attemptOutputs -join [Environment]::NewLine)
        }

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

function Test-ReachableProvisionNodes {
    param(
        $Lab,
        [switch]$DoExecute
    )

    $checks = @()
    foreach ($nodeName in @('sender', 'receiver')) {
        $connection = Get-NodeConnection -Lab $Lab -NodeName $nodeName
        try {
            $probe = Invoke-NodeProbe -User $connection.User -TargetHost $connection.Host -Port $connection.Port -IdentityFile $connection.IdentityFile -DoExecute:$DoExecute
        } catch {
            $probe = [pscustomobject]@{
                success = $false
                exitCode = if ($LASTEXITCODE) { $LASTEXITCODE } else { 255 }
                output = $_.Exception.Message
            }
        }
        $checks += [pscustomobject]@{
            node = $nodeName
            host = $connection.Host
            port = $connection.Port
            success = $probe.success
            exitCode = $probe.exitCode
            output = $probe.output
        }
    }

    return $checks
}

$safeWorkingDirectory = Get-SafeHostWorkingDirectory
Push-Location $safeWorkingDirectory
try {
    Write-Host "[testlab] Provider: $provider"

    $runId = Get-Date -Format "yyyyMMdd-HHmmss"
    $logsRoot = $lab.logsRoot
    if (-not $logsRoot) {
        $logsRoot = ".testlab/logs"
    }
    $logsRoot = Resolve-WorkspacePath -Path ([string]$logsRoot)
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
            & $providerScript -LabConfig $resolvedLabConfig -Execute:$Execute
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
            & $providerScript -LabConfig $resolvedLabConfig -Execute:$Execute
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

    if ($provider -in @('windows-local', 'windows-wsl-qemu', 'manual')) {
        $report.nodeChecks = @(Test-ReachableProvisionNodes -Lab $lab -DoExecute:$Execute)
        $failedChecks = @($report.nodeChecks | Where-Object { -not $_.success })
        foreach ($check in $report.nodeChecks) {
            if ($check.success) {
                Write-Host "[testlab] Node $($check.node) ($($check.host):$($check.port)) reachable"
            } else {
                Write-Warning "Node $($check.node) ($($check.host):$($check.port)) probe failed"
            }
        }

        if ($failedChecks.Count -gt 0) {
            $report | ConvertTo-Json -Depth 8 | Set-Content -Path $reportPath
            $labels = @($failedChecks | ForEach-Object { "$($_.node)@$($_.host):$($_.port) exit=$($_.exitCode)" }) -join '; '
            throw "Provisioned nodes did not remain reachable after provider setup: $labels"
        }
    }

    $report | ConvertTo-Json -Depth 8 | Set-Content -Path $reportPath
    Write-Host "[testlab] Provision report written to $reportPath"
} finally {
    Pop-Location
}
