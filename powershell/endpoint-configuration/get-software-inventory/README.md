# Get-SoftwareInventory.ps1

## Overview
Collects installed software from Windows endpoints using three complementary sources — registry uninstall keys, WMI, and AppX packages — deduplicates the results, and outputs a structured inventory per machine. Supports running against a single machine, a list of hostnames, or a text file of targets for fleet-wide collection.

## What this script does

1. **Pre-checks** — resolves target machine list (local, specified hostnames, or from file)
2. **Registry collection** — reads 64-bit and 32-bit uninstall keys (fastest, most accurate for traditional installers)
3. **WMI collection** — catches software the registry misses (optional — see note below)
4. **AppX collection** — captures Microsoft Store and modern UWP apps not visible in registry
5. **Deduplication** — merges results across sources, preferring registry entries when the same app appears in multiple sources
6. **Report output** — structured JSON and/or CSV per machine, one row per software entry in CSV mode

## Problem solved
No centralized software inventory meant patch management and vulnerability assessments were flying blind. This script produces a clean, structured inventory that feeds directly into SIEM, CMDB, or vulnerability scanner integrations (Tenable, Qualys, Rapid7) without additional processing.

## Usage

```powershell
# Inventory local machine
.\Get-SoftwareInventory.ps1

# Inventory remote machines
.\Get-SoftwareInventory.ps1 -ComputerNames @("SERVER01", "SERVER02", "WRK001")

# Inventory from a hostname list file
.\Get-SoftwareInventory.ps1 -ComputerListPath ".\hostnames.txt"

# Skip WMI (safer for sensitive production servers)
.\Get-SoftwareInventory.ps1 -SkipWMI -ComputerNames @("PRODSVR01")

# Export as CSV
.\Get-SoftwareInventory.ps1 -OutputFormat CSV -ReportPath ".\inventory.csv"
```

## Requirements
- Windows PowerShell 5.1+ or PowerShell 7+
- For remote targets: WinRM enabled on each target, local admin rights

## Note on WMI
The Win32_Product WMI query can trigger MSI reconfiguration validation on some systems, which can cause a brief performance hit. Use `-SkipWMI` on sensitive production servers where this is a concern.

## Part of the Endpoint Configuration & Drift Remediation category
Script 19 of 24 in the PowerShell Infrastructure Library.

## File
[Get-SoftwareInventory.ps1](./Get-SoftwareInventory.ps1)