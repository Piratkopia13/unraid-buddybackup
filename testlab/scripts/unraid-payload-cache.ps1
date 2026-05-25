$ErrorActionPreference = "Stop"

. (Join-Path $PSScriptRoot "testlab-logging.ps1")

function Resolve-TestLabPath {
    param([string]$Path)

    if ([string]::IsNullOrWhiteSpace($Path)) {
        return $Path
    }

    if ([System.IO.Path]::IsPathRooted($Path) -or $Path -match '^[\\/]{2}') {
        return [System.IO.Path]::GetFullPath($Path)
    }

    $workspaceRoot = [System.IO.Path]::GetFullPath((Join-Path $PSScriptRoot "..\.."))
    return [System.IO.Path]::GetFullPath((Join-Path $workspaceRoot $Path))
}

function Ensure-TestLabDir {
    param([string]$Path)

    if (-not (Test-Path -LiteralPath $Path)) {
        New-Item -ItemType Directory -Path $Path -Force | Out-Null
    }
}

function Test-UnraidPayloadRoot {
    param([string]$Path)

    if ([string]::IsNullOrWhiteSpace($Path) -or -not (Test-Path -LiteralPath $Path)) {
        return $false
    }

    foreach ($relativePath in @(
        "bzimage",
        "bzroot",
        "syslinux/mbr.bin",
        "syslinux/syslinux.cfg",
        "syslinux/syslinux_linux"
    )) {
        if (-not (Test-Path -LiteralPath (Join-Path $Path $relativePath))) {
            return $false
        }
    }

    return $true
}

function Resolve-UnraidReleaseUrl {
    param(
        [string]$Version,
        [string]$UrlTemplate
    )

    if ([string]::IsNullOrWhiteSpace($UrlTemplate)) {
        return $null
    }

    if ($UrlTemplate -match '\{version\}') {
        return $UrlTemplate.Replace("{version}", $Version)
    }

    return $UrlTemplate
}

function Get-UnraidPayloadExtractionRoot {
    param([string]$ExtractionRoot)

    if (Test-UnraidPayloadRoot -Path $ExtractionRoot) {
        return $ExtractionRoot
    }

    $children = Get-ChildItem -LiteralPath $ExtractionRoot -Directory -ErrorAction SilentlyContinue
    foreach ($child in $children) {
        if (Test-UnraidPayloadRoot -Path $child.FullName) {
            return $child.FullName
        }
    }

    return $null
}

function Get-UnraidRelease {
    param(
        [string]$Version,
        [string]$UrlTemplate,
        [string]$CacheRoot,
        [switch]$DoExecute
    )

    $resolvedCacheRoot = Resolve-TestLabPath $CacheRoot
    Ensure-TestLabDir $resolvedCacheRoot

    $zipFile = Join-Path -Path $resolvedCacheRoot -ChildPath "unraid-${Version}.zip"

    if (-not $DoExecute) {
        Write-Host "[dry-run] Would use Unraid $Version zip: $zipFile"
        Write-Host "[dry-run]   (pre-place zip there manually if auto-download fails)"
        return $zipFile
    }

    if (Test-Path -LiteralPath $zipFile) {
        try {
            Add-Type -AssemblyName System.IO.Compression.FileSystem
            $ztest = [System.IO.Compression.ZipFile]::OpenRead($zipFile)
            $ztest.Dispose()
            Write-Host "[testlab] Using cached Unraid ${Version}: $zipFile"
            return $zipFile
        } catch {
            Write-Host "[testlab] Cached zip is corrupt, removing: $zipFile"
            Remove-Item -LiteralPath $zipFile -Force -ErrorAction SilentlyContinue
        }
    }

    if (-not $UrlTemplate) {
        throw "Unraid $Version zip not found at '$zipFile' and no download URL is configured.`nDownload the zip manually from https://account.unraid.net and place it at:`n  $zipFile"
    }

    $url = Resolve-UnraidReleaseUrl -Version $Version -UrlTemplate $UrlTemplate
    Write-Host "[testlab] Attempting download of Unraid $Version from $url ..."

    $tmpZip = Join-Path $env:TEMP "unraid-${Version}-download.zip"
    Remove-Item -LiteralPath $tmpZip -Force -ErrorAction SilentlyContinue

    try {
        if (Get-Command curl.exe -ErrorAction SilentlyContinue) {
            & curl.exe -L --fail --silent --show-error -o $tmpZip $url
            if ($LASTEXITCODE -ne 0) {
                throw "curl.exe exit $LASTEXITCODE"
            }
        } else {
            (New-Object System.Net.WebClient).DownloadFile($url, $tmpZip)
        }

        Add-Type -AssemblyName System.IO.Compression.FileSystem
        $ztest = [System.IO.Compression.ZipFile]::OpenRead($tmpZip)
        $ztest.Dispose()
    } catch {
        Remove-Item -LiteralPath $tmpZip -Force -ErrorAction SilentlyContinue
        throw @"
Auto-download failed: $_

Use one of these recovery paths for Unraid ${Version}:
    1. Set lab.wslQemu.unraidDownloadUrls."$Version" to a known direct zip URL
    2. Set lab.wslQemu.unraidDownloadUrlTemplate if one predictable URL pattern still works
    3. Download the zip manually from https://account.unraid.net and place it at: $zipFile
Then re-run this script.
"@
    }

    Copy-Item -LiteralPath $tmpZip -Destination $zipFile -Force
    Remove-Item -LiteralPath $tmpZip -Force -ErrorAction SilentlyContinue
    Write-Host "[testlab] Cached: $zipFile"
    return $zipFile
}

