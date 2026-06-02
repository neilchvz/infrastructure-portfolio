# KEXT - Allow Google Drive

## Overview
A configuration profile that pre-approves the Google Drive kernel extension 
on managed macOS devices, preventing the manual approval prompt that 
appears in System Settings > Privacy & Security.

## The problem this solves
On older macOS versions, installing Google Drive triggers a prompt requiring 
a user or admin to manually approve the kernel extension in Security & Privacy 
settings. In a managed fleet this created a manual touchpoint for every 
deployment — technicians had to physically intervene or walk users through 
approving it themselves.

This profile silently pre-approves the Google Drive kernel extension 
by whitelisting Google's Team Identifier (`EQHXZ8M8AV`), eliminating 
the prompt entirely.

## What this profile configures

- **Allowed Team Identifier** — `EQHXZ8M8AV` (Google LLC)
- **Allow User Overrides** — disabled, users cannot modify this approval

## Important note
Kernel Extensions (KEXT) are a legacy macOS technology. Apple has been 
deprecating KEXT support in favor of System Extensions since macOS Big Sur. 
This profile is maintained for older macOS devices in the fleet that still 
run software requiring kernel extension approval. Modern macOS deployments 
should use PPPC and System Extension profiles instead.

## Platform
Built for and deployed via **Addigy MDM**. Standard Apple kernel extension 
policy payload — portable to Jamf, Intune, or any MDM platform that supports 
`com.apple.syspolicy.kernel-extension-policy`.

## File
[KEXT-Allow-Google-Drive.mobileconfig](./KEXT-Allow-Google-Drive.mobileconfig)