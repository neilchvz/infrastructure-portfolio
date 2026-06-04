# Sync-LicenseAssignment.ps1
# Author   : Neil Chavez
# Version  : 1.0.0
# Category : Identity Lifecycle Automation
# Folder   : powershell/identity-lifecycle/
# Script # : 03 of 24
#
# PURPOSE
# -------
# Ingests an authoritative license assignment source (CSV from an HRIS or identity
# feed) and reconciles the current Microsoft 365 license state in Entra ID against it.
#
# For each user in the source:
#   - If the user exists and is missing the specified SKU   → license is assigned
#   - If the user exists and already has the specified SKU  → no action taken
#   - If the user does not exist in Entra ID               → logged as a warning
#
# For users in Entra ID who hold a SKU that is NOT present in the source file:
#   - If -RemoveUnlicensed is specified                     → license is removed
#   - Otherwise                                             → flagged in the report only
#
# Output is a structured diff report (JSON + optional CSV) showing every add,
# remove, and no-change action taken. Designed for scheduled execution in a
# CI/CD pipeline or triggered at month-end by a FinOps or IT Ops team.
#
# REQUIREMENTS
# ------------
#   - Microsoft.Graph PowerShell SDK
#   - Connect-MgGraph with scopes: User.ReadWrite.All, Organization.Read.All
#   - Caller must have: License Administrator role in Entra ID
#
# USAGE
# -----
#   # Standard reconciliation (assign only — no removals)
#   .\Sync-LicenseAssignment.ps1 -CsvPath .\license-source.csv -LicenseSku "SPE_E5"
#
#   # Full reconciliation (assign missing + remove unlicensed)
#   .\Sync-LicenseAssignment.ps1 -CsvPath .\license-source.csv -LicenseSku "SPE_E5" -RemoveUnlicensed
#
#   # Dry run — see what would change without making any changes
#   .\Sync-LicenseAssignment.ps1 -CsvPath .\license-source.csv -LicenseSku "SPE_E5" -WhatIf
#
# CSV FORMAT
# ----------
# Required column : UserPrincipalName
# Optional columns: DisplayName, Department (used for reporting only)
#
# Example:
#   UserPrincipalName,DisplayName,Department
#   jdoe@contoso.com,Jane Doe,Engineering
#   bsmith@contoso.com,Bob Smith,Finance

[CmdletBinding(SupportsShouldProcess = $true)]
param (
    # Path to the authoritative CSV file containing users who should hold the license
    [Parameter(Mandatory = $true)]
    [ValidateScript({ Test-Path $_ -PathType Leaf })]
    [string]$CsvPath,

    # The SKU part number to reconcile (e.g. "SPE_E5", "ENTERPRISEPREMIUM")
    [Parameter(Mandatory = $true)]
    [ValidateNotNullOrEmpty()]
    [string]$LicenseSku,

    # When set, removes the license from any user in Entra ID not present in the CSV
    [Parameter(Mandatory = $false)]
    [switch]$RemoveUnlicensed,

    # Output path for the structured JSON diff report
    [Parameter(Mandatory = $false)]
    [string]$ReportPath = ".\license-sync-report.json",

    # When set, also writes a CSV version of the diff report alongside the JSON
    [Parameter(Mandatory = $false)]
    [switch]$ExportCsv,

    # UsageLocation applied when assigning a license to a user with no location set
    [Parameter(Mandatory = $false)]
    [ValidateLength(2, 2)]
    [string]$DefaultUsageLocation = "US"
)

#region ── Initialization ─────────────────────────────────────────────────────

# Timestamp used consistently across all log entries and report filenames
$runTimestamp = Get-Date -Format "yyyy-MM-dd HH:mm:ss"
$runId        = (Get-Date -Format "yyyyMMdd-HHmmss")

# Accumulator for structured diff output — each entry represents one user action
$diffReport = @()

# Running counters for summary output
$counters = @{ Assigned = 0; Removed = 0; NoChange = 0; NotFound = 0; Errors = 0 }

