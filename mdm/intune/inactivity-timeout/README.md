# Windows - Inactivity Timeout (15 minutes)

## Overview
An Intune configuration policy that locks managed Windows devices 
automatically after 15 minutes of inactivity.

## What this policy configures

- **Inactivity Timeout** — device locks automatically after 15 minutes 
  of inactivity

## Why this policy exists
Ensures unattended devices are locked automatically, reducing the risk 
of unauthorized access. Part of a broader security baseline alongside 
BitLocker and Conditional Access policies.

## Platform
Built for and deployed via **Microsoft Intune**. Settings catalog policy 
targeting Windows 10 and later.

## File
[Windows-Inactivity-Timeout-15min.json](./Windows-Inactivity-Timeout-15min.json)