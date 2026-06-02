# Security And Privacy - Global Policy

## Overview
A baseline security and privacy configuration profile for managed macOS devices. 
This profile enforces baseline security settings across multiple macOS 
subsystems in a single deployment.

## What this profile enforces

- **Gatekeeper** — enabled, allowing apps downloaded from the Mac App Store 
  and identified developers. Blocks unverified software from running.
- **Firewall** — enabled to block unauthorized incoming connections
- **Screensaver Password** — password required 5 seconds after sleep 
  or screensaver begins
- **Lock Message** — users are permitted to set a custom lock screen message
- **Password Reset** — users are permitted to change their own password
- **Diagnostic Data** — automatic submission of diagnostics to Apple is disabled

## Why this profile exists
Rather than deploying separate profiles for each security subsystem, this profile 
bundles baseline macOS security settings into a single deployable policy. 
It establishes a security baseline across every managed device.

## Platform
Built for and deployed via **Addigy MDM**. Settings are standard Apple 
configuration profile payloads and are portable to other MDM platforms 
such as Jamf or Intune with minor adjustments.

## File
[Security-And-Privacy-Global-Policy.mobileconfig](./Security-And-Privacy-Global-Policy.mobileconfig)