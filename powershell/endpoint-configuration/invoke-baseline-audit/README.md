# Invoke-BaselineAudit.ps1

## Overview
Audits a Windows endpoint against a defined JSON baseline configuration file, checking registry values, service states, firewall rules, and scheduled task states. Every control gets a pass, fail, or error result. The final output is a structured compliance report with a drift score showing what percentage of controls are out of expected state.

## What this script does

1. **Pre-checks** — verifies admin rights, required modules, and loads the baseline manifest
2. **Registry checks** — compares live registry values against expected values defined in the manifest
3. **Service checks** — verifies each service is in its expected state (Running, Stopped, or Disabled)
4. **Firewall checks** — confirms firewall profile states match what the baseline requires
5. **Scheduled task checks** — verifies task states match expected values
6. **Drift score** — calculates the percentage of controls that failed (0 = fully compliant, 100 = everything failed)
7. **Report output** — structured JSON report with per-control results, plus optional CSV

## Problem solved
After deployment there was no way to know whether an endpoint still matched its intended configuration. Patches, user changes, and software installs can quietly drift settings out of baseline. This script gives you an audit layer — run it on a schedule, pipe the output into `Repair-DriftedConfiguration.ps1` to close the loop automatically.

## Usage

```powershell
# Audit local machine
.\Invoke-BaselineAudit.ps1 -BaselineManifestPath ".\baselines\windows-server-2022.json"

# Audit a remote machine, export failures only
.\Invoke-BaselineAudit.ps1 `
    -BaselineManifestPath ".\baselines\windows-server-2022.json" `
    -ComputerName "SERVER01" `
    -FailedOnly `
    -ExportCsv

# Audit then auto-remediate if drift detected
$result = .\Invoke-BaselineAudit.ps1 -BaselineManifestPath ".\baselines\windows-server-2022.json"
if ($result.DriftScore -gt 0) {
    .\Repair-DriftedConfiguration.ps1 `
        -AuditReportPath ".\baseline-audit-report.json" `
        -BaselineManifestPath ".\baselines\windows-server-2022.json"
}
```

## Requirements
- Must run as Local Administrator
- Windows PowerShell 5.1+ or PowerShell 7+
- secedit.exe (included in all Windows versions)
- NetSecurity module for firewall checks

## Note on the baseline manifest
The manifest is a JSON file you define — it lists every control, what to check, and what the expected value is. The same manifest file is used by `Repair-DriftedConfiguration.ps1` for remediation. See the script header for the full manifest format with examples.

## Part of the Endpoint Configuration & Drift Remediation category
Script 17 of 24 in the PowerShell Infrastructure Library.

## File
[Invoke-BaselineAudit.ps1](./Invoke-BaselineAudit.ps1)