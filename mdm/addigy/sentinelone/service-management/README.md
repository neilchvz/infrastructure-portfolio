# SentinelOne - Service Management

## Overview
A configuration profile that locks SentinelOne's background services 
in place on managed macOS devices, preventing users from removing 
or disabling SentinelOne Launch Agents and Launch Daemons.

## What this profile configures

- **Label Prefix Rule** — protects all SentinelOne services matching 
  `com.sentinelone.*` from user removal
- **Bundle Identifier Prefix Rule** — protects all SentinelOne bundles 
  matching `com.sentinelone.*` from user removal

## Why this profile exists
Without this profile a user or local admin could remove SentinelOne's 
background services, effectively disabling endpoint protection without 
IT's knowledge. This profile ensures SentinelOne remains running and 
tamper-resistant on every managed device.

## Note on profile origin
Published by SentinelOne (Sentinel Labs, Inc.) as part of their official 
macOS deployment documentation. Imported and deployed via Addigy.

## Platform
Deployed via **Addigy MDM**. Compatible with any MDM platform that 
supports `com.apple.servicemanagement`.

## File
[SentinelOne-Service-Management.mobileconfig](./SentinelOne-Service-Management.mobileconfig)