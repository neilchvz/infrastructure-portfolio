# Service Management - Approve Background Items

## Overview
A configuration profile that silently pre-approves background services 
for managed applications on macOS. Eliminates the "Background Item Added" 
notification that appears when managed software installs a background 
service — reducing end user confusion and helpdesk noise.

## The problem this solves
Starting with macOS Ventura, Apple introduced user-facing notifications 
whenever an app installed a background service. In a managed environment 
this creates unnecessary helpdesk tickets from users who see the popup 
and suspect malware. This profile suppresses those notifications by 
pre-approving known managed software.

## Approved applications

| Application | Identifier Type |
|-------------|----------------|
| SentinelOne | Bundle ID + Team ID |
| DNSFilter | Bundle ID + Team ID |
| ScreenConnect | Team ID |
| Microsoft OneDrive | Team ID |
| Addigy | Team ID |
| Zoom | Team ID |
| Egnyte | Team ID |
| ConnectWise Automate | Team ID |

## Platform
Built for and deployed via **Addigy MDM**. Standard Apple service 
management payload — portable to Jamf, Intune, or any MDM platform 
that supports `com.apple.servicemanagement`. Team identifiers and 
bundle IDs are vendor-issued and remain consistent across MDM platforms.

## File
[Service-Management-Approve-Background-Items.mobileconfig](./Service-Management-Approve-Background-Items.mobileconfig)