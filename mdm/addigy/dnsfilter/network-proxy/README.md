# DNSFilter - Network Proxy

## Overview
A configuration profile that approves the DNSFilter DNS proxy extension 
on managed macOS devices, allowing DNSFilter to intercept and filter 
DNS queries for content filtering and threat protection.

## What this profile configures

- **DNS Proxy Extension** — approves `com.dnsfilter.agent.macos.DNSProxy` 
  via Team ID `Y532KV8739`
- **App Bundle** — tied to the DNSFilter macOS agent 
  (`com.dnsfilter.agent.macos`)

## Why this profile exists
macOS requires explicit MDM approval for DNS proxy extensions before 
they can intercept DNS traffic. Without this profile DNSFilter cannot 
filter DNS queries — leaving devices unprotected from malicious domains 
and policy-restricted content outside the corporate network.

## Note on profile origin
Published by DNSFilter as part of their official macOS deployment 
documentation. Imported and deployed via Addigy.

## Platform
Deployed via **Addigy MDM**. Compatible with any MDM platform that 
supports `com.apple.dnsProxy.managed`.

## File
[DNSFilter-Network-Proxy.mobileconfig](./DNSFilter-Network-Proxy.mobileconfig)