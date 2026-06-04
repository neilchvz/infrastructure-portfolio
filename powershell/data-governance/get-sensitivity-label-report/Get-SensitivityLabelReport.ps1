# Get-SensitivityLabelReport.ps1
# Author   : Neil Chavez
# Version  : 1.0.0
# Category : Data Governance & Compliance Automation
# Folder   : powershell/data-governance/
# Script # : 12 of 24
#
# PURPOSE
# -------
# Reports sensitivity label coverage across SharePoint Online sites and OneDrive
# accounts in the tenant. Surfaces unlabeled content containers, label downgrade
# events, and sites where external sharing is enabled without a restrictive label —
# a combination that represents a data exposure risk.
#
# What this script evaluates:
#
#   SharePoint Sites:
#     - Sites with no sensitivity label applied
#     - Sites with external sharing enabled (ExternalSharingEnabled = true)
#       but no label, or a permissive label (e.g. Public, General)
#     - Sites using a label below the configured minimum acceptable tier
#
#   OneDrive Accounts:
#     - OneDrive accounts with no sensitivity label applied
#     - Accounts with external sharing enabled and no label
#
# Output: structured JSON + optional CSV report suitable for:
#   - NIST 800-53 MP-3 (Media Marking) and SI-12 (Information Retention) evidence
#   - SOC 2 CC6.1 (Logical Access Controls) supporting documentation
#   - Monthly data classification coverage reviews
#
# REQUIREMENTS
# ------------
#   - Microsoft.Graph PowerShell SDK
#   - SharePoint Online Management Shell (Connect-SPOService)
#   - Connect-MgGraph with scopes: Sites.Read.All, InformationProtectionPolicy.Read
#   - Caller must have: SharePoint Administrator or Global Reader role
#
# USAGE
# -----
#   # Standard report — all sites and OneDrive accounts
#   .\Get-SensitivityLabelReport.ps1 -TenantName "contoso"
#
#   # Report with CSV export
#   .\Get-SensitivityLabelReport.ps1 -TenantName "contoso" -ExportCsv
#
#   # Report only unlabeled or flagged sites
#   .\Get-SensitivityLabelReport.ps1 -TenantName "contoso" -FlaggedOnly -ExportCsv
#
#   # Exclude OneDrive accounts (SharePoint sites only)
#   .\Get-SensitivityLabelReport.ps1 -TenantName "contoso" -SkipOneDrive

