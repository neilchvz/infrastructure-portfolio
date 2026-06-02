# Add Staff to lpadmin Group

## Overview
A shell script that adds the default macOS `staff` group to the `_lpadmin` 
group, granting standard (non-admin) users the ability to add and manage 
printers without requiring full local admin rights.

## The problem this solves
In environments following the principle of least privilege, end users run 
as standard accounts. While this reduces risk, it also prevents users from 
installing printers that require drivers or managing their own print queues 
— generating helpdesk tickets for a task that doesn't warrant L1 involvement.

Before this script, every printer request required a technician to manually 
intervene on the device. This script deploys via MDM and eliminates that 
touchpoint entirely.

## What this script does
Adds the `staff` group to the `_lpadmin` group using `dseditgroup`, 
granting printer management rights to all standard users on the device.

## Usage
```bash
sudo bash add-staff-to-lpadmin.sh
```

## Deployment
Designed to be deployed via MDM (Addigy) as a one-time run script 
across the managed macOS fleet.

## File
[add-staff-to-lpadmin.sh](./add-staff-to-lpadmin.sh)