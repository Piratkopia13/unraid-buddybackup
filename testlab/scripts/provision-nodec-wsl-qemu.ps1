<#
.SYNOPSIS
Provisions a throwaway generic OpenZFS host (nodeC) inside the WSL/QEMU testlab for the generic smoke.

.DESCRIPTION
Boots a cloud image (Ubuntu 24.04 by default; Debian cloud images work via -ImageUrl) inside the
WSL distro used by the local provider, forwards its SSH to a localhost port (default 2224), injects
the lab SSH public key for root via cloud-init, installs OpenZFS and creates the pool that
run-generic-smoke.ps1 expects.

Defaults to dry-run; pass -Execute to make changes. Re-running against a live nodeC is a health
check (it reuses the existing disks and verifies SSH + pool). Use -Teardown to stop the VM and
-Teardown -RemoveDisks to delete its disks.

The script reads testlab/config/lab.local.json for the WSL distro, the nodeC SSH port, the ZFS
pool name and the lab identity file, so it lines up with the smoke's expectations out of the box.
#>
param(
    [string]$LabConfig = "testlab/config/lab.local.json",
    [string]$Distro = "",
    [int]$SshPort = 0,
    [string]$ImageUrl = "https://cloud-images.ubuntu.com/noble/current/noble-server-cloudimg-amd64.img",
    [string]$VmRoot = "/var/lib/buddybackup-nodec",
    [int]$MemoryMB = 3072,
    [int]$Cpus = 2,
    [int]$DataDiskGB = 8,
    [int]$SshReadySeconds = 420,
    [switch]$Recreate,
    [switch]$Teardown,
    [switch]$RemoveDisks,
    [switch]$Execute
)

$ErrorActionPreference = "Stop"

. (Join-Path $PSScriptRoot "unraid-payload-cache.ps1")
. (Join-Path $PSScriptRoot "wsl-common.ps1")

function Get-Json {
    param([string]$Path)
    return Get-Content -Raw -Path $Path | ConvertFrom-Json
}

function Get-ObjectValue {
    param(
        $Object,
        [string]$Name
    )

    if ($null -eq $Object -or [string]::IsNullOrWhiteSpace($Name)) {
        return $null
    }

    if ($Object -is [System.Collections.IDictionary]) {
        return $Object[$Name]
    }

    $property = $Object.PSObject.Properties[$Name]
    if ($property) {
        return $property.Value
    }

    return $null
}

function Get-LocalSshIdentityFile {
    param([string]$IdentityFile)

    if ([string]::IsNullOrWhiteSpace($IdentityFile)) {
        return $IdentityFile
    }

    $resolvedPath = Resolve-TestLabPath $IdentityFile
    if (-not (Test-Path -LiteralPath $resolvedPath)) {
        throw "SSH identity file not found: $resolvedPath"
    }

    $cacheRoot = Join-Path $env:LOCALAPPDATA "BuddyBackup\ssh-cache"
    Ensure-TestLabDir $cacheRoot

    $pathHashBytes = [System.Text.Encoding]::UTF8.GetBytes($resolvedPath)
    $pathHash = [System.BitConverter]::ToString(([System.Security.Cryptography.SHA256]::Create().ComputeHash($pathHashBytes))).Replace("-", "").ToLowerInvariant()
    $fileName = "{0}-{1}" -f ([System.IO.Path]::GetFileName($resolvedPath)), $pathHash.Substring(0, 12)
    $cachedPath = Join-Path $cacheRoot $fileName

    Copy-Item -LiteralPath $resolvedPath -Destination $cachedPath -Force

    if ($env:OS -eq 'Windows_NT') {
        $currentUser = [System.Security.Principal.WindowsIdentity]::GetCurrent().Name
        & icacls $cachedPath /inheritance:r /grant:r "${currentUser}:(F)" | Out-Null
    }

    return $cachedPath
}

function Convert-ToRemoteSingleQuotedArgument {
    param([string]$Value)

    return "'{0}'" -f ($Value -replace "'", "'\''")
}

