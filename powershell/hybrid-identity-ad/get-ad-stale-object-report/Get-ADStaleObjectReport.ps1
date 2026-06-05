<#
.SYNOPSIS
    Identifies stale Active Directory user and computer objects based on configurable
    lastLogonTimestamp and passwordLastSet thresholds, and produces a tiered remediation
    report with OU path, group memberships, and recommended action per object.

.DESCRIPTION
    Get-ADStaleObjectReport.ps1 queries Active Directory for user and computer accounts
    that have exceeded configurable inactivity thresholds. Stale objects expand the
    attack surface, consume licenses when synced to Entra ID via Entra Connect, and
    complicate directory hygiene at scale.

    It performs the following steps:
        1. Validates the ActiveDirectory module and domain connectivity.
        2. Queries all enabled user accounts and evaluates lastLogonTimestamp
           and passwordLastSet against configurable thresholds.
        3. Queries all enabled computer accounts and evaluates lastLogonTimestamp.
        4. Assigns each stale object to a remediation tier:
               Tier 1 — Disable recommended (exceeded primary threshold)
               Tier 2 — Review required (approaching threshold, or missing data)
        5. Enriches each result with OU path, group memberships, and manager.
        6. Outputs a structured JSON and optional CSV report grouped by tier.

    Threshold logic:
        A user is Tier 1 if:
            - lastLogonTimestamp has not been updated in $UserStaleDays OR
            - passwordLastSet has not been updated in $PasswordStaleDays
        A user is Tier 2 if:
            - lastLogonTimestamp is between $UserWarnDays and $UserStaleDays, OR
            - lastLogonTimestamp is null (never logged in) and account > 14 days old

        A computer is Tier 1 if lastLogonTimestamp > $ComputerStaleDays
        A computer is Tier 2 if lastLogonTimestamp is between $ComputerWarnDays and $ComputerStaleDays

    NOTE: lastLogonTimestamp is replicated across DCs but is only updated every
    14 days by design (AD attribute replication optimization). Accounts inactive
    for fewer than 14 days may still appear stale. This is expected behavior.

    REQUIREMENTS:
        - ActiveDirectory PowerShell module (RSAT: Active Directory DS and LDS Tools)
        - Read access to AD — Domain User rights are sufficient for non-privileged OUs
        - Run from a domain-joined machine or with explicit -Server parameter

.PARAMETER UserStaleDays
    Number of days since last logon after which a user account is considered
    Tier 1 stale and recommended for disablement. Default: 90 days.

.PARAMETER UserWarnDays
    Number of days since last logon after which a user account is flagged as
    Tier 2 (approaching stale). Default: 60 days.

.PARAMETER PasswordStaleDays
    Number of days since passwordLastSet after which a user is flagged,
    regardless of logon activity. Catches service accounts and shared credentials.
    Default: 180 days.

.PARAMETER ComputerStaleDays
    Number of days since last logon after which a computer object is Tier 1 stale.
    Default: 90 days.

.PARAMETER ComputerWarnDays
    Number of days since last logon for Tier 2 computer warning. Default: 60 days.

.PARAMETER SearchBase
    Optional. Distinguished Name of the OU to scope the search.
    If omitted, the entire domain is searched.
    Example: "OU=Users,DC=contoso,DC=com"

.PARAMETER ExcludeOUs
    Optional. Array of OU Distinguished Names to exclude from results.
    Useful for skipping service account OUs or managed privileged account OUs.

.PARAMETER SkipComputers
    Switch. When set, computer object evaluation is skipped.

.PARAMETER SkipUsers
    Switch. When set, user account evaluation is skipped.

.PARAMETER ReportPath
    Output path for the structured JSON report. Defaults to .\ad-stale-object-report.json

.PARAMETER ExportCsv
    Switch. When set, also exports a flat CSV version of the report.

.PARAMETER LogPath
    Optional. Path to write a structured JSON run log.
    Defaults to .\ad-stale-object-report.log.json

