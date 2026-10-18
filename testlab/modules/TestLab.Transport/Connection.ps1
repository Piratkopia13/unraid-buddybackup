<#
.SYNOPSIS
    Connection resolution and SSH/SCP argument formatting for TestLab nodes.
.DESCRIPTION
    Provides canonical helpers for resolving SSH identity files, node connections,
    and generating command line arguments for ssh and scp invocations.
#>

function Resolve-IdentityPath {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $false, Position = 0)]
        [Alias('IdentityFile')]
        [string]$IdentityPath,

        [Parameter(Mandatory = $false, Position = 1)]
        [string]$WorkspaceRoot = $null
    )

    if ([string]::IsNullOrWhiteSpace($IdentityPath)) {
        return $IdentityPath
    }

    if ($IdentityPath.StartsWith("~/") -or $IdentityPath.StartsWith("~\")) {
        return Join-Path -Path $HOME -ChildPath $IdentityPath.Substring(2)
    }

    if ([System.IO.Path]::IsPathRooted($IdentityPath)) {
        return [System.IO.Path]::GetFullPath($IdentityPath)
    }

    if ([string]::IsNullOrWhiteSpace($WorkspaceRoot)) {
        $WorkspaceRoot = [System.IO.Path]::GetFullPath((Join-Path $PSScriptRoot "..\..\.."))
    }

    return [System.IO.Path]::GetFullPath((Join-Path $WorkspaceRoot $IdentityPath))
}

function Get-LocalSshIdentityFile {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $false, Position = 0)]
        [Alias('IdentityFile')]
        [string]$IdentityPath,

        [Parameter(Mandatory = $false, Position = 1)]
        [string]$WorkspaceRoot = $null
    )

    if ([string]::IsNullOrWhiteSpace($IdentityPath)) {
        return $IdentityPath
    }

    $resolvedPath = Resolve-IdentityPath -IdentityPath $IdentityPath -WorkspaceRoot $WorkspaceRoot
    if (-not (Test-Path -LiteralPath $resolvedPath)) {
        throw "SSH identity file not found: $resolvedPath"
    }

    $cacheRoot = Join-Path $env:LOCALAPPDATA "BuddyBackup\ssh-cache"
    if (-not (Test-Path -LiteralPath $cacheRoot)) {
        [System.IO.Directory]::CreateDirectory($cacheRoot) | Out-Null
    }

    $pathHashBytes = [System.Text.Encoding]::UTF8.GetBytes($resolvedPath)
    $sha256 = [System.Security.Cryptography.SHA256]::Create()
    $pathHash = [System.BitConverter]::ToString($sha256.ComputeHash($pathHashBytes)).Replace("-", "").ToLowerInvariant()
    $fileName = "{0}-{1}" -f ([System.IO.Path]::GetFileName($resolvedPath)), $pathHash.Substring(0, 12)
    $cachedPath = Join-Path $cacheRoot $fileName

    Copy-Item -LiteralPath $resolvedPath -Destination $cachedPath -Force

    if ($env:OS -eq 'Windows_NT') {
        $currentUser = [System.Security.Principal.WindowsIdentity]::GetCurrent().Name
        & icacls $cachedPath /inheritance:r /grant:r "${currentUser}:(F)" | Out-Null
    }

    return $cachedPath
}

