<#
.SYNOPSIS
    Testlab UI and WebGUI helper script for BuddyBackup Unraid test environment.

.DESCRIPTION
    Provides quick status, URL discovery, HTTP probe checks, and credential
    lookups for the local WSL/QEMU Unraid testlab nodes (nodeA and nodeB).
    Outputs both human-readable console summaries and JSON for automated tools/agents.

.PARAMETER LabConfig
    Path to the lab configuration JSON file. Defaults to testlab/config/lab.local.json.

.PARAMETER Action
    The action to perform:
      - Status (default): Probe running QEMU processes, ports, and HTTP WebGUI status.
      - Urls: Output direct URLs for WebGUI, Plugins, Settings, and BuddyBackup pages.
      - Probe: Perform fast HTTP requests against WebGUI endpoints and report status.
      - Credentials: Display configured WebGUI credentials.

.PARAMETER Node
    Filter to a specific node ('nodeA', 'nodeB', or 'all'). Defaults to 'all'.

.PARAMETER Json
    Switch to output results as a JSON string for easy parsing by scripts or agents.

.EXAMPLE
    .\testlab\scripts\testlab-ui-helper.ps1 -Action Status
    .\testlab\scripts\testlab-ui-helper.ps1 -Action Urls
    .\testlab\scripts\testlab-ui-helper.ps1 -Action Status -Json
#>

[CmdletBinding()]
param(
    [string]$LabConfig = "",
    [ValidateSet("Status", "Urls", "Probe", "Credentials", "Help")]
    [string]$Action = "Status",
    [ValidateSet("all", "nodeA", "nodeB")]
    [string]$Node = "all",
    [switch]$Json
)

$ErrorActionPreference = "Stop"

. (Join-Path $PSScriptRoot "wsl-common.ps1")

# Locate lab config
$repoRoot = (Resolve-Path (Join-Path $PSScriptRoot "..")).Path
if ([string]::IsNullOrWhiteSpace($LabConfig)) {
    $localConfig = Join-Path $repoRoot "config\lab.local.json"
    $exampleConfig = Join-Path $repoRoot "config\lab.example.json"
    if (Test-Path $localConfig) {
        $LabConfig = $localConfig
    } elseif (Test-Path $exampleConfig) {
        $LabConfig = $exampleConfig
    } else {
        throw "Could not find lab configuration file at $localConfig or $exampleConfig."
    }
}

$resolvedConfigPath = (Resolve-Path $LabConfig).Path
$configJson = Get-Content -Raw -LiteralPath $resolvedConfigPath | ConvertFrom-Json

# Helper: Test TCP port
function Test-TcpPort {
    param([string]$HostName, [int]$Port, [int]$TimeoutMs = 1500)
    $client = New-Object System.Net.Sockets.TcpClient
    try {
        $iar = $client.BeginConnect($HostName, $Port, $null, $null)
        $wait = $iar.AsyncWaitHandle.WaitOne($TimeoutMs, $false)
        if ($wait -and $client.Connected) {
            $client.EndConnect($iar)
            return $true
        }
        return $false
    } catch {
        return $false
    } finally {
        $client.Close()
    }
}

# Helper: Probe HTTP endpoint
function Probe-HttpEndpoint {
    param([string]$Url, [int]$TimeoutSec = 3)
    try {
        $prevSec = [System.Net.ServicePointManager]::SecurityProtocol
        [System.Net.ServicePointManager]::SecurityProtocol = [System.Net.SecurityProtocolType]::Tls12 -bor [System.Net.SecurityProtocolType]::Tls13
        # Ignore SSL cert errors for localhost/testlab probes
        [System.Net.ServicePointManager]::ServerCertificateValidationCallback = { $true }

        $response = Invoke-WebRequest -Uri $Url -UseBasicParsing -TimeoutSec $TimeoutSec -MaximumRedirection 3 -ErrorAction Stop
        $statusCode = [int]$response.StatusCode
        $title = ""
        if ($response.Content -match '<title>(.*?)</title>') {
            $title = $matches[1].Trim()
        } elseif ($response.Content -match 'SetPassword') {
            $title = "Tower / Set Password"
        }
        return @{
            Reachable = $true
            StatusCode = $statusCode
            Title = $title
        }
    } catch {
        return @{
            Reachable = $false
            StatusCode = 0
            Title = $_.Exception.Message
        }
    }
}

