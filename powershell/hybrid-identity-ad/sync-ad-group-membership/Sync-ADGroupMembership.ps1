# Sync-ADGroupMembership.ps1
# Author   : Neil Chavez
# Version  : 1.0.0
# Category : Hybrid Identity & Directory Ops
# Folder   : powershell/hybrid-identity-ad/
# Script # : 15 of 24
#
# PURPOSE
# -------
# Reconciles Active Directory group membership against an authoritative source
# (CSV from an HRIS, identity governance platform, or role management system).
#
# For each group defined in the source file:
#   - Users listed in the source who are NOT in the AD group  → added
#   - Users currently in the AD group who are NOT in the source → removed
#   - Users present in both source and AD group               → no change
#
# Every add and remove action is logged with before/after state and the reason
# for the change. Supports -WhatIf for full dry-run preview before live execution.
#
# This script enforces least-privilege at the directory level. Group membership
# drift between an authoritative identity source and AD is a common source of
# access control failures — particularly after role changes, transfers, or
# terminations that were reflected in the HRIS but not propagated to AD.
#
# REQUIREMENTS
# ------------
#   - ActiveDirectory PowerShell module (RSAT: AD DS and LDS Tools)
#   - Caller must have: Write permission on target AD groups
#     (typically Domain Admins or a delegated Group Management role)
#
# CSV FORMAT
# ----------
# One row per group-user relationship. Required columns:
#   GroupName    — The AD group sAMAccountName or Distinguished Name
#   MemberUPN    — The UPN of the user who should be a member
#
# Optional columns (used for reporting only):
#   MemberName, Department, Role
#
# Example:
#   GroupName,MemberUPN,MemberName,Department,Role
#   GRP-Engineering,jdoe@contoso.com,Jane Doe,Engineering,Platform Engineer
#   GRP-Engineering,bsmith@contoso.com,Bob Smith,Engineering,SRE
#   GRP-Finance,alee@contoso.com,Amy Lee,Finance,Analyst
#
# USAGE
# -----
#   # Standard reconciliation against a source CSV
#   .\Sync-ADGroupMembership.ps1 -CsvPath .\group-source.csv
#
#   # Dry run — preview all adds and removes without making changes
#   .\Sync-ADGroupMembership.ps1 -CsvPath .\group-source.csv -WhatIf
#
#   # Reconcile specific groups only (ignore others in CSV)
#   .\Sync-ADGroupMembership.ps1 -CsvPath .\group-source.csv `
#       -GroupFilter @("GRP-Engineering", "GRP-Platform")
#
#   # Report-only mode — generate diff report without making changes
#   .\Sync-ADGroupMembership.ps1 -CsvPath .\group-source.csv -ReportOnly

