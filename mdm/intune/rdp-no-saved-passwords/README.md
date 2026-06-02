# Windows - Don't Allow Passwords to be Saved for RDP Connections

## Overview
An Intune configuration policy that prevents users from saving passwords 
in Remote Desktop Connection on managed Windows devices.

## What this policy configures

- **Do Not Allow Passwords to be Saved** — prevents the Remote Desktop 
  client from saving credentials locally for RDP connections

## Why this policy exists
Saved RDP credentials stored locally represent a credential theft risk. 
If a device is compromised, saved passwords can be extracted and used 
for lateral movement. This policy forces users to authenticate manually 
for every RDP session.

## Platform
Built for and deployed via **Microsoft Intune**. Settings catalog policy 
targeting Windows 10 and later.

## File
[Windows-RDP-No-Saved-Passwords.json](./Windows-RDP-No-Saved-Passwords.json)