function Invoke-NodeSshCommand {
    param(
        $NodeConnection,
        [string]$Command,
        [string]$Label,
        [switch]$DoExecute
    )

    $sshArgs = @(
        "-F", "NUL",
        "-o", "BatchMode=yes",
        "-o", "ConnectTimeout=8",
        "-o", "ServerAliveInterval=15",
        "-o", "ServerAliveCountMax=4",
        "-o", "IdentitiesOnly=yes",
        "-o", "LogLevel=ERROR",
        "-o", "StrictHostKeyChecking=no",
        "-o", "UserKnownHostsFile=NUL",
        "-o", "GlobalKnownHostsFile=NUL",
        "-p", ([string]$NodeConnection.Port)
    )

    if ($NodeConnection.IdentityFile) {
        $identityPath = Get-LocalSshIdentityFile -IdentityFile ([string]$NodeConnection.IdentityFile)
        $sshArgs += @("-i", $identityPath)
    }

    $sshArgs += @("$($NodeConnection.User)@$($NodeConnection.Host)", $Command)

    if (-not $DoExecute) {
        Write-Host "[dry-run][nodec][$Label] ssh $($sshArgs -join ' ')"
        return [pscustomobject]@{
            label = $Label
            success = $true
            exitCode = 0
            output = @("dry-run")
        }
    }

    $previousErrorActionPreference = $ErrorActionPreference
    try {
        $ErrorActionPreference = "Continue"
        $rawOutput = & ssh @sshArgs 2>&1
        $exitCode = $LASTEXITCODE
    } finally {
        $ErrorActionPreference = $previousErrorActionPreference
    }

    return [pscustomobject]@{
        label = $Label
        success = ($exitCode -eq 0)
        exitCode = $exitCode
        output = @($rawOutput | ForEach-Object { [string]$_ })
    }
}

function Invoke-NodeBashScript {
    param(
        $NodeConnection,
        [string]$ScriptContent,
        [string[]]$Arguments,
        [string]$Label,
        [switch]$DoExecute
    )

    $normalizedScript = ($ScriptContent -replace "`r`n", "`n").Trim()
    $scriptB64 = [Convert]::ToBase64String([System.Text.Encoding]::UTF8.GetBytes($normalizedScript))
    $command = "printf '%s' '$scriptB64' | base64 -d | bash -s --"
    if ($Arguments -and $Arguments.Count -gt 0) {
        $command += " " + (($Arguments | ForEach-Object { Convert-ToRemoteSingleQuotedArgument -Value ([string]$_) }) -join " ")
    }

    return Invoke-NodeSshCommand -NodeConnection $NodeConnection -Command $command -Label $Label -DoExecute:$DoExecute
}

function Invoke-NodecWslScript {
    param(
        [string]$Label,
        [string]$ScriptContent,
        [string[]]$Arguments = @(),
        [switch]$DoExecute
    )

    if (-not $DoExecute) {
        Write-Host "[dry-run][nodec][$Label] WSL step in distro '$Distro' (no changes)"
        return [pscustomobject]@{
            label = $Label
            success = $true
            exitCode = 0
            output = @("dry-run")
        }
    }

    $result = Invoke-WslRootBash -Distro $Distro -ScriptContent $ScriptContent -Arguments $Arguments
    $outputLines = @($result.Output | ForEach-Object { [string]$_ })

    return [pscustomobject]@{
        label = $Label
        success = ($result.ExitCode -eq 0)
        exitCode = $result.ExitCode
        output = $outputLines
    }
}

function Add-NodecAction {
    param(
        $Report,
        $Result
    )

    $Report.actions += $Result
}

function Assert-NodecSuccess {
    param(
        $Result,
        [string]$FailureMessage
    )

    if (-not $Result -or -not $Result.success) {
        $outputText = if ($Result) {
            (@($Result.output | ForEach-Object { [string]$_ }) -join [Environment]::NewLine).Trim()
        } else {
            "no result"
        }
        throw "$FailureMessage`n$outputText"
    }
}

$ensureToolsScript = @'
set -euo pipefail