.EXAMPLE
    # Standard domain-wide stale object report
    .\Get-ADStaleObjectReport.ps1

.EXAMPLE
    # Scoped to a specific OU with custom thresholds
    .\Get-ADStaleObjectReport.ps1 `
        -SearchBase "OU=Corp Users,DC=contoso,DC=com" `
        -UserStaleDays 60 `
        -PasswordStaleDays 120 `
        -ExportCsv

.EXAMPLE
    # Computer objects only, export CSV
    .\Get-ADStaleObjectReport.ps1 -SkipUsers -ExportCsv

.EXAMPLE
    # Exclude service account OUs from results
    .\Get-ADStaleObjectReport.ps1 `
        -ExcludeOUs @(
            "OU=ServiceAccounts,DC=contoso,DC=com",
            "OU=ManagedAccounts,DC=contoso,DC=com"
        ) `
        -ExportCsv

.NOTES
    Author      : Neil Chavez
    Version     : 1.0.0
    Category    : Hybrid Identity & Directory Ops
    Folder      : powershell/hybrid-identity-ad/
    Script #    : 14 of 24

    lastLogonTimestamp Note:
        AD replicates lastLogonTimestamp with a 9–14 day lag by design.
        This means accounts inactive for fewer than 14 days may appear in
        results. Add a buffer to thresholds for production environments
        (e.g. use 104 days instead of 90 to account for the 14-day lag).

    Entra Connect Note:
        Stale AD objects synced to Entra ID via Entra Connect (formerly Azure AD Connect)
        consume cloud licenses and expand the cloud attack surface. This report
        feeds directly into hybrid identity hygiene workflows.

    Dependencies:
        Install-WindowsFeature RSAT-AD-PowerShell   # Windows Server
        Add-WindowsCapability -Online -Name Rsat.ActiveDirectory.DS-LDS.Tools~~~~0.0.1.0  # Windows 10/11
#>

