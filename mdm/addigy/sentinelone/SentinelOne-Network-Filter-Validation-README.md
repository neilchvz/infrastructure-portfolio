# SentinelOne - Network Filter Validation

## Overview
A configuration profile that approves SentinelOne's network monitoring 
extension for socket-level traffic inspection on managed macOS devices.

## What this profile configures

- **Network Content Filter** — approves SentinelOne's network monitoring 
  extension (`com.sentinelone.network-monitoring`) via Team ID `4AYE5J54KN`
- **Filter Type** — socket-level filtering enabled, packet filtering disabled
- **Filter Grade** — firewall level, giving SentinelOne visibility into 
  network connections for threat detection

## Why this profile exists
SentinelOne requires explicit MDM approval to load its network monitoring 
extension on macOS. Without this profile the extension is blocked by 
the operating system and SentinelOne loses network visibility — 
reducing its ability to detect and respond to threats.

## Note on profile origin
This profile was published directly by SentinelOne (Sentinel Labs, Inc.) 
and is part of their official macOS deployment documentation. Imported 
and deployed via Addigy.

## Platform
Deployed via **Addigy MDM**. Compatible with any MDM platform that 
supports `com.apple.webcontent-filter`.

## File
[SentinelOne-Network-Filter-Validation.mobileconfig](./SentinelOne-Network-Filter-Validation.mobileconfig)