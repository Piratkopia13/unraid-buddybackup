param(
    [string]$TargetHost,
    [string]$Version,
    [string]$User = "root",
    [int]$Port = 22,
    [string]$IdentityFile = "~/.ssh/id_ed25519",
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
if (-not $Version) { throw "Version is required" }

$resolvedIdentityFile = Resolve-TestLabPath $IdentityFile

$url = "https://github.com/Piratkopia13/unraid-buddybackup/releases/download/$Version/buddybackup.plg"
$cmd = "plugin install $url"

if ($Execute) {
    Write-Host ("[testlab] Installing BuddyBackup {0} on {1}:{2}" -f $Version, $TargetHost, $Port)
    & ssh -p $Port -i $resolvedIdentityFile "$User@$TargetHost" $cmd
    if ($LASTEXITCODE -ne 0) {
        throw ("BuddyBackup install failed on {0}:{1}" -f $TargetHost, $Port)
    }
    Write-Host ("[testlab] BuddyBackup {0} installed on {1}:{2}" -f $Version, $TargetHost, $Port)
} else {
    Write-Host "[dry-run] ssh -p $Port -i $resolvedIdentityFile $User@$TargetHost '$cmd'"
}
