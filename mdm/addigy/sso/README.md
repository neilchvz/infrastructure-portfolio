# Extensible SSO - Microsoft Enterprise SSO

## Overview
A configuration profile that enables the Microsoft Enterprise SSO extension 
on managed macOS devices. This allows users to authenticate once via 
Microsoft Company Portal and gain seamless SSO access to all Microsoft 
and Entra ID integrated applications — without repeated login prompts.

## What this profile configures

- **SSO Extension** — enables the Microsoft Company Portal SSO extension 
  (`com.microsoft.CompanyPortalMac.ssoextension`)
- **App Allow List** — SSO enabled for Safari, Addigy agent, 
  and Microsoft Company Portal
- **App Prefix Allow List** — SSO enabled for all apps under 
  `com.microsoft.`, `com.apple.`, and `com.addigy.` bundle prefixes
- **Browser SSO** — enabled, allowing web-based authentication flows 
  to participate in SSO
- **Authentication URLs** — redirects authentication requests to 
  Microsoft identity endpoints including commercial, US government, 
  and China cloud tenants

## Why this profile exists
Without this profile, macOS users in a Microsoft 365 environment are 
repeatedly prompted to authenticate across apps and browsers. This profile 
establishes a seamless Entra ID authentication experience on macOS, 
consistent with the SSO behavior users expect on Windows.

## Platform
Built for and deployed via **Addigy MDM**. Requires Microsoft Company 
Portal to be installed on the device. Standard Apple extensible SSO 
payload — portable to Jamf, Intune, or any MDM platform that supports 
`com.apple.extensiblesso`.

## File
[Extensible-SSO-Microsoft-Enterprise.mobileconfig](./Extensible-SSO-Microsoft-Enterprise.mobileconfig)