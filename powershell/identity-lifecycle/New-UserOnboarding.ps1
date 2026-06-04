<#
.SYNOPSIS
    Provisions a new user in Microsoft 365, including Entra ID account creation,
    license assignment, security group membership, mailbox enablement, and attribute
    population.

.DESCRIPTION
    New-UserOnboarding.ps1 is a fully parameterized, re-run safe M365 user provisioning
    script designed for automated pipeline execution or manual IT operations use.

    It performs the following steps in sequence:
        1. Validates that required modules are available and connected sessions exist.
        2. Checks whether the user already exists in Entra ID (pre-check before creation).
        3. Creates the Entra ID user account with standard attribute mapping.
        4. Assigns the specified Microsoft 365 license SKU.
        5. Adds the user to one or more security/M365 groups by Object ID.
        6. Sets the manager relationship in Entra ID.
        7. Enables the Exchange Online mailbox and applies a usage location.
        8. Writes a structured output object and a log entry on completion.

    Supports both interactive and pipeline use. Accepts a single user via parameters
    or a batch of users via CSV import (see examples).

    REQUIREMENTS:
        - Microsoft.Graph PowerShell SDK (Connect-MgGraph with appropriate scopes)
        - ExchangeOnlineManagement module (Connect-ExchangeOnline)
        - Caller must have: User Administrator + License Administrator + Exchange Admin
          (or equivalent custom role) in Entra ID.

.PARAMETER FirstName
    The user's first name. Used to construct DisplayName and MailNickname.

.PARAMETER LastName
    The user's last name. Used to construct DisplayName and MailNickname.

.PARAMETER UserPrincipalName
    The full UPN for the new account (e.g. jdoe@contoso.com).
    Must match a verified domain in the tenant.

.PARAMETER Department
    The department attribute to set on the user object (e.g. "Engineering").

.PARAMETER JobTitle
    The job title attribute to set on the user object (e.g. "Platform Engineer").

.PARAMETER ManagerUPN
    The UPN of the user's manager. Used to set the manager relationship in Entra ID.
    Optional. If omitted, the manager field is left unset.

.PARAMETER LicenseSku
    The Microsoft 365 license SKU part number to assign.
    Examples: "ENTERPRISEPREMIUM" (E3), "SPE_E5" (E5), "DEVELOPERPACK_E5"
    Run Get-MgSubscribedSku to list available SKUs in your tenant.

.PARAMETER GroupIds
    An array of Entra ID security or M365 group Object IDs to add the user to.
    Optional. If omitted, no group assignments are made.

.PARAMETER UsageLocation
    The two-letter country code for license assignment compliance (e.g. "US", "GB").
    Required by Microsoft before a license can be assigned. Defaults to "US".

.PARAMETER TemporaryPassword
    The initial temporary password for the account. The user will be required
    to change it on first sign-in. If omitted, a random 16-character password
    is generated and included in the output object.

.PARAMETER WhatIf
    Runs the script in simulation mode. All steps are logged but no changes
    are made to Entra ID, Exchange Online, or group memberships.

.PARAMETER LogPath
    Optional. Path to write a structured JSON log entry for this provisioning action.
    Defaults to .\onboarding-log.json in the current directory.

.EXAMPLE
    # Single user provisioning
    .\New-UserOnboarding.ps1 `
        -FirstName "Jane" `
        -LastName "Doe" `
        -UserPrincipalName "jdoe@contoso.com" `
        -Department "Engineering" `
        -JobTitle "Platform Engineer" `
        -ManagerUPN "msmith@contoso.com" `
        -LicenseSku "SPE_E5" `
        -GroupIds @("xxxxxxxx-xxxx-xxxx-xxxx-xxxxxxxxxxxx", "yyyyyyyy-yyyy-yyyy-yyyy-yyyyyyyyyyyy") `
        -UsageLocation "US"

.EXAMPLE
    # Batch provisioning from CSV
    # CSV must have headers: FirstName, LastName, UserPrincipalName, Department,
    #                        JobTitle, ManagerUPN, LicenseSku, GroupIds, UsageLocation
    # GroupIds in CSV should be semicolon-separated Object IDs.

    Import-Csv -Path .\new-hires.csv | ForEach-Object {
        $groups = $_.GroupIds -split ";" | Where-Object { $_ }
        .\New-UserOnboarding.ps1 `
            -FirstName $_.FirstName `
            -LastName $_.LastName `
            -UserPrincipalName $_.UserPrincipalName `
            -Department $_.Department `
            -JobTitle $_.JobTitle `
            -ManagerUPN $_.ManagerUPN `
            -LicenseSku $_.LicenseSku `
            -GroupIds $groups `
            -UsageLocation $_.UsageLocation
    }

.EXAMPLE
    # Dry run / simulation
    .\New-UserOnboarding.ps1 `
        -FirstName "Test" `
        -LastName "User" `
        -UserPrincipalName "testuser@contoso.com" `
        -LicenseSku "SPE_E5" `
        -WhatIf

.NOTES
    Author      : Neil Chavez
    Version     : 1.0.0
    Category    : Identity Lifecycle Automation
    Folder      : powershell/identity-lifecycle/
    Script #    : 01 of 24

    Pre-Check   : If the UPN already exists in Entra ID, the script will skip
                  account creation and attempt to reconcile license and group state
                  only if -Force is added (not implemented in v1.0; planned).

    Logging     : Each run appends a JSON object to the file at -LogPath.
                  Each log entry includes timestamp, UPN, steps completed,
                  any errors encountered, and WhatIf status.

    Dependencies:
        Install-Module Microsoft.Graph -Scope CurrentUser
        Install-Module ExchangeOnlineManagement -Scope CurrentUser

    Connect before running:
        Connect-MgGraph -Scopes "User.ReadWrite.All","Group.ReadWrite.All","Directory.ReadWrite.All"
        Connect-ExchangeOnline -UserPrincipalName admin@contoso.com
#>

[CmdletBinding(SupportsShouldProcess = $true)]
param (
    [Parameter(Mandatory = $true)]
    [ValidateNotNullOrEmpty()]
    [string]$FirstName,

    [Parameter(Mandatory = $true)]
    [ValidateNotNullOrEmpty()]
    [string]$LastName,

    [Parameter(Mandatory = $true)]
    [ValidatePattern('^[^@]+@[^@]+\.[^@]+$')]
    [string]$UserPrincipalName,

    [Parameter(Mandatory = $false)]
    [string]$Department,

    [Parameter(Mandatory = $false)]
    [string]$JobTitle,

    [Parameter(Mandatory = $false)]
    [string]$ManagerUPN,

    [Parameter(Mandatory = $true)]
    [ValidateNotNullOrEmpty()]
    [string]$LicenseSku,

    [Parameter(Mandatory = $false)]
    [string[]]$GroupIds = @(),

    [Parameter(Mandatory = $false)]
    [ValidateLength(2, 2)]
    [string]$UsageLocation = "US",

    [Parameter(Mandatory = $false)]
    [string]$TemporaryPassword,

    [Parameter(Mandatory = $false)]
    [string]$LogPath = ".\onboarding-log.json"
)

#region ── Helper Functions ────────────────────────────────────────────────────

function Write-Log {
    <#
    .SYNOPSIS
        Writes a timestamped message to the console and accumulates log entries
        for the final JSON output.
    #>
    param (
        [string]$Message,
        [ValidateSet("INFO", "WARN", "ERROR", "SUCCESS")]
        [string]$Level = "INFO"
    )
    $timestamp = Get-Date -Format "yyyy-MM-dd HH:mm:ss"
    $colors = @{ INFO = "Cyan"; WARN = "Yellow"; ERROR = "Red"; SUCCESS = "Green" }
    Write-Host "[$timestamp] [$Level] $Message" -ForegroundColor $colors[$Level]

    # Accumulate for log file
    $script:LogEntries += [PSCustomObject]@{
        Timestamp = $timestamp
        Level     = $Level
        Message   = $Message
    }
}

function New-RandomPassword {
    <#
    .SYNOPSIS
        Generates a random 16-character password meeting standard complexity requirements.
    #>
    $upper   = [char[]]'ABCDEFGHJKLMNPQRSTUVWXYZ'
    $lower   = [char[]]'abcdefghjkmnpqrstuvwxyz'
    $digits  = [char[]]'23456789'
    $special = [char[]]'!@#$%^&*'

    $password  = ($upper  | Get-Random -Count 3) -join ''
    $password += ($lower  | Get-Random -Count 6) -join ''
    $password += ($digits | Get-Random -Count 4) -join ''
    $password += ($special| Get-Random -Count 3) -join ''

    # Shuffle the result
    return (-join ($password.ToCharArray() | Get-Random -Count $password.Length))
}

function Test-RequiredModule {
    <#
    .SYNOPSIS
        Validates that a required PowerShell module is imported in the session.
    #>
    param ([string]$ModuleName)
    if (-not (Get-Module -Name $ModuleName -ErrorAction SilentlyContinue)) {
        Write-Log "Required module '$ModuleName' is not loaded. Run: Import-Module $ModuleName" -Level ERROR
        return $false
    }
    return $true
}

function Test-GraphConnection {
    <#
    .SYNOPSIS
        Validates an active Microsoft Graph session exists.
    #>
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

# Accumulator for structured log output
$script:LogEntries = @()

# Build the result object — updated throughout the script
$result = [PSCustomObject]@{
    UserPrincipalName = $UserPrincipalName
    DisplayName       = "$FirstName $LastName"
    ObjectId          = $null
    LicenseAssigned   = $false
    GroupsAdded       = @()
    ManagerSet        = $false
    MailboxEnabled    = $false
    TemporaryPassword = $null
    WhatIfMode        = $WhatIfPreference.ToString()
    CompletedAt       = $null
    Errors            = @()
}

Write-Log "=== New-UserOnboarding START ===" -Level INFO
Write-Log "Target UPN  : $UserPrincipalName" -Level INFO
Write-Log "Display Name: $FirstName $LastName" -Level INFO
Write-Log "Department  : $Department | Title: $JobTitle" -Level INFO
Write-Log "License SKU : $LicenseSku" -Level INFO
Write-Log "WhatIf Mode : $($WhatIfPreference)" -Level INFO

#endregion

#region ── Step 0: Pre-flight Validation ──────────────────────────────────────

Write-Log "--- Step 0: Pre-flight Validation ---" -Level INFO

$modulesOk = (Test-RequiredModule "Microsoft.Graph.Users") -and
             (Test-RequiredModule "Microsoft.Graph.Groups") -and
             (Test-RequiredModule "ExchangeOnlineManagement")

if (-not $modulesOk) {
    Write-Log "One or more required modules are missing. Exiting." -Level ERROR
    exit 1
}

if (-not (Test-GraphConnection)) {
    exit 1
}

# Generate a password if one was not supplied
if (-not $TemporaryPassword) {
    $TemporaryPassword = New-RandomPassword
    Write-Log "No password supplied. Generated temporary password." -Level INFO
}
$result.TemporaryPassword = $TemporaryPassword

#endregion

#region ── Step 1: Pre-Check — Does This User Already Exist? ─────────────────

Write-Log "--- Step 1: Pre-Check (Existing User) ---" -Level INFO

$existingUser = $null
try {
    $existingUser = Get-MgUser -Filter "userPrincipalName eq '$UserPrincipalName'" -ErrorAction SilentlyContinue
}
catch {
    Write-Log "Error querying Entra ID for existing user: $_" -Level ERROR
}

if ($existingUser) {
    Write-Log "User '$UserPrincipalName' already exists in Entra ID (ObjectId: $($existingUser.Id))." -Level WARN
    Write-Log "Skipping account creation. Use -Force (v2.0) to reconcile attributes." -Level WARN
    $result.ObjectId = $existingUser.Id
    # Early exit with partial result — do not re-create
    $result.CompletedAt = (Get-Date -Format "yyyy-MM-dd HH:mm:ss")
    $result | ConvertTo-Json | Add-Content -Path $LogPath
    return $result
}

Write-Log "No existing account found. Proceeding with provisioning." -Level INFO

#endregion

#region ── Step 2: Create Entra ID User Account ───────────────────────────────

Write-Log "--- Step 2: Create Entra ID User Account ---" -Level INFO

# Build mail nickname from first initial + last name, lowercase, no spaces
$mailNickname = ($FirstName.Substring(0,1) + $LastName).ToLower() -replace '\s', ''

$passwordProfile = @{
    ForceChangePasswordNextSignIn = $true
    Password                      = $TemporaryPassword
}

$newUserParams = @{
    DisplayName       = "$FirstName $LastName"
    GivenName         = $FirstName
    Surname           = $LastName
    UserPrincipalName = $UserPrincipalName
    MailNickName      = $mailNickname
    Department        = $Department
    JobTitle          = $JobTitle
    UsageLocation     = $UsageLocation
    AccountEnabled    = $true
    PasswordProfile   = $passwordProfile
}

if ($PSCmdlet.ShouldProcess($UserPrincipalName, "Create Entra ID user account")) {
    try {
        $newUser = New-MgUser @newUserParams
        $result.ObjectId = $newUser.Id
        Write-Log "User account created successfully. ObjectId: $($newUser.Id)" -Level SUCCESS
    }
    catch {
        $errMsg = "Failed to create user account: $_"
        Write-Log $errMsg -Level ERROR
        $result.Errors += $errMsg
        # Cannot continue without the user object
        $result.CompletedAt = (Get-Date -Format "yyyy-MM-dd HH:mm:ss")
        $result | ConvertTo-Json | Add-Content -Path $LogPath
        exit 1
    }
}
else {
    Write-Log "[WhatIf] Would create Entra ID user: $UserPrincipalName" -Level INFO
    $result.ObjectId = "whatif-placeholder-id"
}

#endregion

#region ── Step 3: Assign License ─────────────────────────────────────────────

Write-Log "--- Step 3: Assign License ($LicenseSku) ---" -Level INFO

try {
    # Resolve SKU part number to SkuId
    $sku = Get-MgSubscribedSku | Where-Object { $_.SkuPartNumber -eq $LicenseSku }

    if (-not $sku) {
        $errMsg = "License SKU '$LicenseSku' not found in tenant. Verify with Get-MgSubscribedSku."
        Write-Log $errMsg -Level ERROR
        $result.Errors += $errMsg
    }
    elseif ($sku.ConsumedUnits -ge $sku.PrepaidUnits.Enabled) {
        $errMsg = "License SKU '$LicenseSku' has no available seats ($($sku.ConsumedUnits)/$($sku.PrepaidUnits.Enabled) used)."
        Write-Log $errMsg -Level ERROR
        $result.Errors += $errMsg
    }
    else {
        $licenseAssignment = @{
            AddLicenses    = @(@{ SkuId = $sku.SkuId })
            RemoveLicenses = @()
        }

        if ($PSCmdlet.ShouldProcess($UserPrincipalName, "Assign license $LicenseSku ($($sku.SkuId))")) {
            Set-MgUserLicense -UserId $result.ObjectId -BodyParameter $licenseAssignment
            $result.LicenseAssigned = $true
            Write-Log "License '$LicenseSku' assigned successfully." -Level SUCCESS
        }
        else {
            Write-Log "[WhatIf] Would assign license: $LicenseSku (SkuId: $($sku.SkuId))" -Level INFO
        }
    }
}
catch {
    $errMsg = "Error during license assignment: $_"
    Write-Log $errMsg -Level ERROR
    $result.Errors += $errMsg
}

#endregion

#region ── Step 4: Add to Security / M365 Groups ──────────────────────────────

Write-Log "--- Step 4: Group Membership ---" -Level INFO

if ($GroupIds.Count -eq 0) {
    Write-Log "No group IDs specified. Skipping group assignment." -Level INFO
}

foreach ($groupId in $GroupIds) {
    try {
        $group = Get-MgGroup -GroupId $groupId -ErrorAction Stop
        Write-Log "Adding user to group: '$($group.DisplayName)' ($groupId)" -Level INFO

        if ($PSCmdlet.ShouldProcess($UserPrincipalName, "Add to group '$($group.DisplayName)'")) {
            $memberRef = @{ "@odata.id" = "https://graph.microsoft.com/v1.0/directoryObjects/$($result.ObjectId)" }
            New-MgGroupMember -GroupId $groupId -BodyParameter $memberRef
            $result.GroupsAdded += $group.DisplayName
            Write-Log "Added to group '$($group.DisplayName)' successfully." -Level SUCCESS
        }
        else {
            Write-Log "[WhatIf] Would add to group: '$($group.DisplayName)'" -Level INFO
        }
    }
    catch {
        $errMsg = "Failed to add user to group '$groupId': $_"
        Write-Log $errMsg -Level ERROR
        $result.Errors += $errMsg
        # Non-fatal: continue with remaining groups
    }
}

#endregion

#region ── Step 5: Set Manager ────────────────────────────────────────────────

Write-Log "--- Step 5: Set Manager ---" -Level INFO

if (-not $ManagerUPN) {
    Write-Log "No manager UPN specified. Skipping manager assignment." -Level INFO
}
else {
    try {
        $manager = Get-MgUser -Filter "userPrincipalName eq '$ManagerUPN'" -ErrorAction Stop

        if (-not $manager) {
            $errMsg = "Manager UPN '$ManagerUPN' not found in Entra ID."
            Write-Log $errMsg -Level WARN
            $result.Errors += $errMsg
        }
        else {
            $managerRef = @{ "@odata.id" = "https://graph.microsoft.com/v1.0/users/$($manager.Id)" }

            if ($PSCmdlet.ShouldProcess($UserPrincipalName, "Set manager to $ManagerUPN")) {
                Set-MgUserManagerByRef -UserId $result.ObjectId -BodyParameter $managerRef
                $result.ManagerSet = $true
                Write-Log "Manager set to '$ManagerUPN' ($($manager.Id))." -Level SUCCESS
            }
            else {
                Write-Log "[WhatIf] Would set manager to: $ManagerUPN" -Level INFO
            }
        }
    }
    catch {
        $errMsg = "Error setting manager '$ManagerUPN': $_"
        Write-Log $errMsg -Level ERROR
        $result.Errors += $errMsg
    }
}

#endregion

#region ── Step 6: Verify Exchange Online Mailbox ─────────────────────────────

Write-Log "--- Step 6: Verify Exchange Online Mailbox ---" -Level INFO

# Exchange Online automatically provisions a mailbox when a license with Exchange
# is assigned. This step confirms the mailbox is visible and applies a display
# name match. Allow up to 5 minutes for propagation.

$maxWaitSeconds = 300
$pollInterval   = 30
$elapsed        = 0
$mailboxReady   = $false

if ($PSCmdlet.ShouldProcess($UserPrincipalName, "Wait for and verify Exchange Online mailbox")) {
    Write-Log "Polling for mailbox provisioning (max $maxWaitSeconds seconds)..." -Level INFO

    while ($elapsed -lt $maxWaitSeconds) {
        try {
            $mbx = Get-EXOMailbox -Identity $UserPrincipalName -ErrorAction SilentlyContinue
            if ($mbx) {
                $mailboxReady = $true
                Write-Log "Mailbox confirmed: $($mbx.PrimarySmtpAddress) | Type: $($mbx.RecipientTypeDetails)" -Level SUCCESS
                break
            }
        }
        catch {
            # Mailbox not yet visible — continue polling
        }

        Write-Log "Mailbox not yet available. Waiting $pollInterval seconds... ($elapsed/$maxWaitSeconds)" -Level INFO
        Start-Sleep -Seconds $pollInterval
        $elapsed += $pollInterval
    }

    if (-not $mailboxReady) {
        $errMsg = "Mailbox for '$UserPrincipalName' was not confirmed within $maxWaitSeconds seconds. " +
                  "It may still be provisioning. Verify manually in Exchange Admin Center."
        Write-Log $errMsg -Level WARN
        $result.Errors += $errMsg
    }
    else {
        $result.MailboxEnabled = $true
    }
}
else {
    Write-Log "[WhatIf] Would poll Exchange Online for mailbox readiness." -Level INFO
}

#endregion

#region ── Step 7: Output & Logging ───────────────────────────────────────────

$result.CompletedAt = (Get-Date -Format "yyyy-MM-dd HH:mm:ss")

Write-Log "=== New-UserOnboarding COMPLETE ===" -Level SUCCESS
Write-Log "UPN             : $($result.UserPrincipalName)" -Level SUCCESS
Write-Log "ObjectId        : $($result.ObjectId)" -Level SUCCESS
Write-Log "License Assigned: $($result.LicenseAssigned)" -Level SUCCESS
Write-Log "Groups Added    : $($result.GroupsAdded -join ', ')" -Level SUCCESS
Write-Log "Manager Set     : $($result.ManagerSet)" -Level SUCCESS
Write-Log "Mailbox Enabled : $($result.MailboxEnabled)" -Level SUCCESS

if ($result.Errors.Count -gt 0) {
    Write-Log "Completed with $($result.Errors.Count) non-fatal error(s). Review output object." -Level WARN
}

# Append structured JSON log entry
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

# Return the structured result object for pipeline use
return $result

#endregion
