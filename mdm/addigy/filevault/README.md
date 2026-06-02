# FileVault Enforcement Profile

## What is FileVault?
FileVault is Apple's built-in full-disk encryption feature for macOS. When enabled, 
it encrypts the entire startup disk — meaning if a device is lost or stolen, 
the data on it is unreadable without the user's login credentials.

In a managed fleet, you don't leave this up to users to enable themselves. 
You enforce it via MDM policy.

## What this profile does
This configuration profile enforces FileVault on managed macOS devices with 
the following settings:

- **Enable FileVault** — encryption is enforced, not optional
- **Defer Enablement until Logout or Login** — the user isn't interrupted mid-session; 
  FileVault enables at their next login or logout event
- **Create personal recovery key** — a unique recovery key is generated per device
- **Prevent FileVault from being disabled** — users cannot turn off encryption
- **Escrow Personal Recovery Key** — the recovery key is encrypted using an 
  Addigy-issued certificate and stored securely in Addigy's database, 
  giving admins recovery access without ever exposing the key to the user

## Platform
Built for and deployed via **Addigy MDM**. The escrow endpoint and signing 
certificate are Addigy-specific — this profile is not directly portable to 
Jamf or Intune without rebuilding the escrow configuration for those platforms. 
The enforcement logic and policy settings are transferable concepts.

## File
[Security-and-Privacy-Enable-FileVault.mobileconfig](./Security-and-Privacy-Enable-FileVault.mobileconfig)