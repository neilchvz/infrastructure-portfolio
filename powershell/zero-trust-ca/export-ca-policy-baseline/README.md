# Export-CAPolicyBaseline.ps1

## Overview
Exports all Entra ID Conditional Access policies to versioned JSON files, 
creating a policy-as-code baseline for Git storage, drift detection, and 
rollback reference. The output is designed to be committed to source control 
so any future deviation from the approved state can be detected.

## What this script does

1. **Pre-flight validation** — verifies required modules and Graph session
2. **Policy retrieval** — pulls all CA policies from the tenant including 
   conditions, grant controls, and session controls
3. **Enrichment** — resolves group Object IDs to human-readable display names 
   and adds metadata for readability
4. **Individual policy files** — writes one JSON file per policy, named by 
   sanitized policy display name
5. **Manifest file** — writes a `baseline-manifest.json` index file listing 
   all exported policies with IDs, states, and export timestamp
6. **Consolidated file** — optionally writes a single `all-policies.json` 
   containing the full policy set

## Why this script exists
Without a source of truth for CA policy state, a single accidental policy 
change could break authentication for the entire organization with no 
rollback path. This script enables GitOps for identity policy — every 
approved CA configuration is version-controlled, reviewable, and recoverable.

## Key features

- **-WhatIf support** — preview what would be exported without writing files
- **-IncludeDisabled flag** — optionally include disabled policies in the export
- **-Consolidate flag** — write a single combined JSON file for bulk comparison
- **Structured logging** — writes a JSON log entry for every run
- **Works with Compare-CAPolicyDrift.ps1** — the manifest is the anchor for 
  downstream drift detection (Script 06)

## Git workflow
After running this script, commit the output directory to your 
policy-as-code repository. Tag the commit with a date or change ticket 
number. Run `Compare-CAPolicyDrift.ps1` at any time to diff live state 
against this baseline.

## Requirements
```powershell
Install-Module Microsoft.Graph -Scope CurrentUser
```

Connect before running:
```powershell
Connect-MgGraph -Scopes "Policy.Read.All","Directory.Read.All"
```

Required role: Security Reader or Global Reader

## Usage

**Standard export:**

.\Export-CAPolicyBaseline.ps1

**Export to specific directory:**

.\Export-CAPolicyBaseline.ps1 -OutputPath ".\zero-trust-ca\baseline\"

**Include disabled policies with consolidated file:**

.\Export-CAPolicyBaseline.ps1 -IncludeDisabled -Consolidate

**Dry run:**

.\Export-CAPolicyBaseline.ps1 -WhatIf

## Part of the Zero Trust / Conditional Access category
Script 05 of 24 in the PowerShell Infrastructure Library.

## File
[Export-CAPolicyBaseline.ps1](./Export-CAPolicyBaseline.ps1)