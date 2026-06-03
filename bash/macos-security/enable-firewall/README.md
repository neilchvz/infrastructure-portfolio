# Enable Firewall

## Overview
A shell script that enables the macOS application firewall via the 
command line, used as part of an automated compliance remediation 
workflow in Addigy.

## What this script does
Writes directly to the macOS firewall preference file to enable the 
application firewall, setting `globalstate` to `1`.

## Why this script exists
This script was born out of two distinct use cases:

**Use case 1 — Profile-averse environments**
A SaaS development client did not want MDM configuration profiles pushed 
to their devices. However they agreed on a baseline of non-negotiable 
security requirements — FileVault and firewall enforcement. This script 
allowed those settings to be enforced through the Addigy compliance 
engine without deploying a configuration profile.

**Use case 2 — Admin override remediation**
The Security and Privacy Global Policy profile enables the firewall 
on managed devices — but local admins can turn it off again. This 
script runs automatically via the compliance engine when a device 
is detected with the firewall disabled, remediating the override 
without manual intervention.

## Deployment context
Deployed via Addigy's compliance policy engine as a remediation script. 
Triggers automatically when a device is flagged as non-compliant for 
having the firewall disabled.

## Usage
```bash
sudo bash enable-firewall.sh
```

## File
[enable-firewall.sh](./enable-firewall.sh)