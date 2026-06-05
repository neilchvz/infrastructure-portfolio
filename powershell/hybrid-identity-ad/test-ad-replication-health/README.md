# Test-ADReplicationHealth.ps1

## Overview
Tests Active Directory replication health across all domain controllers in the domain. Surfaces replication failures, USN rollback indicators, and lingering object conditions. Returns a structured health report that works as a one-off check or integrates directly into a monitoring pipeline.

## What this script does

1. **Pre-checks** — verifies AD module, repadmin availability, and domain connectivity
2. **Per-DC checks** — for each domain controller, checks:
   - Replication failure count and last error (via repadmin)
   - USN rollback indicators (a sign the DC may be serving stale data)
   - NETLOGON service status
   - SYSVOL replication health
   - DNS resolution
   - Time skew against the PDC emulator (Kerberos breaks at 5 minutes — this flags at 4)
3. **Domain-wide checks** — replication summary across all DCs, lingering object detection
4. **Overall status** — returns Healthy, Warning, or Critical based on what was found
5. **Report output** — structured JSON health report plus run log

## Problem solved
Replication failures were only discovered during incidents — password changes not applying, Group Policy not updating, authentication failures on specific DCs. This script makes replication health a proactive, scheduled check rather than a reactive investigation. Can be plugged directly into an alerting pipeline: if `OverallStatus -ne "Healthy"` → fire an alert.

## Usage

```powershell
# Full domain health check
.\Test-ADReplicationHealth.ps1

# Check specific DCs only
.\Test-ADReplicationHealth.ps1 -DomainControllers @("DC01", "DC02")

# Output to a dated file
.\Test-ADReplicationHealth.ps1 -ReportPath ".\dc-health-$(Get-Date -Format 'yyyyMMdd').json"

# Silent mode — return health object for monitoring pipeline use
$health = .\Test-ADReplicationHealth.ps1 -Quiet
if ($health.OverallStatus -ne "Healthy") { Send-Alert $health }
```

## Requirements
- ActiveDirectory PowerShell module (RSAT: AD DS and LDS Tools)
- repadmin.exe (included with RSAT)
- Domain Admin or Replicating Directory Changes right
- Run from a domain-joined machine

## Part of the Hybrid Identity & Directory Ops category
Script 16 of 24 in the PowerShell Infrastructure Library.

## File
[Test-ADReplicationHealth.ps1](./Test-ADReplicationHealth.ps1)