# Helper: Check WSL QEMU processes
function Get-WslQemuProcesses {
    param([string]$Distro = "Ubuntu")
    $qemuPids = @{}
    try {
        $checkScript = @'
for node in nodeA nodeB; do
    pidfile="/tmp/buddybackup-qemu-lab-${node}/qemu.pid"
    if [ -f "$pidfile" ]; then
        pid=$(cat "$pidfile" 2>/dev/null || true)
        if [ -n "$pid" ] && kill -0 "$pid" 2>/dev/null; then
            echo "${node}:${pid}"
        fi
    fi
done
'@
        $res = Invoke-WslRootBash -ScriptContent $checkScript -Distro $Distro
        if ($res -and $res.Output) {
            foreach ($line in $res.Output) {
                if ($line -match '^(node[AB]):(\d+)$') {
                    $qemuPids[$matches[1]] = [int]$matches[2]
                }
            }
        }
    } catch {
        # ignore wsl inspection failure
    }
    return $qemuPids
}

# Node definitions
$nodeKeys = @()
if ($Node -eq "all") {
    if ($configJson.nodes.nodeA) { $nodeKeys += "nodeA" }
    if ($configJson.nodes.nodeB) { $nodeKeys += "nodeB" }
} else {
    $nodeKeys += $Node
}

$rootPassword = ""
if ($configJson.setup -and $configJson.setup.manualAccess -and $configJson.setup.manualAccess.rootPassword) {
    $rootPassword = [string]$configJson.setup.manualAccess.rootPassword
}

$distro = "Ubuntu"
if ($configJson.wslQemu -and $configJson.wslQemu.distro) {
    $distro = [string]$configJson.wslQemu.distro
}

$runningQemuMap = Get-WslQemuProcesses -Distro $distro

# Build node status objects
$nodeResults = @()
foreach ($key in $nodeKeys) {
    $n = $configJson.nodes.$key
    if (-not $n) { continue }

    $sshPort = if ($n.port) { [int]$n.port } else { if ($key -eq "nodeA") { 2222 } else { 2223 } }
    $httpPort = if ($n.webGuiHttpPort) { [int]$n.webGuiHttpPort } else { if ($key -eq "nodeA") { 8080 } else { 8081 } }
    $httpsPort = if ($n.webGuiHttpsPort) { [int]$n.webGuiHttpsPort } else { if ($key -eq "nodeA") { 8443 } else { 8444 } }
    $nodeHost = if ($n.host) { [string]$n.host } else { "127.0.0.1" }
    $unraidVer = if ($n.unraidVersion) { [string]$n.unraidVersion } else { "Unknown" }

    $httpUrl = "http://${nodeHost}:${httpPort}"
    $httpsUrl = "https://${nodeHost}:${httpsPort}"

    $qemuPid = if ($runningQemuMap.ContainsKey($key)) { $runningQemuMap[$key] } else { $null }
    $isQemuRunning = ($null -ne $qemuPid)

    $sshListening = Test-TcpPort -HostName $nodeHost -Port $sshPort
    $httpListening = Test-TcpPort -HostName $nodeHost -Port $httpPort
    $httpsListening = Test-TcpPort -HostName $nodeHost -Port $httpsPort

    $httpProbe = if ($httpListening) { Probe-HttpEndpoint -Url $httpUrl } else { @{ Reachable = $false; StatusCode = 0; Title = "Port not listening" } }

    $pageUrls = [ordered]@{
        WebGUI      = $httpUrl
        Login       = "$httpUrl/login"
        Dashboard   = "$httpUrl/Dashboard"
        Plugins     = "$httpUrl/Plugins"
        Tools       = "$httpUrl/Tools"
        Settings    = "$httpUrl/Settings"
        BuddyBackup = "$httpUrl/Tools/BuddyBackup"
        BuddyBackupSettings = "$httpUrl/Settings/BuddyBackup"
    }

    $nodeObj = [PSCustomObject]@{
        Node          = $key
        Name          = [string]$n.name
        UnraidVersion = $unraidVer
        QemuPid       = $qemuPid
        IsRunning     = $isQemuRunning
        SshPort       = $sshPort
        SshListening  = $sshListening
        HttpUrl       = $httpUrl
        HttpListening = $httpListening
        HttpProbe     = $httpProbe
        HttpsUrl      = $httpsUrl
        HttpsListening = $httpsListening
        WebGuiUser    = "root"
        WebGuiPassword = $rootPassword
        DirectUrls    = $pageUrls
    }

    $nodeResults += $nodeObj
}

