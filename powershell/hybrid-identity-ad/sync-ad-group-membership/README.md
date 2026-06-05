# Sync-ADGroupMembership.ps1

## Overview
Reconciles Active Directory group membership against an authoritative source — typically a CSV export from an HRIS or identity governance platform. Adds users who should be in a group but aren't, removes users who are in the group but no longer should be, and logs every change with before/after state.

## What this script does

1. **Pre-checks** — verifies AD module and domain connectivity
2. **CSV load and validation** — reads the authoritative source file and confirms required columns are present
3. **Per-group reconciliation** — for each group in the source, compares current AD membership against the source list
4. **Adds missing members** — users in the source but not in the AD group get added
5. **Removes unauthorized members** — users in the AD group but not in the source get removed
6. **Full audit trail** — every add, remove, and no-change action is logged with a reason
7. **WhatIf and report-only modes** — preview all changes before running live

## Problem solved
Group membership drift between an HRIS and AD is a common source of access control failures — especially after role changes, transfers, or terminations that were updated in the HR system but never propagated to the directory. This script closes that gap on a schedule, enforcing least-privilege without manual intervention.

## Usage

```powershell
# Standard reconciliation
.\Sync-ADGroupMembership.ps1 -CsvPath .\group-source.csv

# Dry run — see what would change without touching anything
.\Sync-ADGroupMembership.ps1 -CsvPath .\group-source.csv -WhatIf

# Specific groups only
.\Sync-ADGroupMembership.ps1 -CsvPath .\group-source.csv `
    -GroupFilter @("GRP-Engineering", "GRP-Platform")

# Report-only — generate the diff without making changes
.\Sync-ADGroupMembership.ps1 -CsvPath .\group-source.csv -ReportOnly
```

## CSV format
```csv
GroupName,MemberUPN,MemberName,Department,Role
GRP-Engineering,jdoe@org.com,Jane Doe,Engineering,Platform Engineer
GRP-Finance,alee@org.com,Amy Lee,Finance,Analyst
```
`GroupName` and `MemberUPN` are required. The rest are optional and used for reporting only.

## Requirements
- ActiveDirectory PowerShell module (RSAT: AD DS and LDS Tools)
- Write permission on target AD groups (Domain Admins or delegated Group Management role)

## Part of the Hybrid Identity & Directory Ops category
Script 15 of 24 in the PowerShell Infrastructure Library.

## File
[Sync-ADGroupMembership.ps1](./Sync-ADGroupMembership.ps1)