install_missing="$1"
missing=""
for c in qemu-system-x86_64 qemu-img curl cloud-localds; do
  if ! command -v "$c" >/dev/null 2>&1; then
    missing="$missing $c"
  fi
done

if [ -n "$missing" ]; then
  echo "missing-tools:$missing"
  if [ "$install_missing" != "1" ]; then
    echo "ERROR: required WSL tools are missing:$missing" >&2
    exit 1
  fi
  export DEBIAN_FRONTEND=noninteractive
  apt-get update -qq
  apt-get install -y -qq qemu-system-x86 qemu-utils cloud-image-utils curl
fi

for c in qemu-system-x86_64 qemu-img curl cloud-localds; do
  if ! command -v "$c" >/dev/null 2>&1; then
    echo "ERROR: tool still missing after install: $c" >&2
    exit 1
  fi
done

echo "tools-ok"
'@

$prepareDisksScript = @'
set -euo pipefail

vm_root="$1"
image_url="$2"
recreate="$3"
data_gb="$4"
pubkey_b64="$5"

mkdir -p "$vm_root"

boot_image="$vm_root/nodec-boot.qcow2"
data_image="$vm_root/nodec-data.qcow2"
seed_image="$vm_root/seed.iso"

if [ "$recreate" = "1" ]; then
  rm -f "$boot_image" "$data_image" "$seed_image" "$vm_root/user-data" "$vm_root/meta-data"
fi

if [ ! -f "$boot_image" ]; then
  echo "downloading cloud image: $image_url"
  tmp_image="$boot_image.part"
  rm -f "$tmp_image"
  curl -fL --retry 3 --retry-delay 5 -o "$tmp_image" "$image_url"
  mv "$tmp_image" "$boot_image"
fi

if [ ! -f "$data_image" ]; then
  qemu-img create -f qcow2 "$data_image" "${data_gb}G" >/dev/null
fi

public_key=$(printf '%s' "$pubkey_b64" | base64 -d)
cat > "$vm_root/user-data" <<CLOUD_INIT_EOF
#cloud-config
disable_root: false
ssh_pwauth: false
users:
  - name: root
    ssh_authorized_keys:
      - ${public_key}
write_files:
  - path: /etc/ssh/sshd_config.d/99-buddybackup-nodec.conf
    permissions: '0644'
    content: |
      PermitRootLogin prohibit-password
CLOUD_INIT_EOF

printf 'instance-id: nodec\nlocal-hostname: buddybackup-nodec\n' > "$vm_root/meta-data"
cloud-localds "$seed_image" "$vm_root/user-data" "$vm_root/meta-data"

ls -lh "$boot_image" "$data_image" "$seed_image"
echo "prepare-ok"
'@

$launchVmScript = @'
set -euo pipefail

vm_root="$1"
ssh_port="$2"
memory_mb="$3"
cpus="$4"

pid_file="$vm_root/qemu.pid"

if [ -f "$pid_file" ]; then
  pid=$(cat "$pid_file" 2>/dev/null || true)
  if [ -n "$pid" ] && kill -0 "$pid" 2>/dev/null; then
    echo "already-running=$pid"
    exit 0
  fi
  rm -f "$pid_file"
fi

rm -f "$vm_root/serial.log"

# Boot the cloud image from a USB storage device. QEMU 8.2.2+ds-0ubuntu1.18 in
# this WSL lab fails to BIOS-boot this image from virtio-blk ("Boot failed: not
# a bootable disk"), while the same image boots fine through the xHCI path that
# the Unraid lab nodes use, so keep the boot path consistent with them.
qemu-system-x86_64 \
  -m "$memory_mb" -smp "$cpus" -enable-kvm -cpu host \
  -device qemu-xhci,id=xhci \
  -device usb-storage,bus=xhci.0,drive=nodecboot,bootindex=1 \
  -drive if=none,id=nodecboot,format=qcow2,file="$vm_root/nodec-boot.qcow2" \
  -drive if=none,id=nodecdata,format=qcow2,file="$vm_root/nodec-data.qcow2" \
  -device virtio-blk-pci,drive=nodecdata,serial=bbnodecdata \
  -drive if=virtio,format=raw,file="$vm_root/seed.iso" \
  -netdev user,id=net0,hostfwd=tcp:127.0.0.1:${ssh_port}-:22 \
  -device virtio-net-pci,netdev=net0 \
  -serial file:"$vm_root/serial.log" \
  -display none -daemonize -pidfile "$pid_file"

