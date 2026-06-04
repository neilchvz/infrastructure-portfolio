# Get-CAGapReport.ps1

## Overview
Evaluates Entra ID users and service principals against the full Conditional 
Access policy set to identify entities not covered by any enforcing policy. 
Produces a risk-tiered gap report for Zero Trust posture review and 
compliance evidence.

## What this script does

1. Retrieves all enabled CA policies and builds a coverage map
2. Identifies users explicitly excluded from all active policies
3. Identifies users with no applicable policy based on group membership
4. Optionally flags service principals with no CA policy targeting them
5. Cross-references gap findings against privileged role membership for 
   risk tier escalation
6. Outputs a structured JSON/CSV report grouped by risk tier

## Risk tiers

| Tier | Criteria |
|------|----------|
| **Critical** | Privileged role members (Global Admin, Security Admin, etc.) with no CA coverage — immediate remediation required |
| **High** | Licensed users with no CA coverage and sign-in activity in the last 30 days |
| **Medium** | Licensed users with no CA coverage and no recent sign-in |
| **Low** | Unlicensed users or guests with no CA coverage |

## Why this script exists
Even in well-configured tenants, users or privileged accounts can fall through 
CA policy gaps — excluded from all policies or simply never targeted. These 
blind spots represent real Zero Trust exposure. This report makes the invisible 
visible and provides the evidence trail required for SOC 2 and NIST 800-53 
compliance reviews.

## Key features

- **Risk tiering** — findings ranked by severity based on privilege and activity
- **Privileged role detection** — automatically flags Global Admins, Security 
  Admins, and other high-value accounts with coverage gaps
- **-IncludeServicePrincipals flag** — optionally evaluate app CA coverage
- **-ExportCsv flag** — flat CSV output for stakeholder sharing
- **Compliance mapping** — findings map to NIST 800-53 AC-2, AC-17, IA-2

## Requirements
```powershell
Install-Module Microsoft.Graph -Scope CurrentUser
```

Connect before running:
```powershell
Connect-MgGraph -Scopes "Policy.Read.All","Directory.Read.All","User.Read.All","RoleManagement.Read.Directory","AuditLog.Read.All"
```

Required role: Security Reader or Global Reader (read-only)

## Usage

**Standard gap report:**

.\Get-CAGapReport.ps1

**With CSV export:**

.\Get-CAGapReport.ps1 -ExportCsv

**Include service principal coverage:**

.\Get-CAGapReport.ps1 -IncludeServicePrincipals -ExportCsv

## Part of the Zero Trust / Conditional Access category
Script 07 of 24 in the PowerShell Infrastructure Library.

## File
[Get-CAGapReport.ps1](./Get-CAGapReport.ps1)