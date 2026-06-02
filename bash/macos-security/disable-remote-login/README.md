# Disable Remote Login (SSH)

## Overview
A shell script that disables Remote Login on macOS devices, turning off 
inbound SSH access as part of a security baseline enforcement workflow.

## What this script does
Uses `systemsetup` to disable the Remote Login service, preventing 
SSH connections to the device.

## Why this script exists
Remote Login (SSH) represents an unnecessary attack surface on managed 
endpoints where remote access is handled through a managed RMM tool. 
This script is a companion to the Disable Remote Desktop script — 
together they close both inbound remote access vectors on macOS as 
part of a hardened security baseline.

## Deployment context
Designed to run as part of an automated compliance remediation workflow 
in Addigy. When a device is flagged as non-compliant for having Remote 
Login enabled, the workflow automatically deploys this script to remediate.

## Usage
```bash
sudo bash disable-remote-login.sh
```

## File
[disable-remote-login.sh](./disable-remote-login.sh)