echo "launched=$(cat "$pid_file")"
'@

$teardownScript = @'
set -euo pipefail

vm_root="$1"
remove_disks="$2"

stopped="no"

if [ -f "$vm_root/qemu.pid" ]; then
  pid=$(cat "$vm_root/qemu.pid" 2>/dev/null || true)
  if [ -n "$pid" ] && kill -0 "$pid" 2>/dev/null; then
    kill "$pid" 2>/dev/null || true
    for _ in $(seq 1 20); do
      if ! kill -0 "$pid" 2>/dev/null; then
        break
      fi
      sleep 1
    done
    if kill -0 "$pid" 2>/dev/null; then
      kill -9 "$pid" 2>/dev/null || true
    fi
    stopped="yes"
  fi
fi

pkill -f "$vm_root/nodec-boot.qcow2" 2>/dev/null || true
rm -f "$vm_root/qemu.pid"

echo "stopped=$stopped"

if [ "$remove_disks" = "1" ]; then
  rm -rf "$vm_root"
  echo "disks-removed=yes"
fi
'@

$bootDiagnosticsScript = @'
set -uo pipefail

vm_root="$1"
pid_file="$vm_root/qemu.pid"

vm_state="not-running"
if [ -f "$pid_file" ]; then
  pid=$(cat "$pid_file" 2>/dev/null || true)
  if [ -n "$pid" ] && kill -0 "$pid" 2>/dev/null; then
    vm_state="running"
  else
    vm_state="exited"
  fi
fi
echo "vm-state=$vm_state"

if [ -f "$vm_root/serial.log" ]; then
  echo "serial-log-tail:"
  tail -n 30 "$vm_root/serial.log" 2>/dev/null || true
else
  echo "serial-log-tail: (missing)"
fi
'@

$ensureZfsScript = @'
set -euo pipefail

pool="$1"
data_dev="/dev/disk/by-id/virtio-bbnodecdata"
if [ ! -e "$data_dev" ]; then
  for candidate in /dev/disk/by-id/virtio-bbnodecdata*; do
    if [ -e "$candidate" ]; then
      data_dev="$candidate"
      break
    fi
  done
fi

if ! command -v zpool >/dev/null 2>&1 || ! zpool list -H -o name "$pool" >/dev/null 2>&1; then
  export DEBIAN_FRONTEND=noninteractive
  apt-get update -qq

  if grep -qi ubuntu /etc/os-release 2>/dev/null; then
    apt-get install -y -qq "linux-modules-extra-$(uname -r)" zfsutils-linux
  else
    if ! apt-get install -y -qq linux-headers-cloud-amd64 2>/dev/null; then
      apt-get install -y -qq "linux-headers-$(uname -r)"
    fi
    apt-get install -y -qq zfsutils-linux
  fi

  modprobe zfs

  if [ ! -e "$data_dev" ]; then
    echo "ERROR: nodeC data disk not found at $data_dev" >&2
    ls -l /dev/disk/by-id/ >&2 || true
    exit 1
  fi

  if ! zpool list -H -o name "$pool" >/dev/null 2>&1; then
    zpool create -f "$pool" "$data_dev"
  fi
fi

zpool list -H -o name,size,health "$pool"
zfs version
echo "zfs-ready"
'@

$resolvedLabConfig = Resolve-TestLabPath $LabConfig
if (-not (Test-Path -LiteralPath $resolvedLabConfig)) {
    throw "Missing lab config: $resolvedLabConfig"
}

