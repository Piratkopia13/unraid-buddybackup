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

function Get-UnraidCacheObjectValue {
    param(
        $Object,
        [string]$Name
    )

    if ($null -eq $Object -or [string]::IsNullOrWhiteSpace($Name)) {
        return $null
    }

    if ($Object -is [System.Collections.IDictionary]) {
        if ($Object.Contains($Name)) {
            return $Object[$Name]
        }
        return $null
    }

    $property = $Object.PSObject.Properties[$Name]
    if ($property) {
        return $property.Value
    }

    return $null
}

function Set-UnraidCacheObjectValue {
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

    $property = $Object.PSObject.Properties[$Name]
    if ($property) {
        $property.Value = $Value
    } else {
        $Object | Add-Member -NotePropertyName $Name -NotePropertyValue $Value -Force
    }
}

function ConvertTo-UnraidVersionParts {
    param([string]$Version)

    $parts = New-Object System.Collections.Generic.List[int]
    if ([string]::IsNullOrWhiteSpace($Version)) {
        return @()
    }

    foreach ($rawPart in ($Version.Trim() -split '[-.]')) {
        $part = $rawPart.ToLowerInvariant()
        if ($part -eq 'beta') {
            $parts.Add(-2)
        } elseif ($part -eq 'rc') {
            $parts.Add(-1)
        } elseif ($part -match '^beta(\d+)$') {
            $parts.Add(-2)
            $parts.Add([int]$matches[1])
        } elseif ($part -match '^rc(\d+)$') {
            $parts.Add(-1)
            $parts.Add([int]$matches[1])
        } elseif ($part -match '^\d+$') {
            $parts.Add([int]$part)
        } else {
            $parts.Add(0)
        }
    }

    return @($parts)
}

function Compare-UnraidVersion {
    param(
        [string]$Left,
        [string]$Right
    )

    $leftParts = @(ConvertTo-UnraidVersionParts -Version $Left)
    $rightParts = @(ConvertTo-UnraidVersionParts -Version $Right)
    $length = [Math]::Max($leftParts.Count, $rightParts.Count)

    for ($i = 0; $i -lt $length; $i++) {
        $l = if ($i -lt $leftParts.Count) { $leftParts[$i] } else { 0 }
        $r = if ($i -lt $rightParts.Count) { $rightParts[$i] } else { 0 }
        if ($l -ne $r) {
            return $l.CompareTo($r)
        }
    }

    return 0
}

function Strip-UnraidDownloadUrlTracking {
    param([string]$Url)

    if ([string]::IsNullOrWhiteSpace($Url)) {
        return $Url
    }

    return ($Url -replace '([?&])utm_[^&]+&?', '$1' -replace '[?&]$', '')
}

if ($null -eq $script:UnraidReleaseCatalogCache) {
    $script:UnraidReleaseCatalogCache = @{}
}

function Get-UnraidReleaseCatalog {
    param(
        [string]$CatalogUrl = "https://releases.unraid.net/json?includePublic=1",
        [object[]]$CatalogOverride = $null,
        [switch]$ForceRefresh
    )

    if ($null -ne $CatalogOverride) {
        return @($CatalogOverride)
    }

    if ($null -eq $script:UnraidReleaseCatalogCache) {
        $script:UnraidReleaseCatalogCache = @{}
    }

    if (-not $ForceRefresh -and $script:UnraidReleaseCatalogCache.ContainsKey($CatalogUrl)) {
        return @($script:UnraidReleaseCatalogCache[$CatalogUrl])
    }

    $rawJson = $null
    if (Get-Command curl.exe -ErrorAction SilentlyContinue) {
        $curlOutput = & curl.exe -fsSL --max-time 15 $CatalogUrl 2>&1
        if ($LASTEXITCODE -eq 0 -and $curlOutput) {
            $rawJson = (@($curlOutput | ForEach-Object { [string]$_ }) -join "`n").Trim()
        } else {
            $errText = (@($curlOutput | ForEach-Object { [string]$_ }) -join " ").Trim()
            throw "Failed to fetch Unraid release catalog from ${CatalogUrl}: $errText"
        }
    } else {
        $response = Invoke-WebRequest -Uri $CatalogUrl -UseBasicParsing -TimeoutSec 15
        $rawJson = [string]$response.Content
    }

    if ([string]::IsNullOrWhiteSpace($rawJson)) {
        throw "Empty response from Unraid release catalog at $CatalogUrl"
    }

    $parsed = $rawJson | ConvertFrom-Json
    $entries = @($parsed)
    $script:UnraidReleaseCatalogCache[$CatalogUrl] = $entries
    return $entries
}

