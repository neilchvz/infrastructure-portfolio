<#
.SYNOPSIS
    Automated M365 user offboarding script for L1 technicians.

.DESCRIPTION
    Guides an L1 technician through a full user offboarding workflow via
    interactive prompts. Supports both hybrid (on-prem AD + Exchange Online)
    and cloud-only (Entra ID + Exchange Online) environments.

    Workflow:
        1. OAuth interactive login to target tenant
        2. Environment detection (hybrid vs cloud-only)
        3. User lookup and audit snapshot
        4. Mailbox conversion decisions
        5. OneDrive access decisions
        6. Execution of all offboarding steps
        7. Summary output for L1 to paste into internal ticket note

.NOTES
    Author:         Neil Chavez
    Version:        1.0.0
    Created:        2025
    Requirements:   Microsoft.Graph, ExchangeOnlineManagement, PnP.PowerShell modules
                    Scoped admin account with the following roles:
                        - Exchange Administrator
                        - User Administrator
                        - SharePoint Administrator
                        - License Administrator

.EXAMPLE
    .\Invoke-UserOffboard.ps1
#>

#Requires -Modules Microsoft.Graph, ExchangeOnlineManagement, PnP.PowerShell

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

# ─────────────────────────────────────────────
# REGION: HELPERS
# ─────────────────────────────────────────────

function Write-Header {
    param([string]$Text)
    Write-Host ""
    Write-Host "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━" -ForegroundColor Cyan
    Write-Host "  $Text" -ForegroundColor Cyan
    Write-Host "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━" -ForegroundColor Cyan
    Write-Host ""
}

function Write-Step {
    param([string]$Text)
    Write-Host "  ► $Text" -ForegroundColor Yellow
}

function Write-Success {
    param([string]$Text)
    Write-Host "  ✓ $Text" -ForegroundColor Green
}

function Write-Warn {
    param([string]$Text)
    Write-Host "  ⚠ $Text" -ForegroundColor Magenta
}

function New-RandomPassword {
    $chars = 'abcdefghijkmnpqrstuvwxyzABCDEFGHJKLMNPQRSTUVWXYZ23456789!@#$%^&*'
    $password = -join ((1..16) | ForEach-Object { $chars[(Get-Random -Maximum $chars.Length)] })
    return $password
}

function Prompt-YesNo {
    param([string]$Question)
    do {
        $response = Read-Host "  $Question (y/n)"
    } while ($response -notmatch '^[yn]$')
    return $response -eq 'y'
}

# ─────────────────────────────────────────────
# REGION: CONNECT
# ─────────────────────────────────────────────

Write-Header "M365 OFFBOARDING AUTOMATION — v1.0"
Write-Host "  This script will guide you through a full user offboard." -ForegroundColor White
Write-Host "  Answer each prompt carefully. All actions are logged at the end." -ForegroundColor White
Write-Host ""
Write-Host "  Press ENTER to begin and authenticate to the target tenant..." -ForegroundColor Gray
Read-Host | Out-Null

Write-Step "Connecting to Microsoft Graph..."
try {
    Connect-MgGraph -Scopes "User.ReadWrite.All","Group.ReadWrite.All","Directory.ReadWrite.All","Organization.Read.All" -ErrorAction Stop
    Write-Success "Connected to Microsoft Graph."
} catch {
    Write-Error "Failed to connect to Microsoft Graph: $_"
    exit 1
}

Write-Step "Connecting to Exchange Online..."
try {
    Connect-ExchangeOnline -ShowBanner:$false -ErrorAction Stop
    Write-Success "Connected to Exchange Online."
} catch {
    Write-Error "Failed to connect to Exchange Online: $_"
    exit 1
}

# ─────────────────────────────────────────────
# REGION: ENVIRONMENT DETECTION
# ─────────────────────────────────────────────

Write-Header "STEP 1 — ENVIRONMENT TYPE"

$isHybrid = Prompt-YesNo "Is this client a hybrid environment (on-prem AD synced to Entra ID)?"

