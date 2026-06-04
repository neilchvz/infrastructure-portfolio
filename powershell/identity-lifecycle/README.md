# New-UserOnboarding.ps1

## Overview
A fully parameterized M365 user provisioning script designed for automated 
pipeline execution or manual IT operations use. Includes a pre-check to 
prevent duplicate account creation — safe to re-run. Provisions a new user 
end-to-end across Entra ID, Exchange Online, and Microsoft 365 groups from 
a single parameter set or CSV import.

## What this script does
Executes the following steps in sequence:

1. **Pre-flight validation** — verifies required PowerShell modules are 
   available and connected sessions exist
2. **Duplicate check** — verifies the UPN does not already exist in Entra ID 
   before attempting creation
3. **Account creation** — creates the Entra ID user with standard attribute 
   mapping (DisplayName, MailNickname, Department, JobTitle)
4. **License assignment** — resolves the SKU part number, checks available 
   seats, and assigns the specified M365 license
5. **Group membership** — adds the user to one or more security or M365 
   groups by Object ID
6. **Manager assignment** — sets the manager relationship in Entra ID
7. **Mailbox verification** — polls Exchange Online for mailbox provisioning 
   confirmation (up to 5 minutes)
8. **Structured logging** — writes a timestamped JSON log entry with full 
   step results and any errors encountered

## Why this script exists
Manual onboarding across Admin Center, Exchange Online, and Teams took 
25–45 minutes per user and introduced inconsistency across technicians. 
This script makes provisioning idempotent, auditable, and pipeline-ready — 
reducing a multi-step manual process to a single command.

## Key features

- **-WhatIf support** — dry run mode previews all changes without making them
- **CSV batch import** — provision multiple users from a structured CSV file
- **Idempotent design** — safe to re-run without creating duplicate objects
- **Structured JSON logging** — every run appends a timestamped log entry
- **Auto password generation** — generates a compliant 16-character temporary 
  password if none is provided
- **License seat validation** — checks available seats before assigning

## Requirements
```powershell
Install-Module Microsoft.Graph -Scope CurrentUser
Install-Module ExchangeOnlineManagement -Scope CurrentUser
```

Connect before running:
```powershell
Connect-MgGraph -Scopes "User.ReadWrite.All","Group.ReadWrite.All","Directory.ReadWrite.All"
Connect-ExchangeOnline -UserPrincipalName admin@contoso.com
```

Required roles: User Administrator + License Administrator + Exchange Admin

## Usage

**Single user:**
```powershell
.\New-UserOnboarding.ps1 `
    -FirstName "Jane" `
    -LastName "Doe" `
    -UserPrincipalName "jdoe@contoso.com" `
    -Department "Engineering" `
    -JobTitle "Platform Engineer" `
    -ManagerUPN "msmith@contoso.com" `
    -LicenseSku "SPE_E5" `
    -GroupIds @("xxxxxxxx-xxxx-xxxx-xxxx-xxxxxxxxxxxx") `
    -UsageLocation "US"
```

**Batch from CSV:**
```powershell
Import-Csv -Path .\new-hires.csv | ForEach-Object {
    $groups = $_.GroupIds -split ";" | Where-Object { $_ }
    .\New-UserOnboarding.ps1 `
        -FirstName $_.FirstName `
        -LastName $_.LastName `
        -UserPrincipalName $_.UserPrincipalName `
        -LicenseSku $_.LicenseSku `
        -GroupIds $groups
}
```

**Dry run:**
```powershell
.\New-UserOnboarding.ps1 -FirstName "Test" -LastName "User" `
    -UserPrincipalName "testuser@contoso.com" -LicenseSku "SPE_E5" -WhatIf
```

## Part of the Identity Lifecycle Automation category
Script 01 of 24 in the PowerShell Infrastructure Library.

## File
[New-UserOnboarding.ps1](./New-UserOnboarding.ps1)