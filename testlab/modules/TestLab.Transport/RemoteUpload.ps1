<#
.SYNOPSIS
    Remote file upload over SCP for TestLab nodes.
.DESCRIPTION
    Provides canonical implementations for uploading files to remote nodes via SCP,
    ensuring remote target directories exist, and handling retries.
#>

function Invoke-RemoteUpload {
    [CmdletBinding(DefaultParameterSetName = 'ByNode')]
    param(
        [Parameter(ParameterSetName = 'ByNode', Mandatory = $false, Position = 0)]
        $NodeConnection,

        [Parameter(ParameterSetName = 'Legacy')]
        [string]$User,

        [Parameter(ParameterSetName = 'Legacy')]
        [string]$TargetHost,

        [Parameter(ParameterSetName = 'Legacy')]
        [int]$Port = 22,

        [Parameter(ParameterSetName = 'Legacy')]
        [string]$IdentityFile,

        [Parameter(Mandatory = $true, Position = 1)]
        [string[]]$LocalPaths,

        [Parameter(Mandatory = $true, Position = 2)]
        [Alias('RemoteDirectory')]
        [string]$RemotePath,

        [Parameter(Mandatory = $false)]
        [string]$Label = "upload",

        [switch]$DoExecute,
        [int]$TimeoutSeconds = 0
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

    $activeUser = $User
    $activeHost = $TargetHost
    $activePort = $Port
    $activeIdentity = $IdentityFile

    if ($null -ne $NodeConnection) {
        $nodeUser = & $getVal $NodeConnection "User"
        if ([string]::IsNullOrWhiteSpace($nodeUser)) { $nodeUser = & $getVal $NodeConnection "user" }
        if (-not [string]::IsNullOrWhiteSpace($nodeUser)) { $activeUser = $nodeUser }

        $nodeHost = & $getVal $NodeConnection "Host"
        if ([string]::IsNullOrWhiteSpace($nodeHost)) { $nodeHost = & $getVal $NodeConnection "host" }
        if (-not [string]::IsNullOrWhiteSpace($nodeHost)) { $activeHost = $nodeHost }

        $nodePort = & $getVal $NodeConnection "Port"
        if ($null -eq $nodePort) { $nodePort = & $getVal $NodeConnection "port" }
        if ($null -ne $nodePort) { $activePort = [int]$nodePort }

        $nodeIdentity = & $getVal $NodeConnection "IdentityFile"
        if ([string]::IsNullOrWhiteSpace($nodeIdentity)) { $nodeIdentity = & $getVal $NodeConnection "identityFile" }
        if (-not [string]::IsNullOrWhiteSpace($nodeIdentity)) { $activeIdentity = $nodeIdentity }
    }

    if ([string]::IsNullOrWhiteSpace($activeUser)) { $activeUser = "root" }
    if ([string]::IsNullOrWhiteSpace($activeHost)) { $activeHost = "127.0.0.1" }
    if (-not $activePort) { $activePort = 22 }

    $pathsToUpload = @($LocalPaths | Where-Object { -not [string]::IsNullOrWhiteSpace($_) })
    if ($pathsToUpload.Count -eq 0) {
        throw "Remote upload '$Label' was called without any local paths."
    }

    $cachedIdentity = $activeIdentity
    if (-not [string]::IsNullOrWhiteSpace($cachedIdentity)) {
        try {
            $maybePath = Resolve-IdentityPath -IdentityPath $cachedIdentity
            if (Test-Path -LiteralPath $maybePath) {
                $cachedIdentity = Get-LocalSshIdentityFile -IdentityPath $cachedIdentity
            }
        } catch {
            # Preserve original if resolution fails
        }
    }

    $connForScp = [pscustomobject]@{
        User         = $activeUser
        Host         = $activeHost
        Port         = $activePort
        IdentityFile = $cachedIdentity
    }

    if (-not $DoExecute) {
        $previewConn = [pscustomobject]@{
            User         = $activeUser
            Host         = $activeHost
            Port         = $activePort
            IdentityFile = $activeIdentity
        }
        $previewArgs = Get-ScpCommandLineArguments -NodeConnection $previewConn -LocalPaths $pathsToUpload -RemotePath $RemotePath
        Write-Host "[dry-run][upload][$Label] scp $($previewArgs -join ' ')"
        return [pscustomobject]@{
            Label    = $Label
            Command  = "scp upload"
            ExitCode = 0
            Output   = "dry-run"
            Success  = $true
        }
    }

    # Ensure remote directory exists prior to uploading
    $ensureDirResult = Invoke-RemoteCommand -NodeConnection $connForScp -Command ("mkdir -p {0}" -f $RemotePath) -Label ("{0}-mkdir" -f $Label) -DoExecute
    if (-not $ensureDirResult.Success) {
        return [pscustomobject]@{
            Label    = $Label
            Command  = "scp upload"
            ExitCode = $ensureDirResult.ExitCode
            Output   = $ensureDirResult.Output
            Success  = $false
        }
    }

    $scpArgs = Get-ScpCommandLineArguments -NodeConnection $connForScp -LocalPaths $pathsToUpload -RemotePath $RemotePath

    $previousErrorActionPreference = $ErrorActionPreference
    $hadNativeCommandPreference = Test-Path Variable:\PSNativeCommandUseErrorActionPreference
    if ($hadNativeCommandPreference) {
        $previousNativeCommandUseErrorActionPreference = $PSNativeCommandUseErrorActionPreference
    }

    try {
        $ErrorActionPreference = "Continue"
        if ($hadNativeCommandPreference) {
            $PSNativeCommandUseErrorActionPreference = $false
        }

        if ($TimeoutSeconds -gt 0) {
            $job = Start-Job -ScriptBlock {
                param($args)
                $prevEap = $ErrorActionPreference
                try {
                    $ErrorActionPreference = "Continue"
                    $out = & scp @args 2>&1
                    return [pscustomobject]@{
                        ExitCode = $LASTEXITCODE
                        RawOutput = @($out | ForEach-Object { [string]$_ })
                    }
                } finally {
                    $ErrorActionPreference = $prevEap
                }
            } -ArgumentList (,$scpArgs)

            if (Wait-Job -Job $job -Timeout $TimeoutSeconds) {
                $jobResult = Receive-Job -Job $job
                Remove-Job -Job $job -Force
                $exitCode = if ($jobResult -and $null -ne $jobResult.ExitCode) { $jobResult.ExitCode } else { 0 }
                $rawOutput = if ($jobResult -and $null -ne $jobResult.RawOutput) { $jobResult.RawOutput } else { @() }
            } else {
                Stop-Job -Job $job
                Remove-Job -Job $job -Force
                return [pscustomobject]@{
                    Label    = $Label
                    Command  = "scp upload"
                    ExitCode = -1
                    Output   = "Upload timed out after $TimeoutSeconds seconds"
                    Success  = $false
                }
            }
        } else {
            $rawOutput = & scp @scpArgs 2>&1
            $exitCode = $LASTEXITCODE
        }
    } finally {
        $ErrorActionPreference = $previousErrorActionPreference
        if ($hadNativeCommandPreference) {
            $PSNativeCommandUseErrorActionPreference = $previousNativeCommandUseErrorActionPreference
        }
    }

    $output = (@($rawOutput | ForEach-Object { [string]$_ }) -join [Environment]::NewLine).Trim()
    return [pscustomobject]@{
        Label    = $Label
        Command  = "scp upload"
        ExitCode = $exitCode
        Output   = $output
        Success  = ($exitCode -eq 0)
    }
}

function Invoke-RemoteUploadWithRetry {
    [CmdletBinding(DefaultParameterSetName = 'ByNode')]
    param(
        [Parameter(ParameterSetName = 'ByNode', Mandatory = $false, Position = 0)]
        $NodeConnection,

        [Parameter(ParameterSetName = 'Legacy')]
        [string]$User,

        [Parameter(ParameterSetName = 'Legacy')]
        [string]$TargetHost,

        [Parameter(ParameterSetName = 'Legacy')]
        [int]$Port = 22,

        [Parameter(ParameterSetName = 'Legacy')]
        [string]$IdentityFile,

        [Parameter(Mandatory = $true, Position = 1)]
        [string[]]$LocalPaths,

        [Parameter(Mandatory = $true, Position = 2)]
        [Alias('RemoteDirectory')]
        [string]$RemotePath,

        [Parameter(Mandatory = $false)]
        [string]$Label = "upload",

        [Parameter(Mandatory = $false)]
        [int]$MaxAttempts = 6,

        [Parameter(Mandatory = $false)]
        [int]$IntervalSeconds = 5,

        [switch]$DoExecute,
        [int]$TimeoutSeconds = 0
    )

    $attempts = @()
    $result = $null

    for ($attempt = 1; $attempt -le $MaxAttempts; $attempt++) {
        if ($PSCmdlet.ParameterSetName -eq 'Legacy' -or ($null -eq $NodeConnection -and -not [string]::IsNullOrWhiteSpace($TargetHost))) {
            $result = Invoke-RemoteUpload -User $User -TargetHost $TargetHost -Port $Port -IdentityFile $IdentityFile `
                -LocalPaths $LocalPaths -RemotePath $RemotePath -Label $Label -DoExecute:$DoExecute -TimeoutSeconds $TimeoutSeconds
        } else {
            $result = Invoke-RemoteUpload -NodeConnection $NodeConnection `
                -LocalPaths $LocalPaths -RemotePath $RemotePath -Label $Label -DoExecute:$DoExecute -TimeoutSeconds $TimeoutSeconds
        }

        $attempts += $result
        if ($result.Success) {
            break
        }

        if ($DoExecute -and $attempt -lt $MaxAttempts) {
            Start-Sleep -Seconds $IntervalSeconds
        }
    }

    return New-RetrySummaryResult -Result $result -Attempts $attempts
}
