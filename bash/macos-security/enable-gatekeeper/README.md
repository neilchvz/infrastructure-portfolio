# Enable Gatekeeper

## Overview
A shell script that enables Gatekeeper on macOS devices as part of 
an automated compliance remediation workflow in Addigy.

## What this script does
Enables Gatekeeper using `spctl --master-enable`, enforcing Apple's 
application security policy and preventing unverified software from 
running on the device.

## Why this script exists
This script shares the same origin as the Enable Firewall script — 
built for a SaaS development client who declined MDM configuration 
profiles but agreed to a baseline of non-negotiable security requirements. 
Gatekeeper enforcement was one of those requirements.

Also used as a compliance remediation script — when Addigy's compliance 
engine detects Gatekeeper is disabled on a managed device, this script 
runs automatically to remediate without manual intervention.

## Deployment context
Deployed via Addigy's compliance policy engine as a remediation script. 
Triggers automatically when a device is flagged as non-compliant for 
having Gatekeeper disabled.

## Usage
```bash
sudo bash enable-gatekeeper.sh
```

## File
[enable-gatekeeper.sh](./enable-gatekeeper.sh)