Write-Host "`n=== Sync-LicenseAssignment START ===" -ForegroundColor Cyan
Write-Host "Run ID     : $runId" -ForegroundColor Cyan
Write-Host "CSV Source : $CsvPath" -ForegroundColor Cyan
Write-Host "SKU Target : $LicenseSku" -ForegroundColor Cyan
Write-Host "Remove Flag: $($RemoveUnlicensed.IsPresent)" -ForegroundColor Cyan
Write-Host "WhatIf     : $($WhatIfPreference)`n" -ForegroundColor Cyan

#endregion

#region ── Step 0: Pre-flight — Module and Session Checks ─────────────────────

Write-Host "[Step 0] Pre-flight validation..." -ForegroundColor Cyan

if (-not (Get-Module -Name "Microsoft.Graph.Users" -ErrorAction SilentlyContinue)) {
    Write-Host "[ERROR] Microsoft.Graph.Users module not loaded. Run: Import-Module Microsoft.Graph.Users" -ForegroundColor Red
    exit 1
}

$ctx = Get-MgContext
if (-not $ctx) {
    Write-Host "[ERROR] No active Microsoft Graph session. Run Connect-MgGraph first." -ForegroundColor Red
    exit 1
}
Write-Host "[INFO] Graph session active. Tenant: $($ctx.TenantId)" -ForegroundColor Cyan

#endregion

#region ── Step 1: Resolve License SKU ───────────────────────────────────────

Write-Host "[Step 1] Resolving license SKU: $LicenseSku" -ForegroundColor Cyan

$resolvedSku = Get-MgSubscribedSku | Where-Object { $_.SkuPartNumber -eq $LicenseSku }

if (-not $resolvedSku) {
    Write-Host "[ERROR] SKU '$LicenseSku' not found in tenant. Verify with Get-MgSubscribedSku." -ForegroundColor Red
    exit 1
}

$availableSeats = $resolvedSku.PrepaidUnits.Enabled - $resolvedSku.ConsumedUnits
Write-Host "[INFO] SKU resolved. SkuId: $($resolvedSku.SkuId)" -ForegroundColor Cyan
Write-Host "[INFO] Available seats: $availableSeats of $($resolvedSku.PrepaidUnits.Enabled)" -ForegroundColor Cyan

if ($availableSeats -le 0) {
    Write-Host "[WARN] No available seats for '$LicenseSku'. Assignment steps will be skipped." -ForegroundColor Yellow
}

#endregion

#region ── Step 2: Load and Validate CSV Source ───────────────────────────────

Write-Host "[Step 2] Loading CSV source: $CsvPath" -ForegroundColor Cyan

$sourceUsers = Import-Csv -Path $CsvPath -ErrorAction Stop

# Validate required column exists
if (-not ($sourceUsers | Get-Member -Name "UserPrincipalName" -MemberType NoteProperty)) {
    Write-Host "[ERROR] CSV is missing required column: UserPrincipalName" -ForegroundColor Red
    exit 1
}

# Normalize and deduplicate UPNs from the source
$sourceUpns = $sourceUsers |
              Select-Object -ExpandProperty UserPrincipalName |
              Where-Object { $_ -match '@' } |
              ForEach-Object { $_.Trim().ToLower() } |
              Sort-Object -Unique

Write-Host "[INFO] $($sourceUpns.Count) unique UPN(s) loaded from CSV." -ForegroundColor Cyan

#endregion

#region ── Step 3: Reconcile — Assign Missing Licenses ────────────────────────

Write-Host "[Step 3] Reconciling — checking for missing license assignments..." -ForegroundColor Cyan

