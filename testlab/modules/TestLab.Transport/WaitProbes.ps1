<#
.SYNOPSIS
    Readiness probes and waiting helpers for TestLab nodes.
.DESCRIPTION
    Provides adaptive polling loops and readiness probes for SSH availability,
    stability, service settle, and arbitrary remote command checks.
#>

function Wait-UntilReady {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true, Position = 0)]
        [scriptblock]$ProbeScriptBlock,

        [Parameter(Mandatory = $false)]
        [int]$TimeoutSeconds = 60,

        [Parameter(Mandatory = $false)]
        [int]$InitialIntervalSeconds = 1,

        [Parameter(Mandatory = $false)]
        [int]$MaxIntervalSeconds = 3,

        [Parameter(Mandatory = $false)]
        [string]$Description = "readiness",

        [Parameter(Mandatory = $false)]
        [int]$HeartbeatIntervalSeconds = 15,

        [switch]$AsBoolean
    )

    $started = Get-Date
    $attempt = 0
    $lastHeartbeatAt = $started
    $lastResult = $null

    while ((New-TimeSpan -Start $started -End (Get-Date)).TotalSeconds -lt $TimeoutSeconds) {
        $attempt++
        $probeResult = & $ProbeScriptBlock
        $lastResult = $probeResult

        $isSuccess = $false
        if ($probeResult -is [bool]) {
            $isSuccess = $probeResult
        } elseif ($null -ne $probeResult -and ($probeResult.PSObject.Properties['Success'] -ne $null)) {
            $isSuccess = [bool]$probeResult.Success
        } elseif ($null -ne $probeResult -and ($probeResult.PSObject.Properties['ExitCode'] -ne $null)) {
            $isSuccess = ($probeResult.ExitCode -eq 0)
        } elseif ($null -ne $probeResult) {
            $isSuccess = [bool]$probeResult
        }

        if ($isSuccess) {
            $elapsedSeconds = [int](New-TimeSpan -Start $started -End (Get-Date)).TotalSeconds
            if ($AsBoolean) { return $true }
            return [pscustomobject]@{
                Success        = $true
                ElapsedSeconds = $elapsedSeconds
                Attempts       = $attempt
                Result         = $probeResult
            }
        }

        # Adaptive backoff calculation (Section 7.4):
        # 1s for first 5 attempts, then 2s, max 3s
        $currentInterval = if ($attempt -le 5) {
            $InitialIntervalSeconds
        } elseif ($attempt -le 10) {
            [Math]::Min($InitialIntervalSeconds + 1, $MaxIntervalSeconds)
        } else {
            $MaxIntervalSeconds
        }

        $now = Get-Date
        if ((New-TimeSpan -Start $lastHeartbeatAt -End $now).TotalSeconds -ge $HeartbeatIntervalSeconds) {
            $elapsedSoFar = [int](New-TimeSpan -Start $started -End $now).TotalSeconds
            Write-Host ("[testlab] Still waiting for {0} ({1}/{2}s)" -f $Description, $elapsedSoFar, $TimeoutSeconds)
            $lastHeartbeatAt = $now
        }

        $remainingSeconds = $TimeoutSeconds - (New-TimeSpan -Start $started -End (Get-Date)).TotalSeconds
        if ($remainingSeconds -le 0) {
            break
        }

        $sleepDuration = [Math]::Min([double]$currentInterval, [double]$remainingSeconds)
        if ($sleepDuration -gt 0) {
            Start-Sleep -Milliseconds ([int]($sleepDuration * 1000))
        }
    }

    $elapsedSeconds = [int](New-TimeSpan -Start $started -End (Get-Date)).TotalSeconds
    if ($AsBoolean) { return $false }
    return [pscustomobject]@{
        Success        = $false
        ElapsedSeconds = $elapsedSeconds
        Attempts       = $attempt
        Result         = $lastResult
    }
}

