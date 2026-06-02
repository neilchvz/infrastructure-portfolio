# Windows - OneDrive Base Settings

## Overview
A baseline Intune configuration policy that establishes core OneDrive 
sync client settings on managed Windows devices.

## What this policy configures

- **Allow Tenant List** — restricts OneDrive sync to the organization's 
  Microsoft 365 tenant only, preventing sync with external tenants. 
  Replace `YOUR_TENANT_ID` with your Entra ID tenant ID before deploying.
- **Files On Demand** — enabled, allowing files to be visible in Explorer 
  without being fully downloaded locally
- **Sync Admin Reports** — enabled, sending OneDrive sync health data 
  to the Microsoft 365 admin center

## Why this policy exists
Establishes a consistent, secure OneDrive configuration across all managed 
devices — restricting sync to the corporate tenant, enabling cloud-only 
storage by default, and providing IT visibility into sync health.

## Customization
Replace `YOUR_TENANT_ID` in the JSON with your organization's Entra ID 
tenant ID before importing into Intune.

## Platform
Built for and deployed via **Microsoft Intune**. Settings catalog policy 
targeting Windows 10 and later.

## File
[Windows-OneDrive-Base-Settings.json](./Windows-OneDrive-Base-Settings.json)