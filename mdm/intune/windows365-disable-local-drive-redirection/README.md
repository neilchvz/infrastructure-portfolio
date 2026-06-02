# Windows 365 Cloud PCs - Disable Local Drive Redirection

## Overview
An Intune configuration policy that disables local drive redirection 
on Windows 365 Cloud PCs, preventing users from accessing their 
physical local drives from within the Cloud PC session.

## What this policy configures

- **Local Drive Redirection** — disabled, blocking access to the 
  user's physical local drives from within the Windows 365 Cloud PC

## Why this policy exists
In Cloud PC environments, allowing local drive redirection creates a 
data transfer path between the managed Cloud PC and the user's 
unmanaged physical device. Disabling redirection keeps corporate 
data within the Cloud PC boundary and prevents unauthorized data 
movement to personal devices.

## Platform
Built for and deployed via **Microsoft Intune**. Settings catalog policy 
targeting Windows 10 and later — scoped to Windows 365 Cloud PC devices.

## File
[Windows365-Disable-Local-Drive-Redirection.json](./Windows365-Disable-Local-Drive-Redirection.json)