# Output handling
if ($Json) {
    $nodeResults | ConvertTo-Json -Depth 5
    return
}

switch ($Action) {
    "Urls" {
        Write-Host "=== BuddyBackup Testlab WebGUI URLs ===" -ForegroundColor Cyan
        foreach ($nr in $nodeResults) {
            Write-Host "`n[$($nr.Node)] Unraid $($nr.UnraidVersion) ($($nr.Name))" -ForegroundColor Yellow
            Write-Host "  HTTP Base   : $($nr.HttpUrl)"
            Write-Host "  Login       : $($nr.DirectUrls.Login)"
            Write-Host "  Dashboard   : $($nr.DirectUrls.Dashboard)"
            Write-Host "  Plugins     : $($nr.DirectUrls.Plugins)"
            Write-Host "  BuddyBackup : $($nr.DirectUrls.BuddyBackup)"
            Write-Host "  Credentials : User=$($nr.WebGuiUser) / Password=$($nr.WebGuiPassword)"
        }
        Write-Host ""
    }
    "Credentials" {
        Write-Host "=== BuddyBackup Testlab WebGUI Credentials ===" -ForegroundColor Cyan
        Write-Host "Username: root"
        Write-Host "Password: $rootPassword"
        Write-Host "LabConfig: $resolvedConfigPath"
    }
    "Probe" {
        Write-Host "=== BuddyBackup Testlab WebGUI Probe ===" -ForegroundColor Cyan
        foreach ($nr in $nodeResults) {
            $statusStr = if ($nr.HttpProbe.Reachable) { "HTTP $($nr.HttpProbe.StatusCode) - $($nr.HttpProbe.Title)" } else { "Unreachable" }
            Write-Host "[$($nr.Node)] $($nr.HttpUrl) -> $statusStr"
        }
    }
    "Status" {
        Write-Host "=== BuddyBackup Testlab Status Summary ===" -ForegroundColor Cyan
        Write-Host "Config: $resolvedConfigPath`n"

        $summaryTable = $nodeResults | Select-Object `
            Node, `
            @{Name="Unraid"; Expression={$_.UnraidVersion}}, `
            @{Name="QEMU"; Expression={if ($_.IsRunning) { "PID $($_.QemuPid)" } else { "Stopped" }}}, `
            @{Name="SSH (Port)"; Expression={if ($_.SshListening) { "OK ($($_.SshPort))" } else { "Down ($($_.SshPort))" }}}, `
            @{Name="HTTP WebGUI"; Expression={if ($_.HttpListening) { "$($_.HttpUrl) [OK]" } else { "$($_.HttpUrl) [Down]" }}}, `
            @{Name="Page State"; Expression={$_.HttpProbe.Title}}

        $summaryTable | Format-Table -AutoSize

        Write-Host "Credentials: Username: root | Password: $rootPassword" -ForegroundColor Gray
        Write-Host "Tip: Use 'chrome-devtools-mcp' to navigate directly to the HTTP WebGUI URLs." -ForegroundColor DarkCyan
    }
    "Help" {
        Get-Help $MyInvocation.MyCommand.Path -Full
    }
}
