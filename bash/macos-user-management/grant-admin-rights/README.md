# Grant Admin Rights to Current User

## Overview
A shell script that elevates the currently logged-in user to local 
administrator on a macOS device.

## What this script does
Adds the current console user to the local `admin` group using `dscl`, 
granting full local administrator privileges without requiring a manual 
account modification in System Settings.

## Why this script exists
In environments following the principle of least privilege, all users 
run as standard accounts by default. Occasionally a C-level executive 
or highly technical user requires local admin access — typically backed 
by a signed waiver acknowledging the associated risk.

Rather than walking a technician through System Settings or scheduling 
a device session, a L1 tech can deploy this script remotely in under 
a minute via MDM or RMM, granting admin rights instantly without 
touching the device.

## Deployment context
Run on-demand via Addigy or RMM as a targeted script on specific devices. 
Not deployed fleet-wide — intended for individual use cases only.

## Usage
```bash
sudo bash grant-admin-rights.sh
```

## Note
Always ensure a signed waiver or documented approval exists before 
granting local admin rights. Admin access on a standard user fleet 
represents an elevated security risk.

## File
[grant-admin-rights.sh](./grant-admin-rights.sh)