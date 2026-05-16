param(
    [string]$RepoRoot = (Resolve-Path ".").Path
)

$ErrorActionPreference = "Stop"

function Assert-Command {
    param([string]$Name)
    if (-not (Get-Command $Name -ErrorAction SilentlyContinue)) {
        throw "Required command not found: $Name"
    }
}

Write-Host "[testlab] Bootstrapping host prerequisites..."

Assert-Command "git"
Assert-Command "ssh"
Assert-Command "scp"

$labRoot = Join-Path -Path $RepoRoot -ChildPath ".testlab"

$paths = @(
    $labRoot,
    (Join-Path -Path $labRoot -ChildPath "artifacts"),
    (Join-Path -Path $labRoot -ChildPath "logs"),
    (Join-Path -Path $labRoot -ChildPath "cache")
)

foreach ($p in $paths) {
    if (-not (Test-Path $p)) {
        New-Item -ItemType Directory -Path $p | Out-Null
        Write-Host "[testlab] Created $p"
    }
}


# Generate a lab-specific SSH keypair so provisioning can inject it into Unraid VMs
$labKeyPath = Join-Path -Path $labRoot -ChildPath "lab_key"
$labKeyPubPath = "${labKeyPath}.pub"

if (-not (Test-Path $labKeyPath)) {
    Write-Host "[testlab] Generating lab SSH keypair at $labKeyPath..."
    Assert-Command "ssh-keygen"
    # On Windows, ssh-keygen needs the empty passphrase piped via stdin; -N """" is unreliable
    $tmpIn = [System.IO.Path]::GetTempFileName()
    "" | Set-Content -Path $tmpIn -Encoding ASCII
    & ssh-keygen -t ed25519 -C "buddybackup-testlab" -f $labKeyPath -q -N """"
    Remove-Item $tmpIn -Force -ErrorAction SilentlyContinue
    if ($LASTEXITCODE -ne 0) {
        Write-Host "[testlab] WARNING: ssh-keygen failed. Generate a key manually:"
        Write-Host "  ssh-keygen -t ed25519 -C buddybackup-testlab -f $labKeyPath"
    } else {
        Write-Host "[testlab] Lab keypair ready:"
        Write-Host "  Private: $labKeyPath"
        Write-Host "  Public : $labKeyPubPath"
    }
} else {
    Write-Host "[testlab] Lab keypair already exists: $labKeyPath"
}

Write-Host "[testlab] Host bootstrap complete."
