# Set-NISTSecurityBaseline.ps1

## Overview
Applies a curated set of Windows security settings mapped to NIST SP 800-171 and NIST SP 800-53 controls. Every setting in the script is annotated with its control ID in comments — making the script itself a form of compliance documentation. Covers account policy, audit policy, SMB hardening, credential protection, RDP encryption, and more.

## What this script does

1. **Pre-checks** — verifies admin rights before touching anything
2. **Reads before writing** — checks the current value of each setting first; skips the write if it already matches (won't break things if you run it twice)
3. **SMB and network hardening** — enforces SMB signing, restricts NTLM, blocks anonymous access
4. **Credential protection** — disables WDigest, enables LSASS protection, preps for Credential Guard
5. **RDP hardening** — enforces NLA and sets minimum encryption level
6. **Audit policy** — configures Windows audit categories for logon, privilege use, account management, and policy changes
7. **Account policy** — sets lockout thresholds, minimum password length, and password history
8. **Report output** — structured JSON showing every setting applied, already compliant, skipped, or errored

## Problem solved
NIST control implementation was done manually per machine, inconsistently, with no record of what was actually applied. This script makes control application repeatable and version-controllable — run it on a new machine or after a drift event and the baseline is back in place.

## Usage

```powershell
# Apply full NIST baseline
.\Set-NISTSecurityBaseline.ps1

# Preview all changes without applying anything
.\Set-NISTSecurityBaseline.ps1 -WhatIf

# Skip policies managed centrally by Group Policy
.\Set-NISTSecurityBaseline.ps1 -SkipAuditPolicy -SkipAccountPolicy
```

## Requirements
- Must run as Local Administrator
- Windows Server 2016+ or Windows 10/11
- secedit.exe (included in all supported Windows versions)

## Note on Group Policy
Settings applied by this script will be overwritten by conflicting GPOs at the next policy refresh. In GPO-managed environments, use this script to identify gaps rather than as the primary enforcement mechanism.

## Note on restarts
Some settings (WDigest, LSASS protection, Credential Guard) require a restart to take full effect. The report flags which settings need one.

## Part of the Endpoint Configuration & Drift Remediation category
Script 18 of 24 in the PowerShell Infrastructure Library.

## File
[Set-NISTSecurityBaseline.ps1](./Set-NISTSecurityBaseline.ps1)