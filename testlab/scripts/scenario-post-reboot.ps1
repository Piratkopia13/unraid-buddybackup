param(
    [string]$TargetHost,
    [string]$User = "root",
    [int]$Port = 22,
    [string]$IdentityFile = "~/.ssh/id_ed25519",
    [int]$SshReadySeconds = 300,
    [switch]$Execute
)

$ErrorActionPreference = "Stop"

if (-not $TargetHost) { throw "TargetHost is required" }

function Test-SshReady {
    param(
        [string]$TargetHost,
        [string]$User,
        [int]$Port,
        [string]$IdentityFile,
        [int]$TimeoutSeconds
    )

    $started = Get-Date
    while ((New-TimeSpan -Start $started -End (Get-Date)).TotalSeconds -lt $TimeoutSeconds) {
        & ssh -o BatchMode=yes -o ConnectTimeout=5 -p $Port -i $IdentityFile "$User@$TargetHost" "echo ok" 2>$null
        if ($LASTEXITCODE -eq 0) {
            return $true
        }
        Start-Sleep -Seconds 5
    }

    return $false
}

if ($Execute) {
    & ssh -p $Port -i $IdentityFile "$User@$TargetHost" "reboot"
    if (-not (Test-SshReady -TargetHost $TargetHost -User $User -Port $Port -IdentityFile $IdentityFile -TimeoutSeconds $SshReadySeconds)) {
        throw "Host did not return after reboot in $SshReadySeconds seconds: $TargetHost"
    }
    & ssh -p $Port -i $IdentityFile "$User@$TargetHost" "plugin list | grep buddybackup"
} else {
    Write-Host "[dry-run] ssh -p $Port -i $IdentityFile $User@$TargetHost reboot"
    Write-Host "[dry-run] wait for SSH and validate plugin presence"
}
