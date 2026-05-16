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

Write-Host "[testlab] Host bootstrap complete."
