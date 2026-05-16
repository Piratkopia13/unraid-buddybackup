param(
    [string]$BlueprintPath = "testlab/config/vm-blueprint.local.json",
    [switch]$Execute
)

$ErrorActionPreference = "Stop"

# ---------------------------------------------------------------------------
# Shared utilities
# ---------------------------------------------------------------------------

function Require-File {
    param([string]$Path)
    if (-not (Test-Path $Path)) { throw "Missing required file: $Path" }
}

function Ensure-Dir {
    param([string]$Path)
    if (-not (Test-Path $Path)) { New-Item -ItemType Directory -Path $Path | Out-Null }
}

function Get-Json {
    param([string]$Path)
    return Get-Content -Raw -Path $Path | ConvertFrom-Json
}

function Resolve-Backend {
    param([string]$Backend)
    if ($Backend -and $Backend -ne "auto") { return $Backend }
    if (Get-Command Get-VM -ErrorAction SilentlyContinue) { return "hyperv" }
    if (Get-Command VBoxManage -ErrorAction SilentlyContinue) { return "virtualbox" }
    return "none"
}

function Assert-Admin {
    $id = [Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()
    if (-not $id.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
        throw "Hyper-V operations require Administrator. Re-run this script as Administrator."
    }
}

function Expand-LocalPath {
    param([string]$P)
    if ($P -match '^\.[\\/]') { return Join-Path -Path (Get-Location).Path -ChildPath $P.Substring(2) }
    return $P
}

# ---------------------------------------------------------------------------
# Hyper-V: isolated NAT switch
# ---------------------------------------------------------------------------

function New-TestLabSwitch {
    param(
        [string]$SwitchName,
        [string]$GatewayIP,
        [string]$SubnetPrefix,
        [string]$NatName,
        [switch]$DoExecute
    )

    if (-not $DoExecute) {
        Write-Host "[dry-run] Would create internal Hyper-V switch '$SwitchName' + NAT '$NatName' ($SubnetPrefix)"
        return
    }

    if (-not (Get-VMSwitch -Name $SwitchName -ErrorAction SilentlyContinue)) {
        New-VMSwitch -Name $SwitchName -SwitchType Internal | Out-Null
        Write-Host "[testlab] Created Hyper-V switch: $SwitchName"
    } else {
        Write-Host "[testlab] Switch already exists: $SwitchName"
    }

    $adapterAlias = "vEthernet ($SwitchName)"
    $prefixLen = [int]($SubnetPrefix -split "/")[1]

    if (-not (Get-NetIPAddress -InterfaceAlias $adapterAlias -AddressFamily IPv4 -ErrorAction SilentlyContinue)) {
        New-NetIPAddress -IPAddress $GatewayIP -PrefixLength $prefixLen -InterfaceAlias $adapterAlias | Out-Null
        Write-Host "[testlab] Assigned $GatewayIP/$prefixLen to $adapterAlias"
    }

    if (-not (Get-NetNat -Name $NatName -ErrorAction SilentlyContinue)) {
        New-NetNat -Name $NatName -InternalIPInterfaceAddressPrefix $SubnetPrefix | Out-Null
        Write-Host "[testlab] Created NAT: $NatName ($SubnetPrefix)"
    } else {
        Write-Host "[testlab] NAT already exists: $NatName"
    }
}

# ---------------------------------------------------------------------------
# Unraid download + caching
# ---------------------------------------------------------------------------

function Get-UnraidRelease {
    param(
        [string]$Version,
        [string]$UrlTemplate,
        [string]$CacheRoot,
        [switch]$DoExecute
    )

    $zipFile = Join-Path -Path $CacheRoot -ChildPath "unraid-${Version}.zip"

    if (-not $DoExecute) {
        $url = $UrlTemplate.Replace("{version}", $Version)
        Write-Host "[dry-run] Would download Unraid $Version from: $url"
        Write-Host "[dry-run] Would cache to: $zipFile"
        return $zipFile
    }

    if (Test-Path $zipFile) {
        Write-Host "[testlab] Using cached Unraid ${Version}: $zipFile"
        return $zipFile
    }

    $url = $UrlTemplate.Replace("{version}", $Version)
    Write-Host "[testlab] Downloading Unraid $Version from $url ..."
    Invoke-WebRequest -Uri $url -OutFile $zipFile -UseBasicParsing
    Write-Host "[testlab] Cached: $zipFile"
    return $zipFile
}

# ---------------------------------------------------------------------------
# Unraid boot disk: GPT VHDX via diskpart, injected network + SSH config
# ---------------------------------------------------------------------------

function New-UnraidBootDisk {
    param(
        [string]$VhdxPath,
        [string]$UnraidZipPath,
        [string]$NodeIP,
        [string]$GatewayIP,
        [string]$SshPubKey,
        [int]$SizeGB = 2,
        [switch]$DoExecute
    )

    if (-not $DoExecute) {
        Write-Host "[dry-run] Would create Unraid boot VHDX at $VhdxPath (${SizeGB} GB)"
        Write-Host "[dry-run]   Inject static IP $NodeIP, gateway $GatewayIP, SSH pub key"
        return
    }

    if (Test-Path $VhdxPath) {
        Write-Host "[testlab] Boot disk already exists, skipping: $VhdxPath"
        return
    }

    Write-Host "[testlab] Creating boot VHDX: $VhdxPath"
    New-VHD -Path $VhdxPath -SizeBytes ([long]$SizeGB * 1GB) -Dynamic | Out-Null
    Mount-VHD -Path $VhdxPath

    # Wait for Windows to enumerate the mounted disk
    $diskNumber = $null
    for ($i = 0; $i -lt 15; $i++) {
        Start-Sleep -Seconds 1
        $diskNumber = (Get-VHD -Path $VhdxPath).DiskNumber
        if ($null -ne $diskNumber) { break }
    }
    if ($null -eq $diskNumber) {
        Dismount-VHD -Path $VhdxPath -ErrorAction SilentlyContinue
        throw "Could not get disk number for mounted VHD: $VhdxPath"
    }

    Set-Disk -Number $diskNumber -IsOffline $false -ErrorAction SilentlyContinue
    Set-Disk -Number $diskNumber -IsReadOnly $false -ErrorAction SilentlyContinue

    # Find a free drive letter
    $usedLetters = (Get-PSDrive -PSProvider FileSystem).Name
    $driveLetter = [char[]](67..90) |
        ForEach-Object { [string][char]$_ } |
        Where-Object { $_ -notin $usedLetters } |
        Select-Object -First 1
    if (-not $driveLetter) {
        Dismount-VHD -Path $VhdxPath -ErrorAction SilentlyContinue
        throw "No free drive letters available to mount the VHDX."
    }

    try {
        # diskpart: GPT + EFI FAT32 partition — no MBR syslinux needed for Hyper-V Gen 2 UEFI
        $dpScript = @"
select disk $diskNumber
clean
convert gpt
create partition efi size=2048
format quick fs=fat32 label=UNRAID
assign letter=$driveLetter
exit
"@
        $dpFile = [System.IO.Path]::GetTempFileName() + ".txt"
        $dpScript | Set-Content -Path $dpFile -Encoding ASCII
        $dpOut = & diskpart /s $dpFile 2>&1
        Remove-Item $dpFile -Force -ErrorAction SilentlyContinue
        Write-Host "[testlab] diskpart: $($dpOut -join ' | ')"
        Start-Sleep -Seconds 2

        # Extract Unraid zip to temp, then robocopy to drive
        $tempDir = Join-Path -Path $env:TEMP -ChildPath "unraid-extract-$(New-Guid)"
        Ensure-Dir -Path $tempDir
        Write-Host "[testlab] Extracting Unraid zip..."
        Expand-Archive -Path $UnraidZipPath -DestinationPath $tempDir -Force

        $dest = "${driveLetter}:\"
        & robocopy $tempDir $dest /E /NFL /NDL /NJH /NJS | Out-Null
        if ($LASTEXITCODE -ge 8) { throw "robocopy failed (exit $LASTEXITCODE) copying Unraid files to $dest" }
        Remove-Item -Path $tempDir -Recurse -Force -ErrorAction SilentlyContinue
        Write-Host "[testlab] Unraid files copied to $dest"

        # Inject network config
        $configDir = "${driveLetter}:\config"
        Ensure-Dir -Path $configDir

        @"
IFNAME[0]="eth0"
PROTOCOL[0]="ipv4"
USE_DHCP[0]="no"
IPADDR[0]="$NodeIP"
NETMASK[0]="255.255.255.0"
GATEWAY="$GatewayIP"
DNS_SERVER1="8.8.8.8"
"@ | Set-Content -Path (Join-Path $configDir "network.cfg") -Encoding UTF8

        # Inject SSH authorized key
        $sshDir = Join-Path $configDir "ssh"
        Ensure-Dir -Path $sshDir
        $SshPubKey | Set-Content -Path (Join-Path $sshDir "authorized_keys") -Encoding UTF8

        # Append to go script so key is always in /root/.ssh on boot
        $goPath = Join-Path $configDir "go"
        $goAddition = @"

# BuddyBackup testlab: ensure SSH key is loaded on every boot
mkdir -p /root/.ssh
chmod 700 /root/.ssh
cp /boot/config/ssh/authorized_keys /root/.ssh/authorized_keys 2>/dev/null || true
chmod 600 /root/.ssh/authorized_keys 2>/dev/null || true
"@
        Add-Content -Path $goPath -Value $goAddition -Encoding UTF8

        Write-Host "[testlab] Boot disk ready: $VhdxPath"
    } finally {
        Start-Sleep -Seconds 1
        Dismount-VHD -Path $VhdxPath -ErrorAction SilentlyContinue
        Write-Host "[testlab] Unmounted: $VhdxPath"
    }
}

# ---------------------------------------------------------------------------
# Unraid data disk: empty VHDX for ZFS pool
# ---------------------------------------------------------------------------

function New-UnraidDataDisk {
    param(
        [string]$VhdxPath,
        [int]$SizeGB = 20,
        [switch]$DoExecute
    )

    if (-not $DoExecute) {
        Write-Host "[dry-run] Would create data VHDX at $VhdxPath (${SizeGB} GB)"
        return
    }

    if (Test-Path $VhdxPath) {
        Write-Host "[testlab] Data disk already exists, skipping: $VhdxPath"
        return
    }

    New-VHD -Path $VhdxPath -SizeBytes ([long]$SizeGB * 1GB) -Dynamic | Out-Null
    Write-Host "[testlab] Created data disk: $VhdxPath"
}

# ---------------------------------------------------------------------------
# Hyper-V VM creation (Generation 2, Secure Boot off)
# ---------------------------------------------------------------------------

function New-UnraidHyperVVM {
    param(
        [string]$VMName,
        [string]$SwitchName,
        [string]$BootVhdxPath,
        [string]$DataVhdxPath,
        [int]$CPU,
        [long]$MemoryMB,
        [switch]$DoExecute
    )

    if (-not $DoExecute) {
        Write-Host "[dry-run] Would create Hyper-V Gen2 VM '$VMName' (${CPU} vCPU, ${MemoryMB} MB)"
        Write-Host "[dry-run]   Boot: $BootVhdxPath  Data: $DataVhdxPath"
        return
    }

    if (Get-VM -Name $VMName -ErrorAction SilentlyContinue) {
        Write-Host "[testlab] VM already exists, skipping: $VMName"
        return
    }

    $vm = New-VM -Name $VMName -Generation 2 `
        -MemoryStartupBytes ($MemoryMB * 1MB) `
        -SwitchName $SwitchName `
        -VHDPath $BootVhdxPath

    Set-VMProcessor -VM $vm -Count $CPU
    Set-VMMemory -VM $vm -DynamicMemoryEnabled $false
    Set-VMFirmware -VM $vm -EnableSecureBoot Off
    Add-VMHardDiskDrive -VM $vm -Path $DataVhdxPath

    Write-Host "[testlab] Created VM: $VMName"
}

# ---------------------------------------------------------------------------
# SSH readiness wait
# ---------------------------------------------------------------------------

function Wait-NodeSsh {
    param(
        [string]$TargetIP,
        [string]$SshKeyPath,
        [int]$TimeoutSeconds = 300
    )

    $keyPath = Expand-LocalPath $SshKeyPath
    Write-Host "[testlab] Waiting for SSH on $TargetIP (timeout: $TimeoutSeconds s)..."
    $started = Get-Date

    while ((New-TimeSpan -Start $started -End (Get-Date)).TotalSeconds -lt $TimeoutSeconds) {
        & ssh -o BatchMode=yes -o ConnectTimeout=5 -o StrictHostKeyChecking=no -i $keyPath "root@$TargetIP" "echo ready" 2>$null
        if ($LASTEXITCODE -eq 0) {
            Write-Host "[testlab] SSH ready: $TargetIP"
            return $true
        }
        Start-Sleep -Seconds 5
    }

    Write-Host "[testlab] SSH timeout on $TargetIP after $TimeoutSeconds s"
    return $false
}

# ---------------------------------------------------------------------------
# Main
# ---------------------------------------------------------------------------

Require-File $BlueprintPath
$blueprint = Get-Json -Path $BlueprintPath
$backend = Resolve-Backend -Backend $blueprint.backend

$cacheRoot   = Expand-LocalPath ($(if ($blueprint.cacheRoot)   { $blueprint.cacheRoot }   else { ".testlab/cache" }))
$logsRoot    = Expand-LocalPath ($(if ($blueprint.logsRoot)    { $blueprint.logsRoot }    else { ".testlab/logs" }))
Ensure-Dir $cacheRoot
Ensure-Dir $logsRoot

$runId      = Get-Date -Format "yyyyMMdd-HHmmss"
$reportPath = Join-Path $logsRoot "vm-provision-${runId}.json"

Write-Host "[testlab] Backend: $backend"

$report = [pscustomobject]@{
    runId       = $runId
    backend     = $backend
    executeMode = [bool]$Execute
    blueprint   = $BlueprintPath
    nodes       = @()
    status      = "dry-run"
}

if ($backend -eq "none") {
    Write-Host "[testlab] No VM backend found. Install Hyper-V (Windows feature) and re-run."
    $report.status = "no-backend"
    $report | ConvertTo-Json -Depth 8 | Set-Content $reportPath
    Write-Host "[testlab] Report: $reportPath"
    return
}

if ($backend -eq "virtualbox") {
    if ($Execute) { throw "VirtualBox backend is not implemented. Use Hyper-V." }
    Write-Host "[dry-run] VirtualBox provisioning plan would run here."
    $report | ConvertTo-Json -Depth 8 | Set-Content $reportPath
    return
}

# --- Hyper-V ---

if ($Execute) { Assert-Admin }

$hvCfg   = $blueprint.hyperv
$vmCfg   = $blueprint.vm

$switchName   = $(if ($hvCfg.switchName)   { $hvCfg.switchName }   else { "BuddyBackup-TestLab" })
$gatewayIP    = $(if ($hvCfg.gatewayIP)    { $hvCfg.gatewayIP }    else { "10.88.0.1" })
$subnetPrefix = $(if ($hvCfg.subnetPrefix) { $hvCfg.subnetPrefix } else { "10.88.0.0/24" })
$natName      = $(if ($hvCfg.natName)      { $hvCfg.natName }      else { "BuddyBackupTestLabNAT" })
$vhdRoot      = $(if ($hvCfg.vhdRoot)      { $hvCfg.vhdRoot }      else { "C:\VMs\BuddyBackup" })

$cpu         = $(if ($vmCfg.cpu)         { [int]$vmCfg.cpu }     else { 2 })
$memoryMB    = $(if ($vmCfg.memoryMB)    { [long]$vmCfg.memoryMB } else { 4096 })
$bootDiskGB  = $(if ($vmCfg.bootDiskGB)  { [int]$vmCfg.bootDiskGB }  else { 2 })
$dataDiskGB  = $(if ($vmCfg.dataDiskGB)  { [int]$vmCfg.dataDiskGB }  else { 20 })

$urlTemplate = $(if ($blueprint.unraidDownloadUrlTemplate) { $blueprint.unraidDownloadUrlTemplate } else {
    "https://unraid-dl.sfo2.cdn.digitaloceanspaces.com/stable/unraid-{version}.zip"
})

$sshPubKeyPath  = Expand-LocalPath ($(if ($blueprint.sshPublicKeyPath) { $blueprint.sshPublicKeyPath } else { ".testlab/lab_key.pub" }))
$sshPrivKeyPath = $sshPubKeyPath -replace '\.pub$', ''

if (-not (Test-Path $sshPubKeyPath)) {
    if ($Execute) { throw "SSH public key not found: $sshPubKeyPath`nRun testlab/scripts/bootstrap-host.ps1 first." }
    else          { Write-Host "[dry-run] SSH public key would be required at: $sshPubKeyPath" }
}
$sshPubKey = if (Test-Path $sshPubKeyPath) { (Get-Content -Path $sshPubKeyPath -Raw).Trim() } else { "(not yet generated)" }

Ensure-Dir $vhdRoot

# 1. Network
New-TestLabSwitch -SwitchName $switchName -GatewayIP $gatewayIP -SubnetPrefix $subnetPrefix -NatName $natName -DoExecute:$Execute

# 2. Per-node VMs
$nodeResults = @()
foreach ($nodeName in @("sender", "receiver")) {
    $node = $blueprint.$nodeName
    if (-not $node) { throw "Blueprint missing node definition: $nodeName" }

    $vmName      = $node.name
    $nodeIP      = $node.ip
    $nodeVersion = $node.unraidVersion
    $bootVhdx    = Join-Path $vhdRoot "${vmName}-boot.vhdx"
    $dataVhdx    = Join-Path $vhdRoot "${vmName}-data.vhdx"

    Write-Host "[testlab] Provisioning $nodeName ($vmName, Unraid $nodeVersion, IP $nodeIP)..."

    $zipPath = Get-UnraidRelease -Version $nodeVersion -UrlTemplate $urlTemplate -CacheRoot $cacheRoot -DoExecute:$Execute

        New-UnraidBootDisk -VhdxPath $bootVhdx -UnraidZipPath $zipPath `
        -NodeIP $nodeIP -GatewayIP $gatewayIP -SshPubKey $sshPubKey `
        -SizeGB $bootDiskGB -DoExecute:$Execute

    New-UnraidDataDisk -VhdxPath $dataVhdx -SizeGB $dataDiskGB -DoExecute:$Execute

    New-UnraidHyperVVM -VMName $vmName -SwitchName $switchName `
        -BootVhdxPath $bootVhdx -DataVhdxPath $dataVhdx `
        -CPU $cpu -MemoryMB $memoryMB -DoExecute:$Execute

    if ($Execute) {
        Start-VM -Name $vmName
        Write-Host "[testlab] Started VM: $vmName"
    } else {
        Write-Host "[dry-run] Would start VM: $vmName"
    }

    $nodeResults += [pscustomobject]@{
        node         = $nodeName
        name         = $vmName
        ip           = $nodeIP
        unraidVersion = $nodeVersion
        bootVhdx     = $bootVhdx
        dataVhdx     = $dataVhdx
    }
}
$report.nodes = $nodeResults

# 3. Wait for SSH on all nodes
if ($Execute) {
    $allReady = $true
    foreach ($nr in $nodeResults) {
        if (-not (Wait-NodeSsh -TargetIP $nr.ip -SshKeyPath $sshPrivKeyPath -TimeoutSeconds 360)) {
            $allReady = $false
            Write-Host "[testlab] WARNING: $($nr.name) ($($nr.ip)) did not become SSH-ready in time."
        }
    }
    $report.status = if ($allReady) { "ready" } else { "partial" }

    # 4. Write a ready-to-use lab.local.json so the matrix runner can connect immediately
    $labLocalPath = "testlab/config/lab.local.json"
    $labConfig = [ordered]@{
        provider      = "windows-local"
        artifactsRoot = ".testlab/artifacts"
        logsRoot      = ".testlab/logs"
        ssh = [ordered]@{
            user         = "root"
            port         = 22
            identityFile = ".testlab/lab_key"
        }
        nodes = [ordered]@{
            sender = [ordered]@{
                name = $blueprint.sender.name
                host = $blueprint.sender.ip
            }
            receiver = [ordered]@{
                name = $blueprint.receiver.name
                host = $blueprint.receiver.ip
            }
        }
        plugin = [ordered]@{
            installMethod  = "url"
            plgUrlTemplate = "https://github.com/Piratkopia13/unraid-buddybackup/releases/download/{version}/buddybackup.plg"
        }
        timeouts = [ordered]@{
            sshReadySeconds     = 300
            rebootSettleSeconds = 30
        }
    }
    $labConfig | ConvertTo-Json -Depth 8 | Set-Content -Path $labLocalPath -Encoding UTF8
    Write-Host "[testlab] lab.local.json written: $labLocalPath"
    Write-Host "[testlab] Run the matrix with:"
    Write-Host "  .\testlab\scripts\run-matrix.ps1 -LabConfig testlab/config/lab.local.json -Execute"
} else {
    $report.status = "dry-run"
}

$report | ConvertTo-Json -Depth 8 | Set-Content $reportPath
Write-Host "[testlab] Provision report: $reportPath"
