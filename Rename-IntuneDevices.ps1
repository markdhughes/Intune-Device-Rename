<#
.SYNOPSIS
    Renames Intune managed devices from a CSV of old name -> new name pairs via Microsoft Graph.

.DESCRIPTION
    Reads a CSV with columns "old name" and "new name", finds each Intune managed device whose
    deviceName matches the old name, and calls the Graph setDeviceName action to rename it.
    Intune applies the new name the next time the device checks in.

    Requires the Microsoft.Graph.Authentication module. Everything else is done with raw Graph calls.

.PARAMETER CsvPath
    Path to the CSV file. Defaults to test.csv next to the script.

.PARAMETER GraphVersion
    Graph API version to use. Defaults to beta because setDeviceName is only exposed on the beta endpoint.

.PARAMETER ReportPath
    Optional path to write a CSV of results.

.EXAMPLE
    .\Rename-IntuneDevices.ps1 -CsvPath .\test.csv -WhatIf
    Shows what would be renamed without changing anything.

.EXAMPLE
    .\Rename-IntuneDevices.ps1 -CsvPath .\test.csv -ReportPath .\rename-results.csv
#>
[CmdletBinding(SupportsShouldProcess)]
param(
    [Parameter()]
    [string]$CsvPath = (Join-Path $PSScriptRoot 'test.csv'),

    [Parameter()]
    [ValidateSet('v1.0', 'beta')]
    [string]$GraphVersion = 'beta',

    [Parameter()]
    [string]$ReportPath
)

$ErrorActionPreference = 'Stop'

# ---------------------------------------------------------------------------
# Module + connection
# ---------------------------------------------------------------------------
if (-not (Get-Module -ListAvailable -Name Microsoft.Graph.Authentication)) {
    Write-Host 'Installing Microsoft.Graph.Authentication...' -ForegroundColor Yellow
    Install-Module Microsoft.Graph.Authentication -Scope CurrentUser -Force
}
Import-Module Microsoft.Graph.Authentication

$requiredScopes = @(
    'DeviceManagementManagedDevices.Read.All',
    'DeviceManagementManagedDevices.PrivilegedOperations.All'
)

$ctx = Get-MgContext
$missing = $requiredScopes | Where-Object { $null -eq $ctx -or $ctx.Scopes -notcontains $_ }
if ($missing) {
    Write-Host 'Connecting to Microsoft Graph...' -ForegroundColor Cyan
    Connect-MgGraph -Scopes $requiredScopes -NoWelcome
    $ctx = Get-MgContext
}
Write-Host "Connected to tenant $($ctx.TenantId) as $($ctx.Account)" -ForegroundColor Green

# ---------------------------------------------------------------------------
# Load CSV (tolerant of header casing / spacing, e.g. "old name" or "OldName")
# ---------------------------------------------------------------------------
if (-not (Test-Path -LiteralPath $CsvPath)) {
    throw "CSV not found: $CsvPath"
}
$rows = @(Import-Csv -LiteralPath $CsvPath)
if (-not $rows) { throw "CSV is empty: $CsvPath" }

$headers = $rows[0].PSObject.Properties.Name
$oldCol  = $headers | Where-Object { ($_ -replace '[\s_-]', '') -match '^old(device)?name$' } | Select-Object -First 1
$newCol  = $headers | Where-Object { ($_ -replace '[\s_-]', '') -match '^new(device)?name$' } | Select-Object -First 1
if (-not $oldCol -or -not $newCol) {
    throw "CSV must have 'old name' and 'new name' columns. Found: $($headers -join ', ')"
}

# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------
function Get-IntuneDeviceByName {
    param([string]$Name)
    $escaped = $Name -replace "'", "''"
    $uri = "https://graph.microsoft.com/$GraphVersion/deviceManagement/managedDevices?`$filter=deviceName eq '$escaped'&`$select=id,deviceName,operatingSystem,userPrincipalName,lastSyncDateTime"
    $all = @()
    do {
        $resp = Invoke-MgGraphRequest -Method GET -Uri $uri -OutputType PSObject
        $all += $resp.value
        $uri = $resp.'@odata.nextLink'
    } while ($uri)
    return $all
}

