# Windows - Allow Personal OneDrive Accounts

## Overview
An Intune configuration policy that permits users to sign into personal 
Microsoft OneDrive accounts on managed Windows devices.

## What this policy configures

- **Personal OneDrive Sync** — allowed, permitting users to connect 
  personal Microsoft accounts to OneDrive on managed devices

## Why this policy exists
Companion policy to the Block Personal OneDrive profile. Deployed to 
device groups or environments where personal OneDrive access is 
permitted by policy — for example, BYOD scenarios or organizations 
that allow personal cloud storage use.

## Platform
Built for and deployed via **Microsoft Intune**. Settings catalog policy 
targeting Windows 10 and later.

## File
[Windows-Allow-Personal-OneDrive.json](./Windows-Allow-Personal-OneDrive.json)