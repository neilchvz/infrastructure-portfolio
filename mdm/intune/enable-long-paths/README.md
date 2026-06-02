# Windows - Enable Long Paths

## Overview
An Intune configuration policy that enables Win32 long path support 
on managed Windows devices, removing the 260 character path length 
limitation.

## What this policy configures

- **Enable Win32 Long Paths** — removes the default 260 character 
  file path limit, allowing applications and users to work with 
  deeply nested folder structures

## Why this policy exists
The default 260 character path limit causes errors in certain development 
workflows, file migrations, and applications that use deeply nested 
folder structures. Enabling long paths prevents these errors across 
managed endpoints.

## Platform
Built for and deployed via **Microsoft Intune**. Settings catalog policy 
targeting Windows 10 and later.

## File
[Windows-Enable-Long-Paths.json](./Windows-Enable-Long-Paths.json)