[CmdletBinding()]
param (
    [Parameter(Mandatory = $false)]
    [ValidateRange(1, 3650)]
    [int]$UserStaleDays = 90,

    [Parameter(Mandatory = $false)]
    [ValidateRange(1, 3650)]
    [int]$UserWarnDays = 60,

    [Parameter(Mandatory = $false)]
    [ValidateRange(1, 3650)]
    [int]$PasswordStaleDays = 180,

    [Parameter(Mandatory = $false)]
    [ValidateRange(1, 3650)]
    [int]$ComputerStaleDays = 90,

    [Parameter(Mandatory = $false)]
    [ValidateRange(1, 3650)]
    [int]$ComputerWarnDays = 60,

    [Parameter(Mandatory = $false)]
    [string]$SearchBase,

    [Parameter(Mandatory = $false)]
    [string[]]$ExcludeOUs = @(),

    [Parameter(Mandatory = $false)]
    [switch]$SkipComputers,

    [Parameter(Mandatory = $false)]
    [switch]$SkipUsers,

    [Parameter(Mandatory = $false)]
    [string]$ReportPath = ".\ad-stale-object-report.json",

    [Parameter(Mandatory = $false)]
    [switch]$ExportCsv,

    [Parameter(Mandatory = $false)]
    [string]$LogPath = ".\ad-stale-object-report.log.json"
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

function ConvertFrom-ADTimestamp {
    <#
    .SYNOPSIS
        Converts a raw AD lastLogonTimestamp (100-nanosecond intervals since 1601)
        to a readable datetime. Returns null if the value is 0 or not set.
    #>
    param ([long]$Timestamp)
    if ($Timestamp -le 0) { return $null }
    return [datetime]::FromFileTime($Timestamp)
}

function Get-OUPath {
    <#
    .SYNOPSIS
        Extracts a readable OU path from an AD object's DistinguishedName.
        Strips the CN component to show just the OU hierarchy.
    #>
    param ([string]$DistinguishedName)
    if (-not $DistinguishedName) { return "Unknown" }
    # Remove the leading CN=ObjectName, component
    return ($DistinguishedName -replace '^CN=[^,]+,', '')
}

function Test-OUExcluded {
    <#
    .SYNOPSIS
        Returns true if the object's DistinguishedName falls under any excluded OU.
    #>
    param (
        [string]$DistinguishedName,
        [string[]]$ExcludeOUs
    )
    foreach ($ou in $ExcludeOUs) {
        if ($DistinguishedName -like "*,$ou") { return $true }
    }
    return $false
}

#endregion

#region ── Initialization ─────────────────────────────────────────────────────

$script:LogEntries = @()
$runTimestamp      = Get-Date -Format "yyyy-MM-dd HH:mm:ss"
$runId             = Get-Date -Format "yyyyMMdd-HHmmss"

# Threshold datetimes
$userStaleDate     = (Get-Date).AddDays(-$UserStaleDays)
$userWarnDate      = (Get-Date).AddDays(-$UserWarnDays)
$passwordStaleDate = (Get-Date).AddDays(-$PasswordStaleDays)
$computerStaleDate = (Get-Date).AddDays(-$ComputerStaleDays)
$computerWarnDate  = (Get-Date).AddDays(-$ComputerWarnDays)
$neverLoggedInAge  = (Get-Date).AddDays(-14)

$tier1Results = @()
$tier2Results = @()
$counters     = @{
    UsersScanned     = 0
    ComputersScanned = 0
    Tier1Users       = 0
    Tier2Users       = 0
    Tier1Computers   = 0
    Tier2Computers   = 0
    Excluded         = 0
}

Write-Log "=== Get-ADStaleObjectReport START ===" -Level INFO
Write-Log "Run ID             : $runId" -Level INFO
Write-Log "User stale cutoff  : $UserStaleDays days ($($userStaleDate.ToString('yyyy-MM-dd')))" -Level INFO
Write-Log "User warn cutoff   : $UserWarnDays days ($($userWarnDate.ToString('yyyy-MM-dd')))" -Level INFO
Write-Log "Password stale     : $PasswordStaleDays days ($($passwordStaleDate.ToString('yyyy-MM-dd')))" -Level INFO
Write-Log "Computer stale     : $ComputerStaleDays days ($($computerStaleDate.ToString('yyyy-MM-dd')))" -Level INFO
Write-Log "Search Base        : $(if ($SearchBase) { $SearchBase } else { 'Entire domain' })" -Level INFO

#endregion

#region ── Step 0: Pre-flight Validation ──────────────────────────────────────

Write-Log "--- Step 0: Pre-flight Validation ---" -Level INFO

if (-not (Get-Module -Name "ActiveDirectory" -ErrorAction SilentlyContinue)) {
    try {
        Import-Module ActiveDirectory -ErrorAction Stop
        Write-Log "ActiveDirectory module loaded." -Level INFO
    }
    catch {
        Write-Log "ActiveDirectory module not available. Install RSAT AD tools." -Level ERROR
        exit 1
    }
}

# Verify domain connectivity
try {
    $domain = Get-ADDomain -ErrorAction Stop
    Write-Log "Connected to domain: $($domain.DNSRoot) | PDC: $($domain.PDCEmulator)" -Level INFO
}
catch {
    Write-Log "Failed to connect to Active Directory domain: $_" -Level ERROR
    exit 1
}

#endregion

#region ── Step 1: Query and Evaluate User Accounts ───────────────────────────

Write-Log "--- Step 1: Evaluating User Accounts ---" -Level INFO

if ($SkipUsers) {
    Write-Log "SkipUsers specified. Skipping user account evaluation." -Level INFO
}
else {
    # Properties needed for stale evaluation — request only what we use
    $userProperties = @(
        "SamAccountName", "UserPrincipalName", "DisplayName", "Enabled",
        "LastLogonTimestamp", "PasswordLastSet", "WhenCreated",
        "DistinguishedName", "Department", "Title", "Manager",
        "MemberOf", "PasswordNeverExpires"
    )

    $userParams = @{
        Filter     = "Enabled -eq `$true"
        Properties = $userProperties
    }
    if ($SearchBase) { $userParams["SearchBase"] = $SearchBase }

    $allUsers = @()
    try {
        $allUsers = Get-ADUser @userParams -ErrorAction Stop
        Write-Log "Retrieved $($allUsers.Count) enabled user account(s)." -Level INFO
    }
    catch {
        Write-Log "Failed to query AD users: $_" -Level ERROR
    }

    foreach ($user in $allUsers) {
        $counters.UsersScanned++

        # Skip if OU is in the exclusion list
        if ($ExcludeOUs.Count -gt 0 -and (Test-OUExcluded $user.DistinguishedName $ExcludeOUs)) {
            $counters.Excluded++
            continue
        }

        # Convert raw AD timestamps
        $lastLogon    = ConvertFrom-ADTimestamp $user.LastLogonTimestamp
        $passwordSet  = $user.PasswordLastSet
        $accountAge   = ((Get-Date) - $user.WhenCreated).Days

        # Resolve manager UPN if set
        $managerUPN = $null
        if ($user.Manager) {
            try {
                $mgr = Get-ADUser -Identity $user.Manager -Properties UserPrincipalName -ErrorAction SilentlyContinue
                $managerUPN = $mgr?.UserPrincipalName
            }
            catch { }
        }

        # Resolve group names from MemberOf DNs
        $groupNames = $user.MemberOf | ForEach-Object {
            ($_ -replace '^CN=([^,]+),.+$', '$1')
        }

        # ── Tier 1 evaluation ─────────────────────────────────────────────────
        $tier1Reasons = @()

        if (-not $lastLogon -and $user.WhenCreated -lt $neverLoggedInAge) {
            $tier1Reasons += "Never logged in (account older than 14 days)"
        }
        elseif ($lastLogon -and $lastLogon -lt $userStaleDate) {
            $tier1Reasons += "No logon in $UserStaleDays+ days (last: $($lastLogon.ToString('yyyy-MM-dd')))"
        }

        if ($passwordSet -and $passwordSet -lt $passwordStaleDate) {
            $tier1Reasons += "Password not changed in $PasswordStaleDays+ days (last set: $($passwordSet.ToString('yyyy-MM-dd')))"
        }

        if ($user.PasswordNeverExpires) {
            $tier1Reasons += "Password set to never expire — review for service account misuse"
        }

        if ($tier1Reasons.Count -gt 0) {
            $obj = [PSCustomObject]@{
                RunId            = $runId
                ObjectType       = "User"
                Tier             = "Tier1-DisableRecommended"
                SamAccountName   = $user.SamAccountName
                UserPrincipalName = $user.UserPrincipalName
                DisplayName      = $user.DisplayName
                Department       = $user.Department
                JobTitle         = $user.Title
                Manager          = $managerUPN
                OUPath           = Get-OUPath $user.DistinguishedName
                AccountAgeDays   = $accountAge
                LastLogon        = $lastLogon?.ToString("yyyy-MM-dd")
                PasswordLastSet  = $passwordSet?.ToString("yyyy-MM-dd")
                GroupMemberships = $groupNames -join ", "
                StaleReasons     = $tier1Reasons
                Timestamp        = $runTimestamp
            }
            $tier1Results += $obj
            $counters.Tier1Users++
            Write-Log "[TIER 1] $($user.UserPrincipalName) — $($tier1Reasons -join ' | ')" -Level WARN
            continue
        }

        # ── Tier 2 evaluation ─────────────────────────────────────────────────
        $tier2Reasons = @()

        if ($lastLogon -and $lastLogon -lt $userWarnDate -and $lastLogon -ge $userStaleDate) {
            $tier2Reasons += "No logon in $UserWarnDays+ days — approaching stale threshold"
        }

        if (-not $managerUPN) {
            $tier2Reasons += "No manager set in AD"
        }

        if ($tier2Reasons.Count -gt 0) {
            $obj = [PSCustomObject]@{
                RunId            = $runId
                ObjectType       = "User"
                Tier             = "Tier2-ReviewRequired"
                SamAccountName   = $user.SamAccountName
                UserPrincipalName = $user.UserPrincipalName
                DisplayName      = $user.DisplayName
                Department       = $user.Department
                JobTitle         = $user.Title
                Manager          = $managerUPN
                OUPath           = Get-OUPath $user.DistinguishedName
                AccountAgeDays   = $accountAge
                LastLogon        = $lastLogon?.ToString("yyyy-MM-dd")
                PasswordLastSet  = $passwordSet?.ToString("yyyy-MM-dd")
                GroupMemberships = $groupNames -join ", "
                StaleReasons     = $tier2Reasons
                Timestamp        = $runTimestamp
            }
            $tier2Results += $obj
            $counters.Tier2Users++
        }
    }

    Write-Log "User evaluation complete. Tier 1: $($counters.Tier1Users) | Tier 2: $($counters.Tier2Users)" -Level INFO
}

#endregion

#region ── Step 2: Query and Evaluate Computer Objects ────────────────────────

Write-Log "--- Step 2: Evaluating Computer Objects ---" -Level INFO

if ($SkipComputers) {
    Write-Log "SkipComputers specified. Skipping computer object evaluation." -Level INFO
}
else {
    $computerProperties = @(
        "Name", "DNSHostName", "Enabled", "LastLogonTimestamp",
        "WhenCreated", "DistinguishedName", "OperatingSystem",
        "OperatingSystemVersion", "MemberOf"
    )

    $computerParams = @{
        Filter     = "Enabled -eq `$true"
        Properties = $computerProperties
    }
    if ($SearchBase) { $computerParams["SearchBase"] = $SearchBase }

    $allComputers = @()
    try {
        $allComputers = Get-ADComputer @computerParams -ErrorAction Stop
        Write-Log "Retrieved $($allComputers.Count) enabled computer object(s)." -Level INFO
    }
    catch {
        Write-Log "Failed to query AD computers: $_" -Level ERROR
    }

    foreach ($computer in $allComputers) {
        $counters.ComputersScanned++

        if ($ExcludeOUs.Count -gt 0 -and (Test-OUExcluded $computer.DistinguishedName $ExcludeOUs)) {
            $counters.Excluded++
            continue
        }

        $lastLogon  = ConvertFrom-ADTimestamp $computer.LastLogonTimestamp
        $accountAge = ((Get-Date) - $computer.WhenCreated).Days

        $groupNames = $computer.MemberOf | ForEach-Object {
            ($_ -replace '^CN=([^,]+),.+$', '$1')
        }

        # ── Tier 1 ────────────────────────────────────────────────────────────
        $tier1Reasons = @()

        if (-not $lastLogon -and $computer.WhenCreated -lt $neverLoggedInAge) {
            $tier1Reasons += "Computer never authenticated to domain (object older than 14 days)"
        }
        elseif ($lastLogon -and $lastLogon -lt $computerStaleDate) {
            $tier1Reasons += "No domain authentication in $ComputerStaleDays+ days (last: $($lastLogon.ToString('yyyy-MM-dd')))"
        }

        if ($tier1Reasons.Count -gt 0) {
            $obj = [PSCustomObject]@{
                RunId            = $runId
                ObjectType       = "Computer"
                Tier             = "Tier1-DisableRecommended"
                SamAccountName   = $computer.Name
                UserPrincipalName = $computer.DNSHostName
                DisplayName      = $computer.Name
                Department       = $null
                JobTitle         = $null
                Manager          = $null
                OUPath           = Get-OUPath $computer.DistinguishedName
                AccountAgeDays   = $accountAge
                LastLogon        = $lastLogon?.ToString("yyyy-MM-dd")
                PasswordLastSet  = $null
                GroupMemberships = $groupNames -join ", "
                StaleReasons     = $tier1Reasons
                OS               = "$($computer.OperatingSystem) $($computer.OperatingSystemVersion)"
                Timestamp        = $runTimestamp
            }
            $tier1Results += $obj
            $counters.Tier1Computers++
            Write-Log "[TIER 1] $($computer.Name) — $($tier1Reasons -join ' | ')" -Level WARN
            continue
        }

        # ── Tier 2 ────────────────────────────────────────────────────────────
        $tier2Reasons = @()

        if ($lastLogon -and $lastLogon -lt $computerWarnDate -and $lastLogon -ge $computerStaleDate) {
            $tier2Reasons += "No domain auth in $ComputerWarnDays+ days — approaching stale threshold"
        }

        if ($tier2Reasons.Count -gt 0) {
            $obj = [PSCustomObject]@{
                RunId            = $runId
                ObjectType       = "Computer"
                Tier             = "Tier2-ReviewRequired"
                SamAccountName   = $computer.Name
                UserPrincipalName = $computer.DNSHostName
                DisplayName      = $computer.Name
                Department       = $null
                JobTitle         = $null
                Manager          = $null
                OUPath           = Get-OUPath $computer.DistinguishedName
                AccountAgeDays   = $accountAge
                LastLogon        = $lastLogon?.ToString("yyyy-MM-dd")
                PasswordLastSet  = $null
                GroupMemberships = $groupNames -join ", "
                StaleReasons     = $tier2Reasons
                OS               = "$($computer.OperatingSystem) $($computer.OperatingSystemVersion)"
                Timestamp        = $runTimestamp
            }
            $tier2Results += $obj
            $counters.Tier2Computers++
        }
    }

    Write-Log "Computer evaluation complete. Tier 1: $($counters.Tier1Computers) | Tier 2: $($counters.Tier2Computers)" -Level INFO
}

#endregion

#region ── Step 3: Output Report ──────────────────────────────────────────────

$totalTier1 = $counters.Tier1Users + $counters.Tier1Computers
$totalTier2 = $counters.Tier2Users + $counters.Tier2Computers

Write-Log "=== Get-ADStaleObjectReport COMPLETE ===" -Level SUCCESS
Write-Log "Users scanned     : $($counters.UsersScanned)" -Level INFO
Write-Log "Computers scanned : $($counters.ComputersScanned)" -Level INFO
Write-Log "Excluded          : $($counters.Excluded)" -Level INFO
Write-Log "Tier 1 (Disable)  : $totalTier1" -Level $(if ($totalTier1 -gt 0) { "WARN" } else { "SUCCESS" })
Write-Log "Tier 2 (Review)   : $totalTier2" -Level INFO

$report = [PSCustomObject]@{
    RunId        = $runId
    GeneratedAt  = $runTimestamp
    Domain       = $domain.DNSRoot
    Parameters   = [PSCustomObject]@{
        UserStaleDays     = $UserStaleDays
        UserWarnDays      = $UserWarnDays
        PasswordStaleDays = $PasswordStaleDays
        ComputerStaleDays = $ComputerStaleDays
        ComputerWarnDays  = $ComputerWarnDays
        SearchBase        = $SearchBase
    }
    Summary      = $counters
    Tier1Results = $tier1Results
    Tier2Results = $tier2Results
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
        ($tier1Results + $tier2Results) |
            Select-Object Tier, ObjectType, SamAccountName, UserPrincipalName,
                          DisplayName, Department, OUPath, AccountAgeDays,
                          LastLogon, PasswordLastSet, Manager, GroupMemberships,
                          @{ Name = "StaleReasons"; Expression = { $_.StaleReasons -join " | " } } |
            Sort-Object Tier, ObjectType |
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
