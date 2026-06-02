# Restrictions - Set Desktop Picture

## Overview
A configuration profile that enforces a standardized desktop wallpaper 
on managed macOS devices. Built to achieve wallpaper consistency across 
a mixed Windows and macOS fleet, mirroring an existing Windows Group 
Policy Object (GPO).

## What this profile configures

- **Desktop Picture** — forces the wallpaper to a centrally managed image 
  stored at `/Library/Addigy/Screensaver.png`
- The image is deployed separately via Addigy and the profile locks 
  it in place

## Why this profile exists
In environments running both Windows and macOS, consistency matters — 
for branding, compliance, and standardization. This profile replicates 
the same wallpaper enforcement that Group Policy handles on the 
Windows side, ensuring macOS devices are treated as first class 
managed endpoints.

## Platform
Built for and deployed via **Addigy MDM**. The image path references 
the Addigy agent directory — if deploying on Jamf or Intune, update 
the `override-picture-path` to match the image deployment path 
used by that platform.

## File
[Restrictions-Set-Desktop-Picture.mobileconfig](./Restrictions-Set-Desktop-Picture.mobileconfig)