# VPN - Corporate

## Overview
A configuration profile that deploys a corporate VPN connection to managed 
macOS devices silently and consistently via MDM — eliminating manual 
per-device configuration by helpdesk technicians.

## The problem this solves
A mixed Windows and macOS fleet of 100+ devices needed a VPN profile 
rolled out to every endpoint. The existing process required two L1 
technicians to touch each device individually, creating bottlenecks, 
naming inconsistencies, and delays for end users — particularly on macOS 
where one technician had limited experience.

This profile automated the entire macOS side of the rollout, deploying 
a consistent, correctly configured VPN connection to every managed Mac 
simultaneously through Addigy.

## What this profile configures

- **VPN Type** — L2TP over IPSec
- **Authentication** — Shared Secret
- **Server** — configurable via `HOSTNAME_OF_VPN_SERVER`
- **Display Name** — configurable via `DISPLAY_NAME_OF_VPN`
- **Shared Secret** — configurable via `PASSWORD_OF_SSLVPN_CONNECTION`

## Customization
Replace the placeholder values in the profile before deploying:

| Placeholder | Replace With |
|-------------|-------------|
| `HOSTNAME_OF_VPN_SERVER` | Your VPN server hostname or IP |
| `DISPLAY_NAME_OF_VPN` | Name shown to users in Network settings |
| `PASSWORD_OF_SSLVPN_CONNECTION` | Your L2TP shared secret |

## Platform
Built for and deployed via **Addigy MDM**. Standard Apple VPN payload — 
portable to Jamf, Intune, or any MDM platform that supports 
`com.apple.vpn.managed`.

## File
[VPN-Corporate.mobileconfig](./VPN-Corporate.mobileconfig)