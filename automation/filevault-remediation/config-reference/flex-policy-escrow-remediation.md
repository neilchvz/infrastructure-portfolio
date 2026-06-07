# Flex Policy: FileVault Key Escrow Remediation

## Purpose

Automatically remediates macOS devices that have FileVault enabled but no
recovery key escrowed to Addigy. This covers devices that were encrypted
before Addigy was enrolled — the most common escrow gap in a managed fleet.

When Addigy enables FileVault itself via MDM profile, it captures and escrows
the recovery key automatically. When FileVault was already enabled before
Addigy enrollment, no key escrow occurs — the device appears encrypted but
IT has no access to the recovery key.

This policy detects that condition continuously and remediates it silently,
without any user-facing prompt.

---

## Flex Policy Filter

| Device Fact | Operator | Value |
|-------------|----------|-------|
| FileVault Enabled | = | True |
| FileVault Key Escrowed | = | False |

Both conditions must be true for a device to be added to this policy.
Devices are automatically removed from the policy once the key is escrowed
and the Device Facts update on next check-in.

This is a continuous policy — not a one-time run. If a device's escrow
status changes (e.g. a key becomes invalid after a major macOS update),
it will re-enter the policy and be remediated again automatically.

---

## Assets Assigned to This Policy

### 1. Smart App — Escrow Buddy

**What it is:**
Escrow Buddy is an open-source macOS authorization plugin developed by
Netflix's Client Systems Engineering team. It integrates with the macOS
login authorization database and silently generates a new FileVault personal
recovery key the next time the user logs in — without displaying any
additional prompts or interrupting the user experience.

> See: [Escrow Buddy on GitHub](https://github.com/macadmins/escrow-buddy)
> See: [Netflix Tech Blog announcement](https://netflixtechblog.com/escrow-buddy-an-open-source-tool-from-netflix-for-remediation-of-missing-filevault-keys-in-mdm-815aef5107cd)

**Install command (runs at deployment):**
```bash
defaults write /Library/Preferences/com.netflix.Escrow-Buddy.plist GenerateNewKey -bool true
```
This command tells Escrow Buddy to generate a new FileVault recovery key
on the next login event. Without this flag set to true, Escrow Buddy
installs but does not trigger key generation.

**Removal command (runs after key is escrowed):**
```
/Library/Security/SecurityAgentPlugins/Escrow Buddy.bundle
```
Once the key has been escrowed and the Device Fact updates, the device
falls out of the flex policy filter. The removal command uninstalls
Escrow Buddy — keeping the device clean and ensuring the tool is only
present when actively needed.

---

### 2. MDM Profile — FDERecoveryKeyEscrow

An MDM configuration profile containing the `FDERecoveryKeyEscrow` payload
is also assigned to this policy. This profile instructs macOS to automatically
escrow any newly generated FileVault recovery key to the MDM server (Addigy).

This is the pairing that makes the workflow complete:
- Escrow Buddy generates the new key at login
- The MDM escrow profile ensures that key is captured by Addigy

Without both components, key generation alone does not result in escrow.

---

## User Experience

Completely silent. The user logs in as normal. Escrow Buddy intercepts
the login event, generates a new recovery key in the background, and
the MDM profile escrows it to Addigy. The user sees nothing.

The device fact updates on next Addigy check-in, the device exits the
flex policy filter, and Escrow Buddy is uninstalled.

---

## Notes

- macOS major version upgrades can reset the authorization database,
  which deactivates Escrow Buddy. The continuous policy filter catches
  this automatically — if escrow status drops to false after an upgrade,
  the device re-enters the policy.
- Escrow Buddy only works with MDM-based escrow. It is not compatible
  with server-based escrow solutions like Crypt Server.
- The `FDERecoveryKeyEscrow` MDM profile must be deployed before or
  alongside Escrow Buddy for escrow to succeed.

---

*Part of the [Automation Portfolio](https://github.com/neilchvz)*
