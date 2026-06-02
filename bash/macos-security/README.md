# Check FileVault SecureToken Status

## Overview
A diagnostic shell script that checks SecureToken status for all local 
user accounts on a macOS device. Identifies which users have the ability 
to unlock FileVault-encrypted drives.

## What is SecureToken?
SecureToken is a cryptographic credential assigned to macOS user accounts 
that grants them the ability to unlock FileVault-encrypted volumes. Not 
all users on a device automatically receive a SecureToken — understanding 
which accounts have it is critical for FileVault key management.

## What this script does
Iterates through all local user accounts with a UID of 500 or above 
(standard and admin users, excluding system accounts) and reports the 
SecureToken status for each using `sysadminctl`.

## When to use this
- Before rotating or re-escrowing a FileVault recovery key — you need 
  to know which user account has SecureToken to perform the operation
- During audits to verify SecureToken is assigned to the correct accounts
- When troubleshooting FileVault unlock issues on a device

## Usage
```bash
sudo bash check-filevault-securetoken-status.sh
```

## Deployment
Run on-demand via MDM (Addigy) or directly in terminal on the target device.

## File
[check-filevault-securetoken-status.sh](./check-filevault-securetoken-status.sh)