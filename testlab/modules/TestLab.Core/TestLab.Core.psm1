# TestLab.Core Module
# Foundation module for BuddyBackup testlab: SMB-safe file I/O, logging, and configuration management.

$moduleRoot = $PSScriptRoot

. (Join-Path $moduleRoot "FileSystem.ps1")
. (Join-Path $moduleRoot "Logging.ps1")
. (Join-Path $moduleRoot "Config.ps1")

Export-ModuleMember -Function * -Alias *
