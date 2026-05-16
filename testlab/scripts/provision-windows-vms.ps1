param(
    [string]$BlueprintPath = "testlab/config/vm-blueprint.local.json",
    [switch]$Execute
)

$ErrorActionPreference = "Stop"

function Require-File {
    param([string]$Path)
    if (-not (Test-Path $Path)) {
        throw "Missing file: $Path"
    }
}

function Ensure-Dir {
    param([string]$Path)
    if (-not (Test-Path $Path)) {
        New-Item -ItemType Directory -Path $Path | Out-Null
    }
}

function Get-Json {
    param([string]$Path)
    return Get-Content -Raw -Path $Path | ConvertFrom-Json
}

function Resolve-Backend {
    param([string]$Backend)

    if ($Backend -and $Backend -ne "auto") {
        return $Backend
    }

    if (Get-Command Get-VM -ErrorAction SilentlyContinue) {
        return "hyperv"
    }

    if (Get-Command VBoxManage -ErrorAction SilentlyContinue) {
        return "virtualbox"
    }

    return "none"
}

function New-VmPlan {
    param(
        [string]$Backend,
        $Blueprint
    )

    $plan = [ordered]@{
        provider = "windows-local"
        backend = $Backend
        sender = $Blueprint.sender
        receiver = $Blueprint.receiver
        actions = @(
            "create-vm",
            "attach-disk",
            "configure-network",
            "install-unraid",
            "install-plugin",
            "seed-datasets",
            "run-lifecycle-tests"
        )
    }

    return [pscustomobject]$plan
}

Require-File $BlueprintPath

$blueprint = Get-Json -Path $BlueprintPath
$backend = Resolve-Backend -Backend $blueprint.backend

$runId = Get-Date -Format "yyyyMMdd-HHmmss"
$logsRoot = ".testlab/logs"
Ensure-Dir -Path $logsRoot
$reportPath = Join-Path -Path $logsRoot -ChildPath ("vm-provision-{0}.json" -f $runId)

if ($backend -eq "none") {
    Write-Host "[testlab] No local VM backend detected. Writing plan only."
}

$report = [pscustomobject]@{
    runId = $runId
    provider = $blueprint.provider
    backend = $backend
    executeMode = [bool]$Execute
    blueprintPath = $BlueprintPath
    plan = New-VmPlan -Backend $backend -Blueprint $blueprint
    status = if ($backend -eq "none" -and $Execute) { "blocked" } elseif ($Execute) { "planned" } else { "dry-run" }
}

if ($Execute) {
    switch ($backend) {
        "hyperv" {
            Write-Host "[testlab] Hyper-V detected. VM creation is scaffolded but not executed in this checkpoint."
        }
        "virtualbox" {
            Write-Host "[testlab] VirtualBox detected. VM creation is scaffolded but not executed in this checkpoint."
        }
        default {
            Write-Host "[testlab] No backend detected; nothing to execute."
        }
    }
}

$report | ConvertTo-Json -Depth 8 | Set-Content -Path $reportPath
Write-Host "[testlab] VM provisioning plan written to $reportPath"
