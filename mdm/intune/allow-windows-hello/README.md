# Windows - Allow Windows Hello

## Overview
An Intune configuration policy that enables Windows Hello for Business 
on managed Windows devices, allowing biometric and PIN-based authentication.

## What this policy configures

- **Windows Hello for Business** — enabled, allowing users to set up 
  PIN, fingerprint, or facial recognition as sign-in options

## Why this policy exists
Companion policy to the Disable Windows Hello profile. Deployed to 
device groups where Windows Hello is part of the approved authentication 
strategy, enabling a passwordless or MFA-compliant sign-in experience.

## Platform
Built for and deployed via **Microsoft Intune**. Settings catalog policy 
targeting Windows 10 and later.

## File
[Windows-Allow-Windows-Hello.json](./Windows-Allow-Windows-Hello.json)