function Get-HighestConfiguredUnraidVersion {
    param($WslConfig)

    $versionUrls = Get-UnraidCacheObjectValue -Object $WslConfig -Name "unraidDownloadUrls"
    if ($null -eq $versionUrls) {
        return $null
    }

    $keys = @()
    if ($versionUrls -is [System.Collections.IDictionary]) {
        $keys = @($versionUrls.Keys | ForEach-Object { [string]$_ })
    } elseif ($versionUrls.PSObject -and $versionUrls.PSObject.Properties) {
        $keys = @($versionUrls.PSObject.Properties | ForEach-Object { [string]$_.Name })
    }

    $bestVersion = $null
    foreach ($candidate in $keys) {
        if ([string]::IsNullOrWhiteSpace($candidate)) {
            continue
        }
        if ($null -eq $bestVersion -or (Compare-UnraidVersion -Left $candidate -Right $bestVersion) -gt 0) {
            $bestVersion = $candidate
        }
    }

    if ($null -eq $bestVersion) {
        return $null
    }

    return [pscustomobject]@{
        Version = $bestVersion
        Url = [string](Get-UnraidCacheObjectValue -Object $versionUrls -Name $bestVersion)
    }
}

function Test-UnraidLatestVersionToken {
    param([string]$Version)

    if ([string]::IsNullOrWhiteSpace($Version)) {
        return $false
    }

    return ($Version.Trim() -match '^(?i)(latest|latest-supported)$')
}