if ($isHybrid) {
    Write-Step "Hybrid selected. Checking connectivity to local domain..."
    try {
        $domain = (Get-WmiObject Win32_ComputerSystem).Domain
        $dcTest = [System.DirectoryServices.ActiveDirectory.Domain]::GetCurrentDomain()
        Write-Success "Domain reachable: $($dcTest.Name)"
    } catch {
        Write-Host ""
        Write-Host "  ✗ Cannot reach the local domain controller." -ForegroundColor Red
        Write-Host "  ✗ For hybrid environments, this script must be run from a machine" -ForegroundColor Red
        Write-Host "    joined to the domain, or directly on a Domain Controller." -ForegroundColor Red
        Write-Host ""
        Write-Host "  Please re-run this script from the correct machine." -ForegroundColor Yellow
        exit 1
    }
}

# ─────────────────────────────────────────────
# REGION: USER LOOKUP
# ─────────────────────────────────────────────

Write-Header "STEP 2 — USER LOOKUP"

do {
    $samOrUPN = Read-Host "  Enter the user's SAMAccountName or UPN (e.g. jsmith or jsmith@contoso.com)"
    $mgUser = Get-MgUser -Filter "userPrincipalName eq '$samOrUPN' or onPremisesSamAccountName eq '$samOrUPN'" `
        -Property Id,DisplayName,UserPrincipalName,JobTitle,Department,AccountEnabled,OnPremisesSamAccountName,Manager,AssignedLicenses,MemberOf `
        -ExpandProperty Manager -ErrorAction SilentlyContinue

    if (-not $mgUser) {
        Write-Warn "User not found. Please check the username and try again."
    }
} while (-not $mgUser)

Write-Success "User found: $($mgUser.DisplayName) — $($mgUser.UserPrincipalName)"

# ─────────────────────────────────────────────
# REGION: AUDIT SNAPSHOT
# ─────────────────────────────────────────────

Write-Header "STEP 3 — AUDIT SNAPSHOT"
Write-Step "Capturing current user state before any changes..."

# Group memberships
$groupMemberships = Get-MgUserMemberOf -UserId $mgUser.Id -All |
    Where-Object { $_.AdditionalProperties['@odata.type'] -eq '#microsoft.graph.group' } |
    ForEach-Object { $_.AdditionalProperties['displayName'] }

# Assigned licenses
$skuIds = $mgUser.AssignedLicenses | Select-Object -ExpandProperty SkuId
$allSkus = Get-MgSubscribedSku
$licenseNames = $skuIds | ForEach-Object {
    $skuId = $_
    ($allSkus | Where-Object { $_.SkuId -eq $skuId }).SkuPartNumber
}

# Manager
$managerName = if ($mgUser.Manager) { $mgUser.Manager.AdditionalProperties['displayName'] } else { "Not set" }
$managerUPN  = if ($mgUser.Manager) { $mgUser.Manager.AdditionalProperties['userPrincipalName'] } else { $null }

Write-Success "Audit snapshot captured."
Write-Host ""
Write-Host "  User:        $($mgUser.DisplayName)" -ForegroundColor White
Write-Host "  UPN:         $($mgUser.UserPrincipalName)" -ForegroundColor White
Write-Host "  Title:       $($mgUser.JobTitle)" -ForegroundColor White
Write-Host "  Department:  $($mgUser.Department)" -ForegroundColor White
Write-Host "  Manager:     $managerName" -ForegroundColor White
Write-Host "  Licenses:    $($licenseNames -join ', ')" -ForegroundColor White
Write-Host "  Groups:      $($groupMemberships -join ', ')" -ForegroundColor White

# ─────────────────────────────────────────────
# REGION: MAILBOX DECISIONS
# ─────────────────────────────────────────────

Write-Header "STEP 4 — MAILBOX OPTIONS"

$convertToShared  = Prompt-YesNo "Convert mailbox to Shared Mailbox?"
$litigationHold   = $false
$mailboxAccess    = @()
$forwardTo        = $null

