# Disable Remote Desktop (ARD)

## Overview
A shell script that disables Apple Remote Desktop (ARD) on macOS devices 
as part of a security baseline enforcement workflow.

## What this script does
Deactivates the ARD agent using Apple's built-in `kickstart` utility, 
disabling inbound remote desktop connections on the device.

## Why this script exists
Apple Remote Desktop represents an unnecessary attack surface in environments 
where remote access is handled through a managed RMM tool (ScreenConnect). 
For clients handling sensitive data, disabling ARD is part of a hardened 
security baseline — consistent with the same principle applied on the 
Windows side via Intune.

## Deployment context
This script is designed to run as part of an automated compliance 
remediation workflow in Addigy. When a device is flagged as non-compliant 
for having Remote Desktop enabled, the workflow automatically deploys 
this script to remediate — removing the manual touchpoint entirely.

## Usage
```bash
sudo bash disable-remote-desktop.sh
```

## Note
Disabling ARD does not affect ScreenConnect or other RMM agents — 
those operate independently of Apple Remote Desktop.

## File
[disable-remote-desktop.sh](./disable-remote-desktop.sh)