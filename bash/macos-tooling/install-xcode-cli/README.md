# Install Xcode CLI Tools

## Overview
A shell script that checks for and installs the Xcode Command Line Tools 
on macOS devices, handling both modern and legacy macOS versions.

## What this script does
- Checks if Xcode CLI tools are already installed via `xcrun`
- If already installed, exits cleanly with no action taken
- If not installed, detects the macOS build version to determine 
  the correct installation approach
- For Catalina and newer — fetches the latest non-beta CLI tools 
  from `softwareupdate`
- For Mojave and older — uses a legacy `softwareupdate` label format
- Installs the latest available version silently
- Cleans up temporary files on completion

## Why this script exists
Built for a SaaS development client whose engineers needed Xcode CLI 
tools as a prerequisite for development workflows. Since the developers 
were local admins they ended up handling it themselves — but the script 
remains a solid reference for automated Xcode CLI installation across 
a managed fleet.

## Bug fix note
The original script was missing the function definition wrapper causing 
it to fail at runtime, and contained a typo (`/ussr/bin/sed`) on the 
Mojave branch. Both have been corrected in this version.

## Usage
```bash
sudo bash install-xcode-cli.sh
```

## File
[install-xcode-cli.sh](./install-xcode-cli.sh)