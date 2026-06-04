# Sync-LicenseAssignment.ps1

## Overview
A license reconciliation script that compares current Microsoft 365 license 
state in Entra ID against an authoritative source — typically a CSV from an 
HRIS or identity feed. Assigns missing licenses, optionally removes unlicensed 
seats, and outputs a structured diff report.

## What this script does

- Loads and validates an authoritative user list from a CSV file
- Resolves the target license SKU and checks available seat count
- For each user in the source:
  - Already licensed → no action, logged as NoChange
  - Missing license → assigns it
  - Not found in Entra ID → logged as a warning
- Optionally removes the license from any Entra ID user not present in the source
- Outputs a structured JSON diff report with every action taken
- Optionally exports a flat CSV version of the report

## Why this script exists
License sprawl and over-provisioning were creating unnecessary spend. 
Finance needed an auditable reconciliation that could run automatically 
at month-end without manual portal work. This script treats license 
state as something that should be driven by a source of truth — not 
managed manually per user.

## Key features

- **-WhatIf support** — preview all changes before applying them
- **-RemoveUnlicensed flag** — optionally reclaim licenses from users not in the source
- **-ExportCsv flag** — outputs a flat CSV alongside the JSON report
- **Seat validation** — checks available seats before attempting assignment
- **Structured diff report** — every action logged with reason and timestamp

## Requirements
```powershell
Install-Module Microsoft.Graph -Scope CurrentUser
```

Connect before running:
```powershell
Connect-MgGraph -Scopes "User.ReadWrite.All","Organization.Read.All"
```

Required role: License Administrator

## CSV format
The CSV must contain a `UserPrincipalName` column. `DisplayName` and 
`Department` are optional and used for reporting only.

Example:
- UserPrincipalName: jdoe@contoso.com
- DisplayName: Jane Doe
- Department: Engineering

## Usage

**Standard reconciliation:**

.\Sync-LicenseAssignment.ps1 -CsvPath .\license-source.csv -LicenseSku "SPE_E5"

**Full reconciliation with removals:**

.\Sync-LicenseAssignment.ps1 -CsvPath .\license-source.csv -LicenseSku "SPE_E5" -RemoveUnlicensed

**Dry run:**

.\Sync-LicenseAssignment.ps1 -CsvPath .\license-source.csv -LicenseSku "SPE_E5" -WhatIf

## Part of the Identity Lifecycle Automation category
Script 03 of 24 in the PowerShell Infrastructure Library.

## File
[Sync-LicenseAssignment.ps1](./Sync-LicenseAssignment.ps1)