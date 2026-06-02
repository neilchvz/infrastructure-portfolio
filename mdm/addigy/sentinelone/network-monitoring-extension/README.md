# SentinelOne - Network Monitoring Extension

## Overview
A configuration profile that pre-approves SentinelOne's network monitoring 
system extension on managed macOS devices.

## What this profile configures

- **System Extension Approval** — approves `com.sentinelone.network-monitoring` 
  via Team ID `4AYE5J54KN`
- **User Overrides** — permitted, users can view but not remove the extension

## Why this profile exists
macOS requires explicit MDM approval for system extensions before they 
can load. Without this profile SentinelOne's network monitoring extension 
is blocked at the OS level, preventing it from inspecting network traffic 
for threat detection.

## Note on profile origin
Published by SentinelOne (Sentinel Labs, Inc.) as part of their official 
macOS deployment documentation. Imported and deployed via Addigy.

## Platform
Deployed via **Addigy MDM**. Compatible with any MDM platform that 
supports `com.apple.system-extension-policy`.

## File
[SentinelOne-Network-Monitoring-Extension.mobileconfig](./SentinelOne-Network-Monitoring-Extension.mobileconfig)