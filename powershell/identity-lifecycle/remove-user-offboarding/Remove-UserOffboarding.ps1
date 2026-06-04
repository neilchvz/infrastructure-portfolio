<#
.SYNOPSIS
    Executes a structured, auditable offboarding sequence for a departing Microsoft 365
    user, including account disablement, session revocation, license removal, mailbox
    conversion, and OneDrive ownership transfer.

.DESCRIPTION
    Remove-UserOffboarding.ps1 is a re-run safe, fully parameterized offboarding script
    designed for automated pipeline execution or manual IT operations use.

    It performs the following steps in sequence:
        1. Validates required modules and connected sessions.
        2. Pre-check — confirms the target user exists in Entra ID before proceeding.
        3. Disables the Entra ID account (blocks sign-in immediately).
        4. Revokes all active refresh tokens and MFA sessions.
        5. Removes the user from all Entra ID security and M365 groups.
        6. Converts the user mailbox to a shared mailbox and grants delegate access.
        7. Removes all assigned Microsoft 365 license SKUs.
        8. Transfers OneDrive ownership to a specified manager or IT admin account.
        9. Writes a structured output object and appends a JSON log entry.

    Each step is non-destructive to the account itself — the user object is retained
    in Entra ID for the configured soft-delete period (default 30 days) before permanent
    deletion. This preserves audit trail and allows recovery if needed.

    REQUIREMENTS:
        - Microsoft.Graph PowerShell SDK (Connect-MgGraph with appropriate scopes)
        - ExchangeOnlineManagement module (Connect-ExchangeOnline)
        - SharePoint Online Management Shell (Connect-SPOService) for OneDrive transfer
        - Caller must have: User Administrator + License Administrator + Exchange Admin
          + SharePoint Admin (or equivalent custom roles) in Entra ID.

.PARAMETER UserPrincipalName
    The UPN of the user being offboarded (e.g. jdoe@contoso.com).
    Must exist in Entra ID. Script will exit if the user is not found.

.PARAMETER ManagerUPN
    The UPN of the user's manager or designated IT admin account.
    Used as the delegate recipient for the converted shared mailbox and as
    the new OneDrive owner. Required unless -SkipMailboxConversion and
    -SkipOneDriveTransfer are both specified.

.PARAMETER SkipMailboxConversion
    Switch. If specified, the mailbox will not be converted to a shared mailbox.
    Use when the user has no Exchange license or mailbox.

.PARAMETER SkipOneDriveTransfer
    Switch. If specified, OneDrive ownership transfer will be skipped.
    Use when the SharePoint admin connection is unavailable or not required.

.PARAMETER SkipGroupRemoval
    Switch. If specified, group membership removal will be skipped.
    Useful when group cleanup is handled by a separate lifecycle process.

.PARAMETER RetainLicenses
    Switch. If specified, license assignments will not be removed.
    Use when license reclamation is handled by a separate billing process.

.PARAMETER WhatIf
    Runs the script in simulation mode. All steps are logged but no changes
    are made to Entra ID, Exchange Online, or SharePoint Online.

.PARAMETER LogPath
    Optional. Path to write a structured JSON log entry for this offboarding action.
    Defaults to .\offboarding-log.json in the current directory.

.EXAMPLE
    # Standard full offboarding
    .\Remove-UserOffboarding.ps1 `
        -UserPrincipalName "jdoe@contoso.com" `
        -ManagerUPN "msmith@contoso.com"

.EXAMPLE
    # Offboarding without OneDrive transfer (SharePoint not connected)
    .\Remove-UserOffboarding.ps1 `
        -UserPrincipalName "jdoe@contoso.com" `
        -ManagerUPN "msmith@contoso.com" `
        -SkipOneDriveTransfer

.EXAMPLE
    # Batch offboarding from CSV
    # CSV must have headers: UserPrincipalName, ManagerUPN
    Import-Csv -Path .\departures.csv | ForEach-Object {
        .\Remove-UserOffboarding.ps1 `
            -UserPrincipalName $_.UserPrincipalName `
            -ManagerUPN $_.ManagerUPN
    }

.EXAMPLE
    # Dry run / simulation
    .\Remove-UserOffboarding.ps1 `
        -UserPrincipalName "jdoe@contoso.com" `
        -ManagerUPN "msmith@contoso.com" `
        -WhatIf

