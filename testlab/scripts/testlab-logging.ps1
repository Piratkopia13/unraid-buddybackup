$ErrorActionPreference = "Stop"

function Get-TestLabTimestamp {
    return (Get-Date).ToString("HH:mm:ss")
}

function ConvertTo-TestLabMessage {
    param(
        [object[]]$Object,
        [object]$Separator = " "
    )

    if ($null -eq $Object -or $Object.Count -eq 0) {
        return ""
    }

    $parts = @($Object | ForEach-Object {
        if ($null -eq $_) {
            ""
        } else {
            [string]$_
        }
    })

    return [string]::Join([string]$Separator, $parts)
}

function Write-TestLabHostLine {
    param(
        [string]$Message = "",
        [ConsoleColor]$ForegroundColor,
        [ConsoleColor]$BackgroundColor,
        [switch]$NoNewline,
        [switch]$NoTimestamp
    )

    $renderedMessage = if ($NoTimestamp) {
        $Message
    } elseif ([string]::IsNullOrEmpty($Message)) {
        "[{0}]" -f (Get-TestLabTimestamp)
    } else {
        "[{0}] {1}" -f (Get-TestLabTimestamp), $Message
    }

    if (-not $NoNewline) {
        $renderedMessage = "`r{0}" -f $renderedMessage
    }

    $hostParams = @{ Object = $renderedMessage }
    if ($PSBoundParameters.ContainsKey('ForegroundColor')) {
        $hostParams.ForegroundColor = $ForegroundColor
    }
    if ($PSBoundParameters.ContainsKey('BackgroundColor')) {
        $hostParams.BackgroundColor = $BackgroundColor
    }
    if ($NoNewline) {
        $hostParams.NoNewline = $true
    }

    Microsoft.PowerShell.Utility\Write-Host @hostParams
}

function Write-Host {
    [CmdletBinding()]
    param(
        [Parameter(Position = 0, ValueFromRemainingArguments = $true)]
        [object[]]$Object,
        [object]$Separator = " ",
        [ConsoleColor]$ForegroundColor,
        [ConsoleColor]$BackgroundColor,
        [switch]$NoNewline,
        [switch]$NoTimestamp
    )

    $message = ConvertTo-TestLabMessage -Object $Object -Separator $Separator
    $writeParams = @{
        Message = $message
        NoNewline = $NoNewline
        NoTimestamp = $NoTimestamp
    }
    if ($PSBoundParameters.ContainsKey('ForegroundColor')) {
        $writeParams.ForegroundColor = $ForegroundColor
    }
    if ($PSBoundParameters.ContainsKey('BackgroundColor')) {
        $writeParams.BackgroundColor = $BackgroundColor
    }

    Write-TestLabHostLine @writeParams
}

function Write-Warning {
    [CmdletBinding()]
    param(
        [Parameter(Position = 0, ValueFromRemainingArguments = $true)]
        [object[]]$Message
    )

    $warningText = ConvertTo-TestLabMessage -Object $Message
    if ([string]::IsNullOrEmpty($warningText)) {
        $warningText = "warning"
    }

    Write-TestLabHostLine -Message ("WARNING: {0}" -f $warningText) -ForegroundColor Yellow
}

function Resolve-TestLabDateTime {
    param(
        $Value,
        [Nullable[datetime]]$Fallback = $null
    )

    $candidates = @()
    if ($Value -is [System.Array]) {
        $candidates = @($Value | Where-Object { $null -ne $_ })
        [array]::Reverse($candidates)
    } elseif ($null -ne $Value) {
        $candidates = @($Value)
    }

    foreach ($candidate in $candidates) {
        if ($candidate -is [datetime]) {
            return [datetime]$candidate
        }

        if ($candidate -is [System.Management.Automation.InformationRecord]) {
            continue
        }

        $candidateText = [string]$candidate
        if ([string]::IsNullOrWhiteSpace($candidateText)) {
            continue
        }

        $parsedDateTime = [datetime]::MinValue
        if ([datetime]::TryParse($candidateText, [ref]$parsedDateTime)) {
            return $parsedDateTime
        }
    }

    if ($null -ne $Fallback -and $Fallback.HasValue) {
        return $Fallback.Value
    }

    return $null
}

function Write-TestLabHeartbeat {
    param(
        [string]$Message,
        $StartedAt,
        $LastHeartbeatAt = $null,
        [int]$IntervalSeconds = 15,
        [int]$TimeoutSeconds = 0
    )

    $now = Get-Date
    $resolvedStartedAt = Resolve-TestLabDateTime -Value $StartedAt -Fallback $now
    $resolvedLastHeartbeatAt = Resolve-TestLabDateTime -Value $LastHeartbeatAt

    if ($null -ne $resolvedLastHeartbeatAt) {
        $heartbeatAgeSeconds = (New-TimeSpan -Start $resolvedLastHeartbeatAt -End $now).TotalSeconds
        if ($heartbeatAgeSeconds -lt $IntervalSeconds) {
            return $resolvedLastHeartbeatAt
        }
    }

    $elapsedSeconds = [int](New-TimeSpan -Start $resolvedStartedAt -End $now).TotalSeconds
    if ($TimeoutSeconds -gt 0) {
        Write-Host ("[testlab] {0} ({1}/{2}s)" -f $Message, $elapsedSeconds, $TimeoutSeconds)
    } else {
        Write-Host ("[testlab] {0} ({1}s)" -f $Message, $elapsedSeconds)
    }

    return $now
}