$lab = Get-Json -Path $resolvedLabConfig
$nodesCfg = Get-ObjectValue -Object $lab -Name "nodes"
$nodecCfg = Get-ObjectValue -Object $nodesCfg -Name "nodeC"
$wslCfg = Get-ObjectValue -Object $lab -Name "wslQemu"
$setupCfg = Get-ObjectValue -Object $lab -Name "setup"
$zfsCfg = Get-ObjectValue -Object $setupCfg -Name "zfs"
$sshCfg = Get-ObjectValue -Object $lab -Name "ssh"

$Distro = if (-not [string]::IsNullOrWhiteSpace($Distro)) {
    $Distro
} else {
    $configuredDistro = [string](Get-ObjectValue -Object $wslCfg -Name "distro")
    if ([string]::IsNullOrWhiteSpace($configuredDistro)) { "Ubuntu" } else { $configuredDistro }
}

if ($SshPort -le 0) {
    $configuredPort = Get-ObjectValue -Object $nodecCfg -Name "port"
    $SshPort = if ($configuredPort) { [int]$configuredPort } else { 2224 }
}

$resolvedPool = [string](Get-ObjectValue -Object $nodecCfg -Name "zfsPool")
if ([string]::IsNullOrWhiteSpace($resolvedPool)) {
    $resolvedPool = [string](Get-ObjectValue -Object $zfsCfg -Name "poolName")
}
if ([string]::IsNullOrWhiteSpace($resolvedPool)) {
    $resolvedPool = "bbpool"
}

$resolvedDatasetRoot = [string](Get-ObjectValue -Object $nodecCfg -Name "datasetRoot")
if ([string]::IsNullOrWhiteSpace($resolvedDatasetRoot)) {
    $resolvedDatasetRoot = [string](Get-ObjectValue -Object $zfsCfg -Name "datasetRoot")
}
if ([string]::IsNullOrWhiteSpace($resolvedDatasetRoot)) {
    $resolvedDatasetRoot = "buddybackup"
}

$resolvedUser = [string](Get-ObjectValue -Object $nodecCfg -Name "user")
if ([string]::IsNullOrWhiteSpace($resolvedUser)) {
    $resolvedUser = [string](Get-ObjectValue -Object $sshCfg -Name "user")
}
if ([string]::IsNullOrWhiteSpace($resolvedUser)) {
    $resolvedUser = "root"
}

$identityFile = [string](Get-ObjectValue -Object $nodecCfg -Name "identityFile")
if ([string]::IsNullOrWhiteSpace($identityFile)) {
    $identityFile = [string](Get-ObjectValue -Object $sshCfg -Name "identityFile")
}
if ([string]::IsNullOrWhiteSpace($identityFile)) {
    $identityFile = ".testlab/lab_key"
}

$identityPath = Resolve-TestLabPath $identityFile
if (-not (Test-Path -LiteralPath $identityPath)) {
    throw "SSH identity file not found: $identityPath"
}

$publicKeyPath = "$identityPath.pub"
if (-not (Test-Path -LiteralPath $publicKeyPath)) {
    $derivedKey = & ssh-keygen -y -f $identityPath 2>&1
    if ($LASTEXITCODE -ne 0 -or [string]::IsNullOrWhiteSpace(($derivedKey -join ""))) {
        throw "Unable to derive public key for $identityPath. Create $publicKeyPath manually."
    }
    Set-Content -LiteralPath $publicKeyPath -Value $derivedKey -Encoding ASCII
}

$publicKey = (Get-Content -Raw -Path $publicKeyPath).Trim()
if ([string]::IsNullOrWhiteSpace($publicKey)) {
    throw "Empty public key file: $publicKeyPath"
}
$publicKeyB64 = [Convert]::ToBase64String([System.Text.Encoding]::UTF8.GetBytes($publicKey))

$nodecConnection = [pscustomobject]@{
    NodeName     = "nodeC"
    User         = $resolvedUser
    Host         = "127.0.0.1"
    Port         = [int]$SshPort
    IdentityFile = $identityPath
}