.NOTES
    Author      : Neil Chavez
    Version     : 1.0.0
    Category    : Identity Lifecycle Automation
    Folder      : powershell/identity-lifecycle/
    Script #    : 02 of 24

    Pre-Check   : If the target UPN does not exist in Entra ID, the script exits
                  cleanly with a warning rather than throwing an unhandled error.

    Safety      : This script does NOT permanently delete the user object. Entra ID
                  retains soft-deleted users for 30 days, allowing recovery. Hard
                  deletion must be performed manually or via a separate retention script.

    Logging     : Each run appends a JSON object to the file at -LogPath. Each entry
                  includes timestamp, UPN, steps completed, errors, and WhatIf status.

    Dependencies:
        Install-Module Microsoft.Graph -Scope CurrentUser
        Install-Module ExchangeOnlineManagement -Scope CurrentUser
        Install-Module Microsoft.Online.SharePoint.PowerShell -Scope CurrentUser

    Connect before running:
        Connect-MgGraph -Scopes "User.ReadWrite.All","Group.ReadWrite.All","Directory.ReadWrite.All"
        Connect-ExchangeOnline -UserPrincipalName admin@contoso.com
        Connect-SPOService -Url https://contoso-admin.sharepoint.com
#>

[CmdletBinding(SupportsShouldProcess = $true)]
param (
    [Parameter(Mandatory = $true)]
    [ValidatePattern('^[^@]+@[^@]+\.[^@]+$')]
    [string]$UserPrincipalName,

    [Parameter(Mandatory = $false)]
    [ValidatePattern('^[^@]+@[^@]+\.[^@]+$')]
    [string]$ManagerUPN,

    [Parameter(Mandatory = $false)]
    [switch]$SkipMailboxConversion,

    [Parameter(Mandatory = $false)]
    [switch]$SkipOneDriveTransfer,

    [Parameter(Mandatory = $false)]
    [switch]$SkipGroupRemoval,

    [Parameter(Mandatory = $false)]
    [switch]$RetainLicenses,

    [Parameter(Mandatory = $false)]
    [string]$LogPath = ".\offboarding-log.json"
)

#region ── Helper Functions ────────────────────────────────────────────────────

function Write-Log {
    param (
        [string]$Message,
        [ValidateSet("INFO", "WARN", "ERROR", "SUCCESS")]
        [string]$Level = "INFO"
    )
    $timestamp = Get-Date -Format "yyyy-MM-dd HH:mm:ss"
    $colors = @{ INFO = "Cyan"; WARN = "Yellow"; ERROR = "Red"; SUCCESS = "Green" }
    Write-Host "[$timestamp] [$Level] $Message" -ForegroundColor $colors[$Level]
    $script:LogEntries += [PSCustomObject]@{
        Timestamp = $timestamp
        Level     = $Level
        Message   = $Message
    }
}

function Test-RequiredModule {
    param ([string]$ModuleName)
    if (-not (Get-Module -Name $ModuleName -ErrorAction SilentlyContinue)) {
        Write-Log "Required module '$ModuleName' is not loaded. Run: Import-Module $ModuleName" -Level ERROR
        return $false
    }
    return $true
}

function Test-GraphConnection {
    try {
        $ctx = Get-MgContext
        if (-not $ctx) {
            Write-Log "No active Microsoft Graph session found. Run Connect-MgGraph first." -Level ERROR
            return $false
        }
        Write-Log "Graph session active. Tenant: $($ctx.TenantId) | Account: $($ctx.Account)" -Level INFO
        return $true
    }
    catch {
        Write-Log "Failed to verify Graph session: $_" -Level ERROR
        return $false
    }
}

#endregion

#region ── Initialization ─────────────────────────────────────────────────────

$script:LogEntries = @()

$result = [PSCustomObject]@{
    UserPrincipalName    = $UserPrincipalName
    ObjectId             = $null
    AccountDisabled      = $false
    SessionsRevoked      = $false
    GroupsRemoved        = @()
    MailboxConverted     = $false
    LicensesRemoved      = @()
    OneDriveTransferred  = $false
    WhatIfMode           = $WhatIfPreference.ToString()
    CompletedAt          = $null
    Errors               = @()
}

Write-Log "=== Remove-UserOffboarding START ===" -Level INFO
Write-Log "Target UPN  : $UserPrincipalName" -Level INFO
Write-Log "Manager UPN : $(if ($ManagerUPN) { $ManagerUPN } else { 'Not specified' })" -Level INFO
Write-Log "WhatIf Mode : $($WhatIfPreference)" -Level INFO

#endregion

