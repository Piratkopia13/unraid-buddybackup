param(
    [string]$RepoRoot = (Resolve-Path ".").Path
)

$ErrorActionPreference = "Stop"

. (Join-Path $PSScriptRoot "testlab-logging.ps1")

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
    # ssh-keygen cannot write directly to UNC paths on Windows; generate to a local temp dir
    # and then copy the two files to the UNC destination.
    # Windows PowerShell drops true empty-string args for native commands, so pass
    # a quoted empty string literal that ssh-keygen still interprets as empty.
    $tmpDir = Join-Path $env:TEMP "buddybackup-testlab-key-$(New-Guid)"
    New-Item -ItemType Directory -Path $tmpDir -Force | Out-Null
    $tmpKey = Join-Path $tmpDir "lab_key"
    & ssh-keygen -t ed25519 -C "buddybackup-testlab" -f $tmpKey -N '""'
    if ($LASTEXITCODE -eq 0 -and (Test-Path $tmpKey)) {
        Copy-Item -Path $tmpKey          -Destination $labKeyPath    -Force
        Copy-Item -Path "${tmpKey}.pub"  -Destination $labKeyPubPath -Force
        Remove-Item -Path $tmpDir -Recurse -Force -ErrorAction SilentlyContinue
        Write-Host "[testlab] Lab keypair ready:"
        Write-Host "  Private: $labKeyPath"
        Write-Host "  Public : $labKeyPubPath"
    } else {
        Remove-Item -Path $tmpDir -Recurse -Force -ErrorAction SilentlyContinue
        Write-Host "[testlab] WARNING: ssh-keygen failed. Generate a key manually:"
        Write-Host "  ssh-keygen -t ed25519 -C buddybackup-testlab -f `"$labKeyPath`""
    }
} else {
    Write-Host "[testlab] Lab keypair already exists: $labKeyPath"
}

Write-Host "[testlab] Host bootstrap complete."
