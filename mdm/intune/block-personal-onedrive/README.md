# Windows - Block Personal OneDrive Accounts

## Overview
An Intune configuration policy that prevents users from signing into 
personal Microsoft OneDrive accounts on managed Windows devices.

## What this policy configures

- **Disable Personal OneDrive Sync** — blocks users from connecting 
  personal Microsoft accounts to OneDrive on managed devices

## Why this policy exists
Prevents data exfiltration through personal cloud storage. Users cannot 
sync corporate files to a personal OneDrive account, ensuring data 
stays within the organization's controlled environment.

## Platform
Built for and deployed via **Microsoft Intune**. Settings catalog policy 
targeting Windows 10 and later.

## File
[Windows-Block-Personal-OneDrive.json](./Windows-Block-Personal-OneDrive.json)