#region ── Step 0: Pre-flight Validation ──────────────────────────────────────

Write-Log "--- Step 0: Pre-flight Validation ---" -Level INFO

$modulesOk = (Test-RequiredModule "Microsoft.Graph.Users") -and
             (Test-RequiredModule "Microsoft.Graph.Groups") -and
             (Test-RequiredModule "ExchangeOnlineManagement")

if (-not $SkipOneDriveTransfer) {
    $modulesOk = $modulesOk -and (Test-RequiredModule "Microsoft.Online.SharePoint.PowerShell")
}

if (-not $modulesOk) {
    Write-Log "One or more required modules are missing. Exiting." -Level ERROR
    exit 1
}

if (-not (Test-GraphConnection)) { exit 1 }

#endregion

#region ── Step 1: Pre-Check — Confirm User Exists ────────────────────────────

Write-Log "--- Step 1: Pre-Check (Target User) ---" -Level INFO

$targetUser = $null
try {
    $targetUser = Get-MgUser -Filter "userPrincipalName eq '$UserPrincipalName'" `
                             -Property "Id,DisplayName,AccountEnabled,AssignedLicenses" `
                             -ErrorAction Stop
}
catch {
    Write-Log "Error querying Entra ID for target user: $_" -Level ERROR
}

if (-not $targetUser) {
    Write-Log "User '$UserPrincipalName' not found in Entra ID. Nothing to offboard. Exiting." -Level WARN
    exit 0
}

$result.ObjectId = $targetUser.Id
Write-Log "Target user confirmed: $($targetUser.DisplayName) | ObjectId: $($targetUser.Id)" -Level INFO

# Warn if account is already disabled — proceed anyway to ensure all steps run
if (-not $targetUser.AccountEnabled) {
    Write-Log "Account is already disabled. Continuing to verify remaining offboarding steps." -Level WARN
}

#endregion

#region ── Step 2: Disable Account ────────────────────────────────────────────

Write-Log "--- Step 2: Disable Account ---" -Level INFO

if ($PSCmdlet.ShouldProcess($UserPrincipalName, "Disable Entra ID account (block sign-in)")) {
    try {
        Update-MgUser -UserId $result.ObjectId -AccountEnabled $false
        $result.AccountDisabled = $true
        Write-Log "Account disabled successfully. Sign-in is now blocked." -Level SUCCESS
    }
    catch {
        $errMsg = "Failed to disable account: $_"
        Write-Log $errMsg -Level ERROR
        $result.Errors += $errMsg
        # This is a critical step — exit if it fails to avoid partial offboarding
        $result.CompletedAt = (Get-Date -Format "yyyy-MM-dd HH:mm:ss")
        $result | ConvertTo-Json -Depth 5 | Add-Content -Path $LogPath
        exit 1
    }
}
else {
    Write-Log "[WhatIf] Would disable account for: $UserPrincipalName" -Level INFO
}

#endregion

#region ── Step 3: Revoke Active Sessions ─────────────────────────────────────

Write-Log "--- Step 3: Revoke Active Sessions and Tokens ---" -Level INFO

if ($PSCmdlet.ShouldProcess($UserPrincipalName, "Revoke all active refresh tokens and MFA sessions")) {
    try {
        # Revokes all refresh tokens — forces re-authentication on any active session
        Revoke-MgUserSignInSession -UserId $result.ObjectId -ErrorAction Stop
        $result.SessionsRevoked = $true
        Write-Log "All active sessions and refresh tokens revoked successfully." -Level SUCCESS
    }
    catch {
        $errMsg = "Failed to revoke sessions: $_"
        Write-Log $errMsg -Level ERROR
        $result.Errors += $errMsg
        # Non-fatal: account is already disabled; continue with remaining steps
    }
}
else {
    Write-Log "[WhatIf] Would revoke all active sessions for: $UserPrincipalName" -Level INFO
}

#endregion

#region ── Step 4: Remove Group Memberships ───────────────────────────────────

Write-Log "--- Step 4: Remove Group Memberships ---" -Level INFO