if (-not $nodecCfg) {
    Write-Warning "nodes.nodeC is not defined in $resolvedLabConfig. run-generic-smoke.ps1 will still fail with 'Missing lab.nodes.nodeC.host' until you add it."
}

$logsRoot = if ($lab.logsRoot) { Resolve-TestLabPath ([string]$lab.logsRoot) } else { Resolve-TestLabPath ".testlab/logs" }
Ensure-TestLabDir $logsRoot
$runId = Get-Date -Format "yyyyMMdd-HHmmss"
$reportPath = Join-Path $logsRoot ("nodec-{0}.json" -f $runId)

$report = [ordered]@{
    runId       = $runId
    mode        = if ($Teardown) { "teardown" } else { "provision" }
    executeMode = [bool]$Execute
    success     = $false
    error       = $null
    reportPath  = $reportPath
    distro      = $Distro
    vmRoot      = $VmRoot
    sshPort     = [int]$SshPort
    poolName    = $resolvedPool
    datasetRoot = $resolvedDatasetRoot
    imageUrl    = $ImageUrl
    actions     = @()
}

try {
    if ($Teardown) {
        Write-Host "[testlab] Tearing down nodeC (vm root $VmRoot in distro '$Distro')"
        $removeDisksFlag = if ($RemoveDisks) { "1" } else { "0" }
        $teardownResult = Invoke-NodecWslScript -Label "teardown" -ScriptContent $teardownScript -Arguments @($VmRoot, $removeDisksFlag) -DoExecute:$Execute
        Add-NodecAction -Report $report -Result $teardownResult
        Assert-NodecSuccess -Result $teardownResult -FailureMessage "nodeC teardown failed."
        $report.success = $true
    } else {
        Write-Host "[testlab] Provisioning nodeC: distro '$Distro', SSH 127.0.0.1:$SshPort, pool '$resolvedPool', VM root $VmRoot"

        Write-Host "[testlab] Checking WSL/QEMU tooling"
        $toolsResult = Invoke-NodecWslScript -Label "ensure-tools" -ScriptContent $ensureToolsScript -Arguments @("1") -DoExecute:$Execute
        Add-NodecAction -Report $report -Result $toolsResult
        Assert-NodecSuccess -Result $toolsResult -FailureMessage "WSL tool check failed in distro '$Distro'."

        if ($Recreate -and $Execute) {
            Write-Host "[testlab] Stopping any running nodeC before rebuilding its disks"
            $stopResult = Invoke-NodecWslScript -Label "recreate-stop" -ScriptContent $teardownScript -Arguments @($VmRoot, "0") -DoExecute:$Execute
            Add-NodecAction -Report $report -Result $stopResult
            Assert-NodecSuccess -Result $stopResult -FailureMessage "Failed to stop the previous nodeC VM."
        }

        Write-Host "[testlab] Preparing cloud image, data disk and cloud-init seed (first run downloads the image)"
        $recreateFlag = if ($Recreate) { "1" } else { "0" }
        $prepResult = Invoke-NodecWslScript -Label "prepare-disks" -ScriptContent $prepareDisksScript -Arguments @($VmRoot, $ImageUrl, $recreateFlag, [string]$DataDiskGB, $publicKeyB64) -DoExecute:$Execute
        Add-NodecAction -Report $report -Result $prepResult
        Assert-NodecSuccess -Result $prepResult -FailureMessage "nodeC disk/seed preparation failed."

        Write-Host "[testlab] Launching nodeC VM"
        $launchResult = Invoke-NodecWslScript -Label "launch-vm" -ScriptContent $launchVmScript -Arguments @($VmRoot, [string]$SshPort, [string]$MemoryMB, [string]$Cpus) -DoExecute:$Execute
        Add-NodecAction -Report $report -Result $launchResult
        Assert-NodecSuccess -Result $launchResult -FailureMessage "nodeC VM launch failed."

        if ($Execute) {
            Write-Host "[testlab] Waiting for nodeC SSH on 127.0.0.1:$SshPort (up to $SshReadySeconds seconds)"
            $waitStartedAt = Get-Date
            $ready = $false
            $attempt = 0
            $lastProbe = $null
            while (((Get-Date) - $waitStartedAt).TotalSeconds -lt $SshReadySeconds) {
                $attempt++
                $lastProbe = Invoke-NodeSshCommand -NodeConnection $nodecConnection -Command "echo nodec-ready" -Label "ssh-probe" -DoExecute
                if ($lastProbe.success) {
                    $ready = $true
                    break
                }

                if (($attempt % 6) -eq 0) {
                    Write-Host ("[testlab] Still waiting for nodeC SSH ({0}s elapsed)" -f [int]((Get-Date) - $waitStartedAt).TotalSeconds)
                }

                Start-Sleep -Seconds 10
            }

            if (-not $ready) {
                $diagnosticsResult = Invoke-NodecWslScript -Label "boot-diagnostics" -ScriptContent $bootDiagnosticsScript -Arguments @($VmRoot) -DoExecute
                Add-NodecAction -Report $report -Result $diagnosticsResult
                $diagnosticsText = (@($diagnosticsResult.output | ForEach-Object { [string]$_ }) -join [Environment]::NewLine).Trim()

                $stopResult = Invoke-NodecWslScript -Label "readiness-stop" -ScriptContent $teardownScript -Arguments @($VmRoot, "0") -DoExecute
                Add-NodecAction -Report $report -Result $stopResult

                throw "nodeC SSH did not become ready on 127.0.0.1:$SshPort within $SshReadySeconds seconds. The VM was stopped so the next run starts it fresh. Check $VmRoot/serial.log in distro '$Distro'.`n$diagnosticsText"
            }

            Add-NodecAction -Report $report -Result $lastProbe
        } else {
            $dryProbe = Invoke-NodeSshCommand -NodeConnection $nodecConnection -Command "echo nodec-ready" -Label "ssh-probe" -DoExecute:$false
            Add-NodecAction -Report $report -Result $dryProbe
        }

        Write-Host "[testlab] Installing OpenZFS on nodeC and creating pool '$resolvedPool' (first run can take several minutes)"
        $zfsResult = Invoke-NodeBashScript -NodeConnection $nodecConnection -ScriptContent $ensureZfsScript -Arguments @($resolvedPool) -Label "ensure-zfs-pool" -DoExecute:$Execute
        Add-NodecAction -Report $report -Result $zfsResult
        Assert-NodecSuccess -Result $zfsResult -FailureMessage "OpenZFS setup failed on nodeC."

        $report.success = $true

        if ($Execute) {
            Write-Host "[testlab] nodeC is ready: ssh $resolvedUser@127.0.0.1:$SshPort (lab key), pool '$resolvedPool'"
        } else {
            Write-Host "[testlab] Dry-run: nodeC would be reachable at ssh $resolvedUser@127.0.0.1:$SshPort with pool '$resolvedPool'"
        }
        $labConfigBlock = [ordered]@{
            name        = "buddybackup-node-c-generic"
            host        = "127.0.0.1"
            port        = [int]$SshPort
            platform    = "generic-debian"
            zfsPool     = $resolvedPool
            datasetRoot = $resolvedDatasetRoot
        }
        Write-Host "[testlab] Lab config block for testlab/config/lab.local.json:"
        Write-Host ('  "nodeC": ' + ($labConfigBlock | ConvertTo-Json -Compress))
        Write-Host "[testlab] Run the smoke with:"
        Write-Host "  powershell -ExecutionPolicy Bypass -File ./testlab/scripts/run-generic-smoke.ps1 -LabConfig testlab/config/lab.local.json -Execute"
    }
} catch {
    $report.error = ($_ | Out-String).Trim()
    throw
} finally {
    $report.finishedAt = (Get-Date).ToString("o")
    $report | ConvertTo-Json -Depth 8 | Set-Content -Path $reportPath -Encoding UTF8
    Write-Host "[testlab] nodeC report written to $reportPath"
}

if (-not $Execute) {
    Write-Host ""
    Write-Host "Dry-run complete. Pass -Execute to actually provision or tear down nodeC."
}
