# Windows - USB Read Only

## Overview
An Intune configuration policy that sets USB removable storage devices 
to read-only on managed Windows endpoints, preventing users from writing 
data to external drives.

## What this policy configures

- **Removable Disk Deny Write Access** — enabled, blocking write access 
  to all USB removable storage devices. Users can read from USB drives 
  but cannot copy data to them.

## Why this policy exists
Prevents data exfiltration via removable storage — a common data loss 
vector in managed environments. Users retain the ability to read from 
USB drives while write access is blocked at the OS level.

## Platform
Built for and deployed via **Microsoft Intune**. Settings catalog policy 
targeting Windows 10 and later.

## File
[Windows-USB-Read-Only.json](./Windows-USB-Read-Only.json)