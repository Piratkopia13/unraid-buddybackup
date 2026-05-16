param(
    [string]$LabConfig = "testlab/config/lab.local.json",
    [string]$MatrixConfig = "testlab/config/matrix.small.json",
    [switch]$Execute,
    [switch]$SkipArtifacts
)

$ErrorActionPreference = "Stop"

function Require-File {
    param([string]$Path)
    if (-not (Test-Path $Path)) {
        throw "Missing file: $Path"
    }
}

function Get-Json {
    param([string]$Path)
    return Get-Content -Raw -Path $Path | ConvertFrom-Json
}

function Ensure-Dir {
    param([string]$Path)
    if (-not (Test-Path $Path)) {
        New-Item -ItemType Directory -Path $Path | Out-Null
    }
}

function Resolve-IdentityPath {
    param([string]$IdentityFile)

    if (-not $IdentityFile) {
        return $IdentityFile
    }

    if ($IdentityFile.StartsWith("~/")) {
        return Join-Path -Path $HOME -ChildPath $IdentityFile.Substring(2)
    }

    return $IdentityFile
}

function Invoke-RemoteCommand {
    param(
        [string]$User,
        [string]$TargetHost,
        [int]$Port,
        [string]$IdentityFile,
        [string]$Command,
        [string]$Label = "remote",
        [switch]$DoExecute
    )

    $resolvedIdentity = Resolve-IdentityPath -IdentityFile $IdentityFile
    $sshArgs = @("-o", "BatchMode=yes", "-p", "$Port")
    if ($resolvedIdentity) {
        $sshArgs += @("-i", $resolvedIdentity)
    }
    $sshArgs += @("$User@$TargetHost", $Command)

    if ($DoExecute) {
        $output = (& ssh @sshArgs 2>&1 | Out-String).Trim()
        $exitCode = $LASTEXITCODE
        return [pscustomobject]@{
            Label = $Label
            Command = $Command
            ExitCode = $exitCode
            Output = $output
            Success = ($exitCode -eq 0)
        }
    } else {
        Write-Host "[dry-run][ssh][$Label] ssh $($sshArgs -join ' ')"
        return [pscustomobject]@{
            Label = $Label
            Command = $Command
            ExitCode = 0
            Output = "dry-run"
            Success = $true
        }
    }
}

function Wait-SshReady {
    param(
        [string]$User,
        [string]$TargetHost,
        [int]$Port,
        [string]$IdentityFile,
        [int]$TimeoutSeconds
    )

    $started = Get-Date
    while ((New-TimeSpan -Start $started -End (Get-Date)).TotalSeconds -lt $TimeoutSeconds) {
        $probe = Invoke-RemoteCommand -User $User -TargetHost $TargetHost -Port $Port -IdentityFile $IdentityFile -Command "echo ready" -Label "ssh-ready-probe" -DoExecute
        if ($probe.Success) {
            return $true
        }
        Start-Sleep -Seconds 5
    }

    return $false
}

function Install-Plugin {
    param(
        $Lab,
        [string]$TargetHost,
        [string]$Version,
        [switch]$DoExecute
    )

    $url = $Lab.plugin.plgUrlTemplate.Replace("{version}", $Version)
    $cmd = "plugin install $url"
    Invoke-RemoteCommand -User $Lab.ssh.user -TargetHost $TargetHost -Port $Lab.ssh.port -IdentityFile $Lab.ssh.identityFile -Command $cmd -Label "plugin-install" -DoExecute:$DoExecute
}

