# New-SharedMailboxProvisioning.ps1
# Author   : Neil Chavez
# Version  : 1.0.0
# Category : Messaging Infrastructure Ops
# Folder   : powershell/messaging-ops/
# Script # : 09 of 24
#
# PURPOSE
# -------
# Provisions a shared mailbox in Exchange Online using a standardized, repeatable
# process. Enforces consistent naming, permission assignment, auto-mapping behavior,
# Send-As rights, and retention policy tagging from a single parameterized call.
#
# Eliminates the inconsistency introduced by manual provisioning through the
# Exchange Admin Center, where permission types, auto-mapping, and policy
# application are often missed or applied incorrectly.
#
# What this script does:
#   1. Pre-checks whether the mailbox already exists (re-run safe).
#   2. Creates the shared mailbox with a standardized display name and alias.
#   3. Assigns FullAccess permissions to specified members with auto-mapping.
#   4. Grants SendAs rights to specified members.
#   5. Optionally grants SendOnBehalf rights.
#   6. Applies a specified retention policy tag.
#   7. Hides the mailbox from the Global Address List (optional).
#   8. Writes a structured result object and JSON log entry.
#
# REQUIREMENTS
# ------------
#   - ExchangeOnlineManagement module (Connect-ExchangeOnline)
#   - Caller must have: Exchange Administrator role
#
# USAGE
# -----
#   # Standard shared mailbox — FullAccess + SendAs for two members
#   .\New-SharedMailboxProvisioning.ps1 `
#       -DisplayName "IT Help Desk" `
#       -EmailAddress "helpdesk@contoso.com" `
#       -FullAccessMembers @("jdoe@contoso.com", "bsmith@contoso.com") `
#       -SendAsMembers @("jdoe@contoso.com", "bsmith@contoso.com") `
#       -RetentionPolicy "Default 2 Year"
#
#   # Dry run
#   .\New-SharedMailboxProvisioning.ps1 `
#       -DisplayName "Finance Team" `
#       -EmailAddress "finance@contoso.com" `
#       -FullAccessMembers @("jdoe@contoso.com") `
#       -WhatIf
#
#   # Batch provisioning from CSV
#   # CSV headers: DisplayName, EmailAddress, FullAccessMembers, SendAsMembers, RetentionPolicy
#   # FullAccessMembers and SendAsMembers should be semicolon-separated UPNs
#   Import-Csv .\shared-mailboxes.csv | ForEach-Object {
#       $fullAccess = $_.FullAccessMembers -split ";" | Where-Object { $_ }
#       $sendAs     = $_.SendAsMembers     -split ";" | Where-Object { $_ }
#       .\New-SharedMailboxProvisioning.ps1 `
#           -DisplayName $_.DisplayName `
#           -EmailAddress $_.EmailAddress `
#           -FullAccessMembers $fullAccess `
#           -SendAsMembers $sendAs `
#           -RetentionPolicy $_.RetentionPolicy
#   }

[CmdletBinding(SupportsShouldProcess = $true)]
param (
    # Display name shown in the Global Address List
    [Parameter(Mandatory = $true)]
    [ValidateNotNullOrEmpty()]
    [string]$DisplayName,

    # Primary SMTP address for the shared mailbox
    [Parameter(Mandatory = $true)]
    [ValidatePattern('^[^@]+@[^@]+\.[^@]+$')]
    [string]$EmailAddress,

    # Users granted FullAccess (read/manage mailbox contents) with auto-mapping
    [Parameter(Mandatory = $false)]
    [string[]]$FullAccessMembers = @(),

    # Users granted SendAs rights (send email appearing to come from the mailbox)
    [Parameter(Mandatory = $false)]
    [string[]]$SendAsMembers = @(),

    # Users granted SendOnBehalf rights (send on behalf of the mailbox)
    [Parameter(Mandatory = $false)]
    [string[]]$SendOnBehalfMembers = @(),

    # Retention policy to apply to the mailbox — must exist in the tenant
    [Parameter(Mandatory = $false)]
    [string]$RetentionPolicy,

    # When set, hides the shared mailbox from the Global Address List
    [Parameter(Mandatory = $false)]
    [switch]$HideFromGAL,

    # Output path for structured JSON log
    [Parameter(Mandatory = $false)]
    [string]$LogPath = ".\shared-mailbox-provisioning.log.json"
)

#region ── Helper Functions ────────────────────────────────────────────────────

function Write-Log {
    param (
        [string]$Message,
        [ValidateSet("INFO", "WARN", "ERROR", "SUCCESS")]
        [string]$Level = "INFO"
    )
    $timestamp = Get-Date -Format "yyyy-MM-dd HH:mm:ss"
    $colors    = @{ INFO = "Cyan"; WARN = "Yellow"; ERROR = "Red"; SUCCESS = "Green" }
    Write-Host "[$timestamp] [$Level] $Message" -ForegroundColor $colors[$Level]
    $script:LogEntries += [PSCustomObject]@{
        Timestamp = $timestamp
        Level     = $Level
        Message   = $Message
    }
}

#endregion

#region ── Initialization ─────────────────────────────────────────────────────

$script:LogEntries = @()
$runTimestamp      = Get-Date -Format "yyyy-MM-dd HH:mm:ss"

$result = [PSCustomObject]@{
    DisplayName          = $DisplayName
    EmailAddress         = $EmailAddress
    MailboxCreated       = $false
    FullAccessAssigned   = @()
    SendAsAssigned       = @()
    SendOnBehalfAssigned = @()
    RetentionApplied     = $false
    HiddenFromGAL        = $false
    WhatIfMode           = $WhatIfPreference.ToString()
    CompletedAt          = $null
    Errors               = @()
}

Write-Log "=== New-SharedMailboxProvisioning START ===" -Level INFO
Write-Log "Display Name : $DisplayName" -Level INFO
Write-Log "Email Address: $EmailAddress" -Level INFO
Write-Log "FullAccess   : $($FullAccessMembers.Count) member(s)" -Level INFO
Write-Log "SendAs       : $($SendAsMembers.Count) member(s)" -Level INFO
Write-Log "WhatIf Mode  : $($WhatIfPreference)" -Level INFO

#endregion

#region ── Step 0: Pre-flight Validation ──────────────────────────────────────

Write-Log "--- Step 0: Pre-flight Validation ---" -Level INFO

if (-not (Get-Module -Name "ExchangeOnlineManagement" -ErrorAction SilentlyContinue)) {
    Write-Log "ExchangeOnlineManagement module not loaded." -Level ERROR
    exit 1
}

try {
    $null = Get-EXOMailbox -ResultSize 1 -ErrorAction Stop
    Write-Log "Exchange Online session confirmed." -Level INFO
}
catch {
    Write-Log "No active Exchange Online session. Run Connect-ExchangeOnline first." -Level ERROR
    exit 1
}

#endregion

#region ── Step 1: Pre-Check — Does This Mailbox Already Exist? ───────────────

Write-Log "--- Step 1: Pre-Check (Existing Mailbox) ---" -Level INFO

$existingMailbox = $null
try {
    $existingMailbox = Get-EXOMailbox -Identity $EmailAddress -ErrorAction SilentlyContinue
}
catch { <# Not found — expected on first run #> }

if ($existingMailbox) {
    Write-Log "Shared mailbox '$EmailAddress' already exists. Skipping creation." -Level WARN
    Write-Log "Proceeding to verify and reconcile permissions." -Level INFO
    $result.MailboxCreated = $false
}

#endregion

#region ── Step 2: Create Shared Mailbox ──────────────────────────────────────

Write-Log "--- Step 2: Create Shared Mailbox ---" -Level INFO

# Derive a clean alias from the email address local part
$alias = ($EmailAddress -split '@')[0] -replace '[^a-zA-Z0-9]', ''

if (-not $existingMailbox) {
    if ($PSCmdlet.ShouldProcess($EmailAddress, "Create shared mailbox '$DisplayName'")) {
        try {
            New-Mailbox -Shared `
                        -Name $DisplayName `
                        -Alias $alias `
                        -PrimarySmtpAddress $EmailAddress `
                        -ErrorAction Stop | Out-Null

            $result.MailboxCreated = $true
            Write-Log "Shared mailbox created: $EmailAddress (Alias: $alias)" -Level SUCCESS

            # Brief pause to allow Exchange Online provisioning to complete
            Start-Sleep -Seconds 10
        }
        catch {
            $errMsg = "Failed to create shared mailbox '$EmailAddress': $_"
            Write-Log $errMsg -Level ERROR
            $result.Errors += $errMsg
            $result.CompletedAt = (Get-Date -Format "yyyy-MM-dd HH:mm:ss")
            $result | ConvertTo-Json -Depth 5 | Add-Content -Path $LogPath -Encoding UTF8
            exit 1
        }
    }
    else {
        Write-Log "[WhatIf] Would create shared mailbox: $EmailAddress" -Level INFO
    }
}

#endregion

#region ── Step 3: Assign FullAccess Permissions ──────────────────────────────

Write-Log "--- Step 3: Assign FullAccess Permissions ---" -Level INFO

if ($FullAccessMembers.Count -eq 0) {
    Write-Log "No FullAccess members specified. Skipping." -Level INFO
}

foreach ($member in $FullAccessMembers) {
    if ($PSCmdlet.ShouldProcess($EmailAddress, "Grant FullAccess to '$member'")) {
        try {
            Add-MailboxPermission -Identity $EmailAddress `
                                  -User $member `
                                  -AccessRights FullAccess `
                                  -InheritanceType All `
                                  -AutoMapping $true `
                                  -ErrorAction Stop | Out-Null

            $result.FullAccessAssigned += $member
            Write-Log "FullAccess granted to: $member (AutoMapping: enabled)" -Level SUCCESS
        }
        catch {
            $errMsg = "Failed to grant FullAccess to '$member': $_"
            Write-Log $errMsg -Level ERROR
            $result.Errors += $errMsg
            # Non-fatal — continue with remaining members
        }
    }
    else {
        Write-Log "[WhatIf] Would grant FullAccess to: $member" -Level INFO
    }
}

#endregion

#region ── Step 4: Assign SendAs Permissions ──────────────────────────────────

Write-Log "--- Step 4: Assign SendAs Permissions ---" -Level INFO

if ($SendAsMembers.Count -eq 0) {
    Write-Log "No SendAs members specified. Skipping." -Level INFO
}

foreach ($member in $SendAsMembers) {
    if ($PSCmdlet.ShouldProcess($EmailAddress, "Grant SendAs to '$member'")) {
        try {
            Add-RecipientPermission -Identity $EmailAddress `
                                    -Trustee $member `
                                    -AccessRights SendAs `
                                    -Confirm:$false `
                                    -ErrorAction Stop | Out-Null

            $result.SendAsAssigned += $member
            Write-Log "SendAs granted to: $member" -Level SUCCESS
        }
        catch {
            $errMsg = "Failed to grant SendAs to '$member': $_"
            Write-Log $errMsg -Level ERROR
            $result.Errors += $errMsg
        }
    }
    else {
        Write-Log "[WhatIf] Would grant SendAs to: $member" -Level INFO
    }
}

#endregion

#region ── Step 5: Assign SendOnBehalf Permissions ────────────────────────────

Write-Log "--- Step 5: Assign SendOnBehalf Permissions ---" -Level INFO

if ($SendOnBehalfMembers.Count -eq 0) {
    Write-Log "No SendOnBehalf members specified. Skipping." -Level INFO
}
else {
    if ($PSCmdlet.ShouldProcess($EmailAddress, "Grant SendOnBehalf to $($SendOnBehalfMembers.Count) member(s)")) {
        try {
            # SendOnBehalf is set directly on the mailbox object
            Set-Mailbox -Identity $EmailAddress `
                        -GrantSendOnBehalfTo $SendOnBehalfMembers `
                        -ErrorAction Stop

            $result.SendOnBehalfAssigned = $SendOnBehalfMembers
            Write-Log "SendOnBehalf granted to: $($SendOnBehalfMembers -join ', ')" -Level SUCCESS
        }
        catch {
            $errMsg = "Failed to assign SendOnBehalf permissions: $_"
            Write-Log $errMsg -Level ERROR
            $result.Errors += $errMsg
        }
    }
    else {
        Write-Log "[WhatIf] Would grant SendOnBehalf to: $($SendOnBehalfMembers -join ', ')" -Level INFO
    }
}

#endregion

#region ── Step 6: Apply Retention Policy ─────────────────────────────────────

Write-Log "--- Step 6: Apply Retention Policy ---" -Level INFO

if (-not $RetentionPolicy) {
    Write-Log "No retention policy specified. Skipping." -Level INFO
}
else {
    if ($PSCmdlet.ShouldProcess($EmailAddress, "Apply retention policy '$RetentionPolicy'")) {
        try {
            Set-Mailbox -Identity $EmailAddress `
                        -RetentionPolicy $RetentionPolicy `
                        -ErrorAction Stop

            $result.RetentionApplied = $true
            Write-Log "Retention policy '$RetentionPolicy' applied successfully." -Level SUCCESS
        }
        catch {
            $errMsg = "Failed to apply retention policy '$RetentionPolicy': $_"
            Write-Log $errMsg -Level ERROR
            $result.Errors += $errMsg
            # Non-fatal — mailbox is functional; retention can be applied later
        }
    }
    else {
        Write-Log "[WhatIf] Would apply retention policy: $RetentionPolicy" -Level INFO
    }
}

#endregion

#region ── Step 7: Hide from Global Address List (Optional) ───────────────────

Write-Log "--- Step 7: GAL Visibility ---" -Level INFO

if (-not $HideFromGAL) {
    Write-Log "HideFromGAL not specified. Mailbox will be visible in the GAL." -Level INFO
}
else {
    if ($PSCmdlet.ShouldProcess($EmailAddress, "Hide mailbox from Global Address List")) {
        try {
            Set-Mailbox -Identity $EmailAddress -HiddenFromAddressListsEnabled $true -ErrorAction Stop
            $result.HiddenFromGAL = $true
            Write-Log "Mailbox hidden from Global Address List." -Level SUCCESS
        }
        catch {
            $errMsg = "Failed to hide mailbox from GAL: $_"
            Write-Log $errMsg -Level ERROR
            $result.Errors += $errMsg
        }
    }
    else {
        Write-Log "[WhatIf] Would hide mailbox from Global Address List." -Level INFO
    }
}

#endregion

#region ── Step 8: Output & Logging ───────────────────────────────────────────

$result.CompletedAt = (Get-Date -Format "yyyy-MM-dd HH:mm:ss")

Write-Log "=== New-SharedMailboxProvisioning COMPLETE ===" -Level SUCCESS
Write-Log "Mailbox Created      : $($result.MailboxCreated)" -Level SUCCESS
Write-Log "FullAccess Assigned  : $($result.FullAccessAssigned -join ', ')" -Level SUCCESS
Write-Log "SendAs Assigned      : $($result.SendAsAssigned -join ', ')" -Level SUCCESS
Write-Log "SendOnBehalf Assigned: $($result.SendOnBehalfAssigned -join ', ')" -Level SUCCESS
Write-Log "Retention Applied    : $($result.RetentionApplied)" -Level SUCCESS
Write-Log "Hidden from GAL      : $($result.HiddenFromGAL)" -Level SUCCESS

if ($result.Errors.Count -gt 0) {
    Write-Log "Completed with $($result.Errors.Count) non-fatal error(s). Review output object." -Level WARN
}

$logEntry = [PSCustomObject]@{
    RunAt      = $runTimestamp
    Result     = $result
    LogEntries = $script:LogEntries
}

try {
    $logEntry | ConvertTo-Json -Depth 5 | Add-Content -Path $LogPath -Encoding UTF8
    Write-Log "Log written to: $LogPath" -Level INFO
}
catch {
    Write-Log "Warning: Could not write log file: $_" -Level WARN
}

return $result

#endregion
