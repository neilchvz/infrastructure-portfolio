# Compare-CAPolicyDrift.ps1

## Overview
Compares the live Conditional Access policy state in Entra ID against a 
stored JSON baseline produced by `Export-CAPolicyBaseline.ps1`. Detects 
added, removed, and modified policies — and exits with a non-zero code 
when drift is found, enabling use as a gate in CI/CD pipelines.

## What this script does
Detects three categories of drift:

- **Added** — policies present in the live tenant but not in the baseline
- **Removed** — policies in the baseline but missing from the live tenant
- **Modified** — policies present in both, but with changes to state, 
  conditions, grant controls, or session controls

Outputs a structured drift report and exits with code `1` if any drift 
is detected, or `0` if the live state matches the baseline cleanly.

## Why this script exists
Unauthorized or accidental CA policy changes can go undetected for days — 
silently breaking Zero Trust enforcement or creating security gaps. This 
script closes the feedback loop between what was approved and what is 
actually enforced. It also enables policy governance in CI/CD pipelines 
by blocking deployments when CA drift is present.

## Key features

- **Pipeline gate support** — exits non-zero on drift for CI/CD integration
- **Deep comparison** — uses JSON serialization to detect nested field changes 
  in conditions, grant controls, and session controls
- **Three drift categories** — distinguishes between added, removed, and modified
- **Structured drift report** — outputs JSON with per-policy diff summary

## CI/CD usage

```powershell
.\Compare-CAPolicyDrift.ps1 -BaselinePath ".\ca-baseline\baseline-manifest.json"
if ($LASTEXITCODE -ne 0) { throw "CA policy drift detected. Review before deploying." }
```

## Requirements
```powershell
Install-Module Microsoft.Graph -Scope CurrentUser
```

Connect before running:
```powershell
Connect-MgGraph -Scopes "Policy.Read.All"
```

Required role: Security Reader or Global Reader

## Usage

**Standard drift check:**

.\Compare-CAPolicyDrift.ps1 -BaselinePath ".\ca-baseline\baseline-manifest.json"

**Write drift report to specific path:**

.\Compare-CAPolicyDrift.ps1 -BaselinePath ".\ca-baseline\baseline-manifest.json" -ReportPath ".\ca-drift-report.json"

## Part of the Zero Trust / Conditional Access category
Script 06 of 24 in the PowerShell Infrastructure Library.

## File
[Compare-CAPolicyDrift.ps1](./Compare-CAPolicyDrift.ps1)