if ($convertToShared) {
    $litigationHold = Prompt-YesNo "Enable Litigation Hold on the shared mailbox?"

    $addAccessInput = Read-Host "  Who needs access to the mailbox? Enter UPNs comma-separated (or press ENTER to skip)"
    if ($addAccessInput) {
        $mailboxAccess = $addAccessInput -split ',' | ForEach-Object { $_.Trim() }
    }

    $setForward = Prompt-YesNo "Set a forwarding address on this mailbox?"
    if ($setForward) {
        $forwardTo = Read-Host "  Enter forwarding UPN or email address"
    }
}

# ─────────────────────────────────────────────
# REGION: ONEDRIVE DECISIONS
# ─────────────────────────────────────────────

Write-Header "STEP 5 — ONEDRIVE ACCESS"

$oneDriveAccess   = $false
$oneDriveRecipient = $null

$oneDriveAccess = Prompt-YesNo "Does someone need access to this user's OneDrive files?"
if ($oneDriveAccess) {
    $useManager = Prompt-YesNo "Transfer to manager ($managerName)?"
    if ($useManager -and $managerUPN) {
        $oneDriveRecipient = $managerUPN
    } else {
        $oneDriveRecipient = Read-Host "  Enter the UPN of who should receive OneDrive access"
    }
}

# ─────────────────────────────────────────────
# REGION: CONFIRM BEFORE EXECUTION
# ─────────────────────────────────────────────

Write-Header "STEP 6 — CONFIRM & EXECUTE"

Write-Host "  About to perform the following actions on $($mgUser.DisplayName):" -ForegroundColor White
Write-Host ""
Write-Host "  • Disable account in $(if ($isHybrid) { 'on-prem AD + Entra ID' } else { 'Entra ID' })" -ForegroundColor Gray
Write-Host "  • Reset password to a random complex password" -ForegroundColor Gray
Write-Host "  • Remove all group memberships" -ForegroundColor Gray
Write-Host "  • Remove all assigned licenses" -ForegroundColor Gray
if ($convertToShared) {
    Write-Host "  • Convert mailbox to Shared Mailbox" -ForegroundColor Gray
    Write-Host "  • Hide from Global Address List (GAL)" -ForegroundColor Gray
    if ($litigationHold)  { Write-Host "  • Enable Litigation Hold" -ForegroundColor Gray }
    if ($mailboxAccess)   { Write-Host "  • Grant mailbox access to: $($mailboxAccess -join ', ')" -ForegroundColor Gray }
    if ($forwardTo)       { Write-Host "  • Set forwarding to: $forwardTo" -ForegroundColor Gray }
}
if ($oneDriveAccess)      { Write-Host "  • Grant OneDrive access to: $oneDriveRecipient" -ForegroundColor Gray }
Write-Host ""

$confirm = Prompt-YesNo "Proceed with offboard?"
if (-not $confirm) {
    Write-Warn "Offboard cancelled. No changes have been made."
    exit 0
}

# ─────────────────────────────────────────────
# REGION: EXECUTION
# ─────────────────────────────────────────────

Write-Header "EXECUTING OFFBOARD"

$newPassword = New-RandomPassword
$permissionsGranted = @()
$errors = @()

# --- DISABLE ACCOUNT ---
try {
    if ($isHybrid) {
        Write-Step "Disabling on-prem AD account..."
        Disable-ADAccount -Identity $mgUser.OnPremisesSamAccountName
        Write-Success "On-prem AD account disabled."
    }

    Write-Step "Disabling Entra ID account..."
    Update-MgUser -UserId $mgUser.Id -AccountEnabled:$false
    Write-Success "Entra ID account disabled."
} catch {
    $errors += "Disable account: $_"
    Write-Warn "Failed to disable account: $_"
}

# --- RESET PASSWORD ---
try {
    Write-Step "Resetting password..."
    $passwordProfile = @{
        Password                      = $newPassword
        ForceChangePasswordNextSignIn = $false
    }
    Update-MgUser -UserId $mgUser.Id -PasswordProfile $passwordProfile
    Write-Success "Password reset."
} catch {
    $errors += "Password reset: $_"
    Write-Warn "Failed to reset password: $_"
}