function Resolve-UnraidVersionSpec {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Version,
        $WslConfig = $null,
        [string]$CatalogUrl = "https://releases.unraid.net/json?includePublic=1",
        [object[]]$CatalogOverride = $null,
        [switch]$AllowOfflineFallback
    )

    $trimmed = $Version.Trim()
    $versionUrls = Get-UnraidCacheObjectValue -Object $WslConfig -Name "unraidDownloadUrls"
    $urlTemplate = [string](Get-UnraidCacheObjectValue -Object $WslConfig -Name "unraidDownloadUrlTemplate")

    if (Test-UnraidLatestVersionToken -Version $trimmed) {
        try {
            $catalog = @(Get-UnraidReleaseCatalog -CatalogUrl $CatalogUrl -CatalogOverride $CatalogOverride)
            $downloadable = @(
                $catalog | Where-Object {
                    $ver = [string](Get-UnraidCacheObjectValue -Object $_ -Name "version")
                    $url = [string](Get-UnraidCacheObjectValue -Object $_ -Name "url")
                    $pub = Get-UnraidCacheObjectValue -Object $_ -Name "public"
                    $dl = Get-UnraidCacheObjectValue -Object $_ -Name "downloadable"
                    (-not [string]::IsNullOrWhiteSpace($ver)) -and
                    (-not [string]::IsNullOrWhiteSpace($url)) -and
                    ($null -eq $pub -or [bool]$pub) -and
                    ($null -eq $dl -or [bool]$dl)
                }
            )

            $supported = @($downloadable | Where-Object {
                ([string](Get-UnraidCacheObjectValue -Object $_ -Name "supportStatus")) -eq "supported"
            })
            $pool = if ($supported.Count -gt 0) {
                $supported
            } else {
                @($downloadable | Where-Object {
                    ([string](Get-UnraidCacheObjectValue -Object $_ -Name "version")) -notmatch '(?i)(beta|rc)'
                })
            }

            if ($pool.Count -eq 0) {
                $pool = $downloadable
            }

            $selected = $pool | Sort-Object -Descending -Property @{
                Expression = {
                    $parts = @(ConvertTo-UnraidVersionParts -Version ([string](Get-UnraidCacheObjectValue -Object $_ -Name "version")))
                    ("{0:D6}.{1:D6}.{2:D6}.{3:D6}" -f
                        $(if ($parts.Count -gt 0) { $parts[0] + 100 } else { 0 }),
                        $(if ($parts.Count -gt 1) { $parts[1] + 100 } else { 0 }),
                        $(if ($parts.Count -gt 2) { $parts[2] + 100 } else { 0 }),
                        $(if ($parts.Count -gt 3) { $parts[3] + 100 } else { 0 }))
                }
            } | Select-Object -First 1

            if ($null -eq $selected) {
                throw "No downloadable supported Unraid release found in catalog."
            }

            $resolvedVersion = [string](Get-UnraidCacheObjectValue -Object $selected -Name "version")
            $configuredUrl = [string](Get-UnraidCacheObjectValue -Object $versionUrls -Name $resolvedVersion)
            $resolvedCatalogUrl = Strip-UnraidDownloadUrlTracking -Url ([string](Get-UnraidCacheObjectValue -Object $selected -Name "url"))

            return [pscustomobject]@{
                RequestedVersion = $trimmed
                ResolvedVersion  = $resolvedVersion
                DownloadUrl      = if (-not [string]::IsNullOrWhiteSpace($configuredUrl)) { $configuredUrl } else { $resolvedCatalogUrl }
                Md5              = [string](Get-UnraidCacheObjectValue -Object $selected -Name "md5")
                Sha256           = [string](Get-UnraidCacheObjectValue -Object $selected -Name "sha256")
                Source           = "unraid-catalog"
            }
        } catch {
            $fallback = Get-HighestConfiguredUnraidVersion -WslConfig $WslConfig
            if ($AllowOfflineFallback -and $null -ne $fallback) {
                Write-Warning "Failed to resolve Unraid '$trimmed' from ${CatalogUrl} ($($_.Exception.Message)); falling back to configured version '$($fallback.Version)'."
                return [pscustomobject]@{
                    RequestedVersion = $trimmed
                    ResolvedVersion  = $fallback.Version
                    DownloadUrl      = $fallback.Url
                    Md5              = $null
                    Sha256           = $null
                    Source           = "offline-config-fallback"
                }
            }

            throw "Unable to resolve Unraid '$trimmed' from ${CatalogUrl}: $($_.Exception.Message)"
        }
    }

    $configuredExplicitUrl = [string](Get-UnraidCacheObjectValue -Object $versionUrls -Name $trimmed)
    if (-not [string]::IsNullOrWhiteSpace($configuredExplicitUrl)) {
        return [pscustomobject]@{
            RequestedVersion = $trimmed
            ResolvedVersion  = $trimmed
            DownloadUrl      = $configuredExplicitUrl
            Md5              = $null
            Sha256           = $null
            Source           = "config-map"
        }
    }

    try {
        $catalog = @(Get-UnraidReleaseCatalog -CatalogUrl $CatalogUrl -CatalogOverride $CatalogOverride)
        $match = $catalog | Where-Object {
            ([string](Get-UnraidCacheObjectValue -Object $_ -Name "version")) -eq $trimmed -and
            (-not [string]::IsNullOrWhiteSpace([string](Get-UnraidCacheObjectValue -Object $_ -Name "url")))
        } | Select-Object -First 1

        if ($null -ne $match) {
            return [pscustomobject]@{
                RequestedVersion = $trimmed
                ResolvedVersion  = $trimmed
                DownloadUrl      = Strip-UnraidDownloadUrlTracking -Url ([string](Get-UnraidCacheObjectValue -Object $match -Name "url"))
                Md5              = [string](Get-UnraidCacheObjectValue -Object $match -Name "md5")
                Sha256           = [string](Get-UnraidCacheObjectValue -Object $match -Name "sha256")
                Source           = "unraid-catalog"
            }
        }
    } catch {
        # Best-effort catalog lookup for explicit versions; template fallback handles offline/custom cases.
    }

    $templateUrl = Resolve-UnraidReleaseUrl -Version $trimmed -UrlTemplate $urlTemplate
    return [pscustomobject]@{
        RequestedVersion = $trimmed
        ResolvedVersion  = $trimmed
        DownloadUrl      = $templateUrl
        Md5              = $null
        Sha256           = $null
        Source           = if (-not [string]::IsNullOrWhiteSpace($templateUrl)) { "url-template" } else { "none" }
    }
}

