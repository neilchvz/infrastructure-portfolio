# Windows - Disable RDP

## Overview
An Intune configuration policy that disables Remote Desktop Protocol 
on managed Windows endpoints, preventing inbound remote desktop connections.

## What this policy configures

- **Remote Desktop** — disabled, blocking all inbound RDP connections 
  to managed devices

## Why this policy exists
RDP is a common attack vector for lateral movement and ransomware. 
Disabling it on endpoints that don't require remote desktop access 
reduces the attack surface. Remote administration is handled through 
managed tooling instead.

## Platform
Built for and deployed via **Microsoft Intune**. Settings catalog policy 
targeting Windows 10 and later.

## File
[Windows-Disable-RDP.json](./Windows-Disable-RDP.json)