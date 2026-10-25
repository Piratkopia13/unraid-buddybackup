<#
.SYNOPSIS
    OpenZFS pool, dataset, snapshot, and configuration helpers for BuddyBackup TestLab.
.DESCRIPTION
    Provides dataset layout resolution from lab config and remote ZFS manipulation commands
    including pool probes, dataset creation/destruction, and snapshot queries.
#>

$ErrorActionPreference = "Stop"

function Get-SetupZfsValues {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $false, Position = 0)]
        $Lab
    )

    $setupCfg = Get-ObjectValue -Object $Lab -Name "setup"
    $zfsCfg = Get-ObjectValue -Object $setupCfg -Name "zfs"

    $poolName = [string](Get-ObjectValue -Object $zfsCfg -Name "poolName")
    if ([string]::IsNullOrWhiteSpace($poolName)) { $poolName = "bbpool" }

    $datasetRootName = [string](Get-ObjectValue -Object $zfsCfg -Name "datasetRoot")
    if ([string]::IsNullOrWhiteSpace($datasetRootName)) { $datasetRootName = "buddybackup" }

    $plainDatasetName = [string](Get-ObjectValue -Object $zfsCfg -Name "unencryptedDatasetName")
    if ([string]::IsNullOrWhiteSpace($plainDatasetName)) { $plainDatasetName = "plain" }

    $encDatasetName = [string](Get-ObjectValue -Object $zfsCfg -Name "encryptedDatasetName")
    if ([string]::IsNullOrWhiteSpace($encDatasetName)) { $encDatasetName = "secure" }

    $root = "$poolName/$datasetRootName"
    return [pscustomobject]@{
        PoolName           = $poolName
        DatasetRoot        = $root
        UnencryptedDataset = "$root/$plainDatasetName"
        EncryptedDataset   = "$root/$encDatasetName"
    }
}

function Test-ZfsPoolExists {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true, Position = 0)]
        $NodeConnection,

        [Parameter(Mandatory = $true, Position = 1)]
        [string]$PoolName,

        [switch]$DoExecute = $true
    )

    if (-not $DoExecute) {
        return $true
    }

    $cmd = "zpool list -H -o name '$PoolName' >/dev/null 2>&1"
    $res = Invoke-RemoteCommand -NodeConnection $NodeConnection -Command $cmd -Label "test-zpool-exists" -DoExecute:$DoExecute
    return [bool]$res.Success
}

function Test-ZfsDatasetExists {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true, Position = 0)]
        $NodeConnection,

        [Parameter(Mandatory = $true, Position = 1)]
        [string]$Dataset,

        [switch]$DoExecute = $true
    )

    if (-not $DoExecute) {
        return $true
    }

    $cmd = "zfs list -H -o name '$Dataset' >/dev/null 2>&1"
    $res = Invoke-RemoteCommand -NodeConnection $NodeConnection -Command $cmd -Label "test-zfs-dataset-exists" -DoExecute:$DoExecute
    return [bool]$res.Success
}

function Ensure-ZfsDatasetAbsent {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true, Position = 0)]
        $NodeConnection,

        [Parameter(Mandatory = $true, Position = 1)]
        [string]$Dataset,

        [switch]$Recursive = $true,
        [switch]$DoExecute = $true
    )

    if (-not $DoExecute) {
        Write-Host "[dry-run] Would destroy ZFS dataset '$Dataset' if present"
        return [pscustomobject]@{
            Success  = $true
            ExitCode = 0
            Output   = "dry-run"
        }
    }

    $destroyFlag = if ($Recursive) { "-r " } else { "" }
    $cmd = "if zfs list -H -o name '$Dataset' >/dev/null 2>&1; then zfs destroy ${destroyFlag}'$Dataset'; fi"
    return Invoke-RemoteCommand -NodeConnection $NodeConnection -Command $cmd -Label "ensure-dataset-absent" -DoExecute:$DoExecute
}

