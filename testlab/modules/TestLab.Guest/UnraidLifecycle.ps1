<#
.SYNOPSIS
    Unraid guest lifecycle management for BuddyBackup TestLab.
.DESCRIPTION
    Encapsulates host reboot cycles, early boot service settle detection,
    post-reboot verification commands, and manual WebGUI access checks.
#>

$ErrorActionPreference = "Stop"

function Get-RemoteBootId {
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
        [string]$Label = "boot-id",

        [switch]$DoExecute = $true
    )

    $conn = if ($PSCmdlet.ParameterSetName -eq 'Legacy' -or ($null -eq $NodeConnection -and -not [string]::IsNullOrWhiteSpace($TargetHost))) {
        [pscustomobject]@{ User = $User; Host = $TargetHost; Port = $Port; IdentityFile = $IdentityFile }
    } else {
        $NodeConnection
    }

    $result = Invoke-RemoteCommand -NodeConnection $conn -Command "cat /proc/sys/kernel/random/boot_id" -Label $Label -DoExecute:$DoExecute
    return [pscustomobject]@{
        Result = $result
        BootId = if ($result.Output) { [string]$result.Output.Trim() } else { $null }
    }
}

function Wait-NodeBootSettle {
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
        [string]$NodeName = "node",

        [Parameter(Mandatory = $false)]
        [int]$TimeoutSeconds = 90,

        [Parameter(Mandatory = $false)]
        [int]$MinUptimeSeconds = 45,

        [switch]$DoExecute = $true
    )

    if (-not $DoExecute) {
        Write-Host "[dry-run] Would wait for early boot services to settle on $NodeName"
        return [pscustomobject]@{
            Success = $true
            Output  = "dry-run"
        }
    }

    $conn = if ($PSCmdlet.ParameterSetName -eq 'Legacy' -or ($null -eq $NodeConnection -and -not [string]::IsNullOrWhiteSpace($TargetHost))) {
        [pscustomobject]@{ User = $User; Host = $TargetHost; Port = $Port; IdentityFile = $IdentityFile }
    } else {
        $NodeConnection
    }

    $startTime = Get-Date
    $settled = $false
    $lastOutput = ""
    while ((New-TimeSpan -Start $startTime -End (Get-Date)).TotalSeconds -lt $TimeoutSeconds) {
        $checkScript = @"
uptime_secs=`$(cut -d. -f1 /proc/uptime 2>/dev/null || echo 0)
reload_pid=`$(pidof -x reload_services 2>/dev/null || true)
sshd_running=0
if pgrep -x sshd >/dev/null 2>&1; then
    sshd_running=1
fi
echo "uptime=`$uptime_secs reload=`$reload_pid sshd=`$sshd_running"
if [ "`$uptime_secs" -ge $MinUptimeSeconds ] && [ -z "`$reload_pid" ] && [ "`$sshd_running" -eq 1 ]; then
    echo "boot-settled"
fi
"@
        $result = Invoke-RemoteCommand -NodeConnection $conn -Command $checkScript -Label "boot-settle" -LoggedCommand "check early boot service status" -DoExecute:$DoExecute
        if ($result.Success) {
            $outputStr = ($result.Output -split "`r?`n" -join ' ').Trim()
            $lastOutput = $outputStr
            if ($outputStr -match "boot-settled") {
                Write-Host "[testlab] Early boot services settled on $NodeName ($outputStr)"
                $settled = $true
                break
            } else {
                Write-Host "[testlab] Waiting for $NodeName boot services to settle: $outputStr"
            }
        } else {
            Write-Host "[testlab] Node $NodeName SSH not ready during boot settle (exit=$($result.ExitCode)), retrying..."
        }
        Start-Sleep -Seconds 3
    }

    if (-not $settled) {
        throw "Node '$NodeName' did not settle early boot services within $TimeoutSeconds seconds. Last output: $lastOutput"
    }

    return [pscustomobject]@{
        Success = $true
        Output  = $lastOutput
    }
}

