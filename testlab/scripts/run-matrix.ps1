param(
    [string]$LabConfig = "testlab/config/lab.local.json",
    [string]$MatrixConfig = "testlab/config/matrix.small.json",
    [switch]$Execute
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

function Invoke-Ssh {
    param(
        [string]$User,
        [string]$TargetHost,
        [int]$Port,
        [string]$IdentityFile,
        [string]$Command,
        [switch]$DoExecute
    )

    $sshArgs = @("-p", "$Port", "-i", $IdentityFile, "$User@$TargetHost", $Command)
    if ($DoExecute) {
        & ssh @sshArgs
    } else {
        Write-Host "[dry-run][ssh] ssh $($sshArgs -join ' ')"
    }
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
    Invoke-Ssh -User $Lab.ssh.user -TargetHost $TargetHost -Port $Lab.ssh.port -IdentityFile $Lab.ssh.identityFile -Command $cmd -DoExecute:$DoExecute
}

function Run-Scenario {
    param(
        [string]$Scenario,
        $Lab,
        $Cell,
        [switch]$DoExecute
    )

    $sender = $Lab.nodes.sender.host
    $receiver = $Lab.nodes.receiver.host

    switch ($Scenario) {
        "fresh-install" {
            Install-Plugin -Lab $Lab -TargetHost $sender -Version $Cell.sender.plugin -DoExecute:$DoExecute
            Install-Plugin -Lab $Lab -TargetHost $receiver -Version $Cell.receiver.plugin -DoExecute:$DoExecute
        }
        "post-reboot" {
            Invoke-Ssh -User $Lab.ssh.user -TargetHost $sender -Port $Lab.ssh.port -IdentityFile $Lab.ssh.identityFile -Command "reboot" -DoExecute:$DoExecute
            Invoke-Ssh -User $Lab.ssh.user -TargetHost $receiver -Port $Lab.ssh.port -IdentityFile $Lab.ssh.identityFile -Command "reboot" -DoExecute:$DoExecute
        }
        "backup-smoke" {
            $cmd = "/usr/local/emhttp/plugins/buddybackup/scripts/rc.buddybackup.php send_backup smoke"
            Invoke-Ssh -User $Lab.ssh.user -TargetHost $sender -Port $Lab.ssh.port -IdentityFile $Lab.ssh.identityFile -Command $cmd -DoExecute:$DoExecute
        }
        "restore-smoke" {
            $cmd = "/usr/local/emhttp/plugins/buddybackup/scripts/rc.buddybackup.php restore_snapshot smoke restore_last"
            Invoke-Ssh -User $Lab.ssh.user -TargetHost $sender -Port $Lab.ssh.port -IdentityFile $Lab.ssh.identityFile -Command $cmd -DoExecute:$DoExecute
        }
        default {
            throw "Unknown scenario: $Scenario"
        }
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

    foreach ($scenario in $cell.scenarios) {
        try {
            Run-Scenario -Scenario $scenario -Lab $lab -Cell $cell -DoExecute:$Execute
        } catch {
            $status = "fail"
            $errors += "Scenario '$scenario' failed: $($_.Exception.Message)"
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
        executeMode = [bool]$Execute
    }
}

$outPath = Join-Path $runDir "results.json"
$result | ConvertTo-Json -Depth 8 | Set-Content -Path $outPath
Write-Host "[testlab] Results written to $outPath"
