# New-RetentionPolicyDeployment.ps1

## Overview
Deploys Microsoft Purview retention policies from a parameter-driven configuration across Exchange, SharePoint, OneDrive, and Teams workloads. Idempotent — checks existing policy state before creating or updating. Treats retention configuration as code rather than a manual portal task.

## What this script does

1. **Pre-flight validation** — verifies Security & Compliance session (IPPS)
2. **Pre-check** — detects whether a policy with the specified name already exists
3. **Create or update** — creates the policy if new; reconciles and updates if drift is detected
4. **Retention rule deployment** — creates or updates the associated rule defining duration, action, and trigger
5. **WhatIf support** — full dry-run mode previews all changes without applying them
6. **Structured logging** — writes a JSON run log with every action and outcome

## Problem solved
Retention policies were applied inconsistently across workloads, creating legal hold and compliance risk. This script makes retention configuration repeatable, auditable, and pipeline-ready — the same policy can be deployed to a new tenant in one command.

## Usage

```powershell
# Deploy a 7-year retention policy for Exchange
.\New-RetentionPolicyDeployment.ps1 `
    -PolicyName "Exchange - 7 Year Retention" `
    -Workload "Exchange" `
    -RetentionDays 2555 `
    -RetentionAction "KeepAndDelete" `
    -RetentionTrigger "CreationDate" `
    -Comment "Legal hold requirement - Finance team mailboxes"

# Deploy across all workloads
.\New-RetentionPolicyDeployment.ps1 `
    -PolicyName "Global - 3 Year Retention" `
    -Workload "All" `
    -RetentionDays 1095 `
    -RetentionAction "KeepAndDelete" `
    -RetentionTrigger "CreationDate"

# Dry run
.\New-RetentionPolicyDeployment.ps1 `
    -PolicyName "Teams - 2 Year Retention" `
    -Workload "Teams" `
    -RetentionDays 730 `
    -RetentionAction "Keep" `
    -WhatIf
```

## Requirements
- `ExchangeOnlineManagement` module
- Active IPPS session: `Connect-IPPSSession -UserPrincipalName admin@org.com`
- Compliance Administrator or Retention Management role in Purview

## Compliance mapping
- NIST 800-53 AU-11 (Audit Record Retention)
- NIST 800-53 SI-12 (Information Management and Retention)
- SOC 2 CC7.2, A1.2

## Part of the Identity Lifecycle Automation category
Script 11 of 24 in the PowerShell Infrastructure Library.

## File
[New-RetentionPolicyDeployment.ps1](./New-RetentionPolicyDeployment.ps1)