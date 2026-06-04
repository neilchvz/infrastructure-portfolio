# New-SharedMailboxProvisioning.ps1

## Overview
Provisions a shared mailbox in Exchange Online using a standardized, 
repeatable process. Enforces consistent naming, permission assignment, 
auto-mapping, Send-As rights, and retention policy application from a 
single parameterized call. Includes a pre-check to prevent duplicate 
creation — safe to re-run.

## What this script does

1. **Pre-check** — verifies the mailbox doesn't already exist before creating
2. **Mailbox creation** — creates the shared mailbox with standardized alias
3. **FullAccess assignment** — grants specified members full access with auto-mapping enabled
4. **SendAs assignment** — grants specified members Send-As rights
5. **SendOnBehalf assignment** — optionally grants Send-On-Behalf rights
6. **Retention policy** — applies a specified retention policy tag
7. **GAL visibility** — optionally hides the mailbox from the Global Address List
8. **Structured logging** — appends a JSON log entry for every run

## Why this script exists
Inconsistent shared mailbox setups created recurring support tickets around 
missing permissions and auto-mapping not working. Manual provisioning through 
the Exchange Admin Center frequently missed permission types or policy 
application. This script enforces a single, documented provisioning standard 
every time.

## Key features

- **-WhatIf support** — dry run mode previews all changes
- **CSV batch support** — provision multiple mailboxes from a structured CSV
- **Auto-mapping** — enabled by default on FullAccess assignments
- **Structured logging** — every run appends a timestamped JSON log entry

## Requirements

Connect before running:

Connect-ExchangeOnline -UserPrincipalName admin@contoso.com

Required role: Exchange Administrator

## Usage

**Standard provisioning:**

.\New-SharedMailboxProvisioning.ps1 -DisplayName "IT Help Desk" -EmailAddress "helpdesk@contoso.com" -FullAccessMembers @("jdoe@contoso.com") -SendAsMembers @("jdoe@contoso.com") -RetentionPolicy "Default 2 Year"

**Dry run:**

.\New-SharedMailboxProvisioning.ps1 -DisplayName "Finance Team" -EmailAddress "finance@contoso.com" -FullAccessMembers @("jdoe@contoso.com") -WhatIf

## Part of the Messaging Infrastructure Ops category
Script 09 of 24 in the PowerShell Infrastructure Library.

## File
[New-SharedMailboxProvisioning.ps1](./New-SharedMailboxProvisioning.ps1)