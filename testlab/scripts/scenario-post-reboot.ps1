param(
    [string]$TargetHost,
    [string]$User = "root",
    [int]$Port = 22,
    [string]$IdentityFile = "~/.ssh/id_ed25519",
    [int]$SshReadySeconds = 300,
    [switch]$Execute
)

$ErrorActionPreference = "Stop"
if (Test-Path Variable:\PSNativeCommandUseErrorActionPreference) {
    $PSNativeCommandUseErrorActionPreference = $false
}

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

function Ensure-Dir {
    param([string]$Path)
    if (-not (Test-Path $Path)) {
        New-Item -ItemType Directory -Path $Path | Out-Null
    }
}

function Get-LocalSshIdentityFile {
    param([string]$IdentityFile)

    if ([string]::IsNullOrWhiteSpace($IdentityFile)) {
        return $IdentityFile
    }

    $resolvedPath = Resolve-TestLabPath $IdentityFile
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

    if ($env:OS -eq 'Windows_NT') {
        $currentUser = [System.Security.Principal.WindowsIdentity]::GetCurrent().Name
        & icacls $cachedPath /inheritance:r /grant:r "${currentUser}:(F)" | Out-Null
    }

    return $cachedPath
}

if (-not $TargetHost) { throw "TargetHost is required" }

$resolvedIdentityFile = Get-LocalSshIdentityFile $IdentityFile
$labSshOpts = @(
    "-o", "BatchMode=yes",
    "-o", "ConnectTimeout=5",
    "-o", "ServerAliveInterval=15",
    "-o", "ServerAliveCountMax=4",
    "-o", "StrictHostKeyChecking=no",
    "-o", "UserKnownHostsFile=/dev/null",
    "-o", "GlobalKnownHostsFile=/dev/null",
    "-o", "LogLevel=ERROR"
)

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
        $prevEA = $ErrorActionPreference
        try {
            $ErrorActionPreference = "SilentlyContinue"
            & ssh @labSshOpts -p $Port -i $IdentityFile "$User@$TargetHost" "echo ok" 2>&1 | Out-Null
            if ($LASTEXITCODE -eq 0) {
                $elapsedSeconds = [int](New-TimeSpan -Start $started -End (Get-Date)).TotalSeconds
                Write-Host "[testlab] SSH is back on $targetLabel after ${elapsedSeconds}s"
                return $true
            }
        } finally {
            $ErrorActionPreference = $prevEA
        }

        $lastHeartbeatAt = Write-TestLabHeartbeat -Message "Still waiting for SSH on $targetLabel" -StartedAt $started -LastHeartbeatAt $lastHeartbeatAt -IntervalSeconds 15 -TimeoutSeconds $TimeoutSeconds
        Start-Sleep -Seconds 5
    }

    Write-Warning "SSH did not return on $targetLabel within $TimeoutSeconds seconds"
    return $false
}

function Wait-SshUnavailable {
    param(
        [string]$TargetHost,
        [string]$User,
        [int]$Port,
        [string]$IdentityFile,
        [int]$TimeoutSeconds = 45
    )

    $started = Get-Date
    while ((New-TimeSpan -Start $started -End (Get-Date)).TotalSeconds -lt $TimeoutSeconds) {
        $prevEA = $ErrorActionPreference
        try {
            $ErrorActionPreference = "SilentlyContinue"
            & ssh @labSshOpts -p $Port -i $IdentityFile "$User@$TargetHost" "echo ok" 2>&1 | Out-Null
            if ($LASTEXITCODE -ne 0) {
                return $true
            }
        } finally {
            $ErrorActionPreference = $prevEA
        }
        Start-Sleep -Seconds 1
    }
    return $false
}

