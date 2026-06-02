# SentinelOne - All Approval Settings

## Overview
A comprehensive configuration profile that grants SentinelOne all required 
macOS permissions in a single deployment. Bundles PPPC, network filtering, 
system extension, and notification settings into one profile — ensuring 
SentinelOne operates fully and silently on managed devices without 
user interaction or manual approvals.

## What this profile configures

- **PPPC - Full Disk Access** — grants SentinelOne processes 
  (`sentineld`, `sentineld-helper`, `sentineld-shell`, `sentinel-shell`) 
  full disk access required for endpoint protection
- **Network Content Filter** — approves SentinelOne's network monitoring 
  extension (`com.sentinelone.network-monitoring`) for socket-level 
  traffic inspection
- **System Extension** — pre-approves SentinelOne's system extension 
  via Team ID `4AYE5J54KN`
- **Notifications** — suppresses SentinelOne agent notifications, 
  badges, sounds, and lock screen alerts to prevent end user confusion

## Why this profile exists
SentinelOne requires multiple macOS privacy and security approvals to 
function correctly. Without MDM-pushed approvals, users are prompted 
to manually grant permissions — or worse, SentinelOne runs in a degraded 
state without full visibility. This profile ensures complete, silent 
approval across all required subsystems on every managed device.

## Note on profile origin
This profile is based on SentinelOne's officially recommended macOS 
configuration, commonly distributed across MDM platforms. It was 
imported and deployed via Addigy.

## Platform
Deployed via **Addigy MDM**. Compatible with any MDM platform that 
supports standard Apple configuration profile payloads.

## File
[SentinelOne-All-Approval-Settings.mobileconfig](./SentinelOne-All-Approval-Settings.mobileconfig)