function Get-TestLabRowColor {
    param([string]$Status)

    $normalizedStatus = if ($null -eq $Status) {
        ""
    } else {
        ([string]$Status).ToLowerInvariant()
    }

    switch -Regex ($normalizedStatus) {
        '^pass$' { return [ConsoleColor]::Green }
        '^fail$' { return [ConsoleColor]::Red }
        '^skip$' { return [ConsoleColor]::Yellow }
        '^dry-run$' { return [ConsoleColor]::Yellow }
        default { return [ConsoleColor]::Gray }
    }
}

function Format-TestLabTableRow {
    param(
        [hashtable]$Row,
        [hashtable[]]$Columns
    )

    $cells = foreach ($column in $Columns) {
        $value = [string]$Row[$column.Key]
        if ($value.Length -gt $column.Width) {
            $value = $value.Substring(0, $column.Width)
        }
        " {0} " -f $value.PadRight($column.Width)
    }

    return "|{0}|" -f ($cells -join "|")
}

function Write-TestLabResultTable {
    param([object[]]$Rows)

    if (-not $Rows -or $Rows.Count -eq 0) {
        Write-Host "[testlab] No matrix results to display." -ForegroundColor DarkYellow
        return
    }

    $tableRows = @($Rows | ForEach-Object {
        $scenarioSummary = if ($_.scenarioResults) {
            (@($_.scenarioResults | ForEach-Object {
                "{0}={1}" -f $_.Scenario, $(if ($_.Success) { "ok" } else { "fail" })
            }) -join ", ")
        } else {
            "-"
        }

        [ordered]@{
            Cell = [string]$_.cellId
            Lifecycle = [string]$_.lifecycle
            Sender = "{0}/{1}" -f $_.senderUnraid, $_.senderPlugin
            Receiver = "{0}/{1}" -f $_.receiverUnraid, $_.receiverPlugin
            Scenarios = $scenarioSummary
            Status = ([string]$_.status).ToUpperInvariant()
        }
    })

    $columns = @(
        @{ Key = 'Cell'; Header = 'Cell'; Width = 4 },
        @{ Key = 'Lifecycle'; Header = 'Lifecycle'; Width = 9 },
        @{ Key = 'Sender'; Header = 'Sender'; Width = 6 },
        @{ Key = 'Receiver'; Header = 'Receiver'; Width = 8 },
        @{ Key = 'Scenarios'; Header = 'Scenarios'; Width = 9 },
        @{ Key = 'Status'; Header = 'Status'; Width = 6 }
    )

    foreach ($column in $columns) {
        $headerWidth = $column.Header.Length
        $valueWidths = @($tableRows | ForEach-Object { ([string]$_[$column.Key]).Length })
        $maxValueWidth = if ($valueWidths.Count -gt 0) {
            [int](($valueWidths | Measure-Object -Maximum).Maximum)
        } else {
            0
        }
        $column.Width = [Math]::Max([Math]::Max([int]$column.Width, $headerWidth), $maxValueWidth)
    }

    $divider = "+{0}+" -f (($columns | ForEach-Object { ('-' * ($_.Width + 2)) }) -join "+")
    $headerRow = @{}
    foreach ($column in $columns) {
        $headerRow[$column.Key] = $column.Header
    }

    Write-Host "[testlab] Matrix results" -ForegroundColor Cyan
    Write-Host $divider -ForegroundColor DarkGray
    Write-Host (Format-TestLabTableRow -Row $headerRow -Columns $columns) -ForegroundColor Cyan
    Write-Host $divider -ForegroundColor DarkGray

    foreach ($row in $tableRows) {
        $statusColor = Get-TestLabRowColor -Status ([string]$row.Status)
        Write-Host (Format-TestLabTableRow -Row $row -Columns $columns) -ForegroundColor $statusColor
    }

    Write-Host $divider -ForegroundColor DarkGray

    $failedRows = @($Rows | Where-Object { ([string]$_.status).ToLowerInvariant() -ne 'pass' })
    if ($failedRows.Count -gt 0) {
        Write-Host "[testlab] Failure details" -ForegroundColor Red
        foreach ($failedRow in $failedRows) {
            $errorText = if ($failedRow.errors -and $failedRow.errors.Count -gt 0) {
                (@($failedRow.errors | ForEach-Object { [string]$_ }) -join " | ")
            } else {
                "no error text recorded"
            }

            Write-Host ("[testlab] {0}: {1}" -f $failedRow.cellId, $errorText) -ForegroundColor Red
        }
    }
}