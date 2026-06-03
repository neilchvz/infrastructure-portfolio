# Allow Non-Admin Users to Manage WiFi Configuration

## Overview
A shell script that grants standard (non-admin) macOS users the ability 
to manage their own WiFi configuration — including forgetting networks, 
changing DNS settings, and modifying network preferences — without 
requiring admin credentials or L1 technician involvement.

## What this script does
- Grants authorization for non-admin users to modify network preferences 
  via the macOS security authorization database
- Disables the admin requirement for WiFi network changes and IBSS 
  configurations via `airportd`

## Why this script exists
This script solved two problems at once:

**Problem 1 — End user WiFi management**
Standard users working remotely frequently needed help forgetting saved 
networks — a simple task that was generating L1 tickets and consuming 
30-minute time slots. This script empowers users to manage their own 
WiFi without calling the helpdesk.

**Problem 2 — DNS hygiene**
L1 technicians occasionally changed DNS settings to public resolvers 
during troubleshooting and forgot to revert them. This script gives 
technically capable end users the ability to update their own DNS 
back to DHCP — without waiting on IT to fix what IT broke.

## Deployment context
Deployed via Addigy as a one-time run script across standard user 
devices. Pairs well with the Forget Current WiFi SSID script for 
environments where end user self-service is preferred over helpdesk 
dependency.

## Usage
```bash
sudo bash allow-non-admin-wifi-management.sh
```

## File
[allow-non-admin-wifi-management.sh](./allow-non-admin-wifi-management.sh)