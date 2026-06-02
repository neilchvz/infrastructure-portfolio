# Windows - SharePoint Site OneDrive Auto-Sync

## Overview
An Intune configuration policy that automatically mounts SharePoint 
document libraries to OneDrive on managed Windows devices, making 
SharePoint sites accessible directly from File Explorer without 
user action.

## What this policy configures

- **Auto-mount Team Sites** — automatically syncs specified SharePoint 
  document libraries to OneDrive at sign-in
- Multiple department sites can be configured — each entry maps a 
  display name to a SharePoint site URL and identifier string

## Why this policy exists
Eliminates the manual step of users navigating to SharePoint in a browser 
and clicking "Sync" for each document library. Shared drives appear 
automatically in File Explorer on every managed device, giving users 
seamless access to team files from day one.

## Customization
Before importing, replace the placeholder values in the JSON:

| Placeholder | Replace With |
|-------------|-------------|
| `YOUR_TENANT_ID` | Your Entra ID tenant ID |
| `yourcompany.sharepoint.com` | Your SharePoint domain |
| `Department Site 1-7` | Your actual site display names |
| Site and Web IDs | Your actual SharePoint site identifiers |

## Platform
Built for and deployed via **Microsoft Intune**. Settings catalog policy 
targeting Windows 10 and later.

## File
[Windows-SharePoint-OneDrive-Auto-Sync.json](./Windows-SharePoint-OneDrive-Auto-Sync.json)