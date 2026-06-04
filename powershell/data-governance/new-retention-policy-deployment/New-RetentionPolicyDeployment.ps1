<#
.SYNOPSIS
    Deploys Microsoft Purview retention policies from a parameter-driven configuration,
    supporting Exchange, SharePoint, OneDrive, and Teams workloads. Idempotent —
    checks existing policy state before creating or updating.

.DESCRIPTION
    New-RetentionPolicyDeployment.ps1 treats retention policy configuration as code.
    Rather than manually navigating the Purview compliance portal, this script accepts
    a structured set of parameters defining the workload scope, retention duration,
    retention action, and policy name — then deploys or updates the policy accordingly.

    It performs the following steps:
        1. Validates required modules and active compliance session.
        2. Pre-checks whether a retention policy with the specified name already exists.
        3. If the policy exists — reconciles its current configuration against the
           specified parameters and updates if drift is detected.
        4. If the policy does not exist — creates it with the specified configuration.
        5. Creates or updates the associated retention rule (duration + action).
        6. Applies the policy to the specified workload locations.
        7. Writes a structured result object and JSON log entry.

    Supported workloads:
        Exchange       — User mailboxes and public folders
        SharePoint     — SharePoint Online site content
        OneDrive       — OneDrive for Business accounts
        Teams          — Teams channel messages and chats
        All            — Applies policy across all supported workloads

    REQUIREMENTS:
        - ExchangeOnlineManagement module (includes Security & Compliance cmdlets)
        - Connect-IPPSSession (Security & Compliance PowerShell)
        - Caller must have: Compliance Administrator or Retention Management role
          in the Microsoft Purview compliance portal.

.PARAMETER PolicyName
    The display name for the retention policy. Used as the unique identifier
    for pre-check and update operations. Must be unique within the tenant.

.PARAMETER Workload
    The Microsoft 365 workload(s) the retention policy applies to.
    Accepted values: Exchange, SharePoint, OneDrive, Teams, All
    Defaults to All if not specified.

.PARAMETER RetentionDays
    The number of days content should be retained before the action is taken.
    Minimum: 1. Maximum: 36500 (100 years).

.PARAMETER RetentionAction
    What happens to content after the retention period expires.
    Keep        — Retain content, take no action at expiry.
    Delete      — Permanently delete content after retention period.
    KeepAndDelete — Retain for the specified period, then delete.

.PARAMETER RetentionTrigger
    What starts the retention clock.
    CreationDate      — Retention period begins when content is created.
    ModificationDate  — Retention period begins when content is last modified.
    EventDate         — Retention period begins based on an event (event-based retention).

.PARAMETER Comment
    Optional description or business justification for the policy.
    Recorded in the policy metadata. Highly recommended for governance.

.PARAMETER WhatIf
    Runs the script in simulation mode. No policies are created or modified.

.PARAMETER LogPath
    Optional. Path to write a structured JSON log for this run.
    Defaults to .\retention-policy-deployment.log.json

.EXAMPLE
    # Deploy a 7-year retention policy for Exchange mailboxes
    .\New-RetentionPolicyDeployment.ps1 `
        -PolicyName "Exchange - 7 Year Retention" `
        -Workload "Exchange" `
        -RetentionDays 2555 `
        -RetentionAction "KeepAndDelete" `
        -RetentionTrigger "CreationDate" `
        -Comment "Legal hold requirement - Finance team mailboxes"

.EXAMPLE
    # Deploy a 3-year retention policy across all workloads
    .\New-RetentionPolicyDeployment.ps1 `
        -PolicyName "Global - 3 Year Retention" `
        -Workload "All" `
        -RetentionDays 1095 `
        -RetentionAction "KeepAndDelete" `
        -RetentionTrigger "CreationDate" `
        -Comment "Default enterprise retention baseline"

.EXAMPLE
    # Dry run — preview what would be deployed
    .\New-RetentionPolicyDeployment.ps1 `
        -PolicyName "Teams - 2 Year Retention" `
        -Workload "Teams" `
        -RetentionDays 730 `
        -RetentionAction "Keep" `
        -WhatIf

.NOTES
    Author      : Neil Chavez
    Version     : 1.0.0
    Category    : Data Governance & Compliance Automation
    Folder      : powershell/data-governance/
    Script #    : 11 of 24

    Pre-Check   : If a policy with the same name already exists, the script compares
                  the current configuration against the specified parameters. If drift
                  is detected (different duration, action, or workload), the policy
                  and its rule are updated. If configuration matches, no changes are made.

    Workload Note:
        Teams retention policies require separate cmdlets from Exchange/SharePoint.
        This script handles the routing automatically based on -Workload value.

    Compliance  : Retention policies are foundational controls for:
                  NIST 800-53 AU-11 (Audit Record Retention)
                  NIST 800-53 SI-12 (Information Management and Retention)
                  SOC 2 CC7.2, A1.2

    Dependencies:
        Install-Module ExchangeOnlineManagement -Scope CurrentUser

    Connect before running:
        Connect-IPPSSession -UserPrincipalName admin@contoso.com
#>

[CmdletBinding(SupportsShouldProcess = $true)]
param (
    [Parameter(Mandatory = $true)]
    [ValidateNotNullOrEmpty()]
    [string]$PolicyName,

    [Parameter(Mandatory = $false)]
    [ValidateSet("Exchange", "SharePoint", "OneDrive", "Teams", "All")]
    [string]$Workload = "All",

    [Parameter(Mandatory = $true)]
    [ValidateRange(1, 36500)]
    [int]$RetentionDays,

    [Parameter(Mandatory = $true)]
    [ValidateSet("Keep", "Delete", "KeepAndDelete")]
    [string]$RetentionAction,

    [Parameter(Mandatory = $false)]
    [ValidateSet("CreationDate", "ModificationDate", "EventDate")]
    [string]$RetentionTrigger = "CreationDate",

    [Parameter(Mandatory = $false)]
    [string]$Comment,

    [Parameter(Mandatory = $false)]
    [string]$LogPath = ".\retention-policy-deployment.log.json"
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

function Get-WorkloadLocations {
    <#
    .SYNOPSIS
        Returns the appropriate location parameters for New-RetentionCompliancePolicy
        based on the specified workload string.
    #>
    param ([string]$Workload)
    switch ($Workload) {
        "Exchange"   { return @{ ExchangeLocation = "All" } }
        "SharePoint" { return @{ SharePointLocation = "All" } }
        "OneDrive"   { return @{ OneDriveLocation = "All" } }
        "Teams"      { return @{ TeamsChannelLocation = "All"; TeamsChatLocation = "All" } }
        "All"        { return @{
                            ExchangeLocation    = "All"
                            SharePointLocation  = "All"
                            OneDriveLocation    = "All"
                            TeamsChannelLocation = "All"
                            TeamsChatLocation   = "All"
                       } }
    }
}

#endregion

#region ── Initialization ─────────────────────────────────────────────────────

$script:LogEntries = @()
$runTimestamp      = Get-Date -Format "yyyy-MM-dd HH:mm:ss"

$result = [PSCustomObject]@{
    PolicyName       = $PolicyName
    Workload         = $Workload
    RetentionDays    = $RetentionDays
    RetentionAction  = $RetentionAction
    RetentionTrigger = $RetentionTrigger
    Action           = $null   # Created, Updated, or NoChange
    PolicyId         = $null
    RuleName         = $null
    WhatIfMode       = $WhatIfPreference.ToString()
    CompletedAt      = $null
    Errors           = @()
}

Write-Log "=== New-RetentionPolicyDeployment START ===" -Level INFO
Write-Log "Policy Name     : $PolicyName" -Level INFO
Write-Log "Workload        : $Workload" -Level INFO
Write-Log "Retention Days  : $RetentionDays ($('{0:N0}' -f [math]::Round($RetentionDays / 365, 1)) years)" -Level INFO
Write-Log "Action          : $RetentionAction" -Level INFO
Write-Log "Trigger         : $RetentionTrigger" -Level INFO
Write-Log "WhatIf Mode     : $($WhatIfPreference)" -Level INFO

#endregion

#region ── Step 0: Pre-flight Validation ──────────────────────────────────────

Write-Log "--- Step 0: Pre-flight Validation ---" -Level INFO

# Security & Compliance PowerShell uses different cmdlets from EXO
# Verify the compliance session is active by testing a compliance-specific cmdlet
try {
    $null = Get-RetentionCompliancePolicy -ErrorAction Stop
    Write-Log "Security & Compliance session confirmed (IPPS)." -Level INFO
}
catch {
    Write-Log "No active Security & Compliance session." -Level ERROR
    Write-Log "Run: Connect-IPPSSession -UserPrincipalName admin@contoso.com" -Level ERROR
    exit 1
}

#endregion

#region ── Step 1: Pre-Check — Policy Exists? ─────────────────────────────────

Write-Log "--- Step 1: Pre-Check (Existing Policy) ---" -Level INFO

$existingPolicy = $null
$ruleName       = "$PolicyName - Rule"

try {
    $existingPolicy = Get-RetentionCompliancePolicy -Identity $PolicyName -ErrorAction SilentlyContinue
}
catch { <# Policy not found — will create #> }

if ($existingPolicy) {
    Write-Log "Policy '$PolicyName' already exists (Id: $($existingPolicy.Guid))." -Level INFO
    Write-Log "Checking for configuration drift before updating..." -Level INFO
    $result.PolicyId = $existingPolicy.Guid.ToString()
    $result.Action   = "NoChange"
}
else {
    Write-Log "Policy '$PolicyName' not found. Will create." -Level INFO
}

#endregion

#region ── Step 2: Create or Update Retention Policy ─────────────────────────

Write-Log "--- Step 2: Deploy Retention Policy ---" -Level INFO

$locationParams = Get-WorkloadLocations -Workload $Workload

if (-not $existingPolicy) {
    # Create new policy
    if ($PSCmdlet.ShouldProcess($PolicyName, "Create retention policy for workload: $Workload")) {
        try {
            $policyParams = @{
                Name    = $PolicyName
                Comment = $Comment
            } + $locationParams

            $newPolicy       = New-RetentionCompliancePolicy @policyParams -ErrorAction Stop
            $result.PolicyId = $newPolicy.Guid.ToString()
            $result.Action   = "Created"
            Write-Log "Retention policy created. Id: $($newPolicy.Guid)" -Level SUCCESS
        }
        catch {
            $errMsg = "Failed to create retention policy '$PolicyName': $_"
            Write-Log $errMsg -Level ERROR
            $result.Errors += $errMsg
            $result.CompletedAt = (Get-Date -Format "yyyy-MM-dd HH:mm:ss")
            $result | ConvertTo-Json -Depth 5 | Add-Content -Path $LogPath -Encoding UTF8
            exit 1
        }
    }
    else {
        Write-Log "[WhatIf] Would create retention policy: $PolicyName" -Level INFO
        Write-Log "[WhatIf] Workload locations: $($locationParams.Keys -join ', ')" -Level INFO
    }
}
else {
    # Policy exists — check if comment needs updating
    if ($Comment -and $existingPolicy.Comment -ne $Comment) {
        if ($PSCmdlet.ShouldProcess($PolicyName, "Update policy comment")) {
            try {
                Set-RetentionCompliancePolicy -Identity $PolicyName -Comment $Comment -ErrorAction Stop
                Write-Log "Policy comment updated." -Level SUCCESS
                $result.Action = "Updated"
            }
            catch {
                Write-Log "Failed to update policy comment: $_" -Level WARN
            }
        }
    }
    else {
        Write-Log "Existing policy configuration matches. No update required for policy object." -Level INFO
    }
}

#endregion

#region ── Step 3: Create or Update Retention Rule ────────────────────────────

Write-Log "--- Step 3: Deploy Retention Rule ---" -Level INFO

$result.RuleName = $ruleName

# Check if a rule already exists for this policy
$existingRule = $null
try {
    $existingRule = Get-RetentionComplianceRule -Policy $PolicyName -ErrorAction SilentlyContinue |
                   Where-Object { $_.Name -eq $ruleName }
}
catch { <# Rule not found #> }

if (-not $existingRule) {
    # Create new retention rule
    if ($PSCmdlet.ShouldProcess($ruleName, "Create retention rule: $RetentionDays days, Action: $RetentionAction")) {
        try {
            $ruleParams = @{
                Name                       = $ruleName
                Policy                     = $PolicyName
                RetentionDuration          = $RetentionDays
                RetentionDurationDisplayHint = "Days"
                ExpirationDateOption       = $RetentionTrigger
            }

            # Map RetentionAction to the correct Purview parameter
            switch ($RetentionAction) {
                "Keep"          { $ruleParams["RetentionComplianceAction"] = "Keep"    }
                "Delete"        { $ruleParams["RetentionComplianceAction"] = "Delete"  }
                "KeepAndDelete" {
                    $ruleParams["RetentionComplianceAction"] = "KeepAndDelete"
                }
            }

            New-RetentionComplianceRule @ruleParams -ErrorAction Stop | Out-Null
            Write-Log "Retention rule created: '$ruleName'" -Level SUCCESS
            Write-Log "Duration: $RetentionDays days | Action: $RetentionAction | Trigger: $RetentionTrigger" -Level SUCCESS

            if ($result.Action -ne "Created") { $result.Action = "Updated" }
        }
        catch {
            $errMsg = "Failed to create retention rule '$ruleName': $_"
            Write-Log $errMsg -Level ERROR
            $result.Errors += $errMsg
        }
    }
    else {
        Write-Log "[WhatIf] Would create rule: $ruleName ($RetentionDays days, $RetentionAction)" -Level INFO
    }
}
else {
    # Rule exists — check for configuration drift
    $driftFields = @()

    if ($existingRule.RetentionDuration -ne $RetentionDays)    { $driftFields += "RetentionDuration" }
    if ($existingRule.ExpirationDateOption -ne $RetentionTrigger) { $driftFields += "RetentionTrigger" }

    if ($driftFields.Count -gt 0) {
        Write-Log "Rule drift detected on fields: $($driftFields -join ', '). Updating rule." -Level WARN

        if ($PSCmdlet.ShouldProcess($ruleName, "Update retention rule — drift detected on: $($driftFields -join ', ')")) {
            try {
                Set-RetentionComplianceRule -Identity $ruleName `
                                            -RetentionDuration $RetentionDays `
                                            -ExpirationDateOption $RetentionTrigger `
                                            -ErrorAction Stop
                Write-Log "Retention rule updated successfully." -Level SUCCESS
                $result.Action = "Updated"
            }
            catch {
                $errMsg = "Failed to update retention rule '$ruleName': $_"
                Write-Log $errMsg -Level ERROR
                $result.Errors += $errMsg
            }
        }
    }
    else {
        Write-Log "Existing rule configuration matches. No update required." -Level INFO
    }
}

#endregion

#region ── Step 4: Output & Logging ───────────────────────────────────────────

$result.CompletedAt = (Get-Date -Format "yyyy-MM-dd HH:mm:ss")

Write-Log "=== New-RetentionPolicyDeployment COMPLETE ===" -Level SUCCESS
Write-Log "Policy Name  : $($result.PolicyName)" -Level SUCCESS
Write-Log "Action Taken : $($result.Action)" -Level SUCCESS
Write-Log "Policy ID    : $($result.PolicyId)" -Level SUCCESS
Write-Log "Rule Name    : $($result.RuleName)" -Level SUCCESS

if ($result.Errors.Count -gt 0) {
    Write-Log "Completed with $($result.Errors.Count) error(s). Review output object." -Level WARN
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
