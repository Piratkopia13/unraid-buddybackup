param(
    [string]$BlueprintPath = "testlab/config/vm-blueprint.local.json",
    [switch]$RemoveSwitch,   # also removes the Hyper-V switch and NAT rule
    [switch]$Execute         # dry-run by default — must pass -Execute to actually delete anything
)

$ErrorActionPreference = "Stop"

function Get-Json {
    param([string]$Path)
    return Get-Content -Raw -Path $Path | ConvertFrom-Json
}

function Assert-Admin {
    $id = [Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()
    if (-not $id.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
        throw "Hyper-V teardown requires Administrator. Re-run as Administrator."
    }
}

if (-not (Test-Path $BlueprintPath)) {
    throw "Missing blueprint: $BlueprintPath"
}

$blueprint = Get-Json -Path $BlueprintPath

if ($Execute) { Assert-Admin }

$switchName = if ($blueprint.hyperv.switchName) { $blueprint.hyperv.switchName } else { "BuddyBackup-TestLab" }
$natName    = if ($blueprint.hyperv.natName)    { $blueprint.hyperv.natName }    else { "BuddyBackupTestLabNAT" }
$vhdRoot    = if ($blueprint.hyperv.vhdRoot)    { $blueprint.hyperv.vhdRoot }    else { "C:\VMs\BuddyBackup" }

foreach ($nodeName in @("sender", "receiver")) {
    $node   = $blueprint.$nodeName
    if (-not $node) { continue }
    $vmName = $node.name

    # Stop VM
    if ($Execute) {
        $vm = Get-VM -Name $vmName -ErrorAction SilentlyContinue
        if ($vm) {
            if ($vm.State -ne "Off") {
                Write-Host "[testlab] Stopping VM: $vmName"
                Stop-VM -Name $vmName -TurnOff -Force
            }
            Write-Host "[testlab] Removing VM: $vmName"
            Remove-VM -Name $vmName -Force
        } else {
            Write-Host "[testlab] VM not found, skipping: $vmName"
        }
    } else {
        Write-Host "[dry-run] Would stop and remove VM: $vmName"
    }

    # Delete VHDs
    foreach ($suffix in @("-boot.vhdx", "-data.vhdx")) {
        $vhdPath = Join-Path $vhdRoot "${vmName}${suffix}"
        if ($Execute) {
            if (Test-Path $vhdPath) {
                Remove-Item -Path $vhdPath -Force
                Write-Host "[testlab] Deleted: $vhdPath"
            }
        } else {
            Write-Host "[dry-run] Would delete: $vhdPath"
        }
    }
}

# Optionally remove the switch and NAT
if ($RemoveSwitch) {
    if ($Execute) {
        if (Get-NetNat -Name $natName -ErrorAction SilentlyContinue) {
            Remove-NetNat -Name $natName -Confirm:$false
            Write-Host "[testlab] Removed NAT: $natName"
        }
        if (Get-VMSwitch -Name $switchName -ErrorAction SilentlyContinue) {
            Remove-VMSwitch -Name $switchName -Force
            Write-Host "[testlab] Removed switch: $switchName"
        }
    } else {
        Write-Host "[dry-run] Would remove NAT '$natName' and switch '$switchName'"
    }
} else {
    Write-Host "[testlab] Switch and NAT left in place (pass -RemoveSwitch to also remove them)."
}

if (-not $Execute) {
    Write-Host ""
    Write-Host "Dry-run complete. Pass -Execute to actually destroy VMs and disks."
}
