# Get-ADStaleObjectReport.ps1

## Overview
Identifies stale Active Directory user and computer accounts based on configurable inactivity thresholds, then produces a tiered report with OU path, group memberships, and a recommended action for each object. Output feeds directly into a regular AD hygiene cycle.

## What this script does

1. **Pre-checks** — verifies the AD module and domain connectivity
2. **User account scan** — pulls all enabled user accounts and checks last logon and password age against configured thresholds
3. **Computer account scan** — pulls all enabled computer objects and checks last domain authentication
4. **Tier assignment** — categorizes each stale object as Tier 1 (disable recommended) or Tier 2 (review required)
5. **Enrichment** — adds OU path, group memberships, and manager to each result
6. **Report output** — writes a structured JSON report and optional CSV grouped by tier

## Problem solved
Unmanaged AD accounts expand the attack surface and, when synced to Entra ID via Entra Connect, consume cloud licenses for accounts that haven't been active in months. There was no efficient way to surface these at scale — this script produces a clean, tiered remediation list on demand.

## Usage

```powershell
# Standard domain-wide report
.\Get-ADStaleObjectReport.ps1

# Scoped to a specific OU with tighter thresholds
.\Get-ADStaleObjectReport.ps1 `
    -SearchBase "OU=Corp Users,DC=contoso,DC=com" `
    -UserStaleDays 60 `
    -PasswordStaleDays 120 `
    -ExportCsv

# Computer objects only
.\Get-ADStaleObjectReport.ps1 -SkipUsers -ExportCsv

# Exclude service account OUs from results
.\Get-ADStaleObjectReport.ps1 `
    -ExcludeOUs @(
        "OU=ServiceAccounts,DC=contoso,DC=com",
        "OU=ManagedAccounts,DC=contoso,DC=com"
    ) -ExportCsv
```

## Requirements
- ActiveDirectory PowerShell module (RSAT: AD DS and LDS Tools)
- Read access to AD (Domain User rights are sufficient for most OUs)
- Run from a domain-joined machine

## Note on lastLogonTimestamp
AD only updates this attribute every 9–14 days by design. Accounts inactive for fewer than 14 days may appear in results. Add a buffer to thresholds in production (e.g. use 104 days instead of 90) to account for this lag.

## Part of the Hybrid Identity & Directory Ops category
Script 14 of 24 in the PowerShell Infrastructure Library.

## File
[Get-ADStaleObjectReport.ps1](./Get-ADStaleObjectReport.ps1)