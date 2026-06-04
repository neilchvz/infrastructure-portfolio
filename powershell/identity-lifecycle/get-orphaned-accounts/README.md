# Get-OrphanedAccounts.ps1

## Overview
A reporting script that detects orphaned Entra ID user accounts — accounts 
that pose an access control or licensing risk due to prolonged inactivity, 
missing manager, or no license assignment. Produces a tiered report suitable 
for remediation review or feeding into downstream disable workflows.

## What this script does
Evaluates every member account in Entra ID against two risk tiers:

**Tier 1 — Immediate Risk (disable recommended):**
- No sign-in activity beyond the stale threshold (default 90 days) and account is enabled
- Account is enabled but has no assigned licenses
- Account has never signed in and is older than 14 days

**Tier 2 — Review Required:**
- Sign-in activity approaching the stale threshold (default 60 days)
- No manager set in Entra ID

Each flagged account includes: UPN, last sign-in, account age, assigned 
licenses, group memberships, manager, and the specific reason(s) it was flagged.

## Why this script exists
Stale identities expand the attack surface and consume license seats. 
Without a structured way to identify them, they accumulate silently. 
This report drives a regular identity hygiene cycle with clear 
remediation tiers — Tier 1 feeds directly into the offboarding 
workflow, Tier 2 feeds into a review queue.

## Key features

- **Configurable thresholds** — adjust stale and warn day counts via parameters
- **Exclusion pattern** — filter out service accounts and shared mailboxes by UPN regex
- **-ExportCsv flag** — outputs a flat CSV alongside the JSON report
- **-IncludeDisabled flag** — optionally include already-disabled accounts
- **Read-only** — requires Global Reader or Security Reader role only

## Requirements
```powershell
Install-Module Microsoft.Graph -Scope CurrentUser
```

Connect before running:
```powershell
Connect-MgGraph -Scopes "User.Read.All","AuditLog.Read.All","Directory.Read.All"
```

Required role: Global Reader or Security Reader (read-only)

## Usage

**Standard run:**
```powershell
.\Get-OrphanedAccounts.ps1
```

**Custom thresholds:**
```powershell
.\Get-OrphanedAccounts.ps1 -StaleThresholdDays 60 -WarnThresholdDays 30
```

**Exclude service accounts:**
```powershell
.\Get-OrphanedAccounts.ps1 -ExcludePattern "svc-|shared-|noreply"
```

**Export CSV:**
```powershell
.\Get-OrphanedAccounts.ps1 -ExportCsv
```

## Part of the Identity Lifecycle Automation category
Script 04 of 24 in the PowerShell Infrastructure Library.

## File
[Get-OrphanedAccounts.ps1](./Get-OrphanedAccounts.ps1)