function New-ZfsDataset {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true, Position = 0)]
        $NodeConnection,

        [Parameter(Mandatory = $true, Position = 1)]
        [string]$Dataset,

        [Parameter(Mandatory = $false)]
        $Properties = $null,

        [Parameter(Mandatory = $false)]
        [string]$Passphrase = $null,

        [switch]$CreateParents = $true,
        [switch]$DoExecute = $true
    )

    if (-not $DoExecute) {
        Write-Host "[dry-run] Would create ZFS dataset '$Dataset'"
        return [pscustomobject]@{
            Success  = $true
            ExitCode = 0
            Output   = "dry-run"
        }
    }

    $propArgs = @()
    if ($CreateParents) {
        $propArgs += "-p"
    }

    if ($null -ne $Properties) {
        if ($Properties -is [System.Collections.IDictionary]) {
            foreach ($k in $Properties.Keys) {
                $propArgs += "-o"
                $propArgs += ("{0}={1}" -f $k, $Properties[$k])
            }
        } elseif ($Properties -is [System.Collections.IEnumerable]) {
            foreach ($prop in $Properties) {
                $propArgs += "-o"
                $propArgs += [string]$prop
            }
        }
    }

    if (-not [string]::IsNullOrWhiteSpace($Passphrase)) {
        $passphraseB64 = [Convert]::ToBase64String([System.Text.Encoding]::UTF8.GetBytes($Passphrase))
        $propArgs += @(
            "-o", "encryption=aes-256-gcm",
            "-o", "keyformat=passphrase",
            "-o", "keylocation=prompt"
        )
        $script = @"
passphrase=`$(printf '%s' '$passphraseB64' | base64 -d)
printf '%s\n' "`$passphrase" | zfs create $($propArgs -join ' ') '$Dataset'
"@
        return Invoke-RemoteCommand -NodeConnection $NodeConnection -Command $script -LoggedCommand "zfs create encrypted $Dataset (passphrase redacted)" -Label "new-zfs-dataset" -DoExecute:$DoExecute
    } else {
        $cmd = "zfs create $($propArgs -join ' ') '$Dataset'"
        return Invoke-RemoteCommand -NodeConnection $NodeConnection -Command $cmd -Label "new-zfs-dataset" -DoExecute:$DoExecute
    }
}

function Get-ZfsSnapshots {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true, Position = 0)]
        $NodeConnection,

        [Parameter(Mandatory = $true, Position = 1)]
        [string]$Dataset,

        [switch]$Recursive,
        [switch]$DoExecute = $true
    )

    if (-not $DoExecute) {
        return @()
    }

    $recFlag = if ($Recursive) { "-r " } else { "" }
    $cmd = "zfs list -H -o name -t snapshot ${recFlag}'$Dataset' 2>/dev/null || true"
    $res = Invoke-RemoteCommand -NodeConnection $NodeConnection -Command $cmd -Label "get-zfs-snapshots" -DoExecute:$DoExecute

    if (-not $res.Success -or [string]::IsNullOrWhiteSpace($res.Output)) {
        return @()
    }

    return @($res.Output -split "`r?`n" | ForEach-Object { $_.Trim() } | Where-Object { -not [string]::IsNullOrWhiteSpace($_) })
}

function New-ZfsSnapshot {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true, Position = 0)]
        $NodeConnection,

        [Parameter(Mandatory = $true, Position = 1)]
        [string]$SnapshotName,

        [switch]$Recursive,
        [switch]$DoExecute = $true
    )

    if (-not $DoExecute) {
        Write-Host "[dry-run] Would take ZFS snapshot '$SnapshotName'"
        return [pscustomobject]@{
            Success  = $true
            ExitCode = 0
            Output   = "dry-run"
        }
    }

    $recFlag = if ($Recursive) { "-r " } else { "" }
    $cmd = "zfs snapshot ${recFlag}'$SnapshotName'"
    return Invoke-RemoteCommand -NodeConnection $NodeConnection -Command $cmd -Label "new-zfs-snapshot" -DoExecute:$DoExecute
}
