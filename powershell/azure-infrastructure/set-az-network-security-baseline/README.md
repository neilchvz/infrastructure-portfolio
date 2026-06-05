# Set-AzNetworkSecurityBaseline.ps1

## Overview
Audits NSG (Network Security Group) rules across Azure subnets against a defined security baseline. Flags rules that introduce exposure — inbound RDP/SSH open to the Internet, unrestricted outbound, missing flow logs — and optionally removes the flagged inbound rules with `-Enforce`. Every finding is severity-rated (Critical, High, Medium) and the full report is pipeline-compatible.

## What this script does

1. **Pre-checks** — verifies Azure session and resolves target NSGs (full subscription or scoped to a resource group)
2. **Inbound rule audit** — flags any Allow rule that opens management ports (RDP, SSH, WinRM, SQL) to the Internet
3. **Wildcard inbound check** — flags fully open inbound rules regardless of port
4. **Missing Deny-All check** — flags NSGs with no explicit Deny-All-Inbound rule
5. **Outbound audit** — flags unrestricted outbound rules allowing any destination on any port
6. **Flow log check** — flags NSGs with no flow log configuration
7. **Tag check** — flags NSGs missing Owner or Environment tags
8. **Remediation** — when `-Enforce` is set, removes flagged Critical inbound rules (outbound issues require human review)
9. **Report output** — structured JSON and optional CSV, findings sorted by severity

## Problem solved
NSG rule drift is hard to catch without proactive auditing. A single misconfigured inbound rule can expose RDP or SSH to the public Internet and go unnoticed for weeks. This script gives you a scheduled audit layer and an optional auto-remediation path for the most critical exposures.

## Usage

```powershell
# Audit all NSGs in a subscription
.\Set-AzNetworkSecurityBaseline.ps1

# Audit NSGs in a specific resource group
.\Set-AzNetworkSecurityBaseline.ps1 -ResourceGroupName "rg-platform-prod"

# Dry-run remediation — preview what would be removed
.\Set-AzNetworkSecurityBaseline.ps1 -ResourceGroupName "rg-platform-prod" -Enforce -WhatIf

# Live remediation — remove flagged inbound rules
.\Set-AzNetworkSecurityBaseline.ps1 -ResourceGroupName "rg-platform-prod" -Enforce

# Export CSV for security review
.\Set-AzNetworkSecurityBaseline.ps1 -ExportCsv -ReportPath ".\nsg-audit.json"
```

## Requirements
- Az PowerShell module (Az.Network, Az.Accounts)
- Active Azure session: `Connect-AzAccount`
- Network Reader role for audit-only mode
- Network Contributor role when using `-Enforce`

## Note on remediation scope
`-Enforce` only removes Critical inbound rules (management ports open to Internet). Outbound findings and flow log gaps are flagged but not auto-remediated — those require human review and deliberate configuration changes.

## Part of the Azure Infrastructure Automation category
Script 24 of 24 in the PowerShell Infrastructure Library.

## File
[Set-AzNetworkSecurityBaseline.ps1](./Set-AzNetworkSecurityBaseline.ps1)