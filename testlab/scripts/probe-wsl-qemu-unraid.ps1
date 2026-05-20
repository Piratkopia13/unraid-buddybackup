param(
    [string]$Distro = "Ubuntu",
    [string]$PayloadPath = ".testlab/cache/unraid-extracted",
    [string]$SshPublicKeyPath = ".testlab/lab_key.pub",
    [string]$SshPrivateKeyPath = ".testlab/lab_key",
    [string]$InstanceName = "probe",
    [int]$ImageSizeMB = 1024,
    [int]$DataDiskSizeGB = 24,
    [int]$BootWaitSeconds = 35,
    [int]$HostSshPort = 2222,
    [string]$OutputPath,
    [string]$StatusPath,
    [switch]$LeaveRunning
)

$ErrorActionPreference = "Stop"

. (Join-Path $PSScriptRoot "wsl-common.ps1")

function Get-FreeLoopbackPort {
    param([int]$PreferredPort)

    foreach ($candidatePort in $PreferredPort..($PreferredPort + 99)) {
        $listener = $null
        try {
            $listener = [System.Net.Sockets.TcpListener]::new([System.Net.IPAddress]::Loopback, $candidatePort)
            $listener.Start()
            return $candidatePort
        } catch {
            continue
        } finally {
            if ($listener) {
                $listener.Stop()
            }
        }
    }

    throw "Could not find a free localhost TCP port near $PreferredPort for the QEMU SSH forward."
}

function Resolve-WorkspacePath {
    param([string]$Path)

    if ([string]::IsNullOrWhiteSpace($Path)) {
        return $Path
    }

    if ([System.IO.Path]::IsPathRooted($Path)) {
        return Expand-LocalPath $Path
    }

    $workspaceRoot = [System.IO.Path]::GetFullPath((Join-Path $PSScriptRoot "..\.."))
    return [System.IO.Path]::GetFullPath((Join-Path $workspaceRoot $Path))
}

function Stop-WslProbeQemu {
    param(
        [string]$Distro,
        [string]$WslWorkingRoot
    )

    $stopScript = @'
set -euo pipefail

work_root="$1"
pid_file="$work_root/qemu.pid"

if [ -f "$pid_file" ]; then
  kill "$(cat "$pid_file")" 2>/dev/null || true
  rm -f "$pid_file"
fi

pkill -f "$work_root/unraid-boot.img" 2>/dev/null || true
rm -f "$work_root/qemu-monitor.sock"
'@

    $stopResult = Invoke-WslRootBash -Distro $Distro -ScriptContent $stopScript -Arguments @($WslWorkingRoot)
    if ($stopResult.ExitCode -ne 0) {
        throw (("Failed to stop existing WSL QEMU probe with exit code {0}`n{1}" -f $stopResult.ExitCode, (($stopResult.Output | ForEach-Object { [string]$_ }) -join [Environment]::NewLine)).Trim())
    }
}

function Test-PngSignature {
    param([string]$Path)

    if (-not (Test-Path $Path)) {
        return $false
    }

    $header = Get-Content -LiteralPath $Path -Encoding Byte -TotalCount 8
    $pngHeader = @(0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A)
    if ($header.Count -ne $pngHeader.Count) {
        return $false
    }

    for ($i = 0; $i -lt $header.Count; $i++) {
        if ($header[$i] -ne $pngHeader[$i]) {
            return $false
        }
    }

    return $true
}

function Write-ProbeStatus {
    param(
        [string]$Path,
        $StatusObject
    )

    $statusDir = Split-Path -Parent $Path
    if ($statusDir -and -not (Test-Path $statusDir)) {
        New-Item -ItemType Directory -Path $statusDir -Force | Out-Null
    }

    $StatusObject | ConvertTo-Json -Depth 6 | Set-Content -LiteralPath $Path -Encoding UTF8
}

