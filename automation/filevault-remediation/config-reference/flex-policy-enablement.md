# Flex Policy: FileVault Enablement

## Purpose

Automatically enables FileVault on any managed macOS device where it
is not active. This acts as a continuous compliance backstop — catching
devices where the global MDM enablement profile failed on enrollment,
or where FileVault was disabled after the fact by the user.

---

## Flex Policy Filter

| Device Fact | Operator | Value |
|-------------|----------|-------|
| FileVault Enabled | = | False |

Any device where FileVault is not enabled is automatically added to
this policy. Once FileVault is enabled and the Device Fact updates on
next check-in, the device exits the policy automatically.

Like the escrow remediation policy, this runs continuously. A device
that disables FileVault weeks or months after initial enrollment will
be detected and remediated on the next Addigy Device Fact evaluation.

---

## Assets Assigned to This Policy

### MDM Profile — FileVault Enable + Key Escrow

A single MDM configuration profile that combines two payloads:

**1. FileVault Enable (`com.apple.MCX.FileVault2`)**
Instructs macOS to enable FileVault disk encryption. On supported
hardware, this uses the user's login credentials to encrypt the volume.

**2. FDERecoveryKeyEscrow**
Ensures the recovery key generated during FileVault enablement is
automatically escrowed to Addigy. This is applied in the same profile
to guarantee escrow occurs at the moment of encryption — not as a
separate step that could be missed.

---

## User Experience

Unlike the escrow remediation policy, this one is visible to the user.
Addigy's FileVault Device Setting uses **deferred enablement** — FileVault
does not begin encrypting immediately after the profile is installed.
Instead, encryption is triggered the next time a Secure Token user
performs a full logout and login.

**Important:** Restarting the Mac does not trigger deferred enablement.
The user must fully log out of their macOS session.

**The flow:**
1. MDM profile installs on the device — no immediate user impact
2. On next logout, macOS presents a prompt:
   *"To add this user to FileVault, enter the password for [username]"*
3. User enters their password to confirm enablement
4. User logs back in — encryption begins in the background
5. A notification script fires at completion, displaying a message from
   the IT team explaining that FileVault has been enabled to protect their
   data, with helpdesk contact information

If the user selects Cancel at the prompt, they return to the login window
and remain in deferred enablement — FileVault is not enabled. End users
should be informed in advance that this prompt requires their action.

The recovery key is escrowed to Addigy at the time of enablement.
No technician involvement is required after profile deployment.

## Notification Script

A script runs at the end of the enablement process displaying a branded
message from the IT team — explaining what happened, why it matters, and
how to reach support with questions. This has proven effective at preventing
user confusion and support tickets from users who did not expect the prompt.

Example message:

```
From: [IT Company Name]

Hi,

Your IT team has enabled FileVault (hard drive encryption) for your
device to safeguard your data.

If you have any questions about this, please feel free to reach out
to us at [help email] or [main line].

Thank you for your attention to this matter!

Your [IT Company] Support Team
```

---

## Why This Policy Exists Alongside the Global Enrollment Profile

The MSP deploys a global MDM policy at enrollment intended to enable
FileVault on all devices. This catches the cases where that global
policy does not apply successfully — for example:

- Devices enrolled outside the standard workflow
- Edge cases where the MDM profile failed to apply
- Devices where a user with local admin rights disabled FileVault
  after enrollment

The flex policy filter provides a continuous safety net that the
global enrollment profile cannot. If a device falls out of compliance
for any reason, it is detected and remediated automatically.

---

*Part of the [Automation Portfolio](https://github.com/neilchvz) · Neil Chavez · Creator of things.*
