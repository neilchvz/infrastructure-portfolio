# Get-OrphanedAccounts.ps1
# Author   : Neil Chavez
# Version  : 1.0.0
# Category : Identity Lifecycle Automation
# Folder   : powershell/identity-lifecycle/
# Script # : 04 of 24
#
# PURPOSE
# -------
# Detects orphaned Entra ID user accounts — accounts that pose an access control
# or licensing risk due to prolonged inactivity, missing manager, or no license
# assignment. Produces a structured, tiered report suitable for remediation review,
# security audits, or feeding into downstream disable/offboarding workflows.
#
# An account is flagged as orphaned when any of the following conditions are met:
#
#   Tier 1 — Immediate Risk (disable recommended):
#     - No sign-in activity within the last $StaleThresholdDays (default: 90 days)
#       AND the account is currently enabled
#     - Account is enabled but has no assigned licenses (unlicensed active account)
#
#   Tier 2 — Review Required:
#     - Sign-in activity between $StaleThresholdDays and $WarnThresholdDays (default: 60 days)
#     - Account has no manager set in Entra ID
#     - Account has never signed in (lastSignInDateTime is null) and is older than 14 days
#
# Output is a JSON report grouped by tier, with per-account detail including:
#   - UPN, DisplayName, ObjectId
#   - Last sign-in timestamp
#   - Account age (days since creation)
#   - Assigned licenses
#   - Group memberships
#   - Manager (if set)
#   - Orphan reason(s) — an account may match multiple conditions
#
# REQUIREMENTS
# ------------
#   - Microsoft.Graph PowerShell SDK
#   - Connect-MgGraph with scopes:
#       User.Read.All, AuditLog.Read.All, Directory.Read.All
#   - Caller must have: Global Reader or Security Reader role (read-only)
#
# USAGE
# -----
#   # Standard run with defaults (90-day stale threshold)
#   .\Get-OrphanedAccounts.ps1
#
#   # Custom thresholds
#   .\Get-OrphanedAccounts.ps1 -StaleThresholdDays 60 -WarnThresholdDays 30
#
#   # Exclude service accounts and shared mailbox accounts by UPN pattern
#   .\Get-OrphanedAccounts.ps1 -ExcludePattern "svc-|shared-|noreply"
#
#   # Export results as CSV in addition to JSON
#   .\Get-OrphanedAccounts.ps1 -ExportCsv

[CmdletBinding()]
param (
    # Accounts with no sign-in beyond this many days are flagged as Tier 1 (immediate risk)
    [Parameter(Mandatory = $false)]
    [ValidateRange(1, 365)]
    [int]$StaleThresholdDays = 90,

    # Accounts with no sign-in beyond this many days are flagged as Tier 2 (review required)
    [Parameter(Mandatory = $false)]
    [ValidateRange(1, 365)]
    [int]$WarnThresholdDays = 60,

    # Regex pattern applied to UPN — matching accounts are excluded from results
    # Useful for filtering known service accounts, shared mailboxes, or bot accounts
    [Parameter(Mandatory = $false)]
    [string]$ExcludePattern = "",

    # Output path for the structured JSON report
    [Parameter(Mandatory = $false)]
    [string]$ReportPath = ".\orphaned-accounts-report.json",

    # When set, also writes a flat CSV alongside the JSON for easier stakeholder review
    [Parameter(Mandatory = $false)]
    [switch]$ExportCsv,

    # When set, includes accounts that are already disabled in the report
    # By default, disabled accounts are excluded (they are already blocked)
    [Parameter(Mandatory = $false)]
    [switch]$IncludeDisabled
)

#region ── Initialization ─────────────────────────────────────────────────────

$runTimestamp      = Get-Date -Format "yyyy-MM-dd HH:mm:ss"
$runId             = (Get-Date -Format "yyyyMMdd-HHmmss")
$staleThreshold    = (Get-Date).AddDays(-$StaleThresholdDays)
$warnThreshold     = (Get-Date).AddDays(-$WarnThresholdDays)
$neverSignedInAge  = (Get-Date).AddDays(-14)  # Accounts older than 14 days with no sign-in

# Results accumulators
$tier1Results = @()  # Immediate risk — disable recommended
$tier2Results = @()  # Review required
$counters     = @{ Scanned = 0; Tier1 = 0; Tier2 = 0; Excluded = 0 }

Write-Host "`n=== Get-OrphanedAccounts START ===" -ForegroundColor Cyan
Write-Host "Run ID              : $runId" -ForegroundColor Cyan
Write-Host "Stale threshold     : $StaleThresholdDays days (Tier 1 cutoff: $($staleThreshold.ToString('yyyy-MM-dd')))" -ForegroundColor Cyan
Write-Host "Warning threshold   : $WarnThresholdDays days (Tier 2 cutoff: $($warnThreshold.ToString('yyyy-MM-dd')))" -ForegroundColor Cyan
Write-Host "Include disabled    : $($IncludeDisabled.IsPresent)`n" -ForegroundColor Cyan

#endregion

#region ── Step 0: Pre-flight ─────────────────────────────────────────────────

Write-Host "[Step 0] Pre-flight validation..." -ForegroundColor Cyan

if (-not (Get-Module -Name "Microsoft.Graph.Users" -ErrorAction SilentlyContinue)) {
    Write-Host "[ERROR] Microsoft.Graph.Users module not loaded." -ForegroundColor Red
    exit 1
}

$ctx = Get-MgContext
if (-not $ctx) {
    Write-Host "[ERROR] No active Microsoft Graph session. Run Connect-MgGraph first." -ForegroundColor Red
    exit 1
}
Write-Host "[INFO] Graph session active. Tenant: $($ctx.TenantId)" -ForegroundColor Cyan

#endregion

#region ── Step 1: Retrieve All Users ─────────────────────────────────────────

Write-Host "[Step 1] Retrieving all user accounts from Entra ID..." -ForegroundColor Cyan

# Request only the properties needed to keep the query efficient
# signInActivity requires AuditLog.Read.All scope
$properties = @(
    "Id", "UserPrincipalName", "DisplayName", "AccountEnabled",
    "CreatedDateTime", "AssignedLicenses", "Department", "JobTitle",
    "SignInActivity", "Manager", "UserType"
) -join ","

try {
    $allUsers = Get-MgUser -All `
                           -Property $properties `
                           -Filter "UserType eq 'Member'" `
                           -ErrorAction Stop
}
catch {
    Write-Host "[ERROR] Failed to retrieve users from Entra ID: $_" -ForegroundColor Red
    exit 1
}

Write-Host "[INFO] Retrieved $($allUsers.Count) member account(s) from Entra ID." -ForegroundColor Cyan

#endregion

#region ── Step 2: Evaluate Each Account ──────────────────────────────────────

Write-Host "[Step 2] Evaluating accounts against orphan criteria..." -ForegroundColor Cyan

foreach ($user in $allUsers) {
    $counters.Scanned++

    # Skip already-disabled accounts unless explicitly included
    if (-not $IncludeDisabled -and -not $user.AccountEnabled) { continue }

    # Apply exclusion pattern filter — skip service accounts, shared mailboxes, etc.
    if ($ExcludePattern -and $user.UserPrincipalName -match $ExcludePattern) {
        $counters.Excluded++
        continue
    }

    # Parse sign-in and creation timestamps
    $lastSignIn  = $user.SignInActivity?.LastSignInDateTime
    $createdDate = $user.CreatedDateTime
    $accountAge  = if ($createdDate) { ((Get-Date) - [datetime]$createdDate).Days } else { $null }

    # Resolve manager — Graph returns manager as a navigation property
    $managerUpn = $null
    try {
        $mgr = Get-MgUserManager -UserId $user.Id -ErrorAction SilentlyContinue
        $managerUpn = $mgr?.AdditionalProperties['userPrincipalName']
    }
    catch { <# No manager set or insufficient scope — leave null #> }

    # Resolve group memberships — collect display names for the report
    $groupNames = @()
    try {
        $groups = Get-MgUserMemberOf -UserId $user.Id -All -ErrorAction SilentlyContinue |
                  Where-Object { $_.'@odata.type' -eq '#microsoft.graph.group' }
        $groupNames = $groups | ForEach-Object { $_.AdditionalProperties['displayName'] }
    }
    catch { <# Unable to retrieve groups — leave empty #> }

    # Resolve assigned license SKU names
    $licenseNames = @()
    if ($user.AssignedLicenses.Count -gt 0) {
        $allSkus = Get-MgSubscribedSku -ErrorAction SilentlyContinue
        $licenseNames = $user.AssignedLicenses | ForEach-Object {
            ($allSkus | Where-Object { $_.SkuId -eq $_.SkuId })?.SkuPartNumber ?? $_.SkuId.ToString()
        }
    }

    # Build the base account detail object reused across both tiers
    $accountDetail = [PSCustomObject]@{
        RunId             = $runId
        UserPrincipalName = $user.UserPrincipalName
        DisplayName       = $user.DisplayName
        ObjectId          = $user.Id
        AccountEnabled    = $user.AccountEnabled
        AccountAgeDays    = $accountAge
        CreatedDateTime   = $createdDate
        LastSignIn        = $lastSignIn
        DaysSinceSignIn   = if ($lastSignIn) { ((Get-Date) - [datetime]$lastSignIn).Days } else { $null }
        Manager           = $managerUpn
        Department        = $user.Department
        JobTitle          = $user.JobTitle
        AssignedLicenses  = $licenseNames -join ", "
        GroupMemberships  = $groupNames -join ", "
        OrphanReasons     = @()
        Tier              = $null
        Timestamp         = $runTimestamp
    }

    # ── Evaluate Tier 1 conditions ─────────────────────────────────────────────

    $tier1Hit = $false

    # Condition: No sign-in within the stale threshold and account is enabled
    if ($user.AccountEnabled) {
        if (-not $lastSignIn -and $createdDate -and ([datetime]$createdDate -lt $neverSignedInAge)) {
            $accountDetail.OrphanReasons += "Never signed in (account older than 14 days)"
            $tier1Hit = $true
        }
        elseif ($lastSignIn -and ([datetime]$lastSignIn -lt $staleThreshold)) {
            $accountDetail.OrphanReasons += "No sign-in in $StaleThresholdDays+ days (last: $([datetime]$lastSignIn | Get-Date -Format 'yyyy-MM-dd'))"
            $tier1Hit = $true
        }
    }

    # Condition: Account is enabled with no licenses assigned
    if ($user.AccountEnabled -and $user.AssignedLicenses.Count -eq 0) {
        $accountDetail.OrphanReasons += "Enabled account with no license assignment"
        $tier1Hit = $true
    }

    if ($tier1Hit) {
        $accountDetail.Tier = "Tier1-ImmediateRisk"
        $tier1Results += $accountDetail
        $counters.Tier1++
        Write-Host "[TIER 1] $($user.UserPrincipalName) — $($accountDetail.OrphanReasons -join ' | ')" -ForegroundColor Red
        continue
    }

    # ── Evaluate Tier 2 conditions ─────────────────────────────────────────────

    $tier2Hit = $false

    # Condition: Sign-in within the warn threshold but not stale yet
    if ($lastSignIn -and ([datetime]$lastSignIn -lt $warnThreshold) -and ([datetime]$lastSignIn -ge $staleThreshold)) {
        $accountDetail.OrphanReasons += "No sign-in in $WarnThresholdDays+ days — approaching stale threshold"
        $tier2Hit = $true
    }

    # Condition: No manager set in Entra ID
    if (-not $managerUpn) {
        $accountDetail.OrphanReasons += "No manager set in Entra ID"
        $tier2Hit = $true
    }

    if ($tier2Hit) {
        $accountDetail.Tier = "Tier2-ReviewRequired"
        $tier2Results += $accountDetail
        $counters.Tier2++
        Write-Host "[TIER 2] $($user.UserPrincipalName) — $($accountDetail.OrphanReasons -join ' | ')" -ForegroundColor Yellow
    }
}

#endregion

#region ── Step 3: Output Report ──────────────────────────────────────────────

Write-Host "`n=== Get-OrphanedAccounts COMPLETE ===" -ForegroundColor Green
Write-Host "Accounts scanned  : $($counters.Scanned)" -ForegroundColor Cyan
Write-Host "Excluded          : $($counters.Excluded)" -ForegroundColor Cyan
Write-Host "Tier 1 (Immediate): $($counters.Tier1)" -ForegroundColor $(if ($counters.Tier1 -gt 0) { "Red" } else { "Green" })
Write-Host "Tier 2 (Review)   : $($counters.Tier2)" -ForegroundColor $(if ($counters.Tier2 -gt 0) { "Yellow" } else { "Green" })

# Build structured report object
$report = [PSCustomObject]@{
    RunId          = $runId
    RunAt          = $runTimestamp
    Parameters     = @{
        StaleThresholdDays = $StaleThresholdDays
        WarnThresholdDays  = $WarnThresholdDays
        ExcludePattern     = $ExcludePattern
        IncludeDisabled    = $IncludeDisabled.IsPresent
    }
    Summary        = $counters
    Tier1Results   = $tier1Results
    Tier2Results   = $tier2Results
}

# Write JSON report
try {
    $report | ConvertTo-Json -Depth 6 | Set-Content -Path $ReportPath -Encoding UTF8
    Write-Host "JSON report written to: $ReportPath" -ForegroundColor Cyan
}
catch {
    Write-Host "[WARN] Could not write JSON report: $_" -ForegroundColor Yellow
}

# Optionally write flat CSV — all tiers combined for easy spreadsheet review
if ($ExportCsv) {
    $csvPath = $ReportPath -replace '\.json$', '.csv'
    try {
        ($tier1Results + $tier2Results) |
            Select-Object Tier, UserPrincipalName, DisplayName, AccountEnabled,
                          AccountAgeDays, LastSignIn, DaysSinceSignIn,
                          Manager, AssignedLicenses, GroupMemberships,
                          @{ Name = "OrphanReasons"; Expression = { $_.OrphanReasons -join " | " } } |
            Export-Csv -Path $csvPath -NoTypeInformation -Encoding UTF8
        Write-Host "CSV report written to : $csvPath" -ForegroundColor Cyan
    }
    catch {
        Write-Host "[WARN] Could not write CSV report: $_" -ForegroundColor Yellow
    }
}

# Return structured report object for pipeline use
return $report

#endregion
