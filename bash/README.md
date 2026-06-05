# Bash Scripts

A library of macOS shell scripts built for real-world fleet management and deployed
in production via Addigy MDM and RMM tooling. Scripts are intentionally concise — these 
are operational utilities designed for reliability and fast deployment, not frameworks.
Covers security hardening, network management, user administration, and system tooling 
across managed macOS device fleets.

---

## macos-security

Scripts for security baseline enforcement and compliance remediation.

| Folder | Description |
|--------|-------------|
| `macos-security/filevault-securetoken-status/` | Check SecureToken status for all local users |
| `macos-security/disable-remote-desktop/` | Disable Apple Remote Desktop (ARD) |
| `macos-security/disable-remote-login/` | Disable SSH Remote Login |
| `macos-security/enable-firewall/` | Enable macOS application firewall |
| `macos-security/enable-gatekeeper/` | Enable Gatekeeper app verification |

---

## macos-networking

Scripts for network configuration and troubleshooting.

| Folder | Description |
|--------|-------------|
| `macos-networking/forget-current-wifi-ssid/` | Forget the currently connected WiFi network |
| `macos-networking/allow-non-admin-wifi-management/` | Grant standard users WiFi configuration rights |
| `macos-networking/connect-to-server/` | GUI-prompted remote server connection |
| `macos-networking/flush-dns/` | Flush macOS DNS cache |

---

## macos-user-management

Scripts for user account and permissions management.

| Folder | Description |
|--------|-------------|
| `macos-user-management/grant-admin-rights/` | Elevate current user to local administrator |
| `macos-printing/add-staff-to-lpadmin/` | Grant standard users printer management rights |

---

## macos-tooling

Scripts for software installation and system tooling.

| Folder | Description |
|--------|-------------|
| `macos-tooling/install-speedtest-cli/` | Install Ookla Speedtest CLI |
| `macos-tooling/install-xcode-cli/` | Install Xcode Command Line Tools |

----

Part of the [Infrastructure Portfolio](https://neilchvz.github.io/infrastructure-portfolio) · Neil Chavez

---

Neil Chavez · Creator of things.

<!-- >_ curious aren't we? respect. -->