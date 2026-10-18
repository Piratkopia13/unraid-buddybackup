# TestLab.Guest Module
# Layer 3: Guest & Domain Management for BuddyBackup TestLab

$moduleRoot = $PSScriptRoot

# Import required parent modules if not already loaded in the session
if (-not (Get-Module -Name "TestLab.Core")) {
    $corePsm1 = Join-Path $moduleRoot "..\TestLab.Core\TestLab.Core.psm1"
    if (Test-Path -LiteralPath $corePsm1) {
        Import-Module (Resolve-Path -LiteralPath $corePsm1).ProviderPath -DisableNameChecking
    }
}

if (-not (Get-Module -Name "TestLab.Platform")) {
    $platformPsm1 = Join-Path $moduleRoot "..\TestLab.Platform\TestLab.Platform.psm1"
    if (Test-Path -LiteralPath $platformPsm1) {
        Import-Module (Resolve-Path -LiteralPath $platformPsm1).ProviderPath -DisableNameChecking
    }
}

if (-not (Get-Module -Name "TestLab.Transport")) {
    $transportPsm1 = Join-Path $moduleRoot "..\TestLab.Transport\TestLab.Transport.psm1"
    if (Test-Path -LiteralPath $transportPsm1) {
        Import-Module (Resolve-Path -LiteralPath $transportPsm1).ProviderPath -DisableNameChecking
    }
}

. (Join-Path $moduleRoot "UnraidLifecycle.ps1")
. (Join-Path $moduleRoot "PluginManager.ps1")
. (Join-Path $moduleRoot "ZfsManager.ps1")
. (Join-Path $moduleRoot "UpgradeStateManager.ps1")

Export-ModuleMember -Function * -Alias *
