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

self_pid=$$
for pid in $(pgrep -f "$work_root" 2>/dev/null || true); do
  if [ "$pid" != "$self_pid" ]; then
    kill "$pid" 2>/dev/null || true
  fi
done
for i in $(seq 1 30); do
  remaining=0
  for pid in $(pgrep -f "$work_root" 2>/dev/null || true); do
    if [ "$pid" != "$self_pid" ]; then
      remaining=1
      break
    fi
  done
  [ "$remaining" -eq 0 ] && break
  sleep 0.1
done
for pid in $(pgrep -f "$work_root" 2>/dev/null || true); do
  if [ "$pid" != "$self_pid" ]; then
    kill -9 "$pid" 2>/dev/null || true
  fi
done

# Unmount any mounts inside work_root (deepest first)
if [ -f /proc/mounts ] && [ -d "$work_root" ]; then
  awk -v prefix="$work_root" '$2 == prefix || index($2, prefix "/") == 1 { print $2 }' /proc/mounts | sort -r -u | while IFS= read -r mp; do
    umount "$mp" 2>/dev/null || umount -l "$mp" 2>/dev/null || true
  done
fi

# Detach any loop devices associated with files inside work_root
if command -v losetup >/dev/null 2>&1; then
  losetup -a 2>/dev/null | while IFS=: read -r loop_dev rest; do
    case "$rest" in
      *"($work_root"*)
        if [ -f /proc/mounts ]; then
          awk -v dev="$loop_dev" '$1 == dev || index($1, dev "p") == 1 { print $2 }' /proc/mounts | sort -r -u | while IFS= read -r mp; do
            umount "$mp" 2>/dev/null || umount -l "$mp" 2>/dev/null || true
          done
        fi
        losetup -d "$loop_dev" 2>/dev/null || true
        ;;
    esac
  done
fi

# Secondary pass to ensure all mounts under work_root are detached
if [ -f /proc/mounts ] && [ -d "$work_root" ]; then
  awk -v prefix="$work_root" '$2 == prefix || index($2, prefix "/") == 1 { print $2 }' /proc/mounts | sort -r -u | while IFS= read -r mp; do
    umount -l "$mp" 2>/dev/null || true
  done
fi

rm -rf "$work_root"
'@

    $stopResult = Invoke-WslRootBash -Distro $Distro -ScriptContent $stopScript -Arguments @($workRoot)
    if ($stopResult.ExitCode -ne 0) {
        throw (("Failed to stop WSL/QEMU instance '{0}' with exit code {1}`n{2}" -f $InstanceName, $stopResult.ExitCode, (($stopResult.Output | ForEach-Object { [string]$_ }) -join [Environment]::NewLine)).Trim())
    }
}