function Wait-ForRebootCycle {
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
        [string]$PreviousBootId = $null,

        [Parameter(Mandatory = $false)]
        [int]$TimeoutSeconds = 120,

        [Parameter(Mandatory = $false)]
        [int]$SettleSeconds = 0,

        [Parameter(Mandatory = $false)]
        [string]$ReadyCommand = $null,

        [Parameter(Mandatory = $false)]
        [string]$ReadyLoggedCommand = $null,

        [Parameter(Mandatory = $false)]
        [string]$ReadyLabel = "post-reboot-ready",

        [switch]$DoExecute = $true
    )

    $conn = if ($PSCmdlet.ParameterSetName -eq 'Legacy' -or ($null -eq $NodeConnection -and -not [string]::IsNullOrWhiteSpace($TargetHost))) {
        [pscustomobject]@{ User = $User; Host = $TargetHost; Port = $Port; IdentityFile = $IdentityFile }
    } else {
        $NodeConnection
    }

    $targetLabel = "{0}:{1}" -f $conn.Host, $conn.Port

    if (-not $DoExecute) {
        Write-Host "[dry-run] Would wait for reboot cycle to complete on $targetLabel"
        return [pscustomobject]@{
            Success     = $true
            Error       = $null
            BootId      = "dry-run-boot-id"
            ReadyResult = [pscustomobject]@{
                Label    = $ReadyLabel
                Command  = $ReadyLoggedCommand
                ExitCode = 0
                Output   = "dry-run"
                Success  = $true
            }
        }
    }

    $started = Get-Date
    Write-Host "[testlab] Waiting for reboot cycle to complete on $targetLabel"

    if (-not (Wait-SshUnavailable -NodeConnection $conn -TimeoutSeconds $TimeoutSeconds -DoExecute:$DoExecute)) {
        return [pscustomobject]@{
            Success = $false
            Error   = "Host never became unavailable after reboot request."
            BootId  = $null
        }
    }

    $elapsedSeconds = [int](New-TimeSpan -Start $started -End (Get-Date)).TotalSeconds
    $remainingSeconds = [Math]::Max($TimeoutSeconds - $elapsedSeconds, 1)
    if (-not (Wait-SshReady -NodeConnection $conn -TimeoutSeconds $remainingSeconds -DoExecute:$DoExecute)) {
        return [pscustomobject]@{
            Success = $false
            Error   = "Host did not return after reboot within $TimeoutSeconds seconds."
            BootId  = $null
        }
    }

    $confirmedBootId = $null
    $bootIdHeartbeatAt = Get-Date
    while ((New-TimeSpan -Start $started -End (Get-Date)).TotalSeconds -lt $TimeoutSeconds) {
        $bootIdInfo = Get-RemoteBootId -NodeConnection $conn -Label "boot-id-after-reboot" -DoExecute:$DoExecute
        if ($bootIdInfo.Result.Success -and -not [string]::IsNullOrWhiteSpace($bootIdInfo.BootId)) {
            if ([string]::IsNullOrWhiteSpace($PreviousBootId) -or $bootIdInfo.BootId -ne $PreviousBootId) {
                Write-Host "[testlab] Reboot confirmed on $targetLabel with boot_id $($bootIdInfo.BootId)"
                $confirmedBootId = $bootIdInfo.BootId
                break
            }
        }

        $bootIdHeartbeatAt = Write-TestLabHeartbeat -Message "Still waiting for a new boot_id on $targetLabel" -StartedAt $started -LastHeartbeatAt $bootIdHeartbeatAt -IntervalSeconds 15 -TimeoutSeconds $TimeoutSeconds
        Start-Sleep -Seconds 2
    }

    if ([string]::IsNullOrWhiteSpace($confirmedBootId)) {
        return [pscustomobject]@{
            Success     = $false
            Error       = "Host returned, but boot_id did not change after reboot."
            BootId      = $null
            ReadyResult = $null
        }
    }

    $readyResult = $null
    if ($SettleSeconds -gt 0) {
        Write-Host "[testlab] Letting host settle for ${SettleSeconds}s after reboot"
        Start-Sleep -Seconds $SettleSeconds

        # Rather than running a long sleep over SSH which drops when services reload, query remote uptime and sleep locally if needed
        $uptimeProbe = Invoke-RemoteCommand -NodeConnection $conn -Command "cut -d. -f1 /proc/uptime 2>/dev/null || echo 60" -Label "check-remote-uptime" -DoExecute:$DoExecute
        $currentUptime = 60
        if ($uptimeProbe.Success -and -not [string]::IsNullOrWhiteSpace($uptimeProbe.Output)) {
            $parsedUptime = 0
            if ([int]::TryParse($uptimeProbe.Output.Trim(), [ref]$parsedUptime)) {
                $currentUptime = $parsedUptime
            }
        }
        if ($currentUptime -lt 45) {
            $localSleep = [Math]::Max(45 - $currentUptime + 2, 2)
            Write-Host "[testlab] Waiting ${localSleep}s locally for host to pass 45s service reload window..."
            Start-Sleep -Seconds $localSleep
        }

        $serviceWaitCommand = 'while pidof -x reload_services >/dev/null 2>&1; do sleep 1; done; echo settled'
        $settleCheck = Wait-ForRemoteSuccess -NodeConnection $conn -Command $serviceWaitCommand -LoggedCommand "wait for pending Unraid service reloads" -Label "post-reboot-service-settle" -TimeoutSeconds 30 -IntervalSeconds 2 -DoExecute:$DoExecute
        if (-not $settleCheck.Success) {
            Write-Warning "Unraid post-reboot service settle check did not complete cleanly on $targetLabel."
        }

        $settleStableTimeout = [Math]::Min($TimeoutSeconds, 30)
        if (-not (Wait-SshStable -NodeConnection $conn -TimeoutSeconds $settleStableTimeout -ConsecutiveSuccesses 2 -DoExecute:$DoExecute)) {
            Write-Host "[testlab] SSH unstable after settle period on $targetLabel, waiting for recovery"
            $recoveryTimeout = [Math]::Min($TimeoutSeconds, 45)
            if (-not (Wait-SshReady -NodeConnection $conn -TimeoutSeconds $recoveryTimeout -DoExecute:$DoExecute)) {
                return [pscustomobject]@{
                    Success     = $false
                    Error       = "Host SSH dropped during settle period and did not recover on $targetLabel."
                    BootId      = $null
                    ReadyResult = $null
                }
            }
        }
    } else {
        $elapsedSeconds = [int](New-TimeSpan -Start $started -End (Get-Date)).TotalSeconds
        $remainingSeconds = [Math]::Max($TimeoutSeconds - $elapsedSeconds, 1)
        $settleStableTimeout = [Math]::Min($remainingSeconds, 30)
        if (-not (Wait-SshStable -NodeConnection $conn -TimeoutSeconds $settleStableTimeout -DoExecute:$DoExecute)) {
            return [pscustomobject]@{
                Success     = $false
                Error       = "Host did not remain SSH-stable after reboot."
                BootId      = $null
                ReadyResult = $null
            }
        }
    }

    if (-not [string]::IsNullOrWhiteSpace($ReadyCommand)) {
        $elapsedSeconds = [int](New-TimeSpan -Start $started -End (Get-Date)).TotalSeconds
        $remainingSeconds = [Math]::Max($TimeoutSeconds - $elapsedSeconds, 30)
        $readyResult = Wait-ForRemoteSuccess -NodeConnection $conn -Command $ReadyCommand -LoggedCommand $ReadyLoggedCommand -Label $ReadyLabel -TimeoutSeconds $remainingSeconds -IntervalSeconds 5 -DoExecute:$DoExecute
        if (-not $readyResult.Success) {
            $readyOutputText = if ($readyResult.Result -and $null -ne $readyResult.Result.Output) {
                ([string]$readyResult.Result.Output).Trim()
            } else {
                ""
            }

            $readyError = if ([string]::IsNullOrWhiteSpace($readyOutputText)) {
                "Remote check '$ReadyLabel' did not succeed after reboot."
            } else {
                "Remote check '$ReadyLabel' did not succeed after reboot. Last output: $readyOutputText"
            }

            return [pscustomobject]@{
                Success     = $false
                Error       = $readyError
                BootId      = $null
                ReadyResult = $readyResult.Result
            }
        }
    }

    return [pscustomobject]@{
        Success     = $true
        Error       = $null
        BootId      = $confirmedBootId
        ReadyResult = if ($readyResult) { $readyResult.Result } else { $null }
    }
}

