$ErrorActionPreference = "Stop"

function Test-PortAvailable {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [int]$Port,
        [System.Net.IPAddress]$IPAddress = [System.Net.IPAddress]::Loopback
    )

    $listener = $null
    try {
        $listener = [System.Net.Sockets.TcpListener]::new($IPAddress, $Port)
        $listener.Start()
        return $true
    } catch {
        return $false
    } finally {
        if ($null -ne $listener) {
            $listener.Stop()
        }
    }
}

function Get-FreeLoopbackPort {
    [CmdletBinding()]
    param(
        [int]$StartPort = 2222,
        [int]$EndPort = 0,
        [int]$PreferredPort = 0,
        [int[]]$ExcludedPorts = @()
    )

    $actualStart = if ($PreferredPort -gt 0) {
        $PreferredPort
    } else {
        $StartPort
    }

    $actualEnd = if ($EndPort -gt 0 -and $EndPort -ge $actualStart) {
        $EndPort
    } else {
        $actualStart + 99
    }

    foreach ($candidatePort in $actualStart..$actualEnd) {
        if ($ExcludedPorts -contains $candidatePort) {
            continue
        }

        if (Test-PortAvailable -Port $candidatePort) {
            return $candidatePort
        }
    }

    throw "Could not find a free localhost TCP port between $actualStart and $actualEnd."
}
