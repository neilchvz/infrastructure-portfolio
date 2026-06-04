# Set-MailboxDelegationAudit.ps1

## Overview
Enumerates all mailbox delegation assignments across the Exchange Online 
tenant, flags non-standard or unauthorized delegations against an approved 
baseline, and produces a structured audit report with optional remediation.

## What this script does

1. **Pre-flight validation** — verifies Exchange Online module and session
2. **Mailbox retrieval** — collects all user mailboxes (optionally shared)
3. **Delegation collection** — gathers FullAccess, SendAs, and SendOnBehalf 
   permissions per mailbox
4. **Noise filtering** — removes system-level and self-delegations automatically
5. **Baseline comparison** — flags any delegation not present in an approved CSV
6. **External detection** — automatically flags any delegation to an external 
   or guest account as high risk regardless of baseline
7. **Optional remediation** — removes flagged delegations with `-Remediate`
8. **Structured reporting** — outputs JSON and optional CSV

## Why this script exists
Delegation sprawl is a common compliance gap — ex-employees or shared accounts 
retaining mailbox access long after offboarding. Without a structured audit, 
these assignments accumulate silently. This script surfaces the full delegation 
picture and provides an optional remediation path in a single run.

## Key features

- **-WhatIf support** — preview all changes before applying
- **-Remediate flag** — remove flagged delegations automatically
- **-IncludeSharedMailboxes** — expand scope to include shared mailboxes
- **-ExportCsv flag** — flat CSV for compliance team sharing
- **Baseline comparison** — compare against an approved delegation CSV

## Delegation types audited

| Type | Risk Level | Description |
|------|-----------|-------------|
| FullAccess | High | Full read/manage access to mailbox contents |
| SendAs | High | Send email appearing to come from the mailbox |
| SendOnBehalf | Medium | Send on behalf of the mailbox |

## Requirements

Connect before running:

Connect-ExchangeOnline -UserPrincipalName admin@contoso.com

Required role: Exchange Administrator or View-Only Organization Management

## Usage

**Full audit, no baseline:**

.\Set-MailboxDelegationAudit.ps1 -ExportCsv

**Audit with baseline comparison:**

.\Set-MailboxDelegationAudit.ps1 -BaselineCsvPath ".\approved-delegations.csv" -IncludeSharedMailboxes -ExportCsv

**Dry run remediation:**

.\Set-MailboxDelegationAudit.ps1 -BaselineCsvPath ".\approved-delegations.csv" -Remediate -WhatIf

## Part of the Messaging Infrastructure Ops category
Script 08 of 24 in the PowerShell Infrastructure Library.

## File
[Set-MailboxDelegationAudit.ps1](./Set-MailboxDelegationAudit.ps1)