if ($SkipGroupRemoval) {
    Write-Log "SkipGroupRemoval specified. Skipping group cleanup." -Level INFO
}
else {
    try {
        # Retrieve all group memberships for the user
        $memberships = Get-MgUserMemberOf -UserId $result.ObjectId -All -ErrorAction Stop |
                       Where-Object { $_.'@odata.type' -eq '#microsoft.graph.group' }

        if ($memberships.Count -eq 0) {
            Write-Log "No group memberships found for this user." -Level INFO
        }
        else {
            Write-Log "Found $($memberships.Count) group membership(s) to remove." -Level INFO

            foreach ($membership in $memberships) {
                try {
                    $groupId      = $membership.Id
                    $groupName    = $membership.AdditionalProperties['displayName']

                    if ($PSCmdlet.ShouldProcess($UserPrincipalName, "Remove from group '$groupName'")) {
                        Remove-MgGroupMemberByRef -GroupId $groupId -DirectoryObjectId $result.ObjectId -ErrorAction Stop
                        $result.GroupsRemoved += $groupName
                        Write-Log "Removed from group: '$groupName' ($groupId)" -Level SUCCESS
                    }
                    else {
                        Write-Log "[WhatIf] Would remove from group: '$groupName'" -Level INFO
                    }
                }
                catch {
                    $errMsg = "Failed to remove from group '$groupName' ($groupId): $_"
                    Write-Log $errMsg -Level ERROR
                    $result.Errors += $errMsg
                    # Non-fatal: continue with remaining groups
                }
            }
        }
    }
    catch {
        $errMsg = "Failed to retrieve group memberships: $_"
        Write-Log $errMsg -Level ERROR
        $result.Errors += $errMsg
    }
}

#endregion

#region ── Step 5: Convert Mailbox to Shared ──────────────────────────────────

Write-Log "--- Step 5: Convert Mailbox to Shared ---" -Level INFO

