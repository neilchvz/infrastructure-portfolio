# Delay Major macOS Software Updates

## Overview
A configuration profile that defers macOS software update visibility 
on managed devices, giving IT teams time to validate updates before 
they reach end users.

## What this profile enforces

- **Major macOS update delay** — defers visibility of major macOS releases 
  by 45 days
- **Minor macOS update delay** — defers visibility of minor macOS updates 
  by 45 days
- Both major and minor update delays are enforced — users cannot see or 
  install updates until the deferral period has passed

## Why this profile exists
Prevents users from immediately upgrading to a new macOS version before 
IT has validated compatibility with managed software, security tools, 
and MDM profiles. 45 days provides enough runway to test and prepare 
a controlled rollout.

## Platform
Built for and deployed via **Addigy MDM**. Standard Apple restrictions 
payload — portable to Jamf, Intune, or any MDM platform that supports 
`com.apple.applicationaccess`.

## File
[Delay-Major-macOS-Updates.mobileconfig](./Delay-Major-macOS-Updates.mobileconfig)