function Get-BuddyBackupPluginVerifyCommand {
    return ((@'
set -eu

if plugin list | grep -i buddybackup >/dev/null 2>&1; then
  plugin list | grep -i buddybackup
  exit 0
fi

if [ -f /boot/config/plugins/buddybackup/buddybackup.txz ] && [ -f /boot/config/plugins/buddybackup/buddybackup.cfg ] && [ -f /usr/local/emhttp/plugins/buddybackup/scripts/rc.buddybackup.php ]; then
  echo "buddybackup verified via installed plugin files"
  exit 0
fi

echo "buddybackup missing from plugin list and expected plugin files were not found" >&2
plugin list || true
ls -la /boot/config/plugins/buddybackup 2>/dev/null || true
ls -la /usr/local/emhttp/plugins/buddybackup/scripts 2>/dev/null || true
exit 1
'@) -replace "`r`n", "`n").Trim()
}

function Get-BuddyBackupPostRebootReadyCommand {
    return ((@'
set -eu

plugin_root="/boot/config/plugins/buddybackup"
sshd_config="/etc/ssh/sshd_config"
if [ -f /boot/config/ssh/sshd_config ]; then
    sshd_config="/boot/config/ssh/sshd_config"
fi

if [ ! -f "$plugin_root/buddybackup.cfg" ]; then
    echo "buddybackup.cfg is missing" >&2
    exit 1
fi

receiver_configured=0
if [ -f "$plugin_root/incoming.cfg" ] && grep -Eq '^[[:space:]]*enable="?yes"?' "$plugin_root/incoming.cfg"; then
    receiver_configured=1
elif [ -f "$plugin_root/buddybackup.cfg" ] && grep -Eq '^[[:space:]]*ReceiveBackups="?enable"?' "$plugin_root/buddybackup.cfg"; then
    receiver_configured=1
fi

if [ "$receiver_configured" -eq 1 ]; then
    if ! grep -q '^buddybackup:' /etc/shadow 2>/dev/null; then
        echo "buddybackup user is not ready in /etc/shadow" >&2
        exit 1
    fi

    if ! getent passwd buddybackup 2>/dev/null | grep -q ':/home/buddybackup:/bin/bash'; then
        echo "buddybackup home or shell is not ready" >&2
        exit 1
    fi

    if ! getent group buddybackup >/dev/null 2>&1; then
        echo "buddybackup group is missing" >&2
        exit 1
    fi

    if ! grep -Eq '^[[:space:]]*AllowUsers[[:space:]].*buddybackup([[:space:]]|$)' "$sshd_config" 2>/dev/null; then
        echo "sshd AllowUsers is missing buddybackup" >&2
        exit 1
    fi

    if ! grep -Eq '^[[:space:]]*Match[[:space:]]+User[[:space:]]+buddybackup([[:space:]]|$)' "$sshd_config" 2>/dev/null; then
        echo "sshd Match User buddybackup block is missing" >&2
        exit 1
    fi
fi

if pgrep -f 'testlab-postboot-refresh.sh' >/dev/null 2>&1; then
    echo "testlab-postboot-refresh is still running" >&2
    exit 1
fi

if pgrep -f 'rc.buddybackup.php update' >/dev/null 2>&1; then
    echo "rc.buddybackup.php update is still running" >&2
    exit 1
fi

remote_hosts_configured=0
if [ -f "$plugin_root/backups.cfg" ] && grep -Eq '^destination_host="' "$plugin_root/backups.cfg"; then
    remote_hosts_configured=1
fi

if [ "$remote_hosts_configured" -eq 1 ] && ! grep -Eq 'ssh-(ed25519|rsa)|ecdsa-sha2-' "$plugin_root/buddybackup_known_hosts" 2>/dev/null; then
    echo "managed known_hosts is not ready" >&2
    exit 1
fi

echo "buddybackup post-reboot ready"
'@) -replace "`r`n", "`n").Trim()
}

function Get-BuddyBackupPostRebootReadyLoggedCommand {
    return "verify BuddyBackup post-reboot readiness"
}

function Get-ManualAccessConfig {
    param($Lab)

    $setupCfg = Get-ObjectValue -Object $Lab -Name "setup"
    $manualAccessCfg = Get-ObjectValue -Object $setupCfg -Name "manualAccess"
    $rootPassword = [string](Get-ObjectValue -Object $manualAccessCfg -Name "rootPassword")
    if ([string]::IsNullOrWhiteSpace($rootPassword)) {
        $rootPassword = "buddybackup-testlab"
    }

    return [pscustomobject]@{
        webGuiUser     = "root"
        webGuiPassword = $rootPassword
    }
}

function Get-ManualAccessVerifyCommand {
    param($Lab)

    $manualAccess = Get-ManualAccessConfig -Lab $Lab
    $passwordB64 = [Convert]::ToBase64String([System.Text.Encoding]::UTF8.GetBytes([string]$manualAccess.webGuiPassword))

    return (((@'
set -eu

if [ ! -f /boot/config/shadow ]; then
    echo "/boot/config/shadow is missing" >&2
    exit 1
fi

runtime_hash="$(awk -F: '$1=="root" { print $2 }' /etc/shadow)"
persistent_hash="$(awk -F: '$1=="root" { print $2 }' /boot/config/shadow)"

case "$runtime_hash" in
    ""|\!*|\**)
        echo "root password hash is not configured in /etc/shadow" >&2
        exit 1
        ;;
esac

case "$persistent_hash" in
    ""|\!*|\**)
        echo "root password hash is not configured in /boot/config/shadow" >&2
        exit 1
        ;;
esac

if ! command -v php >/dev/null 2>&1; then
    if [ "$runtime_hash" = "$persistent_hash" ]; then
        echo "root password hash persisted"
        exit 0
    fi

    echo "php is unavailable and runtime/persistent hashes differ" >&2
    exit 1
fi

if ! BUDDYBACKUP_PASSWORD_B64="__BUDDYBACKUP_PASSWORD_B64__" BUDDYBACKUP_HASH_TO_CHECK="$runtime_hash" php -r '$password=base64_decode(getenv("BUDDYBACKUP_PASSWORD_B64")); $hash=getenv("BUDDYBACKUP_HASH_TO_CHECK"); exit(($hash !== false && $hash !== "" && crypt($password, $hash) === $hash) ? 0 : 1);'; then
    echo "configured root password does not match /etc/shadow" >&2
    exit 1
fi

if ! BUDDYBACKUP_PASSWORD_B64="__BUDDYBACKUP_PASSWORD_B64__" BUDDYBACKUP_HASH_TO_CHECK="$persistent_hash" php -r '$password=base64_decode(getenv("BUDDYBACKUP_PASSWORD_B64")); $hash=getenv("BUDDYBACKUP_HASH_TO_CHECK"); exit(($hash !== false && $hash !== "" && crypt($password, $hash) === $hash) ? 0 : 1);'; then
    echo "configured root password does not match /boot/config/shadow" >&2
    exit 1
fi

if [ "$runtime_hash" != "$persistent_hash" ]; then
    echo "root password persisted (runtime hash differs but matches configured password)"
    exit 0
fi

echo "root password hash persisted"
'@).Replace("__BUDDYBACKUP_PASSWORD_B64__", $passwordB64)) -replace "`r`n", "`n").Trim()
}

function Get-ManualAccessVerifyLoggedCommand {
    return "verify manual WebGUI password persistence (password redacted)"
}

function Get-TestLabPostBootRefreshCommand {
    return ((@'
plugin_root="/boot/config/plugins/buddybackup"
post_boot_refresh_script="$plugin_root/testlab-postboot-refresh.sh"
post_boot_refresh_begin="#BUDDYBACKUP_TESTLAB_POSTBOOT_REFRESH_BEGIN"
post_boot_refresh_end="#BUDDYBACKUP_TESTLAB_POSTBOOT_REFRESH_END"
go_file="/boot/config/go"
sshd_guard_begin="#BUDDYBACKUP_SSHD_GUARD_BEGIN"
sshd_guard_end="#BUDDYBACKUP_SSHD_GUARD_END"

mkdir -p "$plugin_root"
mkdir -p /boot/config/ssh

ensure_sshd_global_option() {
    local target_file="$1"
    local opt="$2"
    local key="${opt%% *}"
    [ -f "$target_file" ] || return 0
    local tmp_file
    tmp_file="$(mktemp)"
    awk -v opt="$opt" -v key="$key" '
        BEGIN { found = 0; match_seen = 0 }
        $1 == "Match" {
            if (!found && !match_seen) {
                print opt
                found = 1
            }
            match_seen = 1
        }
        tolower($1) == tolower(key) {
            if (match_seen) {
                next
            }
            found = 1
        }
        { print }
        END {
            if (!found && !match_seen) {
                print opt
            }
        }
    ' "$target_file" > "$tmp_file" && mv "$tmp_file" "$target_file"
}

# 1. Update /etc/rc.d/rc.sshd immediately on running system
mkdir -p /boot/config
ident_cfg="/boot/config/ident.cfg"
if [ -f "$ident_cfg" ]; then
    if grep -q '^USE_SSH=' "$ident_cfg"; then
        sed -i 's/^USE_SSH=.*/USE_SSH="yes"/' "$ident_cfg"
    else
        printf '\nUSE_SSH="yes"\n' >> "$ident_cfg"
    fi
else
    printf 'USE_SSH="yes"\n' > "$ident_cfg"
fi

if [ -f /etc/rc.d/rc.sshd ] && ! grep -Fq 'BUDDYBACKUP_RACE_GUARD_V5' /etc/rc.d/rc.sshd; then
    if command -v perl >/dev/null 2>&1; then
        perl -0777 -i -pe '
            s/(sshd_reload\(\)\{).*?(_orig_sshd_reload\(\)\{)/$1\n  #BUDDYBACKUP_RACE_GUARD_V5\n  local old_pid=""\n  [[ -r \$PID ]] && old_pid=\$(cat \$PID)\n  if [[ -n "\$old_pid" ]] && kill -0 "\$old_pid" 2>\/dev\/null; then\n    kill "\$old_pid" 2>\/dev\/null || true\n    local k=0; while kill -0 "\$old_pid" 2>\/dev\/null && [[ \$k -lt 30 ]]; do sleep 0.1; k=\$((k+1)); done\n  fi\n  sshd_build\n  sleep 0.5\n  if ! pgrep -x sshd >\/dev\/null 2>&1; then\n    local w=0; while [[ \$w -lt 25 ]]; do if \$SSHD 2>\/dev\/null; then break; fi; sleep 0.2; w=\$((w+1)); done\n  fi\n  if ! pgrep -x sshd >\/dev\/null 2>&1; then \/etc\/rc.d\/rc.sshd start >\/dev\/null 2>&1 || true; fi\n  return 0\n}\n$2/s
            or
            s/(sshd_reload\(\)\{)/$1\n  #BUDDYBACKUP_RACE_GUARD_V5\n  local old_pid=""\n  [[ -r \$PID ]] && old_pid=\$(cat \$PID)\n  if [[ -n "\$old_pid" ]] && kill -0 "\$old_pid" 2>\/dev\/null; then\n    kill "\$old_pid" 2>\/dev\/null || true\n    local k=0; while kill -0 "\$old_pid" 2>\/dev\/null && [[ \$k -lt 30 ]]; do sleep 0.1; k=\$((k+1)); done\n  fi\n  sshd_build\n  sleep 0.5\n  if ! pgrep -x sshd >\/dev\/null 2>&1; then\n    local w=0; while [[ \$w -lt 25 ]]; do if \$SSHD 2>\/dev\/null; then break; fi; sleep 0.2; w=\$((w+1)); done\n  fi\n  if ! pgrep -x sshd >\/dev\/null 2>&1; then \/etc\/rc.d\/rc.sshd start >\/dev\/null 2>&1 || true; fi\n  return 0\n}\n_orig_sshd_reload(){/s
        ' /etc/rc.d/rc.sshd 2>/dev/null || true
    fi
fi
sysctl -w net.ipv4.ip_nonlocal_bind=1 >/dev/null 2>&1 || true

# 2. Maintain PerSourcePenalties no
ensure_sshd_global_option /etc/ssh/sshd_config "PerSourcePenalties no"
ensure_sshd_global_option /boot/config/ssh/sshd_config "PerSourcePenalties no"

# 3. Ensure persistent /boot/config/go has early SSH guard at the top
if [ -f "$go_file" ]; then
    tmp_go="$(mktemp)"
    awk -v b="$sshd_guard_begin" -v e="$sshd_guard_end" -v pb="$post_boot_refresh_begin" -v pe="$post_boot_refresh_end" '
        $0 == b || $0 == pb { skip=1; next }
        $0 == e || $0 == pe { skip=0; next }
        !skip { print }
    ' "$go_file" > "$tmp_go"

    head_line="$(head -n 1 "$tmp_go" 2>/dev/null || true)"
    {
        if [[ "$head_line" =~ ^#! ]]; then
            echo "$head_line"
        else
            echo "#!/bin/bash"
        fi
        cat <<'EOF_GUARD'
#BUDDYBACKUP_SSHD_GUARD_BEGIN
mkdir -p /boot/config
ident_cfg="/boot/config/ident.cfg"
if [ -f "$ident_cfg" ]; then
    if grep -q '^USE_SSH=' "$ident_cfg"; then
        sed -i 's/^USE_SSH=.*/USE_SSH="yes"/' "$ident_cfg"
    else
        printf '\nUSE_SSH="yes"\n' >> "$ident_cfg"
    fi
else
    printf 'USE_SSH="yes"\n' > "$ident_cfg"
fi

if [ -f /etc/rc.d/rc.sshd ] && ! grep -Fq 'BUDDYBACKUP_RACE_GUARD_V5' /etc/rc.d/rc.sshd; then
    if command -v perl >/dev/null 2>&1; then
        perl -0777 -i -pe '
            s/(sshd_reload\(\)\{).*?(_orig_sshd_reload\(\)\{)/$1\n  #BUDDYBACKUP_RACE_GUARD_V5\n  local old_pid=""\n  [[ -r \$PID ]] && old_pid=\$(cat \$PID)\n  if [[ -n "\$old_pid" ]] && kill -0 "\$old_pid" 2>\/dev\/null; then\n    kill "\$old_pid" 2>\/dev\/null || true\n    local k=0; while kill -0 "\$old_pid" 2>\/dev\/null && [[ \$k -lt 30 ]]; do sleep 0.1; k=\$((k+1)); done\n  fi\n  sshd_build\n  sleep 0.5\n  if ! pgrep -x sshd >\/dev\/null 2>&1; then\n    local w=0; while [[ \$w -lt 25 ]]; do if \$SSHD 2>\/dev\/null; then break; fi; sleep 0.2; w=\$((w+1)); done\n  fi\n  if ! pgrep -x sshd >\/dev\/null 2>&1; then \/etc\/rc.d\/rc.sshd start >\/dev\/null 2>&1 || true; fi\n  return 0\n}\n$2/s
            or
            s/(sshd_reload\(\)\{)/$1\n  #BUDDYBACKUP_RACE_GUARD_V5\n  local old_pid=""\n  [[ -r \$PID ]] && old_pid=\$(cat \$PID)\n  if [[ -n "\$old_pid" ]] && kill -0 "\$old_pid" 2>\/dev\/null; then\n    kill "\$old_pid" 2>\/dev\/null || true\n    local k=0; while kill -0 "\$old_pid" 2>\/dev\/null && [[ \$k -lt 30 ]]; do sleep 0.1; k=\$((k+1)); done\n  fi\n  sshd_build\n  sleep 0.5\n  if ! pgrep -x sshd >\/dev\/null 2>&1; then\n    local w=0; while [[ \$w -lt 25 ]]; do if \$SSHD 2>\/dev\/null; then break; fi; sleep 0.2; w=\$((w+1)); done\n  fi\n  if ! pgrep -x sshd >\/dev\/null 2>&1; then \/etc\/rc.d\/rc.sshd start >\/dev\/null 2>&1 || true; fi\n  return 0\n}\n_orig_sshd_reload(){/s
        ' /etc/rc.d/rc.sshd 2>/dev/null || true
    fi
fi
sysctl -w net.ipv4.ip_nonlocal_bind=1 >/dev/null 2>&1 || true

ensure_sshd_global_option() {
    local target_file="$1"
    local opt="$2"
    local key="${opt%% *}"
    [ -f "$target_file" ] || return 0
    local tmp_file
    tmp_file="$(mktemp)"
    awk -v opt="$opt" -v key="$key" '
        BEGIN { found = 0; match_seen = 0 }
        $1 == "Match" {
            if (!found && !match_seen) {
                print opt
                found = 1
            }
            match_seen = 1
        }
        tolower($1) == tolower(key) {
            if (match_seen) {
                next
            }
            found = 1
        }
        { print }
        END {
            if (!found && !match_seen) {
                print opt
            }
        }
    ' "$target_file" > "$tmp_file" && mv "$tmp_file" "$target_file"
}

ensure_sshd_global_option /etc/ssh/sshd_config "PerSourcePenalties no"
ensure_sshd_global_option /boot/config/ssh/sshd_config "PerSourcePenalties no"
#BUDDYBACKUP_SSHD_GUARD_END
EOF_GUARD
        if [[ "$head_line" =~ ^#! ]]; then
            tail -n +2 "$tmp_go"
        else
            cat "$tmp_go"
        fi
        cat <<EOF

$post_boot_refresh_begin
if [ -f /boot/config/plugins/buddybackup/testlab-postboot-refresh.sh ]; then
    bash /boot/config/plugins/buddybackup/testlab-postboot-refresh.sh >/dev/null 2>&1 &
fi
$post_boot_refresh_end
EOF
    } > "${tmp_go}.new"
    mv "${tmp_go}.new" "$go_file"
    chmod 755 "$go_file"
    rm -f "$tmp_go" 2>/dev/null || true
fi

# 4. Write post-boot refresh script
cat > "$post_boot_refresh_script" <<'EOF_BUDDYBACKUP_POSTBOOT_REFRESH'
#!/bin/bash
set -euo pipefail

# Guard Unraid rc.sshd against port bind race during delayed service reloads
if [ -f /etc/rc.d/rc.sshd ] && ! grep -Fq 'BUDDYBACKUP_RACE_GUARD_V4' /etc/rc.d/rc.sshd; then
    if command -v perl >/dev/null 2>&1; then
        perl -0777 -i -pe '
            s/(sshd_reload\(\)\{).*?(_orig_sshd_reload\(\)\{)/$1\n  #BUDDYBACKUP_RACE_GUARD_V4\n  local old_pid=""\n  [[ -r \$PID ]] && old_pid=\$(cat \$PID)\n  if [[ -n "\$old_pid" ]] && kill -0 "\$old_pid" 2>\/dev\/null; then\n    kill "\$old_pid" 2>\/dev\/null || true\n    local k=0; while kill -0 "\$old_pid" 2>\/dev\/null && [[ \$k -lt 50 ]]; do sleep 0.1; k=\$((k+1)); done\n  fi\n  sshd_build\n  local w=0; while [[ \$w -lt 50 ]]; do if \$SSHD 2>\/dev\/null && pgrep -x sshd >\/dev\/null 2>&1; then break; fi; sleep 0.2; w=\$((w+1)); done\n  if ! pgrep -x sshd >\/dev\/null 2>&1; then \/etc\/rc.d\/rc.sshd start >\/dev\/null 2>&1 || true; fi\n  return 0\n}\n$2/s
            or
            s/(sshd_reload\(\)\{)/$1\n  #BUDDYBACKUP_RACE_GUARD_V4\n  local old_pid=""\n  [[ -r \$PID ]] && old_pid=\$(cat \$PID)\n  if [[ -n "\$old_pid" ]] && kill -0 "\$old_pid" 2>\/dev\/null; then\n    kill "\$old_pid" 2>\/dev\/null || true\n    local k=0; while kill -0 "\$old_pid" 2>\/dev\/null && [[ \$k -lt 50 ]]; do sleep 0.1; k=\$((k+1)); done\n  fi\n  sshd_build\n  local w=0; while [[ \$w -lt 50 ]]; do if \$SSHD 2>\/dev\/null && pgrep -x sshd >\/dev\/null 2>&1; then break; fi; sleep 0.2; w=\$((w+1)); done\n  if ! pgrep -x sshd >\/dev\/null 2>&1; then \/etc\/rc.d\/rc.sshd start >\/dev\/null 2>&1 || true; fi\n  return 0\n}\n_orig_sshd_reload(){/s
        ' /etc/rc.d/rc.sshd 2>/dev/null || true
    fi
fi

ensure_sshd_global_option() {
    local target_file="$1"
    local opt="$2"
    local key="${opt%% *}"
    [ -f "$target_file" ] || return 0
    local tmp_file
    tmp_file="$(mktemp)"
    awk -v opt="$opt" -v key="$key" '
        BEGIN { found = 0; match_seen = 0 }
        $1 == "Match" {
            if (!found && !match_seen) {
                print opt
                found = 1
            }
            match_seen = 1
        }
        tolower($1) == tolower(key) {
            if (match_seen) {
                next
            }
            found = 1
        }
        { print }
        END {
            if (!found && !match_seen) {
                print opt
            }
        }
    ' "$target_file" > "$tmp_file" && mv "$tmp_file" "$target_file"
}

ensure_sshd_global_option /etc/ssh/sshd_config "PerSourcePenalties no"
ensure_sshd_global_option /boot/config/ssh/sshd_config "PerSourcePenalties no"

attempts=60
while [ "$attempts" -gt 0 ]; do
    if ! pgrep -x sshd >/dev/null 2>&1; then
        /etc/rc.d/rc.sshd start >/dev/null 2>&1 || true
        if ! pgrep -x sshd >/dev/null 2>&1; then
            mkdir -p /boot/config/ssh
            cp -f /boot/config/ssh/* /etc/ssh 2>/dev/null || true
            chmod 600 /etc/ssh/* 2>/dev/null || true
            ssh-keygen -A >/dev/null 2>&1 || true
            cp -n /etc/ssh/ssh_host*_key* /boot/config/ssh/ 2>/dev/null || true
            /usr/sbin/sshd >/dev/null 2>&1 || true
        fi
    fi

    if [ -x /usr/local/emhttp/plugins/buddybackup/scripts/rc.buddybackup.php ] && [ -f /boot/config/plugins/buddybackup/buddybackup.cfg ]; then
        # Always run local update to ensure receiver user, groups, and permissions are initialized immediately
        /usr/local/emhttp/plugins/buddybackup/scripts/rc.buddybackup.php update >/dev/null 2>&1 || true

        plugin_root="/boot/config/plugins/buddybackup"
        backups_cfg="$plugin_root/backups.cfg"
        remote_hosts=()
        if [ -f "$backups_cfg" ]; then
            while IFS= read -r host; do
                [ -n "$host" ] && remote_hosts+=("$host")
            done < <(awk -F= '$1=="destination_host" {value=$2; gsub(/^"|"$/, "", value); if (value != "") print value}' "$backups_cfg" 2>/dev/null || true)
        fi

        all_reachable=1
        for rhost in "${remote_hosts[@]}"; do
            if ! ssh-keyscan -T 3 "$rhost" 2>/dev/null | grep -Eq 'ssh-(ed25519|rsa)|ecdsa-sha2-'; then
                all_reachable=0
                break
            fi
        done

        if [ "$all_reachable" -eq 1 ]; then
            bb_ready=0
            if [ "${#remote_hosts[@]}" -gt 0 ]; then
                if grep -Eq 'ssh-(ed25519|rsa)|ecdsa-sha2-' "$plugin_root/buddybackup_known_hosts" 2>/dev/null; then
                    bb_ready=1
                fi
            else
                bb_ready=1
            fi

            receiver_ready=1
            if [ -f "$plugin_root/incoming.cfg" ] && grep -Eq '^[[:space:]]*enable="?yes"?' "$plugin_root/incoming.cfg"; then
                if ! grep -q '^buddybackup:' /etc/shadow 2>/dev/null; then
                    receiver_ready=0
                fi
            elif [ -f "$plugin_root/buddybackup.cfg" ] && grep -Eq '^[[:space:]]*ReceiveBackups="?enable"?' "$plugin_root/buddybackup.cfg"; then
                if ! grep -q '^buddybackup:' /etc/shadow 2>/dev/null; then
                    receiver_ready=0
                fi
            fi

            if [ "$bb_ready" -eq 1 ] && [ "$receiver_ready" -eq 1 ]; then
                uptime_secs=$(cut -d. -f1 /proc/uptime 2>/dev/null || echo 60)
                if [ -n "$uptime_secs" ] && [ "$uptime_secs" -lt 45 ] 2>/dev/null; then
                    sleep $((45 - uptime_secs))
                fi
                while pidof -x reload_services >/dev/null 2>&1; do
                    sleep 1
                done
                if ! pgrep -x sshd >/dev/null 2>&1; then
                    /etc/rc.d/rc.sshd start >/dev/null 2>&1 || true
                    if ! pgrep -x sshd >/dev/null 2>&1; then
                        mkdir -p /boot/config/ssh
                        cp -f /boot/config/ssh/* /etc/ssh 2>/dev/null || true
                        chmod 600 /etc/ssh/* 2>/dev/null || true
                        ssh-keygen -A >/dev/null 2>&1 || true
                        cp -n /etc/ssh/ssh_host*_key* /boot/config/ssh/ 2>/dev/null || true
                        /usr/sbin/sshd >/dev/null 2>&1 || true
                    fi
                fi
                for _ in $(seq 1 30); do
                    if ! pgrep -x sshd >/dev/null 2>&1; then
                        /etc/rc.d/rc.sshd start >/dev/null 2>&1 || true
                    fi
                    sleep 2
                done
                exit 0
            fi
        fi
    fi

    sleep 2
    attempts=$((attempts - 1))
done

exit 0
EOF_BUDDYBACKUP_POSTBOOT_REFRESH
chmod 700 "$post_boot_refresh_script"
'@) -replace "`r`n", "`n").Trim()
}
