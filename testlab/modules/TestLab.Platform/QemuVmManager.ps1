$ErrorActionPreference = "Stop"

function Get-WslQemuProcesses {
    [CmdletBinding()]
    param(
        [string]$Distro = "Ubuntu"
    )

    $qemuPids = @{}
    try {
        $checkScript = @'
for pidfile in /tmp/buddybackup-qemu-*/qemu.pid /var/lib/buddybackup-*/qemu.pid; do
    [ -f "$pidfile" ] || continue
    pid=$(cat "$pidfile" 2>/dev/null || true)
    if [ -n "$pid" ] && kill -0 "$pid" 2>/dev/null; then
        dir=$(dirname "$pidfile")
        base=$(basename "$dir")
        echo "${base}:${pid}"
    fi
done
'@
        $res = Invoke-WslRootBash -ScriptContent $checkScript -Distro $Distro
        if ($res -and $res.Output) {
            foreach ($line in $res.Output) {
                if ($line -match '^([^:]+):(\d+)$') {
                    $rawName = $matches[1]
                    $pid = [int]$matches[2]
                    $qemuPids[$rawName] = $pid

                    # Normalize common aliases: buddybackup-qemu-lab-nodeA -> nodeA, lab-nodeA
                    if ($rawName -match '^(?:buddybackup-qemu-)?(lab-)?(node[A-Za-z0-9]+)$') {
                        $shortNode = $matches[2]
                        $qemuPids[$shortNode] = $pid
                        $qemuPids["lab-$shortNode"] = $pid
                    }
                }
            }
        }
    } catch {
        # Return empty hashtable on inspection failure
    }

    return $qemuPids
}

function Stop-WslLabInstance {
    [CmdletBinding()]
    param(
        [string]$Distro = "Ubuntu",
        [Parameter(Mandatory = $true)]
        [string]$InstanceName,
        [switch]$DoExecute
    )

    $workRoot = if ($InstanceName.StartsWith("/")) {
        $InstanceName
    } else {
        "/tmp/buddybackup-qemu-$InstanceName"
    }

    if (-not $DoExecute) {
        Write-Host "[dry-run] Would stop WSL/QEMU instance '$InstanceName' at $workRoot"
        return
    }

    $stopScript = @'
set -euo pipefail

work_root="$1"
pid_file="$work_root/qemu.pid"

if [ -f "$pid_file" ]; then
  pid=$(cat "$pid_file" 2>/dev/null || true)
  if [ -n "$pid" ]; then
    kill "$pid" 2>/dev/null || true
    for i in $(seq 1 50); do
      kill -0 "$pid" 2>/dev/null || break
      sleep 0.1
    done
    kill -9 "$pid" 2>/dev/null || true
  fi
fi

pkill -f "$work_root" 2>/dev/null || true
for i in $(seq 1 30); do
  pgrep -f "$work_root" >/dev/null 2>&1 || break
  sleep 0.1
done
pkill -9 -f "$work_root" 2>/dev/null || true
rm -rf "$work_root"
'@

    $stopResult = Invoke-WslRootBash -Distro $Distro -ScriptContent $stopScript -Arguments @($workRoot)
    if ($stopResult.ExitCode -ne 0) {
        throw (("Failed to stop WSL/QEMU instance '{0}' with exit code {1}`n{2}" -f $InstanceName, $stopResult.ExitCode, (($stopResult.Output | ForEach-Object { [string]$_ }) -join [Environment]::NewLine)).Trim())
    }
}
