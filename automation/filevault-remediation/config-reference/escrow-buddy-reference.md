# Escrow Buddy — Tool Reference

## What It Is

Escrow Buddy is an open-source macOS authorization plugin developed by
the Client Systems Engineering team at Netflix. It is purpose-built for
one problem: generating and escrowing new FileVault personal recovery
keys on Macs that lack a valid escrowed key in MDM.

> **GitHub:** [github.com/macadmins/escrow-buddy](https://github.com/macadmins/escrow-buddy)
> **Netflix Tech Blog:** [Read the announcement](https://netflixtechblog.com/escrow-buddy-an-open-source-tool-from-netflix-for-remediation-of-missing-filevault-keys-in-mdm-815aef5107cd)

Escrow Buddy is maintained under the Mac Admins Open Source organization
on GitHub — the same community home as Nudge, Munki, and other widely
adopted Mac management tools. It is licensed under Apache 2.0.

---

## Why It Was Chosen

The alternative to Escrow Buddy is a manual process: a technician
identifies a device with a missing escrow key, waits for the machine
to be online, opens a live terminal session, and runs the key rotation
and escrow commands manually.

At scale across multiple client fleets, that process is:
- Time-consuming
- Dependent on device availability
- Easy to miss when new devices are enrolled or existing keys become invalid

Escrow Buddy eliminates all of that. It integrates with the macOS login
authorization database and handles key generation silently at the next
login — no technician involvement, no user disruption, no waiting for
a live terminal window.

The decision to use Escrow Buddy rather than writing a custom solution
was deliberate. Escrow Buddy is battle-tested, open-source, and
maintained by a team at Netflix running one of the largest managed Mac
fleets in the world. Building a custom alternative would have been
redundant and introduced unnecessary maintenance overhead.

---

## How It Works

Escrow Buddy operates as a macOS authorization plugin — a mechanism
that allows software to intercept and extend the macOS login flow.

When installed and configured, Escrow Buddy:

1. Waits for the next user login event
2. Uses the logging-in user's credentials as input to `fdesetup`
3. Generates a new FileVault personal recovery key silently
4. The MDM escrow profile (`FDERecoveryKeyEscrow`) captures the new
   key and sends it to the MDM server automatically

The user experiences a normal login. Nothing additional is displayed.

---

## Key Commands

**Trigger key generation (run via MDM before or at install):**
```bash
defaults write /Library/Preferences/com.netflix.Escrow-Buddy.plist GenerateNewKey -bool true
```
This sets the flag that tells Escrow Buddy to generate a new key at
the next login. Without this flag, Escrow Buddy installs but remains
inactive.

**Removal path (used in Smart App removal command):**
```
/Library/Security/SecurityAgentPlugins/Escrow Buddy.bundle
```

---

## Dependency

Escrow Buddy requires an MDM configuration profile with the
`FDERecoveryKeyEscrow` payload deployed to the target device.
This profile is what routes the newly generated key to the MDM server.

Escrow Buddy generates the key. The MDM profile escrows it.
Both must be present for the workflow to succeed.

---

## Important Notes

- Escrow Buddy only works with MDM-based escrow — not with server-based
  solutions like Crypt Server or Cauliflower Vest.
- macOS major version upgrades can reset the authorization database,
  deactivating Escrow Buddy. The continuous Flex Policy filter catches
  this — devices with a missing escrow key after an upgrade will
  re-enter the policy and be remediated again.
- Escrow Buddy is codesigned and notarized by Apple. New releases are
  built automatically via GitHub Actions when changes are merged.

---

*Part of the [Automation Portfolio](https://github.com/neilchvz)*