function Collect-NodeArtifacts {
    param(
        $Lab,
        [string]$NodeName,
        [string]$TargetHost,
        [string]$CellDir,
        [switch]$DoExecute
    )

    $nodeDir = Join-Path -Path $CellDir -ChildPath $NodeName
    Ensure-Dir -Path $nodeDir

    $commands = @(
        @{ Name = "plugin-list"; Cmd = "plugin list" },
        @{ Name = "buddybackup-log"; Cmd = "test -f /var/log/buddybackup.log && cat /var/log/buddybackup.log || echo '(missing /var/log/buddybackup.log)'" },
        @{ Name = "buddybackup-cfg"; Cmd = "test -f /boot/config/plugins/buddybackup/buddybackup.cfg && cat /boot/config/plugins/buddybackup/buddybackup.cfg || echo '(missing buddybackup.cfg)'" },
        @{ Name = "backups-cfg"; Cmd = "test -f /boot/config/plugins/buddybackup/backups.cfg && cat /boot/config/plugins/buddybackup/backups.cfg || echo '(missing backups.cfg)'" },
        @{ Name = "snapshots-cfg"; Cmd = "test -f /boot/config/plugins/buddybackup/snapshots.cfg && cat /boot/config/plugins/buddybackup/snapshots.cfg || echo '(missing snapshots.cfg)'" },
        @{ Name = "sanoid-cfg"; Cmd = "test -f /boot/config/plugins/buddybackup/sanoid.conf && cat /boot/config/plugins/buddybackup/sanoid.conf || echo '(missing sanoid.conf)'" },
        @{ Name = "uname"; Cmd = "uname -a" },
        @{ Name = "uptime"; Cmd = "uptime" }
    )

    foreach ($item in $commands) {
        $result = Invoke-RemoteCommand -User $Lab.ssh.user -TargetHost $TargetHost -Port $Lab.ssh.port -IdentityFile $Lab.ssh.identityFile -Command $item.Cmd -Label $item.Name -DoExecute:$DoExecute
        $artifactPath = Join-Path -Path $nodeDir -ChildPath ("{0}.txt" -f $item.Name)
        $content = @(
            "label=$($result.Label)",
            "exitCode=$($result.ExitCode)",
            "command=$($result.Command)",
            "output:",
            $result.Output
        ) -join [Environment]::NewLine
        Set-Content -Path $artifactPath -Value $content
    }
}

function Run-Scenario {
    param(
        [string]$Scenario,
        $Lab,
        $Cell,
        [string]$CellDir,
        [switch]$DoExecute
    )

    $sender = $Lab.nodes.sender.host
    $receiver = $Lab.nodes.receiver.host

    $results = @()

    switch ($Scenario) {
        "fresh-install" {
            $results += Install-Plugin -Lab $Lab -TargetHost $sender -Version $Cell.sender.plugin -DoExecute:$DoExecute
            $results += Install-Plugin -Lab $Lab -TargetHost $receiver -Version $Cell.receiver.plugin -DoExecute:$DoExecute
        }
        "post-reboot" {
            $results += Invoke-RemoteCommand -User $Lab.ssh.user -TargetHost $sender -Port $Lab.ssh.port -IdentityFile $Lab.ssh.identityFile -Command "reboot" -Label "sender-reboot" -DoExecute:$DoExecute
            $results += Invoke-RemoteCommand -User $Lab.ssh.user -TargetHost $receiver -Port $Lab.ssh.port -IdentityFile $Lab.ssh.identityFile -Command "reboot" -Label "receiver-reboot" -DoExecute:$DoExecute

            if ($DoExecute) {
                $timeout = 300
                if ($Lab.timeouts -and $Lab.timeouts.sshReadySeconds) {
                    $timeout = [int]$Lab.timeouts.sshReadySeconds
                }

                if (-not (Wait-SshReady -User $Lab.ssh.user -TargetHost $sender -Port $Lab.ssh.port -IdentityFile $Lab.ssh.identityFile -TimeoutSeconds $timeout)) {
                    throw "Sender did not return after reboot in $timeout seconds"
                }
                if (-not (Wait-SshReady -User $Lab.ssh.user -TargetHost $receiver -Port $Lab.ssh.port -IdentityFile $Lab.ssh.identityFile -TimeoutSeconds $timeout)) {
                    throw "Receiver did not return after reboot in $timeout seconds"
                }
            }

            $results += Invoke-RemoteCommand -User $Lab.ssh.user -TargetHost $sender -Port $Lab.ssh.port -IdentityFile $Lab.ssh.identityFile -Command "plugin list | grep buddybackup" -Label "sender-plugin-check" -DoExecute:$DoExecute
            $results += Invoke-RemoteCommand -User $Lab.ssh.user -TargetHost $receiver -Port $Lab.ssh.port -IdentityFile $Lab.ssh.identityFile -Command "plugin list | grep buddybackup" -Label "receiver-plugin-check" -DoExecute:$DoExecute
        }
        "backup-smoke" {
            $cmd = "/usr/local/emhttp/plugins/buddybackup/scripts/rc.buddybackup.php send_backup smoke"
            $results += Invoke-RemoteCommand -User $Lab.ssh.user -TargetHost $sender -Port $Lab.ssh.port -IdentityFile $Lab.ssh.identityFile -Command $cmd -Label "backup-smoke" -DoExecute:$DoExecute
        }
        "restore-smoke" {
            $cmd = "/usr/local/emhttp/plugins/buddybackup/scripts/rc.buddybackup.php restore_snapshot smoke restore_last"
            $results += Invoke-RemoteCommand -User $Lab.ssh.user -TargetHost $sender -Port $Lab.ssh.port -IdentityFile $Lab.ssh.identityFile -Command $cmd -Label "restore-smoke" -DoExecute:$DoExecute
        }
        default {
            throw "Unknown scenario: $Scenario"
        }
    }

    $scenarioPath = Join-Path -Path $CellDir -ChildPath ("scenario-{0}.json" -f $Scenario)
    $results | ConvertTo-Json -Depth 8 | Set-Content -Path $scenarioPath

    $failed = @($results | Where-Object { -not $_.Success })
    if ($failed.Count -gt 0) {
        $labels = @($failed | ForEach-Object { $_.Label }) -join ","
        return [pscustomobject]@{
            Scenario = $Scenario
            Success = $false
            Error = "Failed command labels: $labels"
        }
    }

    return [pscustomobject]@{
        Scenario = $Scenario
        Success = $true
        Error = $null
    }
}

