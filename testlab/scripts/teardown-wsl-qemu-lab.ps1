param(
    [string]$LabConfig = "testlab/config/lab.local.json",
    [string[]]$NodeNames = @("nodeA", "nodeB"),
    [switch]$Execute
)

$ErrorActionPreference = "Stop"

. (Join-Path $PSScriptRoot "wsl-common.ps1")

function Get-Json {
    param([string]$Path)
    return Get-Content -Raw -Path $Path | ConvertFrom-Json
}

function Stop-WslLabInstance {
    param(
        [string]$Distro,
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

if (-not (Test-Path -LiteralPath $LabConfig)) {
    throw "Missing lab config: $LabConfig"
}

$lab = Get-Json -Path $LabConfig
$wslCfg = $lab.wslQemu
$distro = if ($wslCfg -and $wslCfg.distro) { [string]$wslCfg.distro } else { "Ubuntu" }

foreach ($nodeName in $NodeNames) {
    $node = $lab.nodes.$nodeName
    if (-not $node) {
        continue
    }

    $instanceName = if ($node.instanceName) { [string]$node.instanceName } else { "lab-$nodeName" }
    Stop-WslLabInstance -Distro $distro -InstanceName $instanceName -DoExecute:$Execute
}

if (-not $Execute) {
    Write-Host ""
    Write-Host "Dry-run complete. Pass -Execute to actually stop the local WSL/QEMU nodes."
}