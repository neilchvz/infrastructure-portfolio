# Get-SensitivityLabelReport.ps1

## Overview
Reports sensitivity label coverage across SharePoint Online sites and OneDrive accounts in the tenant. Surfaces unlabeled content containers, label downgrade events, and sites where external sharing is enabled without a restrictive label — a combination that represents direct data exposure risk.

## What this script does

1. **Pre-flight validation** — verifies SharePoint Online session
2. **Site retrieval** — collects all SharePoint site collections (excluding system templates)
3. **Label evaluation** — checks each site for label presence, permissive labels, and external sharing state
4. **OneDrive evaluation** — optionally scans OneDrive accounts against the same criteria
5. **Flagging logic** — flags sites with no label, permissive labels with external sharing enabled, or both
6. **Structured output** — writes JSON report and optional CSV for auditor review or SIEM ingestion

## Problem solved
Auditors required evidence of data classification coverage across the tenant and there was no efficient way to pull it. This script generates a full classification inventory on demand and maps findings directly to compliance control evidence.

## Usage

```powershell
# Standard report — all sites and OneDrive
.\Get-SensitivityLabelReport.ps1 -TenantName "contoso"

# Report with CSV export
.\Get-SensitivityLabelReport.ps1 -TenantName "contoso" -ExportCsv

# Flagged items only
.\Get-SensitivityLabelReport.ps1 -TenantName "contoso" -FlaggedOnly -ExportCsv

# Skip OneDrive (faster for large tenants)
.\Get-SensitivityLabelReport.ps1 -TenantName "contoso" -SkipOneDrive
```

## Requirements
- SharePoint Online Management Shell
- Microsoft.Graph PowerShell SDK
- Active SPO session: `Connect-SPOService -Url https://contoso-admin.sharepoint.com`
- SharePoint Administrator or Global Reader role

## Compliance mapping
- NIST 800-53 MP-3 (Media Marking)
- NIST 800-53 SI-12 (Information Retention)
- SOC 2 CC6.1 (Logical Access Controls)

## Part of the Identity Lifecycle Automation category
Script 12 of 24 in the PowerShell Infrastructure Library.

## File
[Get-SensitivityLabelReport.ps1](./Get-SensitivityLabelReport.ps1)