function Test-ValidDeviceName {
    param([string]$Name, [string]$OperatingSystem)
    if ([string]::IsNullOrWhiteSpace($Name)) { return 'Name is blank' }
    # Windows computer names: 1-15 chars, letters/digits/hyphens, not all digits.
    if ($OperatingSystem -like 'Windows*') {
        if ($Name.Length -gt 15)               { return 'Windows names must be 15 characters or fewer' }
        if ($Name -notmatch '^[A-Za-z0-9-]+$') { return 'Windows names may only contain letters, digits and hyphens' }
        if ($Name -match '^\d+$')              { return 'Windows names cannot be all digits' }
    }
    return $null
}

# ---------------------------------------------------------------------------
# Process rows
# ---------------------------------------------------------------------------
$results = foreach ($row in $rows) {
    $oldName = ([string]$row.$oldCol).Trim()
    $newName = ([string]$row.$newCol).Trim()

    $result = [pscustomobject]@{
        OldName  = $oldName
        NewName  = $newName
        DeviceId = $null
        OS       = $null
        Status   = $null
        Message  = $null
    }

    if (-not $oldName -or -not $newName) {
        $result.Status  = 'Skipped'
        $result.Message = 'Blank old or new name'
        Write-Warning "Skipping row: blank old or new name."
        $result; continue
    }

    if ($oldName -ieq $newName) {
        $result.Status  = 'Skipped'
        $result.Message = 'Old and new name are identical'
        Write-Warning "Skipping '$oldName': old and new name are identical."
        $result; continue
    }

    $devices = @(Get-IntuneDeviceByName -Name $oldName)

    if ($devices.Count -eq 0) {
        $result.Status  = 'NotFound'
        $result.Message = 'No Intune device with that name'
        Write-Warning "No Intune device found named '$oldName'."
        $result; continue
    }
    if ($devices.Count -gt 1) {
        $result.Status  = 'Skipped'
        $result.Message = "$($devices.Count) devices share this name; resolve manually"
        Write-Warning "Skipping '$oldName': $($devices.Count) devices share this name."
        $result; continue
    }

    $device = $devices[0]
    $result.DeviceId = $device.id
    $result.OS       = $device.operatingSystem

    $validationError = Test-ValidDeviceName -Name $newName -OperatingSystem $device.operatingSystem
    if ($validationError) {
        $result.Status  = 'Invalid'
        $result.Message = $validationError
        Write-Warning "Skipping '$oldName' -> '$newName': $validationError"
        $result; continue
    }

    # Make sure the target name isn't already in use.
    if (@(Get-IntuneDeviceByName -Name $newName).Count -gt 0) {
        $result.Status  = 'Skipped'
        $result.Message = "A device named '$newName' already exists"
        Write-Warning "Skipping '$oldName': a device named '$newName' already exists."
        $result; continue
    }

    if ($PSCmdlet.ShouldProcess("$oldName ($($device.operatingSystem), $($device.id))", "Rename to '$newName'")) {
        try {
            $uri = "https://graph.microsoft.com/$GraphVersion/deviceManagement/managedDevices/$($device.id)/setDeviceName"
            Invoke-MgGraphRequest -Method POST -Uri $uri -Body @{ deviceName = $newName } -ContentType 'application/json' | Out-Null
            $result.Status  = 'Renamed'
            $result.Message = 'Rename queued; applies on next device check-in'
            Write-Host "Renamed '$oldName' -> '$newName'" -ForegroundColor Green
        }
        catch {
            # Pull the Graph error body (code + message) out of the exception when it's there.
            $graphError = $_
            $detail = $graphError.Exception.Message
            if ($graphError.ErrorDetails -and $graphError.ErrorDetails.Message) {
                try {
                    $body = $graphError.ErrorDetails.Message | ConvertFrom-Json
                    if ($body.error) { $detail = "$($body.error.code): $($body.error.message)" }
                }
                catch { $detail = $graphError.ErrorDetails.Message }
            }
            $result.Status  = 'Failed'
            $result.Message = $detail
            Write-Error "Failed to rename '$oldName' -> '$newName': $detail" -ErrorAction Continue
        }
    }
    else {
        $result.Status  = 'WhatIf'
        $result.Message = 'Would rename'
    }

    $result
}

# ---------------------------------------------------------------------------
# Summary
# ---------------------------------------------------------------------------
Write-Host ''
$results | Format-Table OldName, NewName, OS, Status, Message -AutoSize
$results | Group-Object Status | ForEach-Object { Write-Host ("{0,-10} {1}" -f $_.Name, $_.Count) }

if ($ReportPath) {
    $results | Export-Csv -LiteralPath $ReportPath -NoTypeInformation
    Write-Host "Report written to $ReportPath" -ForegroundColor Cyan
}