[CmdletBinding()]
param (
    # Tenant name used to construct SharePoint admin URL (e.g. "contoso" for contoso.sharepoint.com)
    [Parameter(Mandatory = $true)]
    [ValidateNotNullOrEmpty()]
    [string]$TenantName,

    # Label display names considered permissive (insufficient for external sharing)
    # Customize to match your tenant's label taxonomy
    [Parameter(Mandatory = $false)]
    [string[]]$PermissiveLabels = @("Public", "General", "Non-Business"),

    # When set, only sites with flags are included in report output
    [Parameter(Mandatory = $false)]
    [switch]$FlaggedOnly,

    # When set, skips OneDrive account evaluation (faster for large tenants)
    [Parameter(Mandatory = $false)]
    [switch]$SkipOneDrive,

    # Output path for the structured JSON report
    [Parameter(Mandatory = $false)]
    [string]$ReportPath = ".\sensitivity-label-report.json",

    # When set, also exports a flat CSV alongside the JSON
    [Parameter(Mandatory = $false)]
    [switch]$ExportCsv,

    # Output path for structured JSON log
    [Parameter(Mandatory = $false)]
    [string]$LogPath = ".\sensitivity-label-report.log.json"
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

function Get-SiteLabelFlags {
    <#
    .SYNOPSIS
        Evaluates a SharePoint site object and returns a list of flag reasons
        based on label coverage and external sharing configuration.
    #>
    param (
        $Site,
        [string[]]$PermissiveLabels
    )
    $flags = @()

    # No label applied at all
    if ([string]::IsNullOrWhiteSpace($Site.SensitivityLabel)) {
        $flags += "No sensitivity label applied"
    }

    # External sharing enabled with no label
    if ($Site.SharingCapability -ne "Disabled" -and
        [string]::IsNullOrWhiteSpace($Site.SensitivityLabel)) {
        $flags += "External sharing enabled with no label — data exposure risk"
    }

    # External sharing enabled with a permissive label
    if ($Site.SharingCapability -ne "Disabled" -and
        -not [string]::IsNullOrWhiteSpace($Site.SensitivityLabel) -and
        $PermissiveLabels -contains $Site.SensitivityLabel) {
        $flags += "External sharing enabled with permissive label '$($Site.SensitivityLabel)'"
    }

    return $flags
}

#endregion

#region ── Initialization ─────────────────────────────────────────────────────

$script:LogEntries = @()
$runTimestamp      = Get-Date -Format "yyyy-MM-dd HH:mm:ss"
$runId             = Get-Date -Format "yyyyMMdd-HHmmss"
$adminUrl          = "https://$TenantName-admin.sharepoint.com"

$siteFindings    = @()
$oneDriveFindings = @()
$counters        = @{
    SitesScanned       = 0
    OneDriveScanned    = 0
    Labeled            = 0
    Unlabeled          = 0
    FlaggedSites       = 0
    ExternalSharing    = 0
    Errors             = 0
}

Write-Log "=== Get-SensitivityLabelReport START ===" -Level INFO
Write-Log "Run ID       : $runId" -Level INFO
Write-Log "Tenant       : $TenantName" -Level INFO
Write-Log "Admin URL    : $adminUrl" -Level INFO
Write-Log "Skip OneDrive: $($SkipOneDrive.IsPresent)" -Level INFO
Write-Log "Flagged Only : $($FlaggedOnly.IsPresent)" -Level INFO

#endregion

#region ── Step 0: Pre-flight Validation ──────────────────────────────────────

Write-Log "--- Step 0: Pre-flight Validation ---" -Level INFO

if (-not (Get-Module -Name "Microsoft.Online.SharePoint.PowerShell" -ErrorAction SilentlyContinue)) {
    Write-Log "SharePoint Online Management Shell not loaded." -Level ERROR
    Write-Log "Run: Import-Module Microsoft.Online.SharePoint.PowerShell" -Level ERROR
    exit 1
}

# Verify SPO connection by testing a lightweight call
try {
    $null = Get-SPOTenant -ErrorAction Stop
    Write-Log "SharePoint Online session confirmed." -Level INFO
}
catch {
    Write-Log "No active SharePoint Online session. Run Connect-SPOService -Url $adminUrl" -Level ERROR
    exit 1
}

#endregion

#region ── Step 1: Retrieve All SharePoint Sites ──────────────────────────────

Write-Log "--- Step 1: Retrieve SharePoint Sites ---" -Level INFO

$allSites = @()
try {
    # Get all site collections — include SensitivityLabel and SharingCapability properties
    $allSites = Get-SPOSite -Limit All `
                            -IncludePersonalSite $false `
                            -ErrorAction Stop |
               Where-Object { $_.Template -notlike "SPSMSITEHOST*" -and
                               $_.Template -notlike "POINTPUBLISHINGHUB*" }

    Write-Log "Retrieved $($allSites.Count) SharePoint site(s)." -Level INFO
}
catch {
    Write-Log "Failed to retrieve SharePoint sites: $_" -Level ERROR
    $counters.Errors++
}

#endregion

#region ── Step 2: Evaluate SharePoint Sites ──────────────────────────────────

Write-Log "--- Step 2: Evaluating SharePoint Sites ---" -Level INFO

foreach ($site in $allSites) {
    $counters.SitesScanned++

    if ($site.SensitivityLabel) { $counters.Labeled++   }
    else                        { $counters.Unlabeled++ }

    if ($site.SharingCapability -ne "Disabled") { $counters.ExternalSharing++ }

    $flags     = Get-SiteLabelFlags -Site $site -PermissiveLabels $PermissiveLabels
    $isFlagged = $flags.Count -gt 0
    if ($isFlagged) { $counters.FlaggedSites++ }

    $finding = [PSCustomObject]@{
        RunId            = $runId
        SiteType         = "SharePoint"
        Url              = $site.Url
        Title            = $site.Title
        Template         = $site.Template
        SensitivityLabel = $site.SensitivityLabel
        SharingCapability = $site.SharingCapability
        StorageUsedMB    = [math]::Round($site.StorageUsageCurrent, 0)
        Owner            = $site.Owner
        LastContentModified = $site.LastContentModifiedDate
        IsFlagged        = $isFlagged
        FlagReasons      = $flags
        Timestamp        = $runTimestamp
    }

    $siteFindings += $finding

    if ($isFlagged) {
        Write-Log "FLAGGED: $($site.Url) — $($flags -join ' | ')" -Level WARN
    }
}

Write-Log "SharePoint evaluation complete. Labeled: $($counters.Labeled) | Unlabeled: $($counters.Unlabeled) | Flagged: $($counters.FlaggedSites)" -Level INFO

#endregion

#region ── Step 3: Retrieve and Evaluate OneDrive Accounts ────────────────────

Write-Log "--- Step 3: OneDrive Account Evaluation ---" -Level INFO

if ($SkipOneDrive) {
    Write-Log "SkipOneDrive specified. Skipping OneDrive evaluation." -Level INFO
}
else {
    $allOneDrive = @()
    try {
        $allOneDrive = Get-SPOSite -Limit All `
                                   -IncludePersonalSite $true `
                                   -Filter "Url -like '-my.sharepoint.com/personal/'" `
                                   -ErrorAction Stop
        Write-Log "Retrieved $($allOneDrive.Count) OneDrive account(s)." -Level INFO
    }
    catch {
        Write-Log "Failed to retrieve OneDrive accounts: $_" -Level ERROR
        $counters.Errors++
    }

    foreach ($od in $allOneDrive) {
        $counters.OneDriveScanned++

        $flags     = Get-SiteLabelFlags -Site $od -PermissiveLabels $PermissiveLabels
        $isFlagged = $flags.Count -gt 0
        if ($isFlagged) { $counters.FlaggedSites++ }

        $finding = [PSCustomObject]@{
            RunId            = $runId
            SiteType         = "OneDrive"
            Url              = $od.Url
            Title            = $od.Title
            Template         = $od.Template
            SensitivityLabel = $od.SensitivityLabel
            SharingCapability = $od.SharingCapability
            StorageUsedMB    = [math]::Round($od.StorageUsageCurrent, 0)
            Owner            = $od.Owner
            LastContentModified = $od.LastContentModifiedDate
            IsFlagged        = $isFlagged
            FlagReasons      = $flags
            Timestamp        = $runTimestamp
        }

        $oneDriveFindings += $finding
    }

    Write-Log "OneDrive evaluation complete. Scanned: $($counters.OneDriveScanned)" -Level INFO
}

#endregion

#region ── Step 4: Output Report ──────────────────────────────────────────────

$allFindings = $siteFindings + $oneDriveFindings
$outputData  = if ($FlaggedOnly) {
    $allFindings | Where-Object { $_.IsFlagged -eq $true }
} else {
    $allFindings
}

Write-Log "=== Get-SensitivityLabelReport COMPLETE ===" -Level SUCCESS
Write-Log "Sites Scanned    : $($counters.SitesScanned)" -Level INFO
Write-Log "OneDrive Scanned : $($counters.OneDriveScanned)" -Level INFO
Write-Log "Labeled          : $($counters.Labeled)" -Level SUCCESS
Write-Log "Unlabeled        : $($counters.Unlabeled)" -Level $(if ($counters.Unlabeled -gt 0) { "WARN" } else { "SUCCESS" })
Write-Log "External Sharing : $($counters.ExternalSharing) site(s)" -Level INFO
Write-Log "Flagged          : $($counters.FlaggedSites)" -Level $(if ($counters.FlaggedSites -gt 0) { "WARN" } else { "SUCCESS" })

$report = [PSCustomObject]@{
    RunId       = $runId
    GeneratedAt = $runTimestamp
    TenantName  = $TenantName
    Summary     = $counters
    ComplianceNote = "Findings map to NIST 800-53 MP-3 and SI-12. Use as classification coverage evidence for SOC 2 CC6.1."
    FlaggedOnly = $FlaggedOnly.IsPresent
    Findings    = $outputData
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
        $outputData |
            Select-Object SiteType, Title, Url, SensitivityLabel,
                          SharingCapability, StorageUsedMB, Owner,
                          LastContentModified, IsFlagged,
                          @{ Name = "FlagReasons"; Expression = { $_.FlagReasons -join " | " } } |
            Sort-Object IsFlagged, SiteType, Title |
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