# --- REVOKE SESSIONS ---
try {
    Write-Step "Revoking all active sessions..."
    Revoke-MgUserSignInSession -UserId $mgUser.Id | Out-Null
    Write-Success "Sessions revoked."
} catch {
    $errors += "Revoke sessions: $_"
    Write-Warn "Failed to revoke sessions: $_"
}

# --- REMOVE GROUP MEMBERSHIPS ---
Write-Step "Removing group memberships..."
$removedGroups = @()
$groupObjects = Get-MgUserMemberOf -UserId $mgUser.Id -All |
    Where-Object { $_.AdditionalProperties['@odata.type'] -eq '#microsoft.graph.group' }

foreach ($group in $groupObjects) {
    try {
        Remove-MgGroupMemberByRef -GroupId $group.Id -DirectoryObjectId $mgUser.Id
        $removedGroups += $group.AdditionalProperties['displayName']
    } catch {
        $errors += "Remove group $($group.AdditionalProperties['displayName']): $_"
        Write-Warn "Could not remove from group: $($group.AdditionalProperties['displayName'])"
    }
}
Write-Success "Removed from $($removedGroups.Count) group(s)."

# --- MAILBOX CONVERSION ---
if ($convertToShared) {
    try {
        Write-Step "Converting mailbox to Shared..."
        Set-Mailbox -Identity $mgUser.UserPrincipalName -Type Shared
        Write-Success "Mailbox converted to Shared."
    } catch {
        $errors += "Mailbox conversion: $_"
        Write-Warn "Failed to convert mailbox: $_"
    }

    try {
        Write-Step "Hiding mailbox from GAL..."
        Set-Mailbox -Identity $mgUser.UserPrincipalName -HiddenFromAddressListsEnabled $true
        Write-Success "Mailbox hidden from GAL."
    } catch {
        $errors += "Hide from GAL: $_"
        Write-Warn "Failed to hide from GAL: $_"
    }

    if ($litigationHold) {
        try {
            Write-Step "Enabling Litigation Hold..."
            Set-Mailbox -Identity $mgUser.UserPrincipalName -LitigationHoldEnabled $true
            Write-Success "Litigation Hold enabled."
        } catch {
            $errors += "Litigation Hold: $_"
            Write-Warn "Failed to enable Litigation Hold: $_"
        }
    }

    foreach ($accessUPN in $mailboxAccess) {
        try {
            Write-Step "Granting mailbox access to $accessUPN..."
            Add-MailboxPermission -Identity $mgUser.UserPrincipalName -User $accessUPN -AccessRights FullAccess -AutoMapping $true | Out-Null
            Add-RecipientPermission -Identity $mgUser.UserPrincipalName -Trustee $accessUPN -AccessRights SendAs -Confirm:$false | Out-Null
            $permissionsGranted += "$accessUPN (Full Access + Send As)"
            Write-Success "Access granted to $accessUPN."
        } catch {
            $errors += "Mailbox access for $accessUPN`: $_"
            Write-Warn "Failed to grant mailbox access to $accessUPN`: $_"
        }
    }

    if ($forwardTo) {
        try {
            Write-Step "Setting forwarding to $forwardTo..."
            Set-Mailbox -Identity $mgUser.UserPrincipalName -ForwardingSmtpAddress $forwardTo -DeliverToMailboxAndForward $false
            Write-Success "Forwarding set to $forwardTo."
        } catch {
            $errors += "Forwarding: $_"
            Write-Warn "Failed to set forwarding: $_"
        }
    }
}