Require-File $LabConfig
Require-File $MatrixConfig

$lab = Get-Json -Path $LabConfig
$matrix = Get-Json -Path $MatrixConfig

$runId = Get-Date -Format "yyyyMMdd-HHmmss"
$artifactsRoot = $lab.artifactsRoot
if (-not $artifactsRoot) {
    $artifactsRoot = ".testlab/artifacts"
}
Ensure-Dir -Path $artifactsRoot
$runDir = Join-Path $artifactsRoot $runId
Ensure-Dir -Path $runDir

$result = @()

foreach ($cell in $matrix.cells) {
    Write-Host "[testlab] Running cell $($cell.id) lifecycle=$($cell.lifecycle)"
    $status = "pass"
    $errors = @()
    $scenarioResults = @()
    $cellDir = Join-Path -Path $runDir -ChildPath $cell.id
    Ensure-Dir -Path $cellDir

    foreach ($scenario in $cell.scenarios) {
        try {
            $scenarioRun = Run-Scenario -Scenario $scenario -Lab $lab -Cell $cell -CellDir $cellDir -DoExecute:$Execute
            $scenarioResults += $scenarioRun
            if (-not $scenarioRun.Success) {
                $status = "fail"
                $errors += "Scenario '$scenario' failed: $($scenarioRun.Error)"
            }
        } catch {
            $status = "fail"
            $errors += "Scenario '$scenario' failed: $($_.Exception.Message)"
            $scenarioResults += [pscustomobject]@{
                Scenario = $scenario
                Success = $false
                Error = $_.Exception.Message
            }
        }
    }

    if (-not $SkipArtifacts) {
        try {
            Collect-NodeArtifacts -Lab $lab -NodeName "sender" -TargetHost $lab.nodes.sender.host -CellDir $cellDir -DoExecute:$Execute
            Collect-NodeArtifacts -Lab $lab -NodeName "receiver" -TargetHost $lab.nodes.receiver.host -CellDir $cellDir -DoExecute:$Execute
        } catch {
            $status = "fail"
            $errors += "Artifact collection failed: $($_.Exception.Message)"
        }
    }

    $result += [pscustomobject]@{
        runId = $runId
        cellId = $cell.id
        senderUnraid = $cell.sender.unraid
        receiverUnraid = $cell.receiver.unraid
        senderPlugin = $cell.sender.plugin
        receiverPlugin = $cell.receiver.plugin
        lifecycle = $cell.lifecycle
        status = $status
        errors = $errors
        scenarioResults = $scenarioResults
        artifactDir = $cellDir
        executeMode = [bool]$Execute
    }
}

$outPath = Join-Path $runDir "results.json"
$result | ConvertTo-Json -Depth 8 | Set-Content -Path $outPath
Write-Host "[testlab] Results written to $outPath"
