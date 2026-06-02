# Windows - OneDrive Known Folder Backup (KFB)

## Overview
An Intune configuration policy that silently redirects Windows known 
folders — Desktop, Documents, and Pictures — to OneDrive on managed 
devices, ensuring automatic cloud backup of user files.

## What this policy configures

- **KFM Opt-in with Wizard** — prompts users to move known folders 
  to OneDrive with a guided wizard experience
- **KFM Silent Opt-in** — silently redirects known folders to OneDrive 
  without user interaction, with no option to opt out

## Why this policy exists
Ensures critical user files are automatically backed up to OneDrive 
without requiring user action. Eliminates data loss risk from device 
failure, theft, or replacement — IT can restore a user's Desktop, 
Documents, and Pictures instantly from OneDrive on a new device.

## Customization
Replace `YOUR_TENANT_ID` in the JSON with your organization's Entra ID 
tenant ID before importing into Intune.

## Platform
Built for and deployed via **Microsoft Intune**. Settings catalog policy 
targeting Windows 10 and later.

## File
[Windows-OneDrive-KFB.json](./Windows-OneDrive-KFB.json)