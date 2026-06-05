# Repair-DriftedConfiguration.ps1

## Overview
Reads the output of `Invoke-BaselineAudit.ps1` and fixes every failed control by re-applying the expected values from the baseline manifest. Logs every action with before/after state. Works as a standalone fix or as the second half of an automated audit-then-remediate pipeline.

## What this script does

1. **Pre-checks** — verifies admin rights, loads the audit report and baseline manifest
2. **Identifies failures** — pulls every control with a Fail or Error result from the audit report
3. **Looks up expected values** — cross-references each failed control against the manifest to get the correct target value
4. **Remediates** — re-applies the expected value for each failed control across registry, services, firewall rules, and scheduled tasks
5. **Before/after logging** — every action records what the value was and what it was changed to
6. **WhatIf support** — full dry-run mode shows exactly what would be fixed without touching anything
7. **Report output** — structured JSON remediation report, optional CSV

## Problem solved
Audit findings had no automated fix path — engineers had to manually go through each failed control and correct it. This script closes the loop: run the audit, if drift is detected, run this script, then re-run the audit to verify everything is clean.

## Usage

```powershell
# Preview what would be fixed
.\Repair-DriftedConfiguration.ps1 `
    -AuditReportPath ".\baseline-audit-report.json" `
    -BaselineManifestPath ".\baselines\windows-server-2022.json" `
    -WhatIf

# Apply all fixes
.\Repair-DriftedConfiguration.ps1 `
    -AuditReportPath ".\baseline-audit-report.json" `
    -BaselineManifestPath ".\baselines\windows-server-2022.json"

# Fix specific categories only
.\Repair-DriftedConfiguration.ps1 `
    -AuditReportPath ".\baseline-audit-report.json" `
    -BaselineManifestPath ".\baselines\windows-server-2022.json" `
    -IncludeCategories @("RegistryValue", "Service")

# Full automated pipeline
$audit = .\Invoke-BaselineAudit.ps1 -BaselineManifestPath ".\baselines\win22.json"
if ($audit.DriftScore -gt 0) {
    .\Repair-DriftedConfiguration.ps1 `
        -AuditReportPath ".\baseline-audit-report.json" `
        -BaselineManifestPath ".\baselines\win22.json"
}
```

## Requirements
- Must run as Local Administrator
- Windows PowerShell 5.1+ or PowerShell 7+
- Audit report JSON from `Invoke-BaselineAudit.ps1`
- The same baseline manifest used for the audit

## Part of the Endpoint Configuration & Drift Remediation category
Script 20 of 24 in the PowerShell Infrastructure Library.

## File
[Repair-DriftedConfiguration.ps1](./Repair-DriftedConfiguration.ps1)