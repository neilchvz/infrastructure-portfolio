# Remove-UserOffboarding.ps1

## Overview
A fully parameterized M365 offboarding script that executes a structured, 
auditable sequence for departing users. Includes a pre-check to confirm 
the user exists before proceeding. Safe to re-run without unintended 
side effects.

## What this script does
Executes the following steps in sequence:

1. **Pre-flight validation** — verifies required modules and connected sessions
2. **Pre-check** — confirms the target UPN exists in Entra ID before proceeding
3. **Account disablement** — blocks sign-in immediately
4. **Session revocation** — revokes all active refresh tokens and MFA sessions
5. **Group removal** — removes the user from all Entra ID security and M365 groups
6. **Mailbox conversion** — converts the mailbox to shared and grants delegate access to the manager
7. **License removal** — removes all assigned Microsoft 365 license SKUs
8. **OneDrive transfer** — grants the manager site collection admin rights on the departed user's OneDrive
9. **Structured logging** — appends a timestamped JSON log entry with full step results

The user object is not permanently deleted — Entra ID retains it for 30 days 
allowing recovery if needed.

## Why this script exists
Departed users were retaining active sessions and consuming license seats 
for days after leaving. This script enforces a consistent, auditable 
offboarding sequence and immediately stops license spend — replacing a 
multi-step manual process across Admin Center, Exchange, and SharePoint.

## Key features

- **-WhatIf support** — dry run mode previews all changes without making them
- **Flexible skip flags** — individual steps can be skipped via switches
- **CSV batch support** — offboard multiple users from a structured CSV
- **Structured JSON logging** — every run appends a timestamped log entry
- **Non-destructive** — user object is soft-deleted, not permanently removed

## Skip flags

| Flag | Behavior |
|------|----------|
| `-SkipMailboxConversion` | Skip mailbox conversion (use when no Exchange license) |
| `-SkipOneDriveTransfer` | Skip OneDrive transfer (use when SPO not connected) |
| `-SkipGroupRemoval` | Skip group cleanup (use when handled by another process) |
| `-RetainLicenses` | Keep license assignments (use when handled by billing) |

## Requirements
```powershell
Install-Module Microsoft.Graph -Scope CurrentUser
Install-Module ExchangeOnlineManagement -Scope CurrentUser
Install-Module Microsoft.Online.SharePoint.PowerShell -Scope CurrentUser
```

Connect before running:
```powershell
Connect-MgGraph -Scopes "User.ReadWrite.All","Group.ReadWrite.All","Directory.ReadWrite.All"
Connect-ExchangeOnline -UserPrincipalName admin@contoso.com
Connect-SPOService -Url https://contoso-admin.sharepoint.com
```

## Usage

**Standard offboarding:**
```powershell
.\Remove-UserOffboarding.ps1 `
    -UserPrincipalName "jdoe@contoso.com" `
    -ManagerUPN "msmith@contoso.com"
```

**Dry run:**
```powershell
.\Remove-UserOffboarding.ps1 `
    -UserPrincipalName "jdoe@contoso.com" `
    -ManagerUPN "msmith@contoso.com" `
    -WhatIf
```

## Part of the Identity Lifecycle Automation category
Script 02 of 24 in the PowerShell Infrastructure Library.

## File
[Remove-UserOffboarding.ps1](./Remove-UserOffboarding.ps1)