if ($ImageSizeMB -lt 512) {
    throw "ImageSizeMB must be at least 512 MB."
}
if ($DataDiskSizeGB -lt 4) {
    throw "DataDiskSizeGB must be at least 4 GB."
}
if ($BootWaitSeconds -lt 5) {
    throw "BootWaitSeconds must be at least 5 seconds."
}
if ($InstanceName -notmatch '^[A-Za-z0-9._-]+$') {
    throw "InstanceName '$InstanceName' contains unsupported characters. Use only letters, digits, dots, underscores, and hyphens."
}

$payloadSourcePath = Resolve-WorkspacePath $PayloadPath
if (-not (Test-Path $payloadSourcePath)) {
    throw "Unraid payload path not found: $payloadSourcePath"
}

$requiredPayloadPaths = @(
    "bzimage",
    "bzroot",
    "syslinux/mbr.bin",
    "syslinux/syslinux.cfg",
    "syslinux/syslinux_linux"
)
foreach ($relativePath in $requiredPayloadPaths) {
    $candidate = Join-Path $payloadSourcePath $relativePath
    if (-not (Test-Path $candidate)) {
        throw "Required Unraid payload file not found: $candidate"
    }
}

$publicKeySourcePath = $null
if ($SshPublicKeyPath) {
    $publicKeyCandidate = Resolve-WorkspacePath $SshPublicKeyPath
    if (Test-Path $publicKeyCandidate) {
        $publicKeySourcePath = $publicKeyCandidate
    }
}

$privateKeySourcePath = $null
if ($SshPrivateKeyPath) {
    $privateKeyCandidate = Resolve-WorkspacePath $SshPrivateKeyPath
    if (Test-Path $privateKeyCandidate) {
        $privateKeySourcePath = $privateKeyCandidate
    }
}

if (-not $OutputPath) {
    $stamp = Get-Date -Format "yyyyMMdd-HHmmss"
    $OutputPath = Join-Path $env:LOCALAPPDATA "BuddyBackup\screenshots\qemu-unraid-${stamp}.png"
}
$resolvedOutputPath = Expand-LocalPath $OutputPath
$outputDir = Split-Path -Parent $resolvedOutputPath
if ($outputDir -and -not (Test-Path $outputDir)) {
    New-Item -ItemType Directory -Path $outputDir -Force | Out-Null
}

if (-not $StatusPath) {
    $StatusPath = [System.IO.Path]::ChangeExtension($resolvedOutputPath, ".json")
}
$resolvedStatusPath = Expand-LocalPath $StatusPath

$probeStatus = [ordered]@{
    startedAt            = (Get-Date).ToString("o")
    finishedAt           = $null
    success              = $false
    error                = $null
    distro               = $Distro
    instanceName         = $InstanceName
    outputPath           = $resolvedOutputPath
    statusPath           = $resolvedStatusPath
    screenshotExists     = $false
    screenshotIsValidPng = $false
    selectedHostSshPort  = $null
    sshReady             = $false
    sshExitCode          = $null
    sshOutput            = @()
    leaveRunning         = [bool]$LeaveRunning
    monitorSocketPath    = $null
    serialLogPath        = $null
    wslWorkingRoot       = $null
    dataDiskPath         = $null
    serialTail           = @()
}

$windowsWorkingRoot = Join-Path $env:LOCALAPPDATA "BuddyBackup\wsl-qemu"
$payloadCachePath = Join-Path $windowsWorkingRoot "payload"
$keyCachePath = Join-Path $windowsWorkingRoot "lab_key.pub"
$privateKeyCachePath = Join-Path $windowsWorkingRoot "lab_key"
New-Item -ItemType Directory -Path $windowsWorkingRoot -Force | Out-Null
if (Test-Path $payloadCachePath) {
    Remove-Item -Path $payloadCachePath -Recurse -Force
}
New-Item -ItemType Directory -Path $payloadCachePath -Force | Out-Null
Copy-Item -Path (Join-Path $payloadSourcePath "*") -Destination $payloadCachePath -Recurse -Force

