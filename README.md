# Intune Device Rename

Bulk-rename Intune managed devices from a CSV using Microsoft Graph.

The script reads pairs of old and new device names, finds each matching device in Intune, and calls the Graph `setDeviceName` action. Intune applies the new name on the device's next check-in (and, for Windows, after a restart).

## Requirements

- PowerShell 5.1 or PowerShell 7
- `Microsoft.Graph.Authentication` module (installed automatically if missing)
- An account with the `DeviceManagementManagedDevices.PrivilegedOperations.All` and `DeviceManagementManagedDevices.Read.All` Graph permissions
- An Intune licence on the tenant

## CSV format

```csv
old name,new name
CA-VM-DAILY,test
```

Header names are matched loosely, so `OldName`/`NewName` or `old_name`/`new_name` also work.

## Usage

Preview what would change without renaming anything:

```powershell
.\Rename-IntuneDevices.ps1 -CsvPath .\test.csv -WhatIf
```

Rename and write a results report:

```powershell
.\Rename-IntuneDevices.ps1 -CsvPath .\test.csv -ReportPath .\rename-results.csv
```

If `-CsvPath` is omitted, the script uses `test.csv` in the same folder as the script.

## What it checks before renaming

- Skips rows with a blank old or new name, or where the two are identical
- Skips old names that match zero devices, or more than one device
- Validates Windows names (15 characters max, letters, digits and hyphens only, not all digits)
- Skips if a device with the new name already exists

Each row ends up with a status of `Renamed`, `NotFound`, `Skipped`, `Invalid`, `Failed` or `WhatIf`, shown in a summary table and optionally exported with `-ReportPath`.

## Notes

- `setDeviceName` is only available on the Graph **beta** endpoint, which the script uses by default. Pass `-GraphVersion v1.0` if Microsoft promotes it later.
- Failures report the Graph error code and message, not just the HTTP status.
