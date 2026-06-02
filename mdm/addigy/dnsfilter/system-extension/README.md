# DNSFilter - System Extension

## Overview
A configuration profile that pre-approves DNSFilter's network extension 
on managed macOS devices, allowing it to load without user interaction 
or manual approval prompts.

## What this profile configures

- **Allowed System Extension** — approves 
  `com.dnsfilter.agent.macos.DNSProxy` via Team ID `Y532KV8739`
- **Allowed Extension Type** — `NetworkExtension`, permitting DNSFilter 
  to operate as a network-level filter
- **Removal Disallowed** — users cannot remove this extension approval

## Why this profile exists
macOS requires explicit MDM approval for system extensions before they 
can load. Without this profile DNSFilter's DNS proxy extension is blocked 
at the OS level, preventing it from filtering DNS traffic and protecting 
devices from malicious domains and restricted content.

## Note on profile origin
Published by DNSFilter, Inc. as part of their official macOS deployment 
documentation. Imported and deployed via Addigy.

## Platform
Deployed via **Addigy MDM**. Compatible with any MDM platform that 
supports `com.apple.system-extension-policy`.

## File
[DNSFilter-System-Extension.mobileconfig](./DNSFilter-System-Extension.mobileconfig)