function Get-NodeConnection {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true, Position = 0)]
        [Alias('Lab')]
        $Object,

        [Parameter(Mandatory = $true, Position = 1)]
        [string]$NodeName,

        [Parameter(Mandatory = $false)]
        $FallbackConfig = $null
    )

    $getVal = {
        param($Target, [string]$Name)
        if ($null -eq $Target -or [string]::IsNullOrWhiteSpace($Name)) { return $null }
        if ($Target -is [System.Collections.IDictionary]) {
            if ($Target.Contains($Name)) { return $Target[$Name] }
            return $null
        }
        $prop = $Target.PSObject.Properties[$Name]
        if ($prop) { return $prop.Value }
        return $null
    }

    $canonicalNodeName = switch ($NodeName) {
        "sender" { "nodeA" }
        "receiver" { "nodeB" }
        default { $NodeName }
    }
    $legacyNodeName = switch ($canonicalNodeName) {
        "nodeA" { "sender" }
        "nodeB" { "receiver" }
        default { $null }
    }

    $nodesContainer = & $getVal $Object "nodes"
    if ($null -eq $nodesContainer -and ($Object -is [System.Collections.IDictionary] -or $Object.PSObject.Properties['nodeA'] -ne $null -or $Object.PSObject.Properties['sender'] -ne $null)) {
        $nodesContainer = $Object
    }

    $node = $null
    if ($null -ne $nodesContainer) {
        $node = & $getVal $nodesContainer $canonicalNodeName
        if ($null -eq $node -and $legacyNodeName) {
            $node = & $getVal $nodesContainer $legacyNodeName
        }
    }

    if ($null -eq $node -and $null -ne $FallbackConfig) {
        $fallbackNodes = & $getVal $FallbackConfig "nodes"
        if ($null -ne $fallbackNodes) {
            $node = & $getVal $fallbackNodes $canonicalNodeName
            if ($null -eq $node -and $legacyNodeName) {
                $node = & $getVal $fallbackNodes $legacyNodeName
            }
        }
    }

    $hostVal = if ($node) { & $getVal $node "host" } else { $null }
    if ([string]::IsNullOrWhiteSpace($hostVal)) {
        throw "Missing lab.nodes.$canonicalNodeName.host"
    }

    $sshCfg = & $getVal $Object "ssh"
    if ($null -eq $sshCfg -and $null -ne $FallbackConfig) {
        $sshCfg = & $getVal $FallbackConfig "ssh"
    }

    $defaultPort = if ($sshCfg -and (& $getVal $sshCfg "port")) { [int](& $getVal $sshCfg "port") } else { 22 }
    $defaultUser = if ($sshCfg -and (& $getVal $sshCfg "user")) { [string](& $getVal $sshCfg "user") } else { "root" }
    $defaultIdentity = if ($sshCfg -and (& $getVal $sshCfg "identityFile")) { [string](& $getVal $sshCfg "identityFile") } else { $null }

    $nodeUser = if ($node) { & $getVal $node "user" } else { $null }
    $nodePort = if ($node) { & $getVal $node "port" } else { $null }
    $nodeIdentity = if ($node) { & $getVal $node "identityFile" } else { $null }

    return [pscustomobject]@{
        NodeName     = $canonicalNodeName
        User         = if (-not [string]::IsNullOrWhiteSpace($nodeUser)) { [string]$nodeUser } else { $defaultUser }
        Host         = [string]$hostVal
        Port         = if ($nodePort) { [int]$nodePort } else { $defaultPort }
        IdentityFile = if (-not [string]::IsNullOrWhiteSpace($nodeIdentity)) { [string]$nodeIdentity } else { $defaultIdentity }
    }
}

function Resolve-NodeConnection {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true, Position = 0)]
        $Node,

        [Parameter(Mandatory = $false, Position = 1)]
        $Lab = $null,

        [Parameter(Mandatory = $false)]
        [string]$WorkspaceRoot = $null
    )

    $getVal = {
        param($Target, [string]$Name)
        if ($null -eq $Target -or [string]::IsNullOrWhiteSpace($Name)) { return $null }
        if ($Target -is [System.Collections.IDictionary]) {
            if ($Target.Contains($Name)) { return $Target[$Name] }
            return $null
        }
        $prop = $Target.PSObject.Properties[$Name]
        if ($prop) { return $prop.Value }
        return $null
    }

    # Handle swapped parameter invocation like Resolve-NodeConnection -Lab $Lab -Node $Node
    if ($null -ne $Lab -and $null -eq (& $getVal $Node "host") -and $null -ne (& $getVal $Lab "host")) {
        $temp = $Node
        $Node = $Lab
        $Lab = $temp
    }

    $sshCfg = if ($Lab) { & $getVal $Lab "ssh" } else { $null }
    $defaultPort = if ($sshCfg -and (& $getVal $sshCfg "port")) { [int](& $getVal $sshCfg "port") } else { 22 }
    $defaultUser = if ($sshCfg -and (& $getVal $sshCfg "user")) { [string](& $getVal $sshCfg "user") } else { "root" }
    $defaultIdentityFile = if ($sshCfg -and (& $getVal $sshCfg "identityFile")) { [string](& $getVal $sshCfg "identityFile") } else { $null }

    $nodeUser = & $getVal $Node "user"
    if ([string]::IsNullOrWhiteSpace($nodeUser)) {
        $nodeUser = & $getVal $Node "User"
    }

    $nodeHost = & $getVal $Node "host"
    if ([string]::IsNullOrWhiteSpace($nodeHost)) {
        $nodeHost = & $getVal $Node "Host"
    }

    $nodePort = & $getVal $Node "port"
    if ($null -eq $nodePort) {
        $nodePort = & $getVal $Node "Port"
    }

    $nodeIdentityFile = & $getVal $Node "identityFile"
    if ([string]::IsNullOrWhiteSpace($nodeIdentityFile)) {
        $nodeIdentityFile = & $getVal $Node "IdentityFile"
    }

    $nodeName = & $getVal $Node "nodeName"
    if ([string]::IsNullOrWhiteSpace($nodeName)) {
        $nodeName = & $getVal $Node "NodeName"
    }
    if ([string]::IsNullOrWhiteSpace($nodeName)) {
        $nodeName = & $getVal $Node "name"
    }

    $resolvedIdentity = if (-not [string]::IsNullOrWhiteSpace($nodeIdentityFile)) {
        [string]$nodeIdentityFile
    } else {
        $defaultIdentityFile
    }

    if (-not [string]::IsNullOrWhiteSpace($WorkspaceRoot) -and -not [string]::IsNullOrWhiteSpace($resolvedIdentity)) {
        $resolvedIdentity = Resolve-IdentityPath -IdentityPath $resolvedIdentity -WorkspaceRoot $WorkspaceRoot
    }

    return [pscustomobject]@{
        NodeName     = $nodeName
        User         = if (-not [string]::IsNullOrWhiteSpace($nodeUser)) { [string]$nodeUser } else { $defaultUser }
        Host         = [string]$nodeHost
        Port         = if ($nodePort) { [int]$nodePort } else { $defaultPort }
        IdentityFile = $resolvedIdentity
    }
}