function Resolve-LabUnraidVersions {
    param(
        $Lab,
        [string]$CatalogUrl = "https://releases.unraid.net/json?includePublic=1",
        [object[]]$CatalogOverride = $null,
        [switch]$AllowOfflineFallback
    )

    if ($null -eq $Lab) {
        return $null
    }

    $wslCfg = Get-UnraidCacheObjectValue -Object $Lab -Name "wslQemu"
    $resolvedItems = @()

    $nodes = Get-UnraidCacheObjectValue -Object $Lab -Name "nodes"
    if ($null -ne $nodes) {
        foreach ($nodeName in @("nodeA", "nodeB")) {
            $node = Get-UnraidCacheObjectValue -Object $nodes -Name $nodeName
            if ($null -eq $node) {
                continue
            }

            $ver = [string](Get-UnraidCacheObjectValue -Object $node -Name "unraidVersion")
            if (Test-UnraidLatestVersionToken -Version $ver) {
                $resolution = Resolve-UnraidVersionSpec -Version $ver -WslConfig $wslCfg -CatalogUrl $CatalogUrl -CatalogOverride $CatalogOverride -AllowOfflineFallback:$AllowOfflineFallback
                Set-UnraidCacheObjectValue -Object $node -Name "unraidVersionRequested" -Value $ver
                Set-UnraidCacheObjectValue -Object $node -Name "unraidVersion" -Value $resolution.ResolvedVersion
                $resolvedItems += [pscustomobject]@{
                    Target           = "nodes.$nodeName.unraidVersion"
                    RequestedVersion = $ver
                    ResolvedVersion  = $resolution.ResolvedVersion
                    Source           = $resolution.Source
                }
            }
        }
    }

    $releaseGate = Get-UnraidCacheObjectValue -Object $Lab -Name "releaseGate"
    if ($null -ne $releaseGate) {
        foreach ($propName in @("latestSupportedUnraidVersion", "previousCertifiedUnraidVersion")) {
            $ver = [string](Get-UnraidCacheObjectValue -Object $releaseGate -Name $propName)
            if (Test-UnraidLatestVersionToken -Version $ver) {
                $resolution = Resolve-UnraidVersionSpec -Version $ver -WslConfig $wslCfg -CatalogUrl $CatalogUrl -CatalogOverride $CatalogOverride -AllowOfflineFallback:$AllowOfflineFallback
                Set-UnraidCacheObjectValue -Object $releaseGate -Name "${propName}Requested" -Value $ver
                Set-UnraidCacheObjectValue -Object $releaseGate -Name $propName -Value $resolution.ResolvedVersion
                $resolvedItems += [pscustomobject]@{
                    Target           = "releaseGate.$propName"
                    RequestedVersion = $ver
                    ResolvedVersion  = $resolution.ResolvedVersion
                    Source           = $resolution.Source
                }
            }
        }
    }

    return $resolvedItems
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