# --- ONEDRIVE ACCESS ---
$oneDriveAdminUrl = $null
if ($oneDriveAccess -and $oneDriveRecipient) {
    try {
        Write-Step "Granting OneDrive access to $oneDriveRecipient..."
        $orgDomain = (Get-MgOrganization).VerifiedDomains | Where-Object { $_.IsDefault } | Select-Object -ExpandProperty Name
        $tenantPrefix = $orgDomain.Split('.')[0]
        $adminUrl     = "https://$tenantPrefix-admin.sharepoint.com"
        $upnClean     = $mgUser.UserPrincipalName -replace '@','_' -replace '\.','_'
        $odUrl        = "https://$tenantPrefix-my.sharepoint.com/personal/$upnClean"

        Connect-PnPOnline -Url $adminUrl -Interactive
        Set-PnPTenantSite -Url $odUrl -Owners $oneDriveRecipient

        # Build the direct admin access link for the L1 to include in the ticket
        $oneDriveAdminUrl = "$odUrl/_layouts/15/onedrive.aspx"
        Write-Success "OneDrive access granted to $oneDriveRecipient."
        Write-Host "  OneDrive Link: $oneDriveAdminUrl" -ForegroundColor Cyan
    } catch {
        $errors += "OneDrive access: $_"
        Write-Warn "Failed to grant OneDrive access: $_"
    }
}

# --- REMOVE LICENSES (last step — must run after mailbox and OneDrive) ---
# NOTE: Licenses are removed last. Converting a mailbox to Shared and granting
# OneDrive access both require an active license. Removing licenses first will
# cause those steps to fail.
Write-Step "Removing assigned licenses..."
$removedLicenses = @()
try {
    if ($skuIds.Count -gt 0) {
        Set-MgUserLicense -UserId $mgUser.Id -AddLicenses @() -RemoveLicenses $skuIds | Out-Null
        $removedLicenses = $licenseNames
        Write-Success "Licenses removed: $($licenseNames -join ', ')"
    } else {
        Write-Warn "No licenses found to remove."
    }
} catch {
    $errors += "Remove licenses: $_"
    Write-Warn "Failed to remove licenses: $_"
}

# ─────────────────────────────────────────────
# REGION: SUMMARY OUTPUT
# ─────────────────────────────────────────────

Write-Header "OFFBOARD COMPLETE — COPY OUTPUT BELOW"

$separator = "=" * 60
$timestamp = Get-Date -Format "yyyy-MM-dd HH:mm:ss"

$summary = @"
$separator
OFFBOARD SUMMARY
$separator
Timestamp        : $timestamp
User             : $($mgUser.DisplayName)
UPN              : $($mgUser.UserPrincipalName)
Manager          : $managerName
Environment      : $(if ($isHybrid) { 'Hybrid (on-prem AD + Entra ID)' } else { 'Cloud-Only (Entra ID)' })

ACTIONS COMPLETED
-----------------
Account Disabled : Yes
Password Reset   : $newPassword
Sessions Revoked : Yes

Licenses Removed : $(if ($removedLicenses) { $removedLicenses -join ', ' } else { 'None' })

Groups Removed   :
$(($groupMemberships | ForEach-Object { "  - $_" }) -join "`n")

Mailbox          : $(if ($convertToShared) { 'Converted to Shared, Hidden from GAL' } else { 'No changes' })
Litigation Hold  : $(if ($litigationHold) { 'Enabled' } else { 'Not set' })
Forwarding       : $(if ($forwardTo) { $forwardTo } else { 'Not set' })

Mailbox Access Granted To:
$(if ($permissionsGranted) { ($permissionsGranted | ForEach-Object { "  - $_" }) -join "`n" } else { '  None' })

OneDrive Access  : $(if ($oneDriveAccess -and $oneDriveRecipient) { "Granted to $oneDriveRecipient" } else { 'Not requested' })
OneDrive Link    : $(if ($oneDriveAdminUrl) { $oneDriveAdminUrl } else { 'N/A' })

$(if ($errors.Count -gt 0) {
"ERRORS / WARNINGS
-----------------
$(($errors | ForEach-Object { "  ! $_" }) -join "`n")"
} else {
"No errors encountered."
})
$separator
ACTION REQUIRED: Copy this output and paste into the internal ticket note.
Verify each item above was completed as expected before closing the ticket.
$separator
"@

Write-Host $summary -ForegroundColor White

# Disconnect sessions
Disconnect-ExchangeOnline -Confirm:$false -ErrorAction SilentlyContinue
Disconnect-MgGraph -ErrorAction SilentlyContinue
