param(
    [string]$LabConfig = "testlab/config/lab.local.json",
    [switch]$Execute
)

$ErrorActionPreference = "Stop"

if (-not (Test-Path $LabConfig)) {
    throw "Missing lab config: $LabConfig"
}

$lab = Get-Content -Raw -Path $LabConfig | ConvertFrom-Json
$provider = $lab.provider

if (-not $provider) {
    throw "lab.provider is required"
}

Write-Host "[testlab] Provider: $provider"

switch ($provider) {
    "manual" {
        Write-Host "[testlab] Manual provider selected."
        Write-Host "[testlab] Ensure sender and receiver hosts are reachable and match lab config."
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
