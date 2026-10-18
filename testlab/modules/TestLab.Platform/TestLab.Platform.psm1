# TestLab.Platform Module
# Platform-level integration: WSL bash execution, QEMU VM management, and loopback network handling.

$moduleRoot = $PSScriptRoot

# Import TestLab.Core if not already loaded in the session
if (-not (Get-Module -Name "TestLab.Core")) {
    $corePsm1 = Join-Path $moduleRoot "..\TestLab.Core\TestLab.Core.psm1"
    if (Test-Path -LiteralPath $corePsm1) {
        Import-Module (Resolve-Path -LiteralPath $corePsm1).ProviderPath -DisableNameChecking
    }
}

. (Join-Path $moduleRoot "WslProvider.ps1")
. (Join-Path $moduleRoot "NetworkManager.ps1")
. (Join-Path $moduleRoot "QemuVmManager.ps1")

Export-ModuleMember -Function *
