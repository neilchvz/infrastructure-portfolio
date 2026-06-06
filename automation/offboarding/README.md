# M365 User Offboarding Automation

## The Problem

At a busy MSP managing multiple Microsoft 365 clients, user offboarding was a fully manual process handled by L1 technicians. On average, a complete offboard took **1 to 1.5 hours per user** — and that was on a good day.

The real issues were:

- **Every client was different.** Some ran cloud-only Entra ID environments. Others ran hybrid setups with on-prem Active Directory synced to Entra. L1 techs had to know which client was which before touching anything, and mistakes happened.
- **No standardization.** There was no checklist enforced at the tooling level. Steps got missed — licenses left assigned, shared mailboxes not hidden from the GAL, sessions not revoked, OneDrive files inaccessible after the account was gone.
- **L2 engineers were doing L1 work.** Because offboards touched Exchange Online, Entra ID, on-prem AD, SharePoint, and licensing — all in one ticket — L1s would frequently escalate or ask for help. L2 time was being burned on repetitive, low-complexity work that should never have reached them.
- **Audit trail was inconsistent.** What got removed, what licenses were assigned, who got mailbox access — this was documented manually and inconsistently, or not at all.

The goal was to eliminate all of that. Give L1 a single script. Let them answer prompts. Have the script handle everything else and produce a clean audit-ready output they can paste directly into the ticket.

---

## The Solution

`Invoke-UserOffboard.ps1` is an interactive PowerShell script that guides an L1 technician through a complete M365 offboard via step-by-step prompts. It handles both **hybrid** and **cloud-only** environments, detects which it is dealing with, and executes the appropriate steps automatically.

The technician answers questions. The script does the work.

### What It Automates

| Area | Actions |
|------|---------|
| **Authentication** | OAuth interactive login scoped to the target client tenant |
| **Environment Detection** | Prompts for hybrid vs cloud-only; tests domain controller reachability if hybrid |
| **Audit Snapshot** | Captures all group memberships, assigned licenses, manager, title, and department before any changes |
| **Account Disable** | Disables on-prem AD account (hybrid) and/or Entra ID account |
| **Password Reset** | Generates and sets a random 16-character complex password |
| **Session Revocation** | Immediately revokes all active sign-in sessions |
| **Group Removal** | Removes user from all Entra ID / AD security and M365 groups |
| **Mailbox Conversion** | Converts user mailbox to Shared Mailbox (optional) |
| **GAL Visibility** | Hides shared mailbox from the Global Address List automatically |
| **Litigation Hold** | Enables litigation hold on the shared mailbox if required |
| **Mailbox Access** | Grants Full Access and Send As to specified recipients |
| **Mail Forwarding** | Sets SMTP forwarding to a specified address if required |
| **OneDrive Access** | Grants Site Owner access to the user's OneDrive; outputs direct admin link |
| **License Removal** | Strips all assigned M365 licenses — runs **last** to avoid breaking mailbox conversion and OneDrive access steps |
| **Audit Output** | Produces a structured summary of all actions taken, suitable for pasting into a ticket note |

---

## Architecture

```
L1 Technician runs script
        │
        ▼
┌─────────────────────┐
│  OAuth Login        │  ← Scoped to target tenant via interactive browser prompt
│  (Microsoft Graph + │
│  Exchange Online)   │
└────────┬────────────┘
         │
         ▼
┌─────────────────────┐
│  Environment Check  │  ← Hybrid or Cloud-Only?
│                     │  ← If Hybrid: test DC reachability, exit if unreachable
└────────┬────────────┘
         │
         ▼
┌─────────────────────┐
│  User Lookup +      │  ← Lookup by SAMAccountName or UPN
│  Audit Snapshot     │  ← Capture groups, licenses, manager before changes
└────────┬────────────┘
         │
         ▼
┌─────────────────────┐
│  Decision Prompts   │  ← Mailbox conversion? Litigation hold? Access grants?
│                     │      Forwarding? OneDrive transfer?
└────────┬────────────┘
         │
         ▼
┌─────────────────────┐
│  Confirmation Gate  │  ← Shows full action plan. L1 must confirm before execution.
└────────┬────────────┘
         │
         ▼
┌──────────────────────────────────────────────────────┐
│  Execution                                           │
│  ├── Disable AD account (hybrid only)                │
│  ├── Disable Entra ID account                        │
│  ├── Reset password (random complex)                 │
│  ├── Revoke all active sessions                      │
│  ├── Remove all group memberships                    │
│  ├── Convert mailbox → Shared (if selected)          │
│  ├── Hide from GAL (automatic with shared mailbox)   │
│  ├── Enable Litigation Hold (if selected)            │
│  ├── Grant mailbox access + Send As (if selected)    │
│  ├── Set mail forwarding (if selected)               │
│  ├── Grant OneDrive access + capture direct link     │
│  └── Remove all assigned licenses (always last)      │
└────────┬─────────────────────────────────────────────┘
         │
         ▼
┌─────────────────────┐
│  Audit Summary      │  ← Structured output. L1 copies and pastes into ticket.
│  Output             │  ← Includes all removed items, new password, access grants,
│                     │      errors/warnings if any steps failed.
└─────────────────────┘
```