function Get-SshCommandLineArguments {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true, Position = 0)]
        $NodeConnection,

        [Parameter(Mandatory = $false, Position = 1)]
        [string]$Command = $null
    )

    $getVal = {
        param($Target, [string]$Name)
        if ($null -eq $Target -or [string]::IsNullOrWhiteSpace($Name)) { return $null }
        if ($Target -is [System.Collections.IDictionary]) {
            if ($Target.Contains($Name)) { return $Target[$Name] }
            return $null
        }
        $prop = $Target.PSObject.Properties[$Name]
        if ($prop) { return $prop.Value }
        return $null
    }

    $user = & $getVal $NodeConnection "User"
    if ([string]::IsNullOrWhiteSpace($user)) { $user = & $getVal $NodeConnection "user" }
    if ([string]::IsNullOrWhiteSpace($user)) { $user = "root" }

    $hostVal = & $getVal $NodeConnection "Host"
    if ([string]::IsNullOrWhiteSpace($hostVal)) { $hostVal = & $getVal $NodeConnection "host" }

    $port = & $getVal $NodeConnection "Port"
    if ($null -eq $port) { $port = & $getVal $NodeConnection "port" }
    if (-not $port) { $port = 22 }

    $identityFile = & $getVal $NodeConnection "IdentityFile"
    if ([string]::IsNullOrWhiteSpace($identityFile)) { $identityFile = & $getVal $NodeConnection "identityFile" }

    $args = @(
        "-F", "NUL",
        "-o", "BatchMode=yes",
        "-o", "ConnectTimeout=8",
        "-o", "ServerAliveInterval=15",
        "-o", "ServerAliveCountMax=4",
        "-o", "IdentitiesOnly=yes",
        "-o", "LogLevel=ERROR",
        "-o", "StrictHostKeyChecking=no",
        "-o", "UserKnownHostsFile=NUL",
        "-o", "GlobalKnownHostsFile=NUL",
        "-p", [string]$port
    )
    if (-not [string]::IsNullOrWhiteSpace($identityFile)) {
        $args += @("-i", [string]$identityFile)
    }

    $target = "{0}@{1}" -f $user, $hostVal
    $args += $target

    if ($null -ne $Command -and $Command -ne '') {
        $args += $Command
    }

    return [string[]]$args
}

function Get-ScpCommandLineArguments {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true, Position = 0)]
        $NodeConnection,

        [Parameter(Mandatory = $true, Position = 1)]
        [string[]]$LocalPaths,

        [Parameter(Mandatory = $true, Position = 2)]
        [string]$RemotePath
    )

    $getVal = {
        param($Target, [string]$Name)
        if ($null -eq $Target -or [string]::IsNullOrWhiteSpace($Name)) { return $null }
        if ($Target -is [System.Collections.IDictionary]) {
            if ($Target.Contains($Name)) { return $Target[$Name] }
            return $null
        }
        $prop = $Target.PSObject.Properties[$Name]
        if ($prop) { return $prop.Value }
        return $null
    }

    $user = & $getVal $NodeConnection "User"
    if ([string]::IsNullOrWhiteSpace($user)) { $user = & $getVal $NodeConnection "user" }
    if ([string]::IsNullOrWhiteSpace($user)) { $user = "root" }

    $hostVal = & $getVal $NodeConnection "Host"
    if ([string]::IsNullOrWhiteSpace($hostVal)) { $hostVal = & $getVal $NodeConnection "host" }

    $port = & $getVal $NodeConnection "Port"
    if ($null -eq $port) { $port = & $getVal $NodeConnection "port" }
    if (-not $port) { $port = 22 }

    $identityFile = & $getVal $NodeConnection "IdentityFile"
    if ([string]::IsNullOrWhiteSpace($identityFile)) { $identityFile = & $getVal $NodeConnection "identityFile" }

    $args = @(
        "-F", "NUL",
        "-o", "BatchMode=yes",
        "-o", "ConnectTimeout=8",
        "-o", "ServerAliveInterval=15",
        "-o", "ServerAliveCountMax=4",
        "-o", "IdentitiesOnly=yes",
        "-o", "LogLevel=ERROR",
        "-o", "StrictHostKeyChecking=no",
        "-o", "UserKnownHostsFile=NUL",
        "-o", "GlobalKnownHostsFile=NUL",
        "-P", [string]$port
    )
    if (-not [string]::IsNullOrWhiteSpace($identityFile)) {
        $args += @("-i", [string]$identityFile)
    }

    $paths = @($LocalPaths | Where-Object { -not [string]::IsNullOrWhiteSpace($_) })
    $args += $paths

    $target = "{0}@{1}:{2}" -f $user, $hostVal, $RemotePath
    $args += $target

    return [string[]]$args
}