$cachedPublicKeyPath = ""
if ($publicKeySourcePath) {
    Copy-Item -Path $publicKeySourcePath -Destination $keyCachePath -Force
    $cachedPublicKeyPath = $keyCachePath
}

$cachedPrivateKeyPath = ""
if ($privateKeySourcePath) {
    Copy-Item -Path $privateKeySourcePath -Destination $privateKeyCachePath -Force
    $cachedPrivateKeyPath = $privateKeyCachePath
}

$wslPayloadCachePath = Convert-WindowsPathToWslPath -WindowsPath $payloadCachePath
$wslPublicKeyPath = if ($cachedPublicKeyPath) { Convert-WindowsPathToWslPath -WindowsPath $cachedPublicKeyPath } else { "" }
$wslPrivateKeyPath = if ($cachedPrivateKeyPath) { Convert-WindowsPathToWslPath -WindowsPath $cachedPrivateKeyPath } else { "" }

$wslWorkingRoot = "/tmp/buddybackup-qemu-$InstanceName"
$monitorSocketPath = "$wslWorkingRoot/qemu-monitor.sock"
$serialLogPath = "$wslWorkingRoot/unraid-serial.log"
$pidFilePath = "$wslWorkingRoot/qemu.pid"
$dataDiskPath = "$wslWorkingRoot/buddybackup-data.img"
$probeStatus.monitorSocketPath = $monitorSocketPath
$probeStatus.serialLogPath = $serialLogPath
$probeStatus.wslWorkingRoot = $wslWorkingRoot
$probeStatus.dataDiskPath = $dataDiskPath
$selectedHostSshPort = Get-FreeLoopbackPort -PreferredPort $HostSshPort
$probeStatus.selectedHostSshPort = $selectedHostSshPort
if ($selectedHostSshPort -ne $HostSshPort) {
    Write-Host "[testlab] Host SSH port $HostSshPort is busy; using localhost:$selectedHostSshPort for this probe."
}

Stop-WslProbeQemu -Distro $Distro -WslWorkingRoot $wslWorkingRoot

$buildScript = @'
set -euo pipefail

payload_root="$1"
public_key_path="$2"
image_size_mb="$3"
work_root="$4"
monitor_socket="$5"
serial_log="$6"
pid_file="$7"
host_ssh_port="$8"
data_disk_size_gb="$9"

require_command() {
  command -v "$1" >/dev/null 2>&1
}

if ! require_command qemu-system-x86_64 || ! require_command losetup || ! require_command parted || ! require_command mkfs.vfat || ! require_command socat || ! require_command pnmtopng; then
  apt-get update >/dev/null
  apt-get install -y qemu-system-x86 qemu-utils dosfstools parted netpbm socat >/dev/null
fi

rm -rf "$work_root"
mkdir -p "$work_root/mnt"

image_path="$work_root/unraid-boot.img"
data_image_path="$work_root/buddybackup-data.img"
mount_dir="$work_root/mnt"

truncate -s "${image_size_mb}M" "$image_path"
truncate -s "${data_disk_size_gb}G" "$data_image_path"
parted -s "$image_path" mklabel msdos
parted -s "$image_path" mkpart primary fat32 1MiB 100%
parted -s "$image_path" set 1 boot on

loop_device=$(losetup --find --show -P "$image_path")
cleanup_loop() {
  if mountpoint -q "$mount_dir"; then
    umount "$mount_dir" || true
  fi
  if [ -n "${loop_device:-}" ]; then
    losetup -d "$loop_device" || true
  fi
}
trap cleanup_loop EXIT

mkfs.vfat -F 32 -n UNRAID "${loop_device}p1" >/dev/null
mount "${loop_device}p1" "$mount_dir"
cp -r "$payload_root"/. "$mount_dir"/

mkdir -p "$mount_dir/config"
ident_cfg="$mount_dir/config/ident.cfg"
if [ -f "$ident_cfg" ]; then
    if grep -q '^USE_SSH=' "$ident_cfg"; then
        sed -i 's/^USE_SSH=.*/USE_SSH="yes"/' "$ident_cfg"
    else
        printf '\nUSE_SSH="yes"\n' >> "$ident_cfg"
    fi
