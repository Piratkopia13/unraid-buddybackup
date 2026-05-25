param(
    [string]$Distro = "Ubuntu",
    [string]$MonitorSocketPath = "/tmp/qemu-monitor.sock",
    [string]$WslPngPath = "/tmp/qemu-screen.png",
    [string]$OutputPath
)

$ErrorActionPreference = "Stop"

. (Join-Path $PSScriptRoot "wsl-common.ps1")

if (-not $OutputPath) {
    $stamp = Get-Date -Format "yyyyMMdd-HHmmss"
    $OutputPath = Join-Path $env:LOCALAPPDATA "BuddyBackup\screenshots\qemu-screen-${stamp}.png"
}

$resolvedOutputPath = Expand-LocalPath $OutputPath
$outputDir = Split-Path -Parent $resolvedOutputPath
if ($outputDir -and -not (Test-Path $outputDir)) {
    New-Item -ItemType Directory -Path $outputDir -Force | Out-Null
}

$wslOutputPath = Convert-WindowsPathToWslPath -WindowsPath $resolvedOutputPath -AllowMissing

$monitorSocketCandidates = @($MonitorSocketPath)
if ($MonitorSocketPath -eq "/tmp/qemu-monitor.sock") {
    $monitorSocketCandidates += "/tmp/buddybackup-qemu/qemu-monitor.sock"
    $monitorSocketCandidates += "/tmp/buddybackup-qemu-probe/qemu-monitor.sock"
}

$detectSocketScript = @'
set -euo pipefail

for candidate in "$@"; do
    if [ -S "$candidate" ]; then
        printf '%s\n' "$candidate"
        exit 0
    fi
done

exit 1
'@

$socketDetection = Invoke-WslRootBash -Distro $Distro -ScriptContent $detectSocketScript -Arguments $monitorSocketCandidates
if ($socketDetection.ExitCode -ne 0 -or -not $socketDetection.Output -or -not $socketDetection.Output[0]) {
    throw "Could not find a live QEMU monitor socket in WSL. Checked: $($monitorSocketCandidates -join ', ')"
}

$resolvedMonitorSocketPath = [string]$socketDetection.Output[0]

$captureScript = @'
set -euo pipefail

monitor_socket="$1"
wsl_png="$2"
windows_png="$3"
ppm_path="${wsl_png%.png}.ppm"

if ! command -v socat >/dev/null 2>&1 || ! command -v pnmtopng >/dev/null 2>&1; then
  apt-get update >/dev/null
  apt-get install -y socat netpbm >/dev/null
fi

if [ ! -S "$monitor_socket" ]; then
  echo "Monitor socket not found: $monitor_socket" >&2
  exit 1
fi

rm -f "$ppm_path" "$wsl_png" "$windows_png"
printf 'screendump %s\n' "$ppm_path" | socat - UNIX-CONNECT:"$monitor_socket"
pnmtopng "$ppm_path" > "$wsl_png"
cp "$wsl_png" "$windows_png"
'@

$result = Invoke-WslRootBash -Distro $Distro -ScriptContent $captureScript -Arguments @(
    $resolvedMonitorSocketPath,
    $WslPngPath,
    $wslOutputPath
)

if ($result.ExitCode -ne 0) {
    throw (("WSL screenshot capture failed with exit code {0}`n{1}" -f $result.ExitCode, (($result.Output | ForEach-Object { [string]$_ }) -join [Environment]::NewLine)).Trim())
}

$header = Get-Content -LiteralPath $resolvedOutputPath -Encoding Byte -TotalCount 8
$pngHeader = @(0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A)
$validHeader = ($header.Count -eq $pngHeader.Count)
for ($i = 0; $i -lt $header.Count -and $validHeader; $i++) {
    if ($header[$i] -ne $pngHeader[$i]) {
        $validHeader = $false
    }
}

if (-not $validHeader) {
    $hexHeader = ($header | ForEach-Object { '{0:X2}' -f $_ }) -join ' '
    throw "Captured screenshot is not a valid PNG: $resolvedOutputPath (header: $hexHeader)"
}

Write-Host "[testlab] Saved QEMU screenshot: $resolvedOutputPath"
Write-Host "[testlab] QEMU monitor socket: $resolvedMonitorSocketPath"