foreach ($upn in $sourceUpns) {
    try {
        # Fetch user with only the properties we need
        $user = Get-MgUser -Filter "userPrincipalName eq '$upn'" `
                           -Property "Id,UserPrincipalName,DisplayName,AssignedLicenses,UsageLocation" `
                           -ErrorAction SilentlyContinue

        if (-not $user) {
            Write-Host "[WARN] User not found in Entra ID: $upn" -ForegroundColor Yellow
            $diffReport += [PSCustomObject]@{
                RunId             = $runId
                UserPrincipalName = $upn
                DisplayName       = "N/A"
                Action            = "NotFound"
                Sku               = $LicenseSku
                Reason            = "UPN does not exist in Entra ID"
                WhatIf            = $WhatIfPreference.ToString()
                Timestamp         = $runTimestamp
            }
            $counters.NotFound++
            continue
        }

        # Check if this SKU is already assigned
        $alreadyAssigned = $user.AssignedLicenses | Where-Object { $_.SkuId -eq $resolvedSku.SkuId }

        if ($alreadyAssigned) {
            # No action needed — license is already in the correct state
            Write-Host "[INFO] Already licensed: $upn" -ForegroundColor Gray
            $diffReport += [PSCustomObject]@{
                RunId             = $runId
                UserPrincipalName = $upn
                DisplayName       = $user.DisplayName
                Action            = "NoChange"
                Sku               = $LicenseSku
                Reason            = "License already assigned"
                WhatIf            = $WhatIfPreference.ToString()
                Timestamp         = $runTimestamp
            }
            $counters.NoChange++
            continue
        }

        # License is missing — assign it if seats are available
        if ($availableSeats -le 0) {
            Write-Host "[WARN] Cannot assign to $upn — no available seats." -ForegroundColor Yellow
            $diffReport += [PSCustomObject]@{
                RunId             = $runId
                UserPrincipalName = $upn
                DisplayName       = $user.DisplayName
                Action            = "SkippedNoSeats"
                Sku               = $LicenseSku
                Reason            = "No available seats in SKU"
                WhatIf            = $WhatIfPreference.ToString()
                Timestamp         = $runTimestamp
            }
            $counters.Errors++
            continue
        }

        # Ensure UsageLocation is set — required before any license assignment
        if (-not $user.UsageLocation) {
            Write-Host "[INFO] No usage location set for $upn. Applying default: $DefaultUsageLocation" -ForegroundColor Yellow
            if ($PSCmdlet.ShouldProcess($upn, "Set usage location to $DefaultUsageLocation")) {
                Update-MgUser -UserId $user.Id -UsageLocation $DefaultUsageLocation
            }
        }

        $licenseBody = @{
            AddLicenses    = @(@{ SkuId = $resolvedSku.SkuId })
            RemoveLicenses = @()
        }

        if ($PSCmdlet.ShouldProcess($upn, "Assign license $LicenseSku")) {
            Set-MgUserLicense -UserId $user.Id -BodyParameter $licenseBody -ErrorAction Stop
            Write-Host "[SUCCESS] License assigned: $upn" -ForegroundColor Green
            $diffReport += [PSCustomObject]@{
                RunId             = $runId
                UserPrincipalName = $upn
                DisplayName       = $user.DisplayName
                Action            = "Assigned"
                Sku               = $LicenseSku
                Reason            = "License was missing — assigned from source"
                WhatIf            = $WhatIfPreference.ToString()
                Timestamp         = $runTimestamp
            }
            $counters.Assigned++
            $availableSeats--
        }
        else {
            Write-Host "[WhatIf] Would assign $LicenseSku to: $upn" -ForegroundColor Cyan
        }
    }
    catch {
        $errMsg = "Unexpected error processing '$upn': $_"
        Write-Host "[ERROR] $errMsg" -ForegroundColor Red
        $diffReport += [PSCustomObject]@{
            RunId             = $runId
            UserPrincipalName = $upn
            DisplayName       = "N/A"
            Action            = "Error"
            Sku               = $LicenseSku
            Reason            = $errMsg
            WhatIf            = $WhatIfPreference.ToString()
            Timestamp         = $runTimestamp
        }
        $counters.Errors++
    }
}

#endregion

#region ── Step 4: Reconcile — Remove Unlicensed Users (Optional) ─────────────

Write-Host "[Step 4] Reconciling — checking for licenses to remove..." -ForegroundColor Cyan