else
    printf 'USE_SSH="yes"\n' > "$ident_cfg"
fi
if [ -n "$public_key_path" ] && [ -f "$public_key_path" ]; then
  mkdir -p "$mount_dir/config/ssh"
  cp "$public_key_path" "$mount_dir/config/ssh/authorized_keys"
  cat >> "$mount_dir/config/go" <<'EOF'

# BuddyBackup testlab: ensure SSH key is loaded on every boot
mkdir -p /root/.ssh
chmod 700 /root/.ssh
cp /boot/config/ssh/authorized_keys /root/.ssh/authorized_keys 2>/dev/null || true
chmod 600 /root/.ssh/authorized_keys 2>/dev/null || true
if [ -x /etc/rc.d/rc.sshd ]; then
    chmod +x /etc/rc.d/rc.sshd 2>/dev/null || true
    /etc/rc.d/rc.sshd start 2>/dev/null || true
fi
EOF
fi

if [ -f "$mount_dir/syslinux/syslinux.cfg" ]; then
    sed -Ei 's#^([[:space:]]*append[[:space:]]+initrd=[^[:cntrl:]]*)$#\1 unraidlabel=UNRAID console=tty0 console=ttyS0,115200n8 earlyprintk=serial,ttyS0,115200 earlycon=uart,io,0x3f8,115200n8 loglevel=7#' "$mount_dir/syslinux/syslinux.cfg"
fi

sync
umount "$mount_dir"

chmod +x "$payload_root/syslinux/syslinux_linux"
"$payload_root/syslinux/syslinux_linux" -f --install "${loop_device}p1" >/dev/null
dd if="$payload_root/syslinux/mbr.bin" of="$loop_device" conv=notrunc status=none
fsck.fat -a "${loop_device}p1" >/dev/null || true
sync
losetup -d "$loop_device"
loop_device=""
trap - EXIT

qemu-system-x86_64 \
  -m 4096 \
  -smp 2 \
  -enable-kvm \
  -drive if=none,id=usbdisk,format=raw,file="$image_path" \
    -drive if=none,id=datadisk,format=raw,file="$data_image_path" \
    -device qemu-xhci,id=xhci \
    -device usb-storage,bus=xhci.0,drive=usbdisk,bootindex=1 \
        -device virtio-blk-pci,drive=datadisk,serial=buddybackup_data \
  -netdev user,id=net0,hostfwd=tcp:127.0.0.1:${host_ssh_port}-:22 \
  -device e1000,netdev=net0 \
  -serial file:"$serial_log" \
  -monitor unix:"$monitor_socket",server,nowait \
  -vga std \
  -display none \
  -pidfile "$pid_file" \
  -daemonize

echo "image_path=$image_path"
echo "monitor_socket=$monitor_socket"
echo "serial_log=$serial_log"
echo "pid_file=$pid_file"
echo "data_image_path=$data_image_path"
'@

$buildResult = Invoke-WslRootBash -Distro $Distro -ScriptContent $buildScript -Arguments @(
    $wslPayloadCachePath,
    $wslPublicKeyPath,
    [string]$ImageSizeMB,
    $wslWorkingRoot,
    $monitorSocketPath,
    $serialLogPath,
    $pidFilePath,
    [string]$selectedHostSshPort,
    [string]$DataDiskSizeGB
)

if ($buildResult.ExitCode -ne 0) {
    $probeStatus.error = (("WSL/QEMU probe setup failed with exit code {0}`n{1}" -f $buildResult.ExitCode, (($buildResult.Output | ForEach-Object { [string]$_ }) -join [Environment]::NewLine)).Trim())
    $probeStatus.finishedAt = (Get-Date).ToString("o")
    Write-ProbeStatus -Path $resolvedStatusPath -StatusObject $probeStatus
    throw $probeStatus.error
}