[CmdletBinding(SupportsShouldProcess = $true)]
param (
    # Path to the authoritative CSV source file
    [Parameter(Mandatory = $true)]
    [ValidateScript({ Test-Path $_ -PathType Leaf })]
    [string]$CsvPath,

    # Optional filter — only reconcile these specific group names
    # If omitted, all groups in the CSV are processed
    [Parameter(Mandatory = $false)]
    [string[]]$GroupFilter = @(),

    # Output path for the structured JSON reconciliation report
    [Parameter(Mandatory = $false)]
    [string]$ReportPath = ".\ad-group-sync-report.json",

    # When set, also exports a flat CSV diff report
    [Parameter(Mandatory = $false)]
    [switch]$ExportCsv,

    # When set, generates the diff report but makes no AD changes
    # Similar to -WhatIf but outputs the full report file
    [Parameter(Mandatory = $false)]
    [switch]$ReportOnly,

    # Output path for the JSON run log
    [Parameter(Mandatory = $false)]
    [string]$LogPath = ".\ad-group-sync.log.json"
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
$runId             = Get-Date -Format "yyyyMMdd-HHmmss"

# Diff result accumulator — one entry per action per user per group
$diffResults = @()

$counters = @{
    GroupsProcessed = 0
    GroupsSkipped   = 0
    MembersAdded    = 0
    MembersRemoved  = 0
    NoChange        = 0
    Errors          = 0
}

Write-Log "=== Sync-ADGroupMembership START ===" -Level INFO
Write-Log "Run ID      : $runId" -Level INFO
Write-Log "CSV Source  : $CsvPath" -Level INFO
Write-Log "Report Only : $($ReportOnly.IsPresent)" -Level INFO
Write-Log "WhatIf Mode : $($WhatIfPreference)" -Level INFO

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

try {
    $domain = Get-ADDomain -ErrorAction Stop
    Write-Log "Connected to domain: $($domain.DNSRoot)" -Level INFO
}
catch {
    Write-Log "Failed to connect to AD domain: $_" -Level ERROR
    exit 1
}

#endregion

#region ── Step 1: Load and Validate CSV Source ───────────────────────────────

Write-Log "--- Step 1: Load Source CSV ---" -Level INFO

$sourceData = $null
try {
    $sourceData = Import-Csv -Path $CsvPath -ErrorAction Stop
}
catch {
    Write-Log "Failed to load CSV file: $_" -Level ERROR
    exit 1
}

# Validate required columns exist
foreach ($col in @("GroupName", "MemberUPN")) {
    if (-not ($sourceData | Get-Member -Name $col -MemberType NoteProperty)) {
        Write-Log "CSV is missing required column: $col" -Level ERROR
        exit 1
    }
}

# Normalize UPNs and group names
$sourceData = $sourceData | ForEach-Object {
    [PSCustomObject]@{
        GroupName   = $_.GroupName.Trim()
        MemberUPN   = $_.MemberUPN.Trim().ToLower()
        MemberName  = if ($_.PSObject.Properties['MemberName'])  { $_.MemberName  } else { "" }
        Department  = if ($_.PSObject.Properties['Department'])  { $_.Department  } else { "" }
        Role        = if ($_.PSObject.Properties['Role'])        { $_.Role        } else { "" }
    }
}

# Get the unique set of group names from the source
$sourceGroupNames = $sourceData | Select-Object -ExpandProperty GroupName | Sort-Object -Unique

# Apply group filter if specified
if ($GroupFilter.Count -gt 0) {
    $sourceGroupNames = $sourceGroupNames | Where-Object { $GroupFilter -contains $_ }
    Write-Log "Group filter applied. Processing $($sourceGroupNames.Count) group(s)." -Level INFO
}

Write-Log "Source loaded: $($sourceData.Count) rows | $($sourceGroupNames.Count) unique group(s)." -Level INFO

#endregion

#region ── Step 2: Reconcile Each Group ───────────────────────────────────────

Write-Log "--- Step 2: Reconciling Group Membership ---" -Level INFO

foreach ($groupName in $sourceGroupNames) {

    Write-Log "Processing group: '$groupName'" -Level INFO

    # ── Resolve AD Group ───────────────────────────────────────────────────────
    $adGroup = $null
    try {
        $adGroup = Get-ADGroup -Filter "SamAccountName -eq '$groupName'" `
                               -Properties Members -ErrorAction Stop
    }
    catch {
        Write-Log "Failed to find AD group '$groupName': $_" -Level ERROR
        $counters.GroupsSkipped++
        $diffResults += [PSCustomObject]@{
            RunId      = $runId
            GroupName  = $groupName
            MemberUPN  = "N/A"
            Action     = "Error"
            Reason     = "AD group not found: $_"
            WhatIf     = $WhatIfPreference.ToString()
            Timestamp  = $runTimestamp
        }
        continue
    }

    $counters.GroupsProcessed++

    # ── Get current AD group members ───────────────────────────────────────────
    # Resolve member DNs to UPNs for comparison — only include User objects
    $currentMemberUPNs = @()
    try {
        $currentMembers = Get-ADGroupMember -Identity $adGroup -Recursive -ErrorAction Stop |
                          Where-Object { $_.objectClass -eq "user" }

        $currentMemberUPNs = $currentMembers | ForEach-Object {
            try {
                $u = Get-ADUser -Identity $_.DistinguishedName -Properties UserPrincipalName -ErrorAction SilentlyContinue
                $u?.UserPrincipalName?.ToLower()
            }
            catch { }
        } | Where-Object { $_ }
    }
    catch {
        Write-Log "Failed to retrieve members of '$groupName': $_" -Level WARN
        $counters.Errors++
    }

    # ── Get source-defined members for this group ──────────────────────────────
    $sourceMemberUPNs = $sourceData |
                        Where-Object { $_.GroupName -eq $groupName } |
                        Select-Object -ExpandProperty MemberUPN |
                        Where-Object { $_ -match '@' } |
                        Sort-Object -Unique

    # ── Calculate diff ─────────────────────────────────────────────────────────
    $toAdd    = $sourceMemberUPNs | Where-Object { $currentMemberUPNs -notcontains $_ }
    $toRemove = $currentMemberUPNs | Where-Object { $sourceMemberUPNs -notcontains $_ }
    $noChange = $sourceMemberUPNs | Where-Object { $currentMemberUPNs -contains $_ }

    Write-Log "  Source: $($sourceMemberUPNs.Count) | AD: $($currentMemberUPNs.Count) | Add: $($toAdd.Count) | Remove: $($toRemove.Count) | NoChange: $($noChange.Count)" -Level INFO

    # ── Record no-change entries ───────────────────────────────────────────────
    foreach ($upn in $noChange) {
        $diffResults += [PSCustomObject]@{
            RunId     = $runId
            GroupName = $groupName
            MemberUPN = $upn
            Action    = "NoChange"
            Reason    = "Member present in both source and AD group"
            WhatIf    = $WhatIfPreference.ToString()
            Timestamp = $runTimestamp
        }
        $counters.NoChange++
    }

    # ── Add missing members ────────────────────────────────────────────────────
    foreach ($upn in $toAdd) {
        $adUser = $null
        try {
            $adUser = Get-ADUser -Filter "UserPrincipalName -eq '$upn'" -ErrorAction SilentlyContinue
        }
        catch { }

        if (-not $adUser) {
            Write-Log "  Cannot add '$upn' — user not found in AD." -Level WARN
            $diffResults += [PSCustomObject]@{
                RunId     = $runId
                GroupName = $groupName
                MemberUPN = $upn
                Action    = "SkippedNotFound"
                Reason    = "UPN not found in Active Directory"
                WhatIf    = $WhatIfPreference.ToString()
                Timestamp = $runTimestamp
            }
            $counters.Errors++
            continue
        }

        if (-not $ReportOnly -and $PSCmdlet.ShouldProcess($groupName, "Add member: $upn")) {
            try {
                Add-ADGroupMember -Identity $adGroup -Members $adUser -ErrorAction Stop
                Write-Log "  ADDED: $upn → $groupName" -Level SUCCESS
                $counters.MembersAdded++
                $diffResults += [PSCustomObject]@{
                    RunId     = $runId
                    GroupName = $groupName
                    MemberUPN = $upn
                    Action    = "Added"
                    Reason    = "Member in source but missing from AD group"
                    WhatIf    = $WhatIfPreference.ToString()
                    Timestamp = $runTimestamp
                }
            }
            catch {
                $errMsg = "Failed to add '$upn' to '$groupName': $_"
                Write-Log "  $errMsg" -Level ERROR
                $diffResults += [PSCustomObject]@{
                    RunId     = $runId
                    GroupName = $groupName
                    MemberUPN = $upn
                    Action    = "Error"
                    Reason    = $errMsg
                    WhatIf    = $WhatIfPreference.ToString()
                    Timestamp = $runTimestamp
                }
                $counters.Errors++
            }
        }
        else {
            Write-Log "  [WhatIf/ReportOnly] Would add: $upn → $groupName" -Level INFO
            $diffResults += [PSCustomObject]@{
                RunId     = $runId
                GroupName = $groupName
                MemberUPN = $upn
                Action    = "WouldAdd"
                Reason    = "Member in source but missing from AD group"
                WhatIf    = "True"
                Timestamp = $runTimestamp
            }
        }
    }

    # ── Remove unauthorized members ────────────────────────────────────────────
    foreach ($upn in $toRemove) {
        $adUser = $null
        try {
            $adUser = Get-ADUser -Filter "UserPrincipalName -eq '$upn'" -ErrorAction SilentlyContinue
        }
        catch { }

        if (-not $ReportOnly -and $PSCmdlet.ShouldProcess($groupName, "Remove member: $upn")) {
            try {
                if ($adUser) {
                    Remove-ADGroupMember -Identity $adGroup -Members $adUser -Confirm:$false -ErrorAction Stop
                }
                else {
                    # User may have been deleted from AD but still in group membership list
                    Write-Log "  User '$upn' not found in AD — may be a deleted account. Skipping." -Level WARN
                    continue
                }
                Write-Log "  REMOVED: $upn ← $groupName" -Level SUCCESS
                $counters.MembersRemoved++
                $diffResults += [PSCustomObject]@{
                    RunId     = $runId
                    GroupName = $groupName
                    MemberUPN = $upn
                    Action    = "Removed"
                    Reason    = "Member in AD group but not present in authoritative source"
                    WhatIf    = $WhatIfPreference.ToString()
                    Timestamp = $runTimestamp
                }
            }
            catch {
                $errMsg = "Failed to remove '$upn' from '$groupName': $_"
                Write-Log "  $errMsg" -Level ERROR
                $diffResults += [PSCustomObject]@{
                    RunId     = $runId
                    GroupName = $groupName
                    MemberUPN = $upn
                    Action    = "Error"
                    Reason    = $errMsg
                    WhatIf    = $WhatIfPreference.ToString()
                    Timestamp = $runTimestamp
                }
                $counters.Errors++
            }
        }
        else {
            Write-Log "  [WhatIf/ReportOnly] Would remove: $upn ← $groupName" -Level INFO
            $diffResults += [PSCustomObject]@{
                RunId     = $runId
                GroupName = $groupName
                MemberUPN = $upn
                Action    = "WouldRemove"
                Reason    = "Member in AD group but not present in authoritative source"
                WhatIf    = "True"
                Timestamp = $runTimestamp
            }
        }
    }
}

#endregion

#region ── Step 3: Output Report ──────────────────────────────────────────────

Write-Log "=== Sync-ADGroupMembership COMPLETE ===" -Level SUCCESS
Write-Log "Groups Processed: $($counters.GroupsProcessed)" -Level INFO
Write-Log "Groups Skipped  : $($counters.GroupsSkipped)" -Level INFO
Write-Log "Members Added   : $($counters.MembersAdded)" -Level SUCCESS
Write-Log "Members Removed : $($counters.MembersRemoved)" -Level SUCCESS
Write-Log "No Change       : $($counters.NoChange)" -Level INFO
Write-Log "Errors          : $($counters.Errors)" -Level $(if ($counters.Errors -gt 0) { "WARN" } else { "INFO" })

$report = [PSCustomObject]@{
    RunId       = $runId
    GeneratedAt = $runTimestamp
    Domain      = $domain.DNSRoot
    CsvSource   = $CsvPath
    ReportOnly  = $ReportOnly.IsPresent
    WhatIf      = $WhatIfPreference.ToString()
    Summary     = $counters
    Diff        = $diffResults
}

try {
    $report | ConvertTo-Json -Depth 5 | Set-Content -Path $ReportPath -Encoding UTF8
    Write-Log "JSON report written to: $ReportPath" -Level INFO
}
catch {
    Write-Log "Could not write JSON report: $_" -Level WARN
}

if ($ExportCsv) {
    $csvPath = $ReportPath -replace '\.json$', '.csv'
    try {
        $diffResults |
            Select-Object GroupName, MemberUPN, Action, Reason, WhatIf, Timestamp |
            Sort-Object GroupName, Action |
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
