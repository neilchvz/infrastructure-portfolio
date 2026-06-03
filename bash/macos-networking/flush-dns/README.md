# Flush DNS Cache

## Overview
A shell script that flushes the DNS cache on macOS devices, clearing 
stale or incorrect DNS records that may be causing network connectivity 
or name resolution issues.

## What this script does
- Sends a HUP signal to `mDNSResponder` to restart the DNS responder 
  service
- Flushes the local DNS cache via `dscacheutil`

## Why this script exists
A go-to network troubleshooting tool for L1.5 and L2 technicians. 
When users experience issues reaching internal resources, websites, 
or services — particularly after DNS changes, VPN connections, or 
network migrations — flushing the DNS cache is a fast first step 
that resolves a surprising number of issues without further escalation.

## Deployment context
Run on-demand via Addigy or RMM through a remote terminal session. 
No MDM deployment needed — this is a technician tool, not a fleet 
policy.

## Usage
```bash
sudo bash flush-dns.sh
```

## File
[flush-dns.sh](./flush-dns.sh)