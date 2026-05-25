$ErrorActionPreference = "Stop"

. (Join-Path $PSScriptRoot "testlab-logging.ps1")

function Expand-LocalPath {
    param([string]$Path)

    if ([string]::IsNullOrWhiteSpace($Path)) {
        return $Path
    }

    if ([System.IO.Path]::IsPathRooted($Path)) {
        return [System.IO.Path]::GetFullPath($Path)
    }

    $basePath = (Get-Location).ProviderPath
    return [System.IO.Path]::GetFullPath((Join-Path $basePath $Path))
}

function Convert-WindowsPathToWslPath {
    param(
        [Parameter(Mandatory = $true)]
        [string]$WindowsPath,
        [switch]$AllowMissing
    )

    $providerPath = $WindowsPath
    if (-not $AllowMissing) {
        $resolved = Resolve-Path -LiteralPath $WindowsPath -ErrorAction Stop
        $providerPath = if ($resolved.ProviderPath) { $resolved.ProviderPath } else { $resolved.Path }
    } else {
        $providerPath = [System.IO.Path]::GetFullPath($WindowsPath)
    }

    if ($providerPath -notmatch '^([A-Za-z]):\\(.*)$') {
        throw "Path '$providerPath' is not a local drive path. WSL mount access does not support UNC paths."
    }

    $drive = $matches[1].ToLowerInvariant()
    $tail = $matches[2] -replace '\\', '/'
    if ([string]::IsNullOrEmpty($tail)) {
        return "/mnt/$drive"
    }

    return "/mnt/$drive/$tail"
}

function Invoke-WslRootBash {
    param(
        [Parameter(Mandatory = $true)]
        [string]$ScriptContent,
        [string[]]$Arguments = @(),
        [string]$Distro = "Ubuntu",
        [switch]$StreamOutput,
        [string]$StreamLabel = "wsl"
    )

    $wslExe = (Get-Command wsl.exe -ErrorAction Stop).Source
    $tempRoot = Join-Path $env:TEMP "BuddyBackup"
    if (-not (Test-Path $tempRoot)) {
        New-Item -ItemType Directory -Path $tempRoot -Force | Out-Null
    }

    $tempScript = Join-Path $tempRoot ("wsl-{0}.sh" -f [guid]::NewGuid().ToString("N"))
    $normalizedScript = $ScriptContent -replace "`r`n", "`n"
    [System.IO.File]::WriteAllText($tempScript, $normalizedScript, [System.Text.ASCIIEncoding]::new())

    try {
        $wslScriptPath = Convert-WindowsPathToWslPath -WindowsPath $tempScript
        $argList = @("-u", "root")
        if (-not [string]::IsNullOrWhiteSpace($Distro)) {
            $argList += @("-d", $Distro)
        }
        $argList += @("--", "bash", $wslScriptPath)
        if ($Arguments) {
            $argList += $Arguments
        }

        $didPushLocation = $false
        $currentProviderPath = (Get-Location).ProviderPath
        if ($currentProviderPath -and $currentProviderPath -match '^[\\/]{2}') {
            Push-Location $env:TEMP
            $didPushLocation = $true
        }

        $previousErrorActionPreference = $ErrorActionPreference
        try {
            $ErrorActionPreference = "Continue"
            if ($StreamOutput) {
                $output = @(& $wslExe @argList 2>&1 | ForEach-Object {
                    $chunk = [string]$_
                    $lines = @($chunk -replace "`r", "" -split "`n")
                    foreach ($rawLine in $lines) {
                        $line = $rawLine.Trim()
                        if ([string]::IsNullOrWhiteSpace($line)) {
                            continue
                        }

                        Write-Host "[testlab][$StreamLabel] $line"
                        $line
                    }
                })
            } else {
                $output = @(& $wslExe @argList 2>&1)
            }
            $exitCode = $LASTEXITCODE
        } finally {
            $ErrorActionPreference = $previousErrorActionPreference
            if ($didPushLocation) {
                Pop-Location
            }
        }

        return [pscustomobject]@{
            ExitCode = $exitCode
            Output   = @($output)
        }
    } finally {
        Remove-Item -LiteralPath $tempScript -Force -ErrorAction SilentlyContinue
    }
}