if ($SkipMailboxConversion) {
    Write-Log "SkipMailboxConversion specified. Skipping mailbox conversion." -Level INFO
}
elseif (-not $ManagerUPN) {
    Write-Log "No ManagerUPN provided. Skipping mailbox conversion and delegate assignment." -Level WARN
}
else {
    try {
        $mbx = Get-EXOMailbox -Identity $UserPrincipalName -ErrorAction SilentlyContinue

        if (-not $mbx) {
            Write-Log "No mailbox found for '$UserPrincipalName'. Skipping conversion." -Level WARN
        }
        else {
            if ($PSCmdlet.ShouldProcess($UserPrincipalName, "Convert mailbox to shared and grant access to $ManagerUPN")) {
                # Convert to shared mailbox — removes the license requirement
                Set-Mailbox -Identity $UserPrincipalName -Type Shared -ErrorAction Stop
                Write-Log "Mailbox converted to shared type successfully." -Level SUCCESS

                # Grant the manager full access to the shared mailbox
                Add-MailboxPermission -Identity $UserPrincipalName `
                                      -User $ManagerUPN `
                                      -AccessRights FullAccess `
                                      -InheritanceType All `
                                      -AutoMapping $true `
                                      -ErrorAction Stop
                Write-Log "Full access granted to '$ManagerUPN' on shared mailbox." -Level SUCCESS

                $result.MailboxConverted = $true
            }
            else {
                Write-Log "[WhatIf] Would convert mailbox to shared and grant access to: $ManagerUPN" -Level INFO
            }
        }
    }
    catch {
        $errMsg = "Error during mailbox conversion: $_"
        Write-Log $errMsg -Level ERROR
        $result.Errors += $errMsg
        # Non-fatal: continue with license removal
    }
}

#endregion

#region ── Step 6: Remove License Assignments ─────────────────────────────────

Write-Log "--- Step 6: Remove License Assignments ---" -Level INFO

if ($RetainLicenses) {
    Write-Log "RetainLicenses specified. Skipping license removal." -Level INFO
}
else {
    try {
        # Re-fetch current license state to ensure accuracy
        $currentUser = Get-MgUser -UserId $result.ObjectId -Property "AssignedLicenses" -ErrorAction Stop
        $assignedSkus = $currentUser.AssignedLicenses

        if ($assignedSkus.Count -eq 0) {
            Write-Log "No licenses currently assigned. Nothing to remove." -Level INFO
        }
        else {
            Write-Log "Found $($assignedSkus.Count) assigned license(s). Removing all." -Level INFO

            $licenseUpdate = @{
                AddLicenses    = @()
                RemoveLicenses = $assignedSkus | Select-Object -ExpandProperty SkuId
            }

            if ($PSCmdlet.ShouldProcess($UserPrincipalName, "Remove all assigned licenses")) {
                Set-MgUserLicense -UserId $result.ObjectId -BodyParameter $licenseUpdate -ErrorAction Stop

                # Resolve SKU IDs to readable names for the log
                $allSkus = Get-MgSubscribedSku
                foreach ($skuId in $licenseUpdate.RemoveLicenses) {
                    $skuName = ($allSkus | Where-Object { $_.SkuId -eq $skuId }).SkuPartNumber
                    $result.LicensesRemoved += ($skuName ?? $skuId.ToString())
                }

                Write-Log "Licenses removed: $($result.LicensesRemoved -join ', ')" -Level SUCCESS
            }
            else {
                Write-Log "[WhatIf] Would remove licenses: $($assignedSkus.SkuId -join ', ')" -Level INFO
            }
        }
    }
    catch {
        $errMsg = "Error during license removal: $_"
        Write-Log $errMsg -Level ERROR
        $result.Errors += $errMsg
    }
}

#endregion

#region ── Step 7: Transfer OneDrive Ownership ────────────────────────────────

Write-Log "--- Step 7: Transfer OneDrive Ownership ---" -Level INFO

if ($SkipOneDriveTransfer) {
    Write-Log "SkipOneDriveTransfer specified. Skipping OneDrive transfer." -Level INFO
}
elseif (-not $ManagerUPN) {
    Write-Log "No ManagerUPN provided. Skipping OneDrive ownership transfer." -Level WARN
}
else {
    try {
        # Derive the OneDrive URL from the UPN
        # Format: https://<tenant>-my.sharepoint.com/personal/<upn_formatted>
        $tenantName   = ($UserPrincipalName -split '@')[1] -replace '\..*', ''
        $upnFormatted = $UserPrincipalName -replace '@', '_' -replace '\.', '_'
        $oneDriveUrl  = "https://$tenantName-my.sharepoint.com/personal/$upnFormatted"

        Write-Log "Derived OneDrive URL: $oneDriveUrl" -Level INFO

        if ($PSCmdlet.ShouldProcess($UserPrincipalName, "Transfer OneDrive ownership to $ManagerUPN")) {
            # Set the manager as a secondary site collection admin to gain access
            Set-SPOUser -Site $oneDriveUrl -LoginName $ManagerUPN -IsSiteCollectionAdmin $true -ErrorAction Stop
            $result.OneDriveTransferred = $true
            Write-Log "OneDrive site collection admin rights granted to '$ManagerUPN'." -Level SUCCESS
            Write-Log "Manager can access the OneDrive at: $oneDriveUrl" -Level INFO
        }
        else {
            Write-Log "[WhatIf] Would transfer OneDrive admin rights to: $ManagerUPN" -Level INFO
            Write-Log "[WhatIf] Target OneDrive URL: $oneDriveUrl" -Level INFO
        }
    }
    catch {
        $errMsg = "Error during OneDrive transfer: $_"
        Write-Log $errMsg -Level ERROR
        $result.Errors += $errMsg
        # Non-fatal: core offboarding steps are complete
    }
}

#endregion

#region ── Step 8: Output & Logging ───────────────────────────────────────────

$result.CompletedAt = (Get-Date -Format "yyyy-MM-dd HH:mm:ss")

Write-Log "=== Remove-UserOffboarding COMPLETE ===" -Level SUCCESS
Write-Log "UPN                 : $($result.UserPrincipalName)" -Level SUCCESS
Write-Log "Account Disabled    : $($result.AccountDisabled)" -Level SUCCESS
Write-Log "Sessions Revoked    : $($result.SessionsRevoked)" -Level SUCCESS
Write-Log "Groups Removed      : $($result.GroupsRemoved.Count) group(s)" -Level SUCCESS
Write-Log "Mailbox Converted   : $($result.MailboxConverted)" -Level SUCCESS
Write-Log "Licenses Removed    : $($result.LicensesRemoved -join ', ')" -Level SUCCESS
Write-Log "OneDrive Transferred: $($result.OneDriveTransferred)" -Level SUCCESS

if ($result.Errors.Count -gt 0) {
    Write-Log "Completed with $($result.Errors.Count) non-fatal error(s). Review output object." -Level WARN
}

$logEntry = [PSCustomObject]@{
    RunAt      = $result.CompletedAt
    Result     = $result
    LogEntries = $script:LogEntries
}

try {
    $logEntry | ConvertTo-Json -Depth 5 | Add-Content -Path $LogPath -Encoding UTF8
    Write-Log "Log written to: $LogPath" -Level INFO
}
catch {
    Write-Log "Warning: Could not write log file to '$LogPath': $_" -Level WARN
}

return $result

#endregion
