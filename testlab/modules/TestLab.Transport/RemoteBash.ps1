<#
.SYNOPSIS
    Remote bash command execution and quoting for TestLab nodes.
.DESCRIPTION
    Provides canonical implementations for converting commands and scripts
    into Base64-safe remote bash invocations, executing remote commands over SSH,
    and handling retries.
#>

function Convert-ToRemoteShellCommand {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $false, Position = 0)]
        [string]$Command
    )

    if ([string]::IsNullOrWhiteSpace($Command)) {
        return $Command
    }

    if ($Command -match '^printf ''%s'' ''[A-Za-z0-9+/=]+'' \| base64 -d \| bash') {
        return $Command
    }

    if ($Command -match '[\r\n\"''\$\(\)\{\}\;\|\&\<\>\`\\]') {
        $normalizedCommand = ($Command -replace "`r`n", "`n").Trim()
        $commandB64 = [Convert]::ToBase64String([System.Text.Encoding]::UTF8.GetBytes($normalizedCommand))
        return "printf '%s' '$commandB64' | base64 -d | bash"
    }

    return $Command
}

function Convert-ToRemoteSingleQuotedArgument {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $false, Position = 0)]
        [string]$Value
    )

    if ($null -eq $Value) {
        return "''"
    }

    return "'{0}'" -f ($Value.Replace("'", "'\''"))
}

function Convert-ToRemoteBashScriptCommand {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true, Position = 0)]
        [Alias('Script')]
        [string]$ScriptContent,

        [Parameter(Mandatory = $false, Position = 1)]
        [string[]]$Arguments = @()
    )

    $normalizedScript = ($ScriptContent -replace "`r`n", "`n").Trim()
    $scriptB64 = [Convert]::ToBase64String([System.Text.Encoding]::UTF8.GetBytes($normalizedScript))
    $quotedArguments = @($Arguments | ForEach-Object { Convert-ToRemoteSingleQuotedArgument -Value ([string]$_) })
    if ($quotedArguments.Count -gt 0) {
        return "printf '%s' '$scriptB64' | base64 -d | bash -s -- $($quotedArguments -join ' ')"
    }

    return "printf '%s' '$scriptB64' | base64 -d | bash"
}

function Invoke-RemoteCommand {
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
        [Alias('ScriptContent', 'Script')]
        [string]$Command,

        [Parameter(Mandatory = $false)]
        [string]$LoggedCommand = $null,

        [Parameter(Mandatory = $false)]
        [string]$Label = "remote",

        [switch]$DoExecute,
        [int]$TimeoutSeconds = 0,
        [switch]$StreamOutput,
        [string]$StreamLabel = $null
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

    # Resolve active connection
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

    # Resolve cached identity file if it exists locally on disk
    $cachedIdentity = $activeIdentity
    if (-not [string]::IsNullOrWhiteSpace($cachedIdentity)) {
        try {
            $maybePath = Resolve-IdentityPath -IdentityPath $cachedIdentity
            if (Test-Path -LiteralPath $maybePath) {
                $cachedIdentity = Get-LocalSshIdentityFile -IdentityPath $cachedIdentity
            }
        } catch {
            # If identity file cannot be resolved or cached, preserve original
        }
    }

    $connForSsh = [pscustomobject]@{
        User         = $activeUser
        Host         = $activeHost
        Port         = $activePort
        IdentityFile = $cachedIdentity
    }

    $remoteCommand = Convert-ToRemoteShellCommand -Command $Command
    $commandForLogs = if ([string]::IsNullOrWhiteSpace($LoggedCommand)) { $Command } else { $LoggedCommand }

    # Windows caps native process command lines at 32k characters (CreateProcess lpCommandLine limit).
    # Upload scripts over SCP if the command string exceeds the threshold.
    if ($remoteCommand.Length -gt 24000) {
        return Invoke-RemoteBashUpload -NodeConnection $connForSsh `
            -BashScript $Command `
            -Label $Label `
            -DoExecute:$DoExecute `
            -TimeoutSeconds $TimeoutSeconds `
            -StreamOutput:$StreamOutput `
            -StreamLabel $StreamLabel
    }

    $sshArgs = Get-SshCommandLineArguments -NodeConnection $connForSsh -Command $remoteCommand

    if (-not $DoExecute) {
        $previewConn = [pscustomobject]@{
            User         = $activeUser
            Host         = $activeHost
            Port         = $activePort
            IdentityFile = $activeIdentity
        }
        $previewArgs = Get-SshCommandLineArguments -NodeConnection $previewConn -Command $commandForLogs
        Write-Host "[dry-run][ssh][$Label] ssh $($previewArgs -join ' ')"
        return [pscustomobject]@{
            Label    = $Label
            Command  = $commandForLogs
            ExitCode = 0
            Output   = "dry-run"
            Success  = $true
        }
    }

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

        if ($TimeoutSeconds -gt 0 -and -not $StreamOutput) {
            $job = Start-Job -ScriptBlock {
                param($args)
                $prevEap = $ErrorActionPreference
                try {
                    $ErrorActionPreference = "Continue"
                    $out = & ssh @args 2>&1
                    return [pscustomobject]@{
                        ExitCode = $LASTEXITCODE
                        RawOutput = @($out | ForEach-Object { [string]$_ })
                    }
                } finally {
                    $ErrorActionPreference = $prevEap
                }
            } -ArgumentList (,$sshArgs)

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
                    Command  = $commandForLogs
                    ExitCode = -1
                    Output   = "Command timed out after $TimeoutSeconds seconds"
                    Success  = $false
                }
            }
        } elseif ($StreamOutput) {
            $streamTag = if (-not [string]::IsNullOrWhiteSpace($StreamLabel)) { $StreamLabel } else { $Label }
            $rawOutput = @(& ssh @sshArgs 2>&1 | ForEach-Object {
                $chunk = [string]$_
                $lines = @($chunk -replace "`r", "" -split "`n")
                foreach ($rawLine in $lines) {
                    $line = $rawLine.Trim()
                    if ([string]::IsNullOrWhiteSpace($line)) {
                        continue
                    }
                    Write-Host "[testlab][$streamTag] $line"
                    $line
                }
            })
            $exitCode = $LASTEXITCODE
        } else {
            $rawOutput = & ssh @sshArgs 2>&1
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
        Command  = $commandForLogs
        ExitCode = $exitCode
        Output   = $output
        Success  = ($exitCode -eq 0)
    }
}

function Invoke-RemoteBashUpload {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true, Position = 0)]
        $NodeConnection,

        [Parameter(Mandatory = $true, Position = 1)]
        [Alias('ScriptContent', 'Script', 'Command')]
        [string]$BashScript,

        [Parameter(Mandatory = $false, Position = 2)]
        [string[]]$Arguments = @(),

        [Parameter(Mandatory = $false)]
        [string]$Label = "remote-bash-upload",

        [switch]$DoExecute,
        [int]$TimeoutSeconds = 0,
        [switch]$StreamOutput,
        [string]$StreamLabel = $null
    )

    $scriptName = "buddybackup-testlab-{0}.sh" -f ([Guid]::NewGuid().ToString("N").Substring(0, 12))
    $remotePath = "/tmp/$scriptName"
    $localPath = Join-Path ([System.IO.Path]::GetTempPath()) $scriptName
    $commandForLogs = if ([string]::IsNullOrWhiteSpace($BashScript)) { "upload $scriptName and run with bash" } else { $BashScript }

    if (-not $DoExecute) {
        $quotedRemotePath = Convert-ToRemoteSingleQuotedArgument -Value $remotePath
        $quotedArguments = @($Arguments | ForEach-Object { Convert-ToRemoteSingleQuotedArgument -Value ([string]$_) })
        $runCmd = "bash $quotedRemotePath"
        if ($quotedArguments.Count -gt 0) {
            $runCmd += " " + ($quotedArguments -join " ")
        }
        Write-Host "[dry-run][upload][$Label] upload $scriptName to /tmp and run: $runCmd"
        return [pscustomobject]@{
            Label    = $Label
            Command  = $commandForLogs
            ExitCode = 0
            Output   = "dry-run"
            Success  = $true
        }
    }

    try {
        $normalizedScript = ($BashScript -replace "`r`n", "`n").Trim() + "`n"
        $utf8NoBom = New-Object System.Text.UTF8Encoding($false)
        [System.IO.File]::WriteAllText($localPath, $normalizedScript, $utf8NoBom)

        $uploadResult = Invoke-RemoteUpload -NodeConnection $NodeConnection `
            -LocalPaths @($localPath) `
            -RemotePath "/tmp" `
            -Label ("{0}-upload" -f $Label) `
            -DoExecute:$DoExecute `
            -TimeoutSeconds $TimeoutSeconds

        if (-not $uploadResult.Success) {
            return [pscustomobject]@{
                Label    = $Label
                Command  = $commandForLogs
                ExitCode = if ($null -ne $uploadResult.ExitCode) { $uploadResult.ExitCode } else { 1 }
                Output   = "Failed to upload $scriptName to remote node.`n$($uploadResult.Output)"
                Success  = $false
            }
        }

        $quotedRemotePath = Convert-ToRemoteSingleQuotedArgument -Value $remotePath
        $quotedArguments = @($Arguments | ForEach-Object { Convert-ToRemoteSingleQuotedArgument -Value ([string]$_) })
        $runCommand = "bash $quotedRemotePath"
        if ($quotedArguments.Count -gt 0) {
            $runCommand += " " + ($quotedArguments -join " ")
        }
        $wrappedCommand = "$runCommand; rc=`$?; rm -f $quotedRemotePath; exit `$rc"

        return Invoke-RemoteCommand -NodeConnection $NodeConnection `
            -Command $wrappedCommand `
            -LoggedCommand $commandForLogs `
            -Label $Label `
            -DoExecute:$DoExecute `
            -TimeoutSeconds $TimeoutSeconds `
            -StreamOutput:$StreamOutput `
            -StreamLabel $StreamLabel
    } finally {
        if (Test-Path -LiteralPath $localPath) {
            Remove-Item -LiteralPath $localPath -Force -ErrorAction SilentlyContinue
        }
    }
}

function Invoke-RemoteBash {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true, Position = 0)]
        $NodeConnection,

        [Parameter(Mandatory = $true, Position = 1)]
        [Alias('ScriptContent', 'Script', 'Command')]
        [string]$BashScript,

        [Parameter(Mandatory = $false, Position = 2)]
        [string[]]$Arguments = @(),

        [Parameter(Mandatory = $false)]
        [string]$Label = "remote-bash",

        [switch]$DoExecute,
        [int]$TimeoutSeconds = 0,
        [switch]$StreamOutput,
        [string]$StreamLabel = $null
    )

    $remoteCommand = Convert-ToRemoteBashScriptCommand -ScriptContent $BashScript -Arguments $Arguments

    # Windows caps native process command lines at 32k characters (CreateProcess lpCommandLine limit).
    # Upload scripts over SCP if the script content or command string exceeds the threshold.
    if ($BashScript.Length -gt 12000 -or $remoteCommand.Length -gt 16000) {
        return Invoke-RemoteBashUpload -NodeConnection $NodeConnection `
            -BashScript $BashScript `
            -Arguments $Arguments `
            -Label $Label `
            -DoExecute:$DoExecute `
            -TimeoutSeconds $TimeoutSeconds `
            -StreamOutput:$StreamOutput `
            -StreamLabel $StreamLabel
    }

    return Invoke-RemoteCommand -NodeConnection $NodeConnection `
        -Command $remoteCommand `
        -LoggedCommand $BashScript `
        -Label $Label `
        -DoExecute:$DoExecute `
        -TimeoutSeconds $TimeoutSeconds `
        -StreamOutput:$StreamOutput `
        -StreamLabel $StreamLabel
}

function New-RetrySummaryResult {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $false, Position = 0)]
        $Result,

        [Parameter(Mandatory = $false, Position = 1)]
        [object[]]$Attempts = @()
    )

    if ($null -eq $Result) {
        return $null
    }

    $attemptList = @($Attempts | Where-Object { $null -ne $_ })
    if ($attemptList.Count -le 1) {
        return $Result
    }

    $Result | Add-Member -NotePropertyName AttemptCount -NotePropertyValue $attemptList.Count -Force
    $Result | Add-Member -NotePropertyName Attempts -NotePropertyValue @($attemptList) -Force
    return $Result
}

function Invoke-RemoteCommandWithRetry {
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
        [string]$Command,

        [Parameter(Mandatory = $false)]
        [string]$LoggedCommand = $null,

        [Parameter(Mandatory = $false)]
        [string]$Label = "remote",

        [Parameter(Mandatory = $false)]
        [int]$MaxAttempts = 4,

        [Parameter(Mandatory = $false)]
        [int]$IntervalSeconds = 5,

        [switch]$DoExecute,
        [int]$TimeoutSeconds = 0,
        [switch]$StreamOutput,
        [string]$StreamLabel = $null
    )

    $attempts = @()
    $result = $null

    for ($attempt = 1; $attempt -le $MaxAttempts; $attempt++) {
        if ($PSCmdlet.ParameterSetName -eq 'Legacy' -or ($null -eq $NodeConnection -and -not [string]::IsNullOrWhiteSpace($TargetHost))) {
            $result = Invoke-RemoteCommand -User $User -TargetHost $TargetHost -Port $Port -IdentityFile $IdentityFile `
                -Command $Command -LoggedCommand $LoggedCommand -Label $Label -DoExecute:$DoExecute `
                -TimeoutSeconds $TimeoutSeconds -StreamOutput:$StreamOutput -StreamLabel $StreamLabel
        } else {
            $result = Invoke-RemoteCommand -NodeConnection $NodeConnection `
                -Command $Command -LoggedCommand $LoggedCommand -Label $Label -DoExecute:$DoExecute `
                -TimeoutSeconds $TimeoutSeconds -StreamOutput:$StreamOutput -StreamLabel $StreamLabel
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

function Get-RemoteFileValue {
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
        [string]$Path,

        [Parameter(Mandatory = $false)]
        [string]$Label = "read-remote-file",

        [switch]$DoExecute
    )

    $conn = if ($PSCmdlet.ParameterSetName -eq 'Legacy' -or ($null -eq $NodeConnection -and -not [string]::IsNullOrWhiteSpace($TargetHost))) {
        [pscustomobject]@{ User = $User; Host = $TargetHost; Port = $Port; IdentityFile = $IdentityFile }
    } else {
        $NodeConnection
    }

    $result = Invoke-RemoteCommand -NodeConnection $conn -Command ("cat {0}" -f $Path) -Label $Label -DoExecute:$DoExecute
    return [pscustomobject]@{
        Result = $result
        Value  = if ($result.Success -and -not [string]::IsNullOrWhiteSpace($result.Output)) { [string]$result.Output.Trim() } else { $null }
    }
}
