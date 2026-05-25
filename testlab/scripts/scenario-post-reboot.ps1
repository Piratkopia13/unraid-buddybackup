param(
    [string]$TargetHost,
    [string]$User = "root",
    [int]$Port = 22,
    [string]$IdentityFile = "~/.ssh/id_ed25519",
    [int]$SshReadySeconds = 300,
    [switch]$Execute
)

$ErrorActionPreference = "Stop"

. (Join-Path $PSScriptRoot "testlab-logging.ps1")

function Resolve-TestLabPath {
    param([string]$Path)

    if ([string]::IsNullOrWhiteSpace($Path)) {
        return $Path
    }

    if ($Path.StartsWith('~/') -or $Path.StartsWith('~\')) {
        return Join-Path -Path $HOME -ChildPath $Path.Substring(2)
    }

    if ([System.IO.Path]::IsPathRooted($Path)) {
        return [System.IO.Path]::GetFullPath($Path)
    }

    $workspaceRoot = [System.IO.Path]::GetFullPath((Join-Path $PSScriptRoot "..\.."))
    return [System.IO.Path]::GetFullPath((Join-Path $workspaceRoot $Path))
}

if (-not $TargetHost) { throw "TargetHost is required" }

$resolvedIdentityFile = Resolve-TestLabPath $IdentityFile

function Test-SshReady {
    param(
        [string]$TargetHost,
        [string]$User,
        [int]$Port,
        [string]$IdentityFile,
        [int]$TimeoutSeconds
    )

    $started = Get-Date
    $targetLabel = "{0}:{1}" -f $TargetHost, $Port
    Write-Host "[testlab] Waiting for SSH to return on $targetLabel after reboot"
    $lastHeartbeatAt = $started
    while ((New-TimeSpan -Start $started -End (Get-Date)).TotalSeconds -lt $TimeoutSeconds) {
        & ssh -o BatchMode=yes -o ConnectTimeout=5 -p $Port -i $IdentityFile "$User@$TargetHost" "echo ok" 2>$null
        if ($LASTEXITCODE -eq 0) {
            $elapsedSeconds = [int](New-TimeSpan -Start $started -End (Get-Date)).TotalSeconds
            Write-Host "[testlab] SSH is back on $targetLabel after ${elapsedSeconds}s"
            return $true
        }

        $lastHeartbeatAt = Write-TestLabHeartbeat -Message "Still waiting for SSH on $targetLabel" -StartedAt $started -LastHeartbeatAt $lastHeartbeatAt -IntervalSeconds 15 -TimeoutSeconds $TimeoutSeconds
        Start-Sleep -Seconds 5
    }

    Write-Warning "SSH did not return on $targetLabel within $TimeoutSeconds seconds"
    return $false
}

if ($Execute) {
    Write-Host ("[testlab] Requesting reboot on {0}:{1}" -f $TargetHost, $Port)
    & ssh -p $Port -i $resolvedIdentityFile "$User@$TargetHost" "reboot"
    if ($LASTEXITCODE -ne 0) {
        throw ("Failed to request reboot on {0}:{1}" -f $TargetHost, $Port)
    }
    if (-not (Test-SshReady -TargetHost $TargetHost -User $User -Port $Port -IdentityFile $resolvedIdentityFile -TimeoutSeconds $SshReadySeconds)) {
        throw "Host did not return after reboot in $SshReadySeconds seconds: $TargetHost"
    }
    Write-Host ("[testlab] Validating BuddyBackup after reboot on {0}:{1}" -f $TargetHost, $Port)
    & ssh -p $Port -i $resolvedIdentityFile "$User@$TargetHost" "plugin list | grep buddybackup"
    if ($LASTEXITCODE -ne 0) {
        throw ("BuddyBackup was not detected after reboot on {0}:{1}" -f $TargetHost, $Port)
    }
    Write-Host ("[testlab] BuddyBackup validated after reboot on {0}:{1}" -f $TargetHost, $Port)
} else {
    Write-Host "[dry-run] ssh -p $Port -i $resolvedIdentityFile $User@$TargetHost reboot"
    Write-Host "[dry-run] wait for SSH and validate plugin presence"
}