function Wait-SshReady {
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

        [Parameter(Mandatory = $false)]
        [int]$TimeoutSeconds = 60,

        [Parameter(Mandatory = $false)]
        [int]$IntervalSeconds = 1,

        [switch]$DoExecute = $true
    )

    $conn = if ($PSCmdlet.ParameterSetName -eq 'Legacy' -or ($null -eq $NodeConnection -and -not [string]::IsNullOrWhiteSpace($TargetHost))) {
        [pscustomobject]@{ User = $User; Host = $TargetHost; Port = $Port; IdentityFile = $IdentityFile }
    } else {
        $NodeConnection
    }

    $targetLabel = "{0}:{1}" -f $conn.Host, $conn.Port
    Write-Host "[testlab] Waiting for SSH readiness on $targetLabel"

    $probeBlock = {
        $probe = Invoke-RemoteCommand -NodeConnection $conn -Command "echo ready" -Label "ssh-ready-probe" -DoExecute:$DoExecute
        return $probe.Success
    }

    $maxInterval = [Math]::Max($IntervalSeconds, 3)
    $res = Wait-UntilReady -ProbeScriptBlock $probeBlock -TimeoutSeconds $TimeoutSeconds -InitialIntervalSeconds $IntervalSeconds -MaxIntervalSeconds $maxInterval -Description "SSH readiness on $targetLabel"

    if ($res.Success) {
        Write-Host "[testlab] SSH ready on $targetLabel after $($res.ElapsedSeconds)s"
        return $true
    }

    Write-Warning "SSH did not become ready on $targetLabel within $TimeoutSeconds seconds"
    return $false
}

function Wait-SshUnavailable {
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

        [Parameter(Mandatory = $false)]
        [int]$TimeoutSeconds = 60,

        [Parameter(Mandatory = $false)]
        [int]$IntervalSeconds = 1,

        [switch]$DoExecute = $true
    )

    $conn = if ($PSCmdlet.ParameterSetName -eq 'Legacy' -or ($null -eq $NodeConnection -and -not [string]::IsNullOrWhiteSpace($TargetHost))) {
        [pscustomobject]@{ User = $User; Host = $TargetHost; Port = $Port; IdentityFile = $IdentityFile }
    } else {
        $NodeConnection
    }

    $targetLabel = "{0}:{1}" -f $conn.Host, $conn.Port
    Write-Host "[testlab] Waiting for SSH to drop on $targetLabel"

    $probeBlock = {
        $probe = Invoke-RemoteCommand -NodeConnection $conn -Command "echo ready" -Label "ssh-unavailable-probe" -DoExecute:$DoExecute
        return (-not $probe.Success)
    }

    $maxInterval = [Math]::Max($IntervalSeconds, 2)
    $res = Wait-UntilReady -ProbeScriptBlock $probeBlock -TimeoutSeconds $TimeoutSeconds -InitialIntervalSeconds $IntervalSeconds -MaxIntervalSeconds $maxInterval -Description "SSH to drop on $targetLabel"

    if ($res.Success) {
        Write-Host "[testlab] SSH became unavailable on $targetLabel after $($res.ElapsedSeconds)s"
        return $true
    }

    Write-Warning "SSH never dropped on $targetLabel within $TimeoutSeconds seconds"
    return $false
}

function Wait-SshStable {
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

        [Parameter(Mandatory = $false)]
        [Alias('RequiredSuccesses')]
        [int]$ConsecutiveSuccesses = 3,

        [Parameter(Mandatory = $false)]
        [int]$IntervalSeconds = 2,

        [Parameter(Mandatory = $false)]
        [int]$TimeoutSeconds = 60,

        [switch]$DoExecute = $true
    )

    $conn = if ($PSCmdlet.ParameterSetName -eq 'Legacy' -or ($null -eq $NodeConnection -and -not [string]::IsNullOrWhiteSpace($TargetHost))) {
        [pscustomobject]@{ User = $User; Host = $TargetHost; Port = $Port; IdentityFile = $IdentityFile }
    } else {
        $NodeConnection
    }

    $started = Get-Date
    $successCount = 0
    $targetLabel = "{0}:{1}" -f $conn.Host, $conn.Port
    Write-Host "[testlab] Verifying SSH stability on $targetLabel"
    $lastHeartbeatAt = $started

    while ((New-TimeSpan -Start $started -End (Get-Date)).TotalSeconds -lt $TimeoutSeconds) {
        $probe = Invoke-RemoteCommand -NodeConnection $conn -Command "echo ready" -Label "ssh-stability-probe" -DoExecute:$DoExecute
        if ($probe.Success) {
            $successCount += 1
            if ($successCount -ge $ConsecutiveSuccesses) {
                $elapsedSeconds = [int](New-TimeSpan -Start $started -End (Get-Date)).TotalSeconds
                Write-Host "[testlab] SSH remained stable on $targetLabel after ${elapsedSeconds}s"
                return $true
            }
        } else {
            $successCount = 0
        }

        $now = Get-Date
        if ((New-TimeSpan -Start $lastHeartbeatAt -End $now).TotalSeconds -ge 15) {
            $elapsedSoFar = [int](New-TimeSpan -Start $started -End $now).TotalSeconds
            Write-Host ("[testlab] Still checking SSH stability on {0} ({1}/{2}s)" -f $targetLabel, $elapsedSoFar, $TimeoutSeconds)
            $lastHeartbeatAt = $now
        }

        $sleepSecs = if ($IntervalSeconds -gt 0) { $IntervalSeconds } else { 2 }
        $remaining = $TimeoutSeconds - (New-TimeSpan -Start $started -End (Get-Date)).TotalSeconds
        if ($remaining -le 0) {
            break
        }
        $sleepActual = [Math]::Min([double]$sleepSecs, [double]$remaining)
        if ($sleepActual -gt 0) {
            Start-Sleep -Milliseconds ([int]($sleepActual * 1000))
        }
    }

    Write-Warning "SSH did not remain stable on $targetLabel within $TimeoutSeconds seconds"
    return $false
}

