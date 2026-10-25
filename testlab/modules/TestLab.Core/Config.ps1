$ErrorActionPreference = "Stop"

function Get-ObjectValue {
    param(
        $Object,
        [string]$Name
    )

    if ($null -eq $Object -or [string]::IsNullOrWhiteSpace($Name)) {
        return $null
    }

    if ($Object -is [System.Collections.IDictionary]) {
        return $Object[$Name]
    }

    if ($Object.PSObject -and $Object.PSObject.Properties) {
        $property = $Object.PSObject.Properties[$Name]
        if ($property) {
            return $property.Value
        }
    }

    return $null
}

function Set-ObjectValue {
    param(
        $Object,
        [string]$Name,
        $Value
    )

    if ($null -eq $Object -or [string]::IsNullOrWhiteSpace($Name)) {
        return
    }

    if ($Object -is [System.Collections.IDictionary]) {
        $Object[$Name] = $Value
        return
    }

    if ($Object.PSObject -and $Object.PSObject.Properties) {
        $property = $Object.PSObject.Properties[$Name]
        if ($property) {
            $property.Value = $Value
        } else {
            $Object | Add-Member -NotePropertyName $Name -NotePropertyValue $Value -Force
        }
        return
    }
}

function Get-TestLabCanonicalNodeName {
    param([string]$NodeName)

    if ([string]::IsNullOrWhiteSpace($NodeName)) {
        return $NodeName
    }

    switch -Regex ($NodeName.Trim()) {
        '^(sender|node[-_]?a|buddybackup-node-?a)$' { return "nodeA" }
        '^(receiver|node[-_]?b|buddybackup-node-?b)$' { return "nodeB" }
        '^(generic|node[-_]?c|buddybackup-node-?c(-generic)?)$' { return "nodeC" }
        default { return $NodeName }
    }
}

function Get-TestLabLegacyNodeName {
    param([string]$NodeName)

    if ([string]::IsNullOrWhiteSpace($NodeName)) {
        return $null
    }

    switch (Get-TestLabCanonicalNodeName -NodeName $NodeName) {
        "nodeA" { return "sender" }
        "nodeB" { return "receiver" }
        default { return $null }
    }
}

function Get-TestLabHostNodeName {
    param([string]$NodeName)

    if ([string]::IsNullOrWhiteSpace($NodeName)) {
        return $NodeName
    }

    switch (Get-TestLabCanonicalNodeName -NodeName $NodeName) {
        "nodeA" { return "buddybackup-node-a" }
        "nodeB" { return "buddybackup-node-b" }
        "nodeC" { return "buddybackup-node-c-generic" }
        default { return $NodeName }
    }
}

function Get-TestLabNodeValue {
    param(
        $Object,
        [string]$NodeName
    )

    if ($null -eq $Object -or [string]::IsNullOrWhiteSpace($NodeName)) {
        return $null
    }

    # 1. Try canonical node name (e.g. nodeA)
    $canonicalNodeName = Get-TestLabCanonicalNodeName -NodeName $NodeName
    $value = Get-ObjectValue -Object $Object -Name $canonicalNodeName
    if ($null -ne $value) {
        return $value
    }

    # 2. Try legacy node name (e.g. sender)
    $legacyNodeName = Get-TestLabLegacyNodeName -NodeName $NodeName
    if (-not [string]::IsNullOrWhiteSpace($legacyNodeName)) {
        $value = Get-ObjectValue -Object $Object -Name $legacyNodeName
        if ($null -ne $value) {
            return $value
        }
    }

    # 3. Try exact node name as passed
    $value = Get-ObjectValue -Object $Object -Name $NodeName
    if ($null -ne $value) {
        return $value
    }

    # 4. Try host node name (e.g. buddybackup-node-a)
    $hostNodeName = Get-TestLabHostNodeName -NodeName $NodeName
    if (-not [string]::IsNullOrWhiteSpace($hostNodeName)) {
        $value = Get-ObjectValue -Object $Object -Name $hostNodeName
        if ($null -ne $value) {
            return $value
        }
    }

    # 5. Check if any child object has a 'name' property matching NodeName or Canonical/Host aliases
    if ($Object -is [System.Collections.IDictionary]) {
        foreach ($key in $Object.Keys) {
            $child = $Object[$key]
            $childName = Get-ObjectValue -Object $child -Name "name"
            if (-not [string]::IsNullOrWhiteSpace($childName)) {
                if ($childName -eq $NodeName -or 
                    (Get-TestLabCanonicalNodeName -NodeName $childName) -eq $canonicalNodeName) {
                    return $child
                }
            }
        }
    } elseif ($Object.PSObject -and $Object.PSObject.Properties) {
        foreach ($prop in $Object.PSObject.Properties) {
            $child = $prop.Value
            if ($null -ne $child) {
                $childName = Get-ObjectValue -Object $child -Name "name"
                if (-not [string]::IsNullOrWhiteSpace($childName)) {
                    if ($childName -eq $NodeName -or 
                        (Get-TestLabCanonicalNodeName -NodeName $childName) -eq $canonicalNodeName) {
                        return $child
                    }
                }
            }
        }
    }

    return $null
}

function Test-LabSupportsMatrixUnraidVersions {
    param(
        $Lab,
        [object[]]$MatrixCells
    )

    $provider = [string](Get-ObjectValue -Object $Lab -Name 'provider')
    $supportedProviders = @('windows-local', 'windows-wsl-qemu', 'manual')
    if ($provider -notin $supportedProviders) {
        return [pscustomobject]@{
            Success = $true
            Error = $null
        }
    }

    $mismatches = @()
    foreach ($nodeName in @('nodeA', 'nodeB')) {
        $labNode = Get-TestLabNodeValue -Object (Get-ObjectValue -Object $Lab -Name 'nodes') -NodeName $nodeName
        $labVersion = [string](Get-ObjectValue -Object $labNode -Name 'unraidVersion')
        if ([string]::IsNullOrWhiteSpace($labVersion)) {
            continue
        }

        $cellVersions = @($MatrixCells | ForEach-Object { [string](Get-ObjectValue -Object (Get-TestLabNodeValue -Object $_ -NodeName $nodeName) -Name 'unraid') } |
            Where-Object { -not [string]::IsNullOrWhiteSpace($_) } |
            Select-Object -Unique)

        foreach ($cellVersion in $cellVersions) {
            if ($cellVersion -ne $labVersion) {
                $mismatches += [pscustomobject]@{
                    node = $nodeName
                    labVersion = $labVersion
                    matrixVersion = $cellVersion
                }
            }
        }
    }

    if ($mismatches.Count -eq 0) {
        return [pscustomobject]@{
            Success = $true
            Error = $null
        }
    }

    $details = @($mismatches | ForEach-Object {
        "node=$($_.node) lab=$($_.labVersion) matrix=$($_.matrixVersion)"
    }) -join '; '

    return [pscustomobject]@{
        Success = $false
        Error = "This testlab run cannot vary Unraid versions per matrix cell. The current provider '$provider' uses the already provisioned lab node versions from the lab config, but the matrix requests different Unraid versions: $details. Provision nodes that match the matrix, or run separate release-gate executions per Unraid baseline instead of mixing them in one run."
    }
}

function Resolve-TestLabPath {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Path,
        [string]$WorkspaceRoot = $null
    )

    if ([string]::IsNullOrWhiteSpace($Path)) {
        return $Path
    }

    if ($Path.StartsWith('~/') -or $Path.StartsWith('~\')) {
        return [System.IO.Path]::GetFullPath((Join-Path -Path $HOME -ChildPath $Path.Substring(2)))
    }

    if ([System.IO.Path]::IsPathRooted($Path)) {
        return [System.IO.Path]::GetFullPath($Path)
    }

    $root = if (-not [string]::IsNullOrWhiteSpace($WorkspaceRoot)) {
        $WorkspaceRoot
    } else {
        Get-TestLabWorkspaceRoot -ScriptRoot $PSScriptRoot
    }

    return [System.IO.Path]::GetFullPath((Join-Path $root $Path))
}

function Get-TestLabConfig {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Path,
        [string]$FallbackPath = $null,
        [string]$WorkspaceRoot = $null
    )

    $resolvedPath = Resolve-TestLabPath -Path $Path -WorkspaceRoot $WorkspaceRoot
    if (Test-Path -LiteralPath $resolvedPath) {
        return (Get-TestLabJson -Path $resolvedPath)
    }

    if (-not [string]::IsNullOrWhiteSpace($FallbackPath)) {
        $resolvedFallback = Resolve-TestLabPath -Path $FallbackPath -WorkspaceRoot $WorkspaceRoot
        if (Test-Path -LiteralPath $resolvedFallback) {
            return (Get-TestLabJson -Path $resolvedFallback)
        }
    }

    throw "Testlab configuration file not found at '$resolvedPath'$(if ($FallbackPath) { " or fallback '$FallbackPath'" })."
}