if (-not $RemoveUnlicensed) {
    Write-Host "[INFO] -RemoveUnlicensed not specified. Skipping removal pass." -ForegroundColor Cyan
}
else {
    # Pull all users in the tenant who currently hold this SKU
    $licensedInTenant = Get-MgUser -Filter "assignedLicenses/any(x:x/skuId eq $($resolvedSku.SkuId))" `
                                   -Property "Id,UserPrincipalName,DisplayName" `
                                   -All -ErrorAction Stop

    Write-Host "[INFO] $($licensedInTenant.Count) user(s) currently hold SKU '$LicenseSku' in tenant." -ForegroundColor Cyan

    foreach ($licensedUser in $licensedInTenant) {
        $upnNormalized = $licensedUser.UserPrincipalName.ToLower().Trim()

        # If this user is in the authoritative source, they should keep the license
        if ($sourceUpns -contains $upnNormalized) { continue }

        # Not in source — license should be removed
        Write-Host "[INFO] Removing license from unlicensed user: $upnNormalized" -ForegroundColor Yellow

        try {
            $removeBody = @{
                AddLicenses    = @()
                RemoveLicenses = @($resolvedSku.SkuId)
            }

            if ($PSCmdlet.ShouldProcess($upnNormalized, "Remove license $LicenseSku")) {
                Set-MgUserLicense -UserId $licensedUser.Id -BodyParameter $removeBody -ErrorAction Stop
                Write-Host "[SUCCESS] License removed: $upnNormalized" -ForegroundColor Green
                $diffReport += [PSCustomObject]@{
                    RunId             = $runId
                    UserPrincipalName = $upnNormalized
                    DisplayName       = $licensedUser.DisplayName
                    Action            = "Removed"
                    Sku               = $LicenseSku
                    Reason            = "User not present in authoritative source"
                    WhatIf            = $WhatIfPreference.ToString()
                    Timestamp         = $runTimestamp
                }
                $counters.Removed++
            }
            else {
                Write-Host "[WhatIf] Would remove $LicenseSku from: $upnNormalized" -ForegroundColor Cyan
            }
        }
        catch {
            $errMsg = "Failed to remove license from '$upnNormalized': $_"
            Write-Host "[ERROR] $errMsg" -ForegroundColor Red
            $diffReport += [PSCustomObject]@{
                RunId             = $runId
                UserPrincipalName = $upnNormalized
                DisplayName       = $licensedUser.DisplayName
                Action            = "Error"
                Sku               = $LicenseSku
                Reason            = $errMsg
                WhatIf            = $WhatIfPreference.ToString()
                Timestamp         = $runTimestamp
            }
            $counters.Errors++
        }
    }
}

#endregion

#region ── Step 5: Output Report ──────────────────────────────────────────────

Write-Host "`n=== Sync-LicenseAssignment COMPLETE ===" -ForegroundColor Green
Write-Host "Assigned  : $($counters.Assigned)" -ForegroundColor Green
Write-Host "Removed   : $($counters.Removed)" -ForegroundColor Green
Write-Host "No Change : $($counters.NoChange)" -ForegroundColor Cyan
Write-Host "Not Found : $($counters.NotFound)" -ForegroundColor Yellow
Write-Host "Errors    : $($counters.Errors)" -ForegroundColor $(if ($counters.Errors -gt 0) { "Red" } else { "Green" })

# Write structured JSON report
$reportOutput = [PSCustomObject]@{
    RunId      = $runId
    RunAt      = $runTimestamp
    Sku        = $LicenseSku
    CsvSource  = $CsvPath
    WhatIf     = $WhatIfPreference.ToString()
    Summary    = $counters
    Diff       = $diffReport
}

try {
    $reportOutput | ConvertTo-Json -Depth 5 | Set-Content -Path $ReportPath -Encoding UTF8
    Write-Host "JSON report written to: $ReportPath" -ForegroundColor Cyan
}
catch {
    Write-Host "[WARN] Could not write JSON report to '$ReportPath': $_" -ForegroundColor Yellow
}

# Optionally write a flat CSV version of the diff for easier review
if ($ExportCsv) {
    $csvReportPath = $ReportPath -replace '\.json$', '.csv'
    try {
        $diffReport | Export-Csv -Path $csvReportPath -NoTypeInformation -Encoding UTF8
        Write-Host "CSV report written to : $csvReportPath" -ForegroundColor Cyan
    }
    catch {
        Write-Host "[WARN] Could not write CSV report to '$csvReportPath': $_" -ForegroundColor Yellow
    }
}

# Return the structured report object for pipeline use
return $reportOutput

#endregion