$serialTailScript = @'
set -euo pipefail
serial_log="$1"
if [ -f "$serial_log" ]; then
  tail -n 80 "$serial_log"
fi
'@

$sshProbeScript = @'
set -euo pipefail
private_key_path="$1"
host_ssh_port="$2"

if ! command -v ssh >/dev/null 2>&1; then
    apt-get update >/dev/null
    apt-get install -y openssh-client >/dev/null
fi

chmod 600 "$private_key_path"
ssh -o BatchMode=yes -o ConnectTimeout=5 -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o GlobalKnownHostsFile=/dev/null -o IdentitiesOnly=yes -i "$private_key_path" -p "$host_ssh_port" root@127.0.0.1 "echo ready"
'@

$serialResult = $null
$sshReady = $false
$sshExitCode = $null
$sshOutput = @()
$startedQemu = $true

try {
    Start-Sleep -Seconds $BootWaitSeconds

    & (Join-Path $PSScriptRoot "capture-wsl-qemu-screen.ps1") -Distro $Distro -MonitorSocketPath $monitorSocketPath -OutputPath $resolvedOutputPath

    $serialResult = Invoke-WslRootBash -Distro $Distro -ScriptContent $serialTailScript -Arguments @($serialLogPath)
    if ($serialResult.ExitCode -ne 0) {
        throw (("Failed to read QEMU serial log with exit code {0}`n{1}" -f $serialResult.ExitCode, (($serialResult.Output | ForEach-Object { [string]$_ }) -join [Environment]::NewLine)).Trim())
    }
    $probeStatus.serialTail = @($serialResult.Output)

    if ($wslPrivateKeyPath) {
        $sshResult = Invoke-WslRootBash -Distro $Distro -ScriptContent $sshProbeScript -Arguments @(
            $wslPrivateKeyPath,
            [string]$selectedHostSshPort
        )
        $sshOutput = @($sshResult.Output | ForEach-Object { [string]$_ })
        $sshExitCode = $sshResult.ExitCode
        $sshReady = ($sshExitCode -eq 0)
    }
    $probeStatus.sshReady = $sshReady
    $probeStatus.sshExitCode = $sshExitCode
    $probeStatus.sshOutput = @($sshOutput)
    $probeStatus.screenshotExists = Test-Path $resolvedOutputPath
    $probeStatus.screenshotIsValidPng = Test-PngSignature -Path $resolvedOutputPath
    $probeStatus.success = $true

    Write-Host "[testlab] QEMU screenshot: $resolvedOutputPath"
    Write-Host "[testlab] WSL monitor socket: $monitorSocketPath"
    Write-Host "[testlab] WSL serial log: $serialLogPath"
    Write-Host "[testlab] SSH ready on localhost:$selectedHostSshPort : $sshReady"
    if ($serialResult.Output.Count -gt 0) {
        Write-Host "[testlab] Serial tail:"
        $serialResult.Output | ForEach-Object { Write-Host $_ }
    }
    if ($sshOutput.Count -gt 0) {
        Write-Host "[testlab] SSH probe output:"
        $sshOutput | ForEach-Object { Write-Host $_ }
    }
} catch {
    $probeStatus.error = ($_ | Out-String).Trim()
    throw
} finally {
    if ($startedQemu -and -not $LeaveRunning) {
        Stop-WslProbeQemu -Distro $Distro -WslWorkingRoot $wslWorkingRoot
    }
    $probeStatus.finishedAt = (Get-Date).ToString("o")
    if (-not $probeStatus.screenshotExists) {
        $probeStatus.screenshotExists = Test-Path $resolvedOutputPath
    }
    if (-not $probeStatus.screenshotIsValidPng -and $probeStatus.screenshotExists) {
        $probeStatus.screenshotIsValidPng = Test-PngSignature -Path $resolvedOutputPath
    }
    Write-ProbeStatus -Path $resolvedStatusPath -StatusObject $probeStatus
}