function Wait-PluginReady {
    param(
        [string]$TargetHost,
        [string]$User,
        [int]$Port,
        [string]$IdentityFile,
        [int]$TimeoutSeconds = 120
    )

    $started = Get-Date
    while ((New-TimeSpan -Start $started -End (Get-Date)).TotalSeconds -lt $TimeoutSeconds) {
        $prevEA = $ErrorActionPreference
        try {
            $ErrorActionPreference = "SilentlyContinue"
            & ssh @labSshOpts -p $Port -i $IdentityFile "$User@$TargetHost" "plugin list 2>/dev/null | grep -i buddybackup >/dev/null 2>&1 || [ -f /usr/local/emhttp/plugins/buddybackup/scripts/rc.buddybackup.php ]" 2>&1 | Out-Null
            if ($LASTEXITCODE -eq 0) {
                return $true
            }
        } finally {
            $ErrorActionPreference = $prevEA
        }
        Start-Sleep -Seconds 3
    }
    return $false
}

if ($Execute) {
    Write-Host ("[testlab] Requesting reboot on {0}:{1}" -f $TargetHost, $Port)
    & ssh @labSshOpts -p $Port -i $resolvedIdentityFile "$User@$TargetHost" "(sleep 1 && reboot) >/dev/null 2>&1 & exit 0"
    if ($LASTEXITCODE -ne 0) {
        & ssh @labSshOpts -p $Port -i $resolvedIdentityFile "$User@$TargetHost" "reboot" 2>$null
    }

    Write-Host ("[testlab] Waiting for SSH to disconnect on {0}:{1}" -f $TargetHost, $Port)
    Start-Sleep -Seconds 2
    Wait-SshUnavailable -TargetHost $TargetHost -User $User -Port $Port -IdentityFile $resolvedIdentityFile -TimeoutSeconds 45 | Out-Null

    if (-not (Test-SshReady -TargetHost $TargetHost -User $User -Port $Port -IdentityFile $resolvedIdentityFile -TimeoutSeconds $SshReadySeconds)) {
        throw "Host did not return after reboot in $SshReadySeconds seconds: $TargetHost"
    }

    Write-Host ("[testlab] Waiting for BuddyBackup to initialize after reboot on {0}:{1}" -f $TargetHost, $Port)
    if (-not (Wait-PluginReady -TargetHost $TargetHost -User $User -Port $Port -IdentityFile $resolvedIdentityFile -TimeoutSeconds 120)) {
        throw ("BuddyBackup was not detected after reboot on {0}:{1}" -f $TargetHost, $Port)
    }

    # Validate receiver user integrity if configured
    & ssh @labSshOpts -p $Port -i $resolvedIdentityFile "$User@$TargetHost" "if id buddybackup >/dev/null 2>&1; then getent passwd buddybackup | grep -q ':/home/buddybackup:/bin/bash' && getent group buddybackup >/dev/null 2>&1; fi"
    if ($LASTEXITCODE -ne 0) {
        throw ("BuddyBackup receiver user has invalid home, shell, or missing group after reboot on {0}:{1}" -f $TargetHost, $Port)
    }

    # If receiver authorized_keys and local sender key exist, perform receiver public-key echo test
    $remoteSshCheck = @'
if [ -s /home/buddybackup/.ssh/authorized_keys ] && [ -f /boot/config/plugins/buddybackup/buddybackup_sender_key ]; then
    target_ip=$(hostname -I 2>/dev/null | awk '{print $1}')
    target_ip=${target_ip:-127.0.0.1}
    ssh -o BatchMode=yes -o StrictHostKeyChecking=no -o ConnectTimeout=5 -o ServerAliveInterval=10 -o ServerAliveCountMax=3 -i /boot/config/plugins/buddybackup/buddybackup_sender_key buddybackup@${target_ip} "echo ok" >/dev/null 2>&1
fi
'@
    & ssh @labSshOpts -p $Port -i $resolvedIdentityFile "$User@$TargetHost" $remoteSshCheck
    if ($LASTEXITCODE -ne 0) {
        throw ("BuddyBackup receiver SSH public-key echo test failed after reboot on {0}:{1}" -f $TargetHost, $Port)
    }

    Write-Host ("[testlab] BuddyBackup validated after reboot on {0}:{1}" -f $TargetHost, $Port)
} else {
    Write-Host "[dry-run] ssh -p $Port -i $resolvedIdentityFile $User@$TargetHost reboot"
    Write-Host "[dry-run] wait for SSH, validate plugin presence, and test receiver user integrity & SSH access"
}
