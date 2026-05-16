param(
    [string]$TargetHost,
    [string]$Version,
    [string]$User = "root",
    [int]$Port = 22,
    [string]$IdentityFile = "~/.ssh/id_ed25519",
    [switch]$Execute
)

$ErrorActionPreference = "Stop"

if (-not $TargetHost) { throw "TargetHost is required" }
if (-not $Version) { throw "Version is required" }

$url = "https://github.com/Piratkopia13/unraid-buddybackup/releases/download/$Version/buddybackup.plg"
$cmd = "plugin install $url"

if ($Execute) {
    & ssh -p $Port -i $IdentityFile "$User@$TargetHost" $cmd
} else {
    Write-Host "[dry-run] ssh -p $Port -i $IdentityFile $User@$TargetHost '$cmd'"
}
