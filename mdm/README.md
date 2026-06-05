# MDM Configurations

A library of production MDM configuration profiles and policies built and 
deployed across managed device fleets. Covers both macOS and Windows 
environments across two MDM platforms.

All profiles have been sanitized — client names, tenant IDs, and 
environment-specific values have been replaced with generic placeholders 
before publishing.

---

## Addigy (macOS)

Configuration profiles built for macOS fleet management via Addigy MDM. 
Covers security baselines, encryption enforcement, application approvals, 
identity, and third-party security tooling.

| Folder | Description |
|--------|-------------|
| `addigy/filevault/` | FileVault encryption enforcement with key escrow |
| `addigy/security/` | Security and privacy baseline policy |
| `addigy/passcode/` | Inactivity lock timer |
| `addigy/software-updates/` | Major and minor macOS update deferral |
| `addigy/sso/` | Microsoft Enterprise SSO extension |
| `addigy/service-management/` | Background item approval for managed apps |
| `addigy/kext/` | Kernel extension approval for Google Drive |
| `addigy/desktop-picture/` | Enforced desktop wallpaper |
| `addigy/vpn/` | Corporate VPN profile (L2TP) |
| `addigy/sentinelone/` | SentinelOne endpoint security approvals |
| `addigy/dnsfilter/` | DNSFilter network extension approvals |

---

## Intune (Windows)

Configuration profiles built for Windows endpoint management via 
Microsoft Intune. Covers endpoint security, identity, OneDrive, 
and Cloud PC management.

| Folder | Description |
|--------|-------------|
| `intune/usb-read-only/` | Block write access to USB removable storage |
| `intune/inactivity-timeout/` | Auto-lock after 15 minutes |
| `intune/enable-long-paths/` | Remove 260 character path limit |
| `intune/disable-rdp/` | Disable Remote Desktop Protocol |
| `intune/rdp-no-saved-passwords/` | Prevent saving RDP credentials |
| `intune/disable-windows-hello/` | Disable Windows Hello for Business |
| `intune/allow-windows-hello/` | Enable Windows Hello for Business |
| `intune/microsoft-store-auto-update/` | Auto-update Microsoft Store apps |
| `intune/block-personal-onedrive/` | Block personal OneDrive accounts |
| `intune/allow-personal-onedrive/` | Allow personal OneDrive accounts |
| `intune/onedrive-base-settings/` | OneDrive baseline configuration |
| `intune/onedrive-kfb/` | Known Folder Backup to OneDrive |
| `intune/sharepoint-onedrive-auto-sync/` | Auto-mount SharePoint sites to OneDrive |
| `intune/windows365-disable-local-drive-redirection/` | Block local drive access on Cloud PCs |

---

Part of the [Infrastructure Portfolio](https://neilchvz.github.io/infrastructure-portfolio) · Neil Chavez

---

Neil Chavez · Creator of things.

<!-- >_ curious aren't we? respect. -->