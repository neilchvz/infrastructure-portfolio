# Windows - Disable Windows Hello

## Overview
An Intune configuration policy that disables Windows Hello for Business 
on managed Windows devices, preventing biometric and PIN-based 
authentication setup.

## What this policy configures

- **Windows Hello for Business** — disabled, preventing users from 
  setting up PIN, fingerprint, or facial recognition as sign-in options

## Why this policy exists
In environments where Windows Hello for Business is not part of the 
approved authentication strategy — typically where Entra ID Conditional 
Access enforces specific MFA methods — disabling Hello prevents 
inconsistent authentication configurations across the fleet.

## Platform
Built for and deployed via **Microsoft Intune**. Account protection 
policy targeting Windows 10 and later.

## File
[Windows-Disable-Windows-Hello.json](./Windows-Disable-Windows-Hello.json)