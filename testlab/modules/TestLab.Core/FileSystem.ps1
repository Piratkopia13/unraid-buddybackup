$ErrorActionPreference = "Stop"

function Ensure-TestLabDir {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [string]$Path
    )

    if ([string]::IsNullOrWhiteSpace($Path)) {
        return $Path
    }

    $resolvedPath = if ([System.IO.Path]::IsPathRooted($Path)) {
        [System.IO.Path]::GetFullPath($Path)
    } else {
        [System.IO.Path]::GetFullPath($Path)
    }

    if (-not (Test-Path -LiteralPath $resolvedPath)) {
        [System.IO.Directory]::CreateDirectory($resolvedPath) | Out-Null
    }

    return $resolvedPath
}

function Get-TestLabWorkspaceRoot {
    [CmdletBinding()]
    param(
        [string]$ScriptRoot = $null
    )

    if ([string]::IsNullOrWhiteSpace($ScriptRoot)) {
        if (-not [string]::IsNullOrWhiteSpace($PSScriptRoot)) {
            $ScriptRoot = $PSScriptRoot
        } else {
            $ScriptRoot = (Get-Location).ProviderPath
        }
    }

    $current = [System.IO.Path]::GetFullPath($ScriptRoot)
    while (-not [string]::IsNullOrWhiteSpace($current)) {
        if ((Test-Path (Join-Path $current ".git")) -or
            (Test-Path (Join-Path $current "src\usr\local\emhttp\plugins\buddybackup")) -or
            (Test-Path (Join-Path $current "testlab\config"))) {
            return $current
        }
        $parent = [System.IO.Path]::GetDirectoryName($current)
        if ([string]::IsNullOrWhiteSpace($parent) -or $parent -eq $current) {
            break
        }
        $current = $parent
    }

    return [System.IO.Path]::GetFullPath($ScriptRoot)
}

function Resolve-TestLabWorkspacePath {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [string]$WorkspaceRoot,
        [Parameter(Mandatory = $true)]
        [string]$Path
    )

    if ([string]::IsNullOrWhiteSpace($Path)) {
        return $WorkspaceRoot
    }

    if ($Path.StartsWith('~/') -or $Path.StartsWith('~\')) {
        return [System.IO.Path]::GetFullPath((Join-Path -Path $HOME -ChildPath $Path.Substring(2)))
    }

    if ([System.IO.Path]::IsPathRooted($Path)) {
        return [System.IO.Path]::GetFullPath($Path)
    }

    return [System.IO.Path]::GetFullPath((Join-Path $WorkspaceRoot $Path))
}

function Read-TestLabTextFile {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [string]$Path,
        [System.Text.Encoding]$Encoding = [System.Text.Encoding]::UTF8,
        [int]$MaxRetries = 5,
        [int]$RetryDelayMs = 200
    )

    $resolvedPath = if ([System.IO.Path]::IsPathRooted($Path)) {
        [System.IO.Path]::GetFullPath($Path)
    } else {
        $resolved = Resolve-Path -LiteralPath $Path -ErrorAction SilentlyContinue
        if ($resolved) {
            if ($resolved.ProviderPath) { $resolved.ProviderPath } else { $resolved.Path }
        } else {
            [System.IO.Path]::GetFullPath($Path)
        }
    }

    if (-not (Test-Path -LiteralPath $resolvedPath)) {
        throw [System.IO.FileNotFoundException]::new("File not found: $resolvedPath", $resolvedPath)
    }

    $lastError = $null
    for ($attempt = 1; $attempt -le $MaxRetries; $attempt++) {
        try {
            $fileStream = [System.IO.FileStream]::new(
                $resolvedPath,
                [System.IO.FileMode]::Open,
                [System.IO.FileAccess]::Read,
                [System.IO.FileShare]::ReadWrite
            )
            try {
                $streamReader = [System.IO.StreamReader]::new($fileStream, $Encoding)
                try {
                    return $streamReader.ReadToEnd()
                } finally {
                    $streamReader.Dispose()
                }
            } finally {
                $fileStream.Dispose()
            }
        } catch {
            $lastError = $_
            if ($attempt -lt $MaxRetries) {
                Start-Sleep -Milliseconds $RetryDelayMs
            }
        }
    }

    throw "Failed to read file '$resolvedPath' after $MaxRetries attempts: $($lastError.Exception.Message)"
}

function Write-TestLabTextFile {
    [CmdletBinding()]
    [Alias('Set-TestLabTextFile')]
    param(
        [Parameter(Mandatory = $true)]
        [string]$Path,
        [Parameter(Mandatory = $true, ValueFromPipeline = $true)]
        [AllowEmptyString()]
        [Alias('Value')]
        [string]$Content,
        [System.Text.Encoding]$Encoding = [System.Text.Encoding]::UTF8
    )

    $resolvedPath = if ([System.IO.Path]::IsPathRooted($Path)) {
        [System.IO.Path]::GetFullPath($Path)
    } else {
        [System.IO.Path]::GetFullPath($Path)
    }

    $parentDir = [System.IO.Path]::GetDirectoryName($resolvedPath)
    if (-not [string]::IsNullOrWhiteSpace($parentDir) -and -not (Test-Path -LiteralPath $parentDir)) {
        [System.IO.Directory]::CreateDirectory($parentDir) | Out-Null
    }

    [System.IO.File]::WriteAllText($resolvedPath, $Content, $Encoding)
}

function Get-TestLabJson {
    [CmdletBinding()]
    [Alias('Read-TestLabJson')]
    param(
        [Parameter(Mandatory = $true)]
        [string]$Path
    )

    $raw = Read-TestLabTextFile -Path $Path
    if ([string]::IsNullOrWhiteSpace($raw)) {
        return $null
    }
    return ($raw | ConvertFrom-Json)
}

function Set-TestLabJson {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true, Position = 0)]
        [string]$Path,
        [Parameter(Mandatory = $false, Position = 1)]
        $Object = $null,
        [Parameter(Mandatory = $false)]
        $Value = $null,
        [int]$Depth = 10
    )

    $target = if ($null -ne $Object) { $Object } else { $Value }
    $json = $target | ConvertTo-Json -Depth $Depth
    Write-TestLabTextFile -Path $Path -Content $json
}
