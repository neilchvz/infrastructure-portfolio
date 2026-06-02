# Passcode - Inactivity Timer (15 minutes)

## Overview
A lightweight configuration profile that enforces an automatic lock timer 
on managed macOS devices.

## What this profile enforces

- **Inactivity Timer** — device locks automatically after 15 minutes of inactivity

## Why this profile exists
Ensures devices left unattended are locked automatically, reducing the risk 
of unauthorized access. Typically deployed as part of a broader security 
baseline alongside screensaver password enforcement.

## Platform
Built for and deployed via **Addigy MDM**. Standard Apple password policy 
payload — portable to Jamf, Intune, or any MDM platform that supports 
`com.apple.mobiledevice.passwordpolicy`.

## File
[Passcode-Inactivity-Timer-15min.mobileconfig](./Passcode-Inactivity-Timer-15min.mobileconfig)