function Ensure-UnraidPayload {
    param(
        [string]$Version,
        [string]$CacheRoot = ".testlab/cache",
        [string]$UrlTemplate,
        [switch]$DoExecute
    )

    $resolvedCacheRoot = Resolve-TestLabPath $CacheRoot
    Ensure-TestLabDir $resolvedCacheRoot

    $payloadRoot = Join-Path $resolvedCacheRoot "unraid-${Version}-extracted"
    if (Test-UnraidPayloadRoot -Path $payloadRoot) {
        Write-Host "[testlab] Using extracted Unraid $Version payload: $payloadRoot"
        return $payloadRoot
    }

    if (-not $DoExecute) {
        Write-Host "[dry-run] Would ensure extracted Unraid $Version payload at $payloadRoot"
        $resolvedUrl = Resolve-UnraidReleaseUrl -Version $Version -UrlTemplate $UrlTemplate
        if (-not [string]::IsNullOrWhiteSpace($resolvedUrl)) {
            Write-Host "[dry-run]   configured Unraid download URL: $resolvedUrl"
        }
        return $payloadRoot
    }

    $zipPath = Get-UnraidRelease -Version $Version -UrlTemplate $UrlTemplate -CacheRoot $resolvedCacheRoot -DoExecute
    $stagingRoot = Join-Path $resolvedCacheRoot ("unraid-{0}-extracting-{1}" -f $Version, [guid]::NewGuid().ToString("N"))
    Ensure-TestLabDir $stagingRoot

    try {
        Add-Type -AssemblyName System.IO.Compression.FileSystem
        [System.IO.Compression.ZipFile]::ExtractToDirectory($zipPath, $stagingRoot)

        $sourceRoot = Get-UnraidPayloadExtractionRoot -ExtractionRoot $stagingRoot
        if (-not $sourceRoot) {
            throw "Extracted Unraid zip does not contain the expected boot payload files."
        }

        if (Test-Path -LiteralPath $payloadRoot) {
            Remove-Item -LiteralPath $payloadRoot -Recurse -Force
        }

        Move-Item -LiteralPath $sourceRoot -Destination $payloadRoot
        if (Test-Path -LiteralPath $stagingRoot) {
            Remove-Item -LiteralPath $stagingRoot -Recurse -Force -ErrorAction SilentlyContinue
        }
    } catch {
        Remove-Item -LiteralPath $stagingRoot -Recurse -Force -ErrorAction SilentlyContinue
        throw
    }

    if (-not (Test-UnraidPayloadRoot -Path $payloadRoot)) {
        throw "Extracted payload is missing required files: $payloadRoot"
    }

    Write-Host "[testlab] Extracted Unraid $Version payload: $payloadRoot"
    return $payloadRoot
}