# Invoke-AzPolicyComplianceScan.ps1

## Overview
Triggers an on-demand Azure Policy compliance scan, waits for it to finish, then retrieves all non-compliant resources in scope. Designed to run as a deployment pipeline gate — exits non-zero if non-compliant resources are found, so a pipeline can stop before promoting changes that violate policy.

## What this script does

1. **Pre-checks** — verifies Azure session and resolves the target scope
2. **Triggers a fresh scan** — kicks off an on-demand evaluation via the Azure REST API rather than relying on the 24-hour cached state
3. **Waits for completion** — polls every 30 seconds until the scan finishes or hits the configured timeout
4. **Retrieves findings** — queries all non-compliant resources in scope, with optional filtering to specific policy definitions
5. **Report output** — structured JSON and optional CSV of non-compliant resources grouped by policy
6. **Pipeline gate** — exits with code 1 if non-compliant resources are found and `-FailOnNonCompliance` is set

## Problem solved
Azure Policy compliance state only refreshes every 24 hours by default. After deploying a resource, the compliance portal could show stale results for up to a day. This script forces a fresh evaluation and gets accurate compliance state immediately — making it usable as a real deployment gate rather than a lagging indicator.

## Usage

```powershell
# Scan full subscription
.\Invoke-AzPolicyComplianceScan.ps1

# Scan a specific resource group and fail pipeline on non-compliance
.\Invoke-AzPolicyComplianceScan.ps1 `
    -ResourceGroupName "rg-platform-prod" `
    -FailOnNonCompliance `
    -ExportCsv

# Filter to specific policy definitions
.\Invoke-AzPolicyComplianceScan.ps1 `
    -PolicyDefinitionNames @(
        "Require a tag on resource groups",
        "Storage accounts should use private link"
    ) `
    -FailOnNonCompliance

# Use as a pipeline gate
.\Invoke-AzPolicyComplianceScan.ps1 -ResourceGroupName "rg-platform-prod" -FailOnNonCompliance
if ($LASTEXITCODE -ne 0) {
    throw "Azure Policy non-compliance detected. Review report before proceeding."
}
```

## Requirements
- Az PowerShell module (Az.PolicyInsights, Az.Accounts, Az.Resources)
- Active Azure session: `Connect-AzAccount`
- Resource Policy Contributor or Security Reader role on target scope

## Part of the Azure Infrastructure Automation category
Script 23 of 24 in the PowerShell Infrastructure Library.

## File
[Invoke-AzPolicyComplianceScan.ps1](./Invoke-AzPolicyComplianceScan.ps1)