function Wait-ForRemoteSuccess {
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
        [string]$Label = "remote-check",

        [Parameter(Mandatory = $false)]
        [int]$TimeoutSeconds = 60,

        [Parameter(Mandatory = $false)]
        [int]$IntervalSeconds = 3,

        [switch]$DoExecute = $true
    )

    $conn = if ($PSCmdlet.ParameterSetName -eq 'Legacy' -or ($null -eq $NodeConnection -and -not [string]::IsNullOrWhiteSpace($TargetHost))) {
        [pscustomobject]@{ User = $User; Host = $TargetHost; Port = $Port; IdentityFile = $IdentityFile }
    } else {
        $NodeConnection
    }

    $started = Get-Date
    $lastResult = $null
    $targetLabel = "{0}:{1}" -f $conn.Host, $conn.Port
    Write-Host "[testlab] Waiting for remote check '$Label' on $targetLabel"
    $lastHeartbeatAt = $started
    $attempt = 0

    while ((New-TimeSpan -Start $started -End (Get-Date)).TotalSeconds -lt $TimeoutSeconds) {
        $attempt++
        $lastResult = Invoke-RemoteCommand -NodeConnection $conn -Command $Command -LoggedCommand $LoggedCommand -Label $Label -DoExecute:$DoExecute
        if ($lastResult.Success) {
            $elapsedSeconds = [int](New-TimeSpan -Start $started -End (Get-Date)).TotalSeconds
            Write-Host "[testlab] Remote check '$Label' passed on $targetLabel after ${elapsedSeconds}s"
            return [pscustomobject]@{
                Success = $true
                Result  = $lastResult
            }
        }

        $now = Get-Date
        if ((New-TimeSpan -Start $lastHeartbeatAt -End $now).TotalSeconds -ge 15) {
            $elapsedSoFar = [int](New-TimeSpan -Start $started -End $now).TotalSeconds
            Write-Host ("[testlab] Still waiting for remote check '{0}' on {1} ({2}/{3}s)" -f $Label, $targetLabel, $elapsedSoFar, $TimeoutSeconds)
            $lastHeartbeatAt = $now
        }

        $currentInterval = if ($PSBoundParameters.ContainsKey('IntervalSeconds')) {
            $IntervalSeconds
        } else {
            if ($attempt -le 5) { 1 } elseif ($attempt -le 10) { 2 } else { 3 }
        }

        $remaining = $TimeoutSeconds - (New-TimeSpan -Start $started -End (Get-Date)).TotalSeconds
        if ($remaining -le 0) {
            break
        }
        $sleepActual = [Math]::Min([double]$currentInterval, [double]$remaining)
        if ($sleepActual -gt 0) {
            Start-Sleep -Milliseconds ([int]($sleepActual * 1000))
        }
    }

    $lastOutputText = if ($lastResult -and $null -ne $lastResult.Output) {
        ([string]$lastResult.Output).Trim()
    } else {
        ""
    }

    if ([string]::IsNullOrWhiteSpace($lastOutputText)) {
        Write-Warning "Remote check '$Label' did not succeed on $targetLabel within $TimeoutSeconds seconds"
    } else {
        Write-Warning "Remote check '$Label' did not succeed on $targetLabel within $TimeoutSeconds seconds. Last output: $lastOutputText"
    }

    return [pscustomobject]@{
        Success = $false
        Result  = $lastResult
    }
}
