# Get-AzCostAnomalyReport.ps1

## Overview
Queries Azure Cost Management for daily spend per subscription and resource group, compares it against a 30-day rolling average, and flags any days where spending deviates beyond a configurable threshold. Outputs a ranked anomaly report sorted by severity, suitable for alert routing or dashboard ingestion.

## What this script does

1. **Pre-checks** — verifies Azure session and resolves target subscription list
2. **Baseline calculation** — pulls 30 days of daily spend data and calculates the average as a baseline
3. **Anomaly detection** — for each day in the lookback window, calculates the deviation from baseline and flags anything over the threshold
4. **Resource group breakdown** — optionally drills down to per-resource-group spend for more granular findings
5. **Ranked output** — sorts anomalies by deviation percentage, highest first
6. **Report output** — structured JSON report and optional CSV

## Problem solved
Cost spikes from misconfigured resources, runaway autoscale events, or forgotten dev environments were only caught when the monthly invoice arrived. This script makes cost anomaly detection a daily, scheduled check rather than a monthly surprise — and gives you a ranked list of exactly where the deviation is coming from.

## Usage

```powershell
# Check current subscription (last 7 days vs 30-day baseline)
.\Get-AzCostAnomalyReport.ps1

# Check specific subscriptions
.\Get-AzCostAnomalyReport.ps1 -SubscriptionIds @("sub-id-1", "sub-id-2")

# Custom threshold and lookback window
.\Get-AzCostAnomalyReport.ps1 -AnomalyThresholdPercent 30 -LookbackDays 14

# Include resource group level breakdown
.\Get-AzCostAnomalyReport.ps1 -IncludeResourceGroupBreakdown -ExportCsv
```

## Requirements
- Az PowerShell module (Az.CostManagement, Az.Accounts, Az.Resources)
- Active Azure session: `Connect-AzAccount`
- Cost Management Reader role on target subscription(s)

## Part of the Azure Infrastructure Automation category
Script 22 of 24 in the PowerShell Infrastructure Library.

## File
[Get-AzCostAnomalyReport.ps1](./Get-AzCostAnomalyReport.ps1)