---

## Stack

| Tool | Role |
|------|------|
| **PowerShell 7+** | Script runtime |
| **Microsoft Graph (SDK)** | User management, group membership, license removal, session revocation |
| **ExchangeOnlineManagement** | Mailbox conversion, GAL visibility, litigation hold, forwarding, permissions |
| **PnP.PowerShell** | OneDrive / SharePoint site owner grant |
| **Active Directory (RSAT)** | On-prem account disable (hybrid environments only) |

---

## Prerequisites

### Required PowerShell Modules

```powershell
Install-Module Microsoft.Graph -Scope CurrentUser
Install-Module ExchangeOnlineManagement -Scope CurrentUser
Install-Module PnP.PowerShell -Scope CurrentUser
```

For hybrid environments, the **Active Directory** module must be available:
```powershell
# Install RSAT on Windows (or run from a Domain Controller)
Add-WindowsCapability -Online -Name Rsat.ActiveDirectory.DS-LDS.Tools~~~~0.0.1.0
```

### Required Admin Roles

This script is designed to be run with a **scoped admin account** — not Global Admin. The following roles are sufficient:

| Role | Purpose |
|------|---------|
| Exchange Administrator | Mailbox conversion, permissions, forwarding |
| User Administrator | Account disable, password reset, license removal |
| SharePoint Administrator | OneDrive access grant via PnP |
| License Administrator | M365 license removal |

> L1 technicians should use a dedicated scoped admin account. Global Admin is not required and should not be used for routine offboards.

---

## Usage

```powershell
.\Invoke-UserOffboard.ps1
```

No parameters. The script is fully interactive — it will prompt for everything it needs.

### Hybrid Environments

For clients with on-prem AD, the script **must be run from a machine that can reach the domain controller** — either a domain-joined workstation or directly on the DC. If the script cannot reach the domain, it will detect this and exit with a clear message rather than proceeding.

---

## Example Output

At the end of every offboard, the script produces a structured summary block:

```
============================================================
OFFBOARD SUMMARY
============================================================
Timestamp        : 2025-06-06 14:32:11
User             : Jane Smith
UPN              : jsmith@contoso.com
Manager          : Michael Torres
Environment      : Hybrid (on-prem AD + Entra ID)

ACTIONS COMPLETED
-----------------
Account Disabled : Yes
Password Reset   : Kx7#mQpL9vRn2!Yw
Sessions Revoked : Yes

Groups Removed   :
  - All Staff
  - Marketing Team
  - SharePoint-Marketing-Members
  - Contoso VPN Users

Mailbox          : Converted to Shared, Hidden from GAL
Litigation Hold  : Enabled
Forwarding       : Not set

Mailbox Access Granted To:
  - mwilson@contoso.com (Full Access + Send As)

OneDrive Access  : Granted to mtorres@contoso.com
OneDrive Link    : https://contoso-my.sharepoint.com/personal/jsmith_contoso_com/_layouts/15/onedrive.aspx

Licenses Removed : ENTERPRISEPREMIUM, POWER_BI_PRO
============================================================
ACTION REQUIRED: Copy this output and paste into the internal ticket note.
Verify each item above was completed as expected before closing the ticket.
============================================================
```

The L1 technician copies this output and pastes it into the internal ticket note. This serves as the audit record for that offboard. Dispatch Manager will then see the audit once ticket is escalated for their closure and send out related info to point of contact.

---

## Outcome

| Metric | Before | After |
|--------|--------|-------|
| Average offboard time | 1 – 1.5 hours | 15 – 20 minutes |
| L2 escalations per offboard | Frequent | Near zero |
| Missed steps (GAL, sessions, etc.) | Common | Eliminated |
| Audit documentation | Inconsistent | Standardized, automatic |
| Multi-client support | Manual per-client knowledge | Handled by script logic |

Offboarding became an L1-completable task with no technical M365 knowledge required beyond answering prompts. L2 engineers were freed from routine offboard tickets entirely.

---

## Notes

- The script captures a full audit snapshot **before** making any changes. Even if the script fails partway through, the pre-change state is already recorded.
- Any steps that fail during execution are captured and included in the summary output under `ERRORS / WARNINGS` — so L1 knows exactly what to manually follow up on.
- The script disconnects all sessions cleanly on completion.
- **License removal runs last by design.** Converting a mailbox to Shared and granting OneDrive access both require an active Exchange/SharePoint license. Removing licenses first causes those steps to fail silently — a common mistake in manual offboards.
- OneDrive access uses the PnP.PowerShell `Set-PnPTenantSite` method, which grants Site Owner permissions to the recipient's OneDrive library. This is the Microsoft-recommended approach for post-offboard file access. The direct OneDrive link is captured and included in the summary output so the L1 can verify access without navigating the SharePoint Admin Center.

---

Part of the [Automation Portfolio](https://github.com/neilchvz)
