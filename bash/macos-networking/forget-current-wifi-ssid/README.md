# Forget Current WiFi SSID

## Overview
A shell script that detects the currently connected WiFi network, 
removes it from the device's preferred networks list, and cycles 
the WiFi interface — forcing the device to forget the network 
and reconnect fresh.

## What this script does
- Detects the current SSID using the `airport` utility
- Removes it from preferred wireless networks via `networksetup`
- Disables and re-enables the WiFi interface to force a clean state
- Clears the SSID variable on exit

## Why this script exists
Originally deployed during a client migration to certificate-based 
WiFi authentication. Stragglers who had the old SSID saved kept 
connecting to the legacy network instead of the new secured one. 
This script was deployed via MDM to silently remove the old network 
and force devices onto the correct one.

Has since become a general purpose utility — useful any time a user 
needs their saved network cleared without navigating through System 
Settings themselves.

## Deployment context
Deployed via Addigy as a one-time run script targeting specific 
devices or user groups. Also useful as an on-demand script run 
through a remote terminal session.

## Usage
```bash
sudo bash forget-current-wifi-ssid.sh
```

## Note
This script targets the `en0` interface — the default WiFi adapter 
on most Macs. Verify the interface name on the target device if 
results are unexpected.

## File
[forget-current-wifi-ssid.sh](./forget-current-wifi-ssid.sh)