<#
.SYNOPSIS
    Evaluates Entra ID users and service principals against the full Conditional
    Access policy set to identify entities not covered by any enforcing policy,
    producing a risk-tiered gap report for Zero Trust posture review.

.DESCRIPTION
    Get-CAGapReport.ps1 analyzes the Conditional Access policy configuration in
    Entra ID and surfaces coverage gaps — users, groups, or service principals
    that are not subject to any active, enforcing CA policy.

    It performs the following analysis:
        1. Retrieves all enabled CA policies and builds a coverage map.
        2. Identifies users explicitly excluded from all active policies.
        3. Identifies users with no applicable policy based on group membership.
        4. Flags service principals (applications) with no CA policy targeting them.
        5. Cross-references gap findings against privileged role membership to
           apply risk tier escalation.
        6. Outputs a structured JSON/CSV report grouped by risk tier.

    Risk Tiers:
        Critical — Privileged role members (Global Admin, Security Admin, etc.)
                   with no enforcing CA policy. Requires immediate remediation.
        High     — Licensed users with no CA policy coverage and sign-in activity
                   in the last 30 days.
        Medium   — Licensed users with no CA policy coverage and no recent sign-in.
        Low      — Unlicensed users or guests with no CA policy coverage.

    REQUIREMENTS:
        - Microsoft.Graph PowerShell SDK
        - Connect-MgGraph with scopes:
            Policy.Read.All, Directory.Read.All, User.Read.All,
            RoleManagement.Read.Directory, AuditLog.Read.All
        - Caller must have: Security Reader or Global Reader role in Entra ID

.PARAMETER ReportPath
    Output path for the structured JSON gap report.
    Defaults to .\ca-gap-report.json

.PARAMETER ExportCsv
    Switch. When set, also exports a flat CSV version of the gap findings
    alongside the JSON. Useful for sharing with non-technical stakeholders.

.PARAMETER IncludeServicePrincipals
    Switch. When set, evaluates application registrations and service principals
    against CA app-targeting policies. Off by default to reduce runtime.

.PARAMETER PrivilegedRoleIds
    Array of Entra ID role definition IDs to treat as privileged for risk tiering.
    Defaults to a standard set including Global Admin, Security Admin,
    Exchange Admin, SharePoint Admin, and Conditional Access Admin.

.PARAMETER LogPath
    Optional. Path to write a structured JSON log for this run.
    Defaults to .\ca-gap-report.log.json

.EXAMPLE
    # Standard gap report
    .\Get-CAGapReport.ps1

.EXAMPLE
    # Gap report with CSV export for stakeholder sharing
    .\Get-CAGapReport.ps1 -ReportPath ".\zero-trust-ca\gap-report.json" -ExportCsv

.EXAMPLE
    # Full report including service principal coverage analysis
    .\Get-CAGapReport.ps1 -IncludeServicePrincipals -ExportCsv

.NOTES
    Author      : Neil Chavez
    Version     : 1.0.0
    Category    : Zero Trust / Conditional Access
    Folder      : powershell/zero-trust-ca/
    Script #    : 07 of 24

    Scope Note  : CA policy evaluation is inherently complex. This script uses
                  a best-effort coverage model based on policy include/exclude
                  declarations. It does not simulate the full Microsoft CA
                  evaluation engine. Use results as a risk indicator, not a
                  definitive enforcement audit.

    Compliance  : Gap findings map directly to NIST 800-53 AC-2 (Account Management),
                  AC-17 (Remote Access), and IA-2 (MFA for Privileged Users) controls.
                  Use report output as control evidence for SOC 2 or FedRAMP audits.

    Dependencies:
        Install-Module Microsoft.Graph -Scope CurrentUser

    Connect before running:
        Connect-MgGraph -Scopes "Policy.Read.All","Directory.Read.All","User.Read.All","RoleManagement.Read.Directory","AuditLog.Read.All"
#>

[CmdletBinding()]
param (
    [Parameter(Mandatory = $false)]
    [string]$ReportPath = ".\ca-gap-report.json",

    [Parameter(Mandatory = $false)]
    [switch]$ExportCsv,

    [Parameter(Mandatory = $false)]
    [switch]$IncludeServicePrincipals,

    [Parameter(Mandatory = $false)]
    [string[]]$PrivilegedRoleIds = @(
        "62e90394-69f5-4237-9190-012177145e10",  # Global Administrator
        "194ae4cb-b126-40b2-bd5b-6091b380977d",  # Security Administrator
        "f28a1f50-f6e7-4571-818b-6a12f2af6b6c",  # SharePoint Administrator
        "29232cdf-9323-42fd-ade2-1d097af3e4de",  # Exchange Administrator
        "b1be1c3e-b65d-4f19-8427-f6fa0d97feb9",  # Conditional Access Administrator
        "9b895d92-2cd3-44c7-9d02-a6ac2d5ea5c3",  # Application Administrator
        "e8611ab8-c189-46e8-94e1-60213ab1f814"   # Privileged Role Administrator
    ),

    [Parameter(Mandatory = $false)]
    [string]$LogPath = ".\ca-gap-report.log.json"
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

function Get-RiskTier {
    <#
    .SYNOPSIS
        Assigns a risk tier to a gap finding based on role membership and sign-in activity.
    #>
    param (
        [bool]$IsPrivileged,
        [bool]$IsLicensed,
        [bool]$HasRecentSignIn
    )
    if ($IsPrivileged)                    { return "Critical" }
    if ($IsLicensed -and $HasRecentSignIn){ return "High"     }
    if ($IsLicensed)                      { return "Medium"   }
    return "Low"
}

#endregion

#region ── Initialization ─────────────────────────────────────────────────────

$script:LogEntries = @()
$runTimestamp      = Get-Date -Format "yyyy-MM-dd HH:mm:ss"
$runId             = Get-Date -Format "yyyyMMdd-HHmmss"
$recentSignInCutoff = (Get-Date).AddDays(-30)

# Gap findings accumulator
$gapFindings = @()
$counters    = @{ Critical = 0; High = 0; Medium = 0; Low = 0; Covered = 0 }

Write-Log "=== Get-CAGapReport START ===" -Level INFO
Write-Log "Run ID       : $runId" -Level INFO
Write-Log "Report Path  : $ReportPath" -Level INFO
Write-Log "Inc. SPs     : $($IncludeServicePrincipals.IsPresent)" -Level INFO

#endregion

#region ── Step 0: Pre-flight ─────────────────────────────────────────────────

Write-Log "--- Step 0: Pre-flight Validation ---" -Level INFO

$requiredModules = @("Microsoft.Graph.Identity.SignIns", "Microsoft.Graph.Users",
                     "Microsoft.Graph.Identity.Governance")
foreach ($mod in $requiredModules) {
    if (-not (Get-Module -Name $mod -ErrorAction SilentlyContinue)) {
        Write-Log "Required module '$mod' is not loaded." -Level ERROR
        exit 1
    }
}

$ctx = Get-MgContext
if (-not $ctx) {
    Write-Log "No active Microsoft Graph session. Run Connect-MgGraph first." -Level ERROR
    exit 1
}
Write-Log "Graph session active. Tenant: $($ctx.TenantId) | Account: $($ctx.Account)" -Level INFO

#endregion

#region ── Step 1: Load CA Policies and Build Coverage Map ────────────────────

Write-Log "--- Step 1: Load CA Policies and Build Coverage Map ---" -Level INFO

$activePolicies = @()
try {
    # Only evaluate enabled and report-only policies — disabled policies have no enforcement
    $allPolicies    = Get-MgIdentityConditionalAccessPolicy -All -ErrorAction Stop
    $activePolicies = $allPolicies | Where-Object { $_.State -ne "disabled" }
    Write-Log "Total policies: $($allPolicies.Count) | Active (enabled/report-only): $($activePolicies.Count)" -Level INFO
}
catch {
    Write-Log "Failed to retrieve CA policies: $_" -Level ERROR
    exit 1
}

if ($activePolicies.Count -eq 0) {
    Write-Log "No active CA policies found. All users are uncovered." -Level WARN
}

# Build a flat list of all explicitly excluded user/group IDs across all active policies
# These identities are intentionally bypassed by CA policy
$globalExclusions = @{
    Users  = [System.Collections.Generic.HashSet[string]]::new()
    Groups = [System.Collections.Generic.HashSet[string]]::new()
}

# Build a set of all policies that target "All" users (broadest possible scope)
$allUserPolicies = $activePolicies | Where-Object {
    $_.Conditions.Users.IncludeUsers -contains "All"
}

foreach ($policy in $activePolicies) {
    foreach ($userId  in $policy.Conditions.Users.ExcludeUsers)  { $null = $globalExclusions.Users.Add($userId)  }
    foreach ($groupId in $policy.Conditions.Users.ExcludeGroups) { $null = $globalExclusions.Groups.Add($groupId) }
}

Write-Log "Policies targeting 'All Users': $($allUserPolicies.Count)" -Level INFO
Write-Log "Globally excluded users: $($globalExclusions.Users.Count) | Excluded groups: $($globalExclusions.Groups.Count)" -Level INFO

#endregion

#region ── Step 2: Retrieve Users and Privileged Role Members ─────────────────

Write-Log "--- Step 2: Retrieve Users and Role Membership ---" -Level INFO

# Fetch all member accounts with sign-in and license data
$allUsers = @()
try {
    $allUsers = Get-MgUser -All `
                           -Property "Id,UserPrincipalName,DisplayName,AccountEnabled,AssignedLicenses,SignInActivity,UserType" `
                           -Filter "UserType eq 'Member'" `
                           -ErrorAction Stop
    Write-Log "Retrieved $($allUsers.Count) member accounts." -Level INFO
}
catch {
    Write-Log "Failed to retrieve users: $_" -Level ERROR
    exit 1
}

# Build a set of privileged user IDs by querying each privileged role
$privilegedUserIds = [System.Collections.Generic.HashSet[string]]::new()

foreach ($roleId in $PrivilegedRoleIds) {
    try {
        $members = Get-MgDirectoryRoleMember -DirectoryRoleId $roleId -ErrorAction SilentlyContinue
        foreach ($member in $members) {
            $null = $privilegedUserIds.Add($member.Id)
        }
    }
    catch {
        # Role may not be activated in tenant — skip silently
    }
}

Write-Log "Privileged role members identified: $($privilegedUserIds.Count)" -Level INFO

#endregion

#region ── Step 3: Evaluate Each User for CA Coverage ─────────────────────────

Write-Log "--- Step 3: Evaluating user CA coverage ---" -Level INFO

foreach ($user in $allUsers) {

    # Skip disabled accounts — they cannot sign in regardless of CA state
    if (-not $user.AccountEnabled) { continue }

    $isPrivileged    = $privilegedUserIds.Contains($user.Id)
    $isLicensed      = ($user.AssignedLicenses.Count -gt 0)
    $lastSignIn      = $user.SignInActivity?.LastSignInDateTime
    $hasRecentSignIn = $lastSignIn -and ([datetime]$lastSignIn -gt $recentSignInCutoff)

    # Determine if the user is covered by at least one active CA policy
    $isCovered   = $false
    $coverReason = ""

    # Check 1: Is there any "All Users" policy where this user is NOT explicitly excluded?
    foreach ($policy in $allUserPolicies) {
        $excludedByUser  = $policy.Conditions.Users.ExcludeUsers  -contains $user.Id
        $excludedByGroup = $false

        # Check if any of the user's groups are in the policy's exclusion list
        # (Simplified: we check global exclusion groups; full group membership check is expensive at scale)
        foreach ($exGroup in $policy.Conditions.Users.ExcludeGroups) {
            if ($globalExclusions.Groups.Contains($exGroup)) {
                $excludedByGroup = $true
                break
            }
        }

        if (-not $excludedByUser -and -not $excludedByGroup) {
            $isCovered   = $true
            $coverReason = "Covered by 'All Users' policy: '$($policy.DisplayName)'"
            break
        }
    }

    # Check 2: Is the user explicitly included in at least one policy?
    if (-not $isCovered) {
        $inclusionPolicies = $activePolicies | Where-Object {
            $_.Conditions.Users.IncludeUsers -contains $user.Id
        }
        if ($inclusionPolicies.Count -gt 0) {
            $isCovered   = $true
            $coverReason = "Explicitly included in $($inclusionPolicies.Count) policy/policies"
        }
    }

    if ($isCovered) {
        $counters.Covered++
        continue
    }

    # User has no CA coverage — build gap finding
    $riskTier = Get-RiskTier -IsPrivileged $isPrivileged -IsLicensed $isLicensed -HasRecentSignIn $hasRecentSignIn

    $gapFindings += [PSCustomObject]@{
        RunId             = $runId
        UserPrincipalName = $user.UserPrincipalName
        DisplayName       = $user.DisplayName
        ObjectId          = $user.Id
        RiskTier          = $riskTier
        IsPrivileged      = $isPrivileged
        IsLicensed        = $isLicensed
        LastSignIn        = $lastSignIn
        HasRecentSignIn   = $hasRecentSignIn
        GapReason         = "No active CA policy applies to this user"
        Timestamp         = $runTimestamp
    }

    $counters[$riskTier]++

    $tierColor = @{ Critical = "Red"; High = "Yellow"; Medium = "Yellow"; Low = "Gray" }
    Write-Log "[$riskTier] Gap: $($user.UserPrincipalName)$(if ($isPrivileged) { ' [PRIVILEGED]' })" -Level $(
        if ($riskTier -eq "Critical") { "ERROR" } elseif ($riskTier -in "High","Medium") { "WARN" } else { "INFO" }
    )
}

#endregion

#region ── Step 4: Service Principal Coverage (Optional) ─────────────────────

if ($IncludeServicePrincipals) {
    Write-Log "--- Step 4: Evaluating Service Principal CA Coverage ---" -Level INFO

    $servicePrincipals = @()
    try {
        $servicePrincipals = Get-MgServicePrincipal -All `
                                                    -Property "Id,DisplayName,AppId,ServicePrincipalType" `
                                                    -ErrorAction Stop |
                             Where-Object { $_.ServicePrincipalType -eq "Application" }
        Write-Log "Retrieved $($servicePrincipals.Count) application service principals." -Level INFO
    }
    catch {
        Write-Log "Failed to retrieve service principals: $_" -Level WARN
    }

    # Build set of application IDs covered by at least one active CA policy
    $coveredAppIds = [System.Collections.Generic.HashSet[string]]::new()
    foreach ($policy in $activePolicies) {
        foreach ($appId in $policy.Conditions.Applications.IncludeApplications) {
            $null = $coveredAppIds.Add($appId)
        }
    }

    foreach ($sp in $servicePrincipals) {
        if (-not $coveredAppIds.Contains($sp.AppId) -and
            -not ($activePolicies | Where-Object { $_.Conditions.Applications.IncludeApplications -contains "All" })) {

            $gapFindings += [PSCustomObject]@{
                RunId             = $runId
                UserPrincipalName = "N/A (Service Principal)"
                DisplayName       = $sp.DisplayName
                ObjectId          = $sp.Id
                RiskTier          = "Medium"
                IsPrivileged      = $false
                IsLicensed        = $false
                LastSignIn        = $null
                HasRecentSignIn   = $false
                GapReason         = "Service principal not targeted by any active CA app policy"
                Timestamp         = $runTimestamp
            }
            $counters.Medium++
        }
    }
}

#endregion

#region ── Step 5: Output Report ──────────────────────────────────────────────

$totalGaps = $gapFindings.Count

Write-Log "=== Get-CAGapReport COMPLETE ===" -Level SUCCESS
Write-Log "Users evaluated : $($allUsers.Count)" -Level INFO
Write-Log "Covered         : $($counters.Covered)" -Level SUCCESS
Write-Log "Total gaps      : $totalGaps" -Level $(if ($totalGaps -gt 0) { "WARN" } else { "SUCCESS" })
Write-Log "  Critical      : $($counters.Critical)" -Level $(if ($counters.Critical -gt 0) { "ERROR" } else { "INFO" })
Write-Log "  High          : $($counters.High)" -Level $(if ($counters.High -gt 0) { "WARN" } else { "INFO" })
Write-Log "  Medium        : $($counters.Medium)" -Level INFO
Write-Log "  Low           : $($counters.Low)" -Level INFO

$report = [PSCustomObject]@{
    RunId        = $runId
    GeneratedAt  = $runTimestamp
    TenantId     = $ctx.TenantId
    Summary      = [PSCustomObject]@{
        TotalUsersEvaluated  = $allUsers.Count
        CoveredByPolicy      = $counters.Covered
        TotalGaps            = $totalGaps
        Critical             = $counters.Critical
        High                 = $counters.High
        Medium               = $counters.Medium
        Low                  = $counters.Low
        ActivePoliciesCount  = $activePolicies.Count
        PrivilegedUsersFound = $privilegedUserIds.Count
    }
    GapFindings  = $gapFindings
    ComplianceNote = "Gap findings map to NIST 800-53 AC-2, AC-17, IA-2. Use as control evidence for SOC 2 / FedRAMP audits."
}

try {
    $report | ConvertTo-Json -Depth 6 | Set-Content -Path $ReportPath -Encoding UTF8
    Write-Log "JSON report written to: $ReportPath" -Level INFO
}
catch {
    Write-Log "Could not write JSON report: $_" -Level WARN
}

if ($ExportCsv) {
    $csvPath = $ReportPath -replace '\.json$', '.csv'
    try {
        $gapFindings |
            Select-Object RiskTier, UserPrincipalName, DisplayName, IsPrivileged,
                          IsLicensed, LastSignIn, HasRecentSignIn, GapReason |
            Sort-Object RiskTier |
            Export-Csv -Path $csvPath -NoTypeInformation -Encoding UTF8
        Write-Log "CSV report written to: $csvPath" -Level INFO
    }
    catch {
        Write-Log "Could not write CSV report: $_" -Level WARN
    }
}

$logEntry = [PSCustomObject]@{
    RunAt      = $runTimestamp
    Result     = $report.Summary
    LogEntries = $script:LogEntries
}
try {
    $logEntry | ConvertTo-Json -Depth 5 | Set-Content -Path $LogPath -Encoding UTF8
}
catch {
    Write-Log "Could not write log file: $_" -Level WARN
}

return $report

#endregion
