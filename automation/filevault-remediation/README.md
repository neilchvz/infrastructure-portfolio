# FileVault Compliance Automation

## The Problem

FileVault disk encryption is a non-negotiable security baseline across
every managed macOS client fleet. At an MSP managing dozens of client
environments, ensuring every device was encrypted — and that the IT
team had access to every recovery key — was a persistent operational
challenge.

Two distinct failure modes existed:

**1. FileVault not enabled**
The global MDM enrollment profile was designed to enable FileVault on
every enrolled device. It worked most of the time. But edge cases slipped
through — devices enrolled outside the standard workflow, MDM profile
failures, or users with local admin rights who disabled encryption after
the fact. These devices existed in a blind spot: non-compliant and
undetected until someone looked.

**2. FileVault enabled, recovery key not escrowed**
When Addigy enables FileVault itself, it captures and escrows the
recovery key to the device record automatically. When a device arrives
with FileVault already enabled — common with employee-owned machines,
devices migrated from another MDM, or Macs set up before enrollment —
no key escrow occurs. The device appears encrypted and healthy but
IT has no access to the recovery key.

When a user gets locked out of their encrypted Mac, the IT team is
expected to have that key. Saying "we don't have it" is not an option.

The manual remediation for both problems required a technician to
identify the affected device, wait for it to be online, open a live
terminal session, and run the appropriate commands. Across a multi-client
fleet, that process was slow, inconsistent, and dependent on a device
being available at the moment someone thought to check.

---

## The Solution

Two continuous Addigy Flex Policies — one for each failure mode —
that detect non-compliant devices automatically and remediate them
without any technician involvement.

The policies run indefinitely. A device that falls out of compliance
weeks or months after initial enrollment is detected and remediated
on the next Addigy Device Fact evaluation. There is no maintenance
window, no manual audit, and no scheduled task to manage.

---

## Architecture

```
Addigy evaluates Device Facts on every device check-in
                    │
        ┌───────────┴────────────┐
        ▼                        ▼
┌───────────────────┐   ┌────────────────────────┐
│  FV = ON          │   │  FV = OFF              │
│  Key Escrowed=OFF │   │                        │
│                   │   │  Policy 2              │
│  Policy 1         │   │  FileVault Enablement  │
│  Escrow           │   │                        │
│  Remediation      │   │  MDM profile enables   │
│                   │   │  FV + escrows key      │
│  Escrow Buddy     │   │                        │
│  installs +       │   │  Deferred enablement   │
│  rotates key      │   │  logout/login prompt   │
│  silently         │   |  + IT notification     |
│                   │   └──────────┬─────────────┘
│  MDM profile      │              │
│  escrows new key  │              │
│                   │              │
│  Escrow Buddy     │              │
│  uninstalls       │              │
└──────────┬────────┘              │
           │                       │
           ▼                       ▼
  Device Fact updates: FV=ON, Key Escrowed=ON
           │
           ▼
  Device exits flex policy filter automatically
  No technician involvement at any stage
```

---

## Policy 1 — Escrow Remediation

**Filter:** FileVault Enabled = `True` AND FileVault Key Escrowed = `False`

Targets devices that are encrypted but have no recovery key in Addigy.
This is the most common gap in a managed fleet — devices that were
encrypted before MDM enrollment.

**Remediation:**

Deploys [Escrow Buddy](https://github.com/macadmins/escrow-buddy) —
an open-source macOS authorization plugin built by Netflix's Client
Systems Engineering team. Escrow Buddy integrates with the macOS login
authorization database and silently generates a new FileVault recovery
key at the user's next login, without displaying any additional prompts.

A companion MDM profile with the `FDERecoveryKeyEscrow` payload captures
the new key and escrows it to Addigy automatically.

Once complete, Escrow Buddy is uninstalled via the Smart App removal
command. The device exits the policy filter on next check-in.

**User experience:** Silent. Nothing displayed.

> Escrow Buddy was chosen over a custom solution deliberately. It is
> battle-tested, open-source, maintained by Netflix's Mac engineering team,
> and does exactly this job. Building a custom alternative would have been
> redundant. See [`config-reference/escrow-buddy-reference.md`](./config-reference/escrow-buddy-reference.md)
> for full context on the tool selection decision.

---

## Policy 2 — FileVault Enablement

**Filter:** FileVault Enabled = `False`

Targets devices with FileVault completely off — whether due to MDM
profile failure at enrollment or a user disabling it after the fact.

**Remediation:**

A single MDM configuration profile combining FileVault enablement
and `FDERecoveryKeyEscrow` in one payload. FileVault is enabled and
the recovery key is escrowed to Addigy at the same time — no second
step required.

**User experience:** Addigy uses deferred enablement — the MDM profile
installs silently, but encryption doesn't begin until the user performs
a full logout and login. At logout, macOS presents a prompt asking the
user to enter their password to confirm FileVault enablement. A notification
script fires at completion, displaying a branded message from the IT team
explaining what happened and providing helpdesk contact details.

> Note: Restarting does not trigger deferred enablement. The user must
> fully log out. If the user cancels the prompt, they remain in deferred
> enablement and the policy will catch them on the next evaluation cycle.

---

## Why Two Separate Policies

The two failure modes require fundamentally different remediation paths:

| | Policy 1 | Policy 2 |
|---|---|---|
| **Condition** | FV on, key missing | FV off |
| **Tool** | Escrow Buddy + MDM profile | MDM profile only |
| **User experience** | Silent | Deferred enablement — logout/login prompt + branded IT notification |
| **Key rotation** | Yes — new key generated | N/A — new key created at enablement |

Combining them into a single policy would require conditional logic
that neither Addigy's flex policy system nor MDM profiles support cleanly.
Keeping them separate makes each policy's purpose, filter, and behavior
unambiguous.

---

## Continuous Compliance

Both policies run indefinitely — not as a one-time remediation. Addigy
evaluates Device Facts on every device check-in. If a device's compliance
status changes for any reason:

- A major macOS update resets the authorization database, invalidating
  the Escrow Buddy plugin
- A user disables FileVault
- A new device enrolls outside the standard workflow
- A migrated device arrives with FileVault pre-enabled

...it will be detected and remediated automatically on the next evaluation
cycle, without any manual intervention or scheduled audit.

---

## Stack

| Tool | Role |
|------|------|
| **Addigy MDM** | Flex Policy filtering via Device Facts, Smart App deployment, MDM profile delivery |
| **Addigy Device Facts** | Native FileVault status and key escrow status — no custom scripts required |
| **Escrow Buddy (Netflix/macadmins)** | Silent FileVault key rotation at login |
| **MDM Configuration Profile** | FileVault enablement and FDERecoveryKeyEscrow payload |

---

## Repository Structure

```
filevault-compliance-automation/
├── README.md                                        ← this file
└── config-reference/
    ├── flex-policy-escrow-remediation.md            ← Policy 1 configuration reference
    ├── flex-policy-enablement.md                    ← Policy 2 configuration reference
    └── escrow-buddy-reference.md                    ← tool selection rationale + usage
```

---

## Outcome

| Metric | Before | After |
|--------|--------|-------|
| Detection of missing escrow keys | Manual audit — only found when someone looked | Continuous — detected on every device check-in |
| Remediation of missing escrow keys | Technician required, device must be online | Automatic — resolved at next user login |
| Detection of FileVault disabled | Manual audit | Continuous — detected on every device check-in |
| Remediation of FileVault disabled | Manual MDM push or terminal session | Automatic — MDM profile deployed by flex policy |
| Ongoing maintenance required | Yes — recurring manual checks | None |

---

*Part of the [Automation Portfolio](https://github.com/neilchvz) · Neil Chavez · Creator of things.*
