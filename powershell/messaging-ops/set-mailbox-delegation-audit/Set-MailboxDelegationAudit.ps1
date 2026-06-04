<#
.SYNOPSIS
    Enumerates all mailbox delegation assignments across the Exchange Online tenant,
    flags non-standard or unauthorized delegations against an approved baseline,
    and produces a structured audit report with optional remediation.

.DESCRIPTION
    Set-MailboxDelegationAudit.ps1 queries every mailbox in the Exchange Online
    organization and collects all three delegation types: FullAccess, SendAs, and
    SendOnBehalf. Results are compared against an optional approved baseline CSV.
    Any delegation not present in the baseline is flagged for review.

    It performs the following steps:
        1. Validates required modules and active Exchange Online session.
        2. Retrieves all user and shared mailboxes in the tenant.
        3. For each mailbox, collects FullAccess, SendAs, and SendOnBehalf permissions.
        4. Filters out system-level and self-delegations (noise reduction).
        5. Optionally compares results against an approved baseline CSV.
        6. Flags non-standard delegations with a configurable risk level.
        7. Optionally removes flagged delegations with -Remediate switch.
        8. Writes a structured JSON and optional CSV report.

    REQUIREMENTS:
        - ExchangeOnlineManagement module (Connect-ExchangeOnline)
        - Caller must have: Exchange Administrator or View-Only Organization
          Management role in Exchange Online.

.PARAMETER BaselineCsvPath
    Optional. Path to a CSV file containing approved delegation assignments.
    CSV must have headers: Mailbox, DelegateUPN, PermissionType
    If omitted, all delegations are reported without a baseline comparison.

.PARAMETER IncludeSharedMailboxes
    Switch. When set, shared mailboxes are included in the audit scope.
    By default only user mailboxes are evaluated.

.PARAMETER IncludeSystemDelegations
    Switch. When set, system-level delegations (e.g. NT AUTHORITY entries,
    self-permissions) are included in output. By default these are filtered
    as noise since they are standard Exchange internal assignments.

.PARAMETER Remediate
    Switch. When set, delegations flagged as non-baseline are removed.
    Requires -BaselineCsvPath to be specified. Use with -WhatIf first.
    THIS IS A DESTRUCTIVE OPERATION — test with -WhatIf before running live.

.PARAMETER ReportPath
    Output path for the structured JSON audit report.
    Defaults to .\mailbox-delegation-audit.json

.PARAMETER ExportCsv
    Switch. When set, also exports a flat CSV version of the report.
    Useful for sharing with compliance or security teams.

.PARAMETER WhatIf
    Runs the script in simulation mode. No delegations are removed.
    All findings are still reported.

.PARAMETER LogPath
    Optional. Path to write a structured JSON log for this run.
    Defaults to .\mailbox-delegation-audit.log.json

.EXAMPLE
    # Full tenant audit — report only, no baseline comparison
    .\Set-MailboxDelegationAudit.ps1 -ExportCsv

.EXAMPLE
    # Audit against an approved baseline, include shared mailboxes
    .\Set-MailboxDelegationAudit.ps1 `
        -BaselineCsvPath ".\approved-delegations.csv" `
        -IncludeSharedMailboxes `
        -ExportCsv

.EXAMPLE
    # Dry run remediation — see what would be removed
    .\Set-MailboxDelegationAudit.ps1 `
        -BaselineCsvPath ".\approved-delegations.csv" `
        -Remediate `
        -WhatIf

.EXAMPLE
    # Live remediation — remove all non-baseline delegations
    .\Set-MailboxDelegationAudit.ps1 `
        -BaselineCsvPath ".\approved-delegations.csv" `
        -Remediate

.NOTES
    Author      : Neil Chavez
    Version     : 1.0.0
    Category    : Messaging Infrastructure Ops
    Folder      : powershell/messaging-ops/
    Script #    : 08 of 24

    Risk Note   : FullAccess and SendAs delegations are the highest risk types.
                  SendOnBehalf is lower risk but should still be documented.
                  Any delegation to an external or guest account is automatically
                  flagged as high risk regardless of baseline status.

    Performance : Large tenants (10k+ mailboxes) may take 20-40 minutes to complete.
                  Consider scoping with -Filter on Get-EXOMailbox for targeted runs.

    Baseline CSV Format:
        Mailbox,DelegateUPN,PermissionType
        shared@contoso.com,manager@contoso.com,FullAccess
        shared@contoso.com,manager@contoso.com,SendAs

    Dependencies:
        Install-Module ExchangeOnlineManagement -Scope CurrentUser

    Connect before running:
        Connect-ExchangeOnline -UserPrincipalName admin@contoso.com
#>

[CmdletBinding(SupportsShouldProcess = $true)]
param (
    [Parameter(Mandatory = $false)]
    [ValidateScript({ Test-Path $_ -PathType Leaf })]
    [string]$BaselineCsvPath,

    [Parameter(Mandatory = $false)]
    [switch]$IncludeSharedMailboxes,

    [Parameter(Mandatory = $false)]
    [switch]$IncludeSystemDelegations,

    [Parameter(Mandatory = $false)]
    [switch]$Remediate,

    [Parameter(Mandatory = $false)]
    [string]$ReportPath = ".\mailbox-delegation-audit.json",

    [Parameter(Mandatory = $false)]
    [switch]$ExportCsv,

    [Parameter(Mandatory = $false)]
    [string]$LogPath = ".\mailbox-delegation-audit.log.json"
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

function Test-SystemTrustee {
    <#
    .SYNOPSIS
        Returns true if the trustee is a system-level account that should be
        filtered from delegation reports (noise reduction).
    #>
    param ([string]$Trustee)
    $systemPatterns = @(
        "NT AUTHORITY",
        "S-1-5-",          # SID-based entries
        "SELF",
        "Exchange Services",
        "Exchange Servers"
    )
    foreach ($pattern in $systemPatterns) {
        if ($Trustee -like "*$pattern*") { return $true }
    }
    return $false
}

#endregion

#region ── Initialization ─────────────────────────────────────────────────────

$script:LogEntries  = @()
$runTimestamp       = Get-Date -Format "yyyy-MM-dd HH:mm:ss"
$runId              = Get-Date -Format "yyyyMMdd-HHmmss"

# Accumulators
$allFindings        = @()
$remediationActions = @()
$counters           = @{
    MailboxesScanned   = 0
    DelegationsFound   = 0
    BaselineMatches    = 0
    NonBaselineFlags   = 0
    ExternalDelegates  = 0
    Remediated         = 0
    Errors             = 0
}

Write-Log "=== Set-MailboxDelegationAudit START ===" -Level INFO
Write-Log "Run ID              : $runId" -Level INFO
Write-Log "Baseline CSV        : $(if ($BaselineCsvPath) { $BaselineCsvPath } else { 'Not provided — all delegations reported' })" -Level INFO
Write-Log "Include Shared MBX  : $($IncludeSharedMailboxes.IsPresent)" -Level INFO
Write-Log "Remediate Mode      : $($Remediate.IsPresent)" -Level INFO
Write-Log "WhatIf Mode         : $($WhatIfPreference)" -Level INFO

# Safety guard — remediation requires a baseline to compare against
if ($Remediate -and -not $BaselineCsvPath) {
    Write-Log "-Remediate requires -BaselineCsvPath to be specified. Exiting." -Level ERROR
    exit 1
}

#endregion

#region ── Step 0: Pre-flight Validation ──────────────────────────────────────

Write-Log "--- Step 0: Pre-flight Validation ---" -Level INFO

if (-not (Get-Module -Name "ExchangeOnlineManagement" -ErrorAction SilentlyContinue)) {
    Write-Log "ExchangeOnlineManagement module not loaded. Run: Import-Module ExchangeOnlineManagement" -Level ERROR
    exit 1
}

# Verify active Exchange Online session
try {
    $null = Get-EXOMailbox -ResultSize 1 -ErrorAction Stop
    Write-Log "Exchange Online session confirmed." -Level INFO
}
catch {
    Write-Log "No active Exchange Online session. Run Connect-ExchangeOnline first." -Level ERROR
    exit 1
}

#endregion

#region ── Step 1: Load Approved Baseline (Optional) ──────────────────────────

Write-Log "--- Step 1: Load Approved Delegation Baseline ---" -Level INFO

$baselineEntries = @()

if ($BaselineCsvPath) {
    try {
        $baselineEntries = Import-Csv -Path $BaselineCsvPath -ErrorAction Stop

        # Validate required columns
        $requiredCols = @("Mailbox", "DelegateUPN", "PermissionType")
        foreach ($col in $requiredCols) {
            if (-not ($baselineEntries | Get-Member -Name $col -MemberType NoteProperty)) {
                Write-Log "Baseline CSV is missing required column: $col" -Level ERROR
                exit 1
            }
        }

        Write-Log "Baseline loaded: $($baselineEntries.Count) approved delegation(s)." -Level INFO
    }
    catch {
        Write-Log "Failed to load baseline CSV: $_" -Level ERROR
        exit 1
    }
}
else {
    Write-Log "No baseline provided. All delegations will be reported without comparison." -Level INFO
}

#endregion

#region ── Step 2: Retrieve Mailboxes ─────────────────────────────────────────

Write-Log "--- Step 2: Retrieve Mailboxes ---" -Level INFO

$mailboxTypes = @("UserMailbox")
if ($IncludeSharedMailboxes) { $mailboxTypes += "SharedMailbox" }

$allMailboxes = @()
foreach ($mbxType in $mailboxTypes) {
    try {
        $batch = Get-EXOMailbox -RecipientTypeDetails $mbxType `
                                -ResultSize Unlimited `
                                -Properties PrimarySmtpAddress, DisplayName, RecipientTypeDetails `
                                -ErrorAction Stop
        $allMailboxes += $batch
        Write-Log "Retrieved $($batch.Count) $mbxType mailbox(es)." -Level INFO
    }
    catch {
        Write-Log "Failed to retrieve $mbxType mailboxes: $_" -Level ERROR
        $counters.Errors++
    }
}

Write-Log "Total mailboxes in scope: $($allMailboxes.Count)" -Level INFO

if ($allMailboxes.Count -eq 0) {
    Write-Log "No mailboxes found in scope. Exiting." -Level WARN
    exit 0
}

#endregion

#region ── Step 3: Collect Delegation Assignments ─────────────────────────────

Write-Log "--- Step 3: Collecting Delegation Assignments ---" -Level INFO

foreach ($mailbox in $allMailboxes) {
    $counters.MailboxesScanned++
    $mbxUpn = $mailbox.PrimarySmtpAddress

    # Progress indicator for large tenants
    if ($counters.MailboxesScanned % 50 -eq 0) {
        Write-Log "Progress: $($counters.MailboxesScanned) / $($allMailboxes.Count) mailboxes processed..." -Level INFO
    }

    # ── FullAccess permissions ─────────────────────────────────────────────────
    try {
        $fullAccessPerms = Get-MailboxPermission -Identity $mbxUpn -ErrorAction SilentlyContinue |
                           Where-Object { $_.AccessRights -contains "FullAccess" -and $_.IsInherited -eq $false }

        foreach ($perm in $fullAccessPerms) {
            $trustee = $perm.User.ToString()

            # Filter system trustees unless explicitly included
            if (-not $IncludeSystemDelegations -and (Test-SystemTrustee $trustee)) { continue }

            $isExternal  = $trustee -notlike "*@*contoso*" -and $trustee -match "@"
            $inBaseline  = $baselineEntries | Where-Object {
                $_.Mailbox -eq $mbxUpn -and $_.DelegateUPN -eq $trustee -and $_.PermissionType -eq "FullAccess"
            }
            $flagged     = $BaselineCsvPath -and -not $inBaseline

            $allFindings += [PSCustomObject]@{
                RunId          = $runId
                Mailbox        = $mbxUpn
                MailboxType    = $mailbox.RecipientTypeDetails
                DelegateUPN    = $trustee
                PermissionType = "FullAccess"
                IsExternal     = $isExternal
                InBaseline     = ($null -ne $inBaseline)
                Flagged        = ($flagged -or $isExternal)
                FlagReason     = if ($isExternal) { "External delegate — high risk" }
                                 elseif ($flagged) { "Not present in approved baseline" }
                                 else { "" }
                Timestamp      = $runTimestamp
            }
            $counters.DelegationsFound++
            if ($flagged -or $isExternal) { $counters.NonBaselineFlags++ }
            if ($isExternal)              { $counters.ExternalDelegates++ }
            if ($inBaseline)              { $counters.BaselineMatches++   }
        }
    }
    catch {
        Write-Log "Failed to get FullAccess permissions for '$mbxUpn': $_" -Level WARN
        $counters.Errors++
    }

    # ── SendAs permissions ─────────────────────────────────────────────────────
    try {
        $sendAsPerms = Get-RecipientPermission -Identity $mbxUpn -ErrorAction SilentlyContinue |
                       Where-Object { $_.AccessRights -contains "SendAs" }

        foreach ($perm in $sendAsPerms) {
            $trustee = $perm.Trustee.ToString()

            if (-not $IncludeSystemDelegations -and (Test-SystemTrustee $trustee)) { continue }

            $isExternal  = $trustee -notlike "*@*contoso*" -and $trustee -match "@"
            $inBaseline  = $baselineEntries | Where-Object {
                $_.Mailbox -eq $mbxUpn -and $_.DelegateUPN -eq $trustee -and $_.PermissionType -eq "SendAs"
            }
            $flagged     = $BaselineCsvPath -and -not $inBaseline

            $allFindings += [PSCustomObject]@{
                RunId          = $runId
                Mailbox        = $mbxUpn
                MailboxType    = $mailbox.RecipientTypeDetails
                DelegateUPN    = $trustee
                PermissionType = "SendAs"
                IsExternal     = $isExternal
                InBaseline     = ($null -ne $inBaseline)
                Flagged        = ($flagged -or $isExternal)
                FlagReason     = if ($isExternal) { "External delegate — high risk" }
                                 elseif ($flagged) { "Not present in approved baseline" }
                                 else { "" }
                Timestamp      = $runTimestamp
            }
            $counters.DelegationsFound++
            if ($flagged -or $isExternal) { $counters.NonBaselineFlags++ }
            if ($isExternal)              { $counters.ExternalDelegates++ }
            if ($inBaseline)              { $counters.BaselineMatches++   }
        }
    }
    catch {
        Write-Log "Failed to get SendAs permissions for '$mbxUpn': $_" -Level WARN
        $counters.Errors++
    }

    # ── SendOnBehalf permissions ───────────────────────────────────────────────
    try {
        $sobPerms = $mailbox.GrantSendOnBehalfTo

        foreach ($trusteeObj in $sobPerms) {
            $trustee = $trusteeObj.ToString()

            $isExternal  = $trustee -notlike "*@*contoso*" -and $trustee -match "@"
            $inBaseline  = $baselineEntries | Where-Object {
                $_.Mailbox -eq $mbxUpn -and $_.DelegateUPN -eq $trustee -and $_.PermissionType -eq "SendOnBehalf"
            }
            $flagged     = $BaselineCsvPath -and -not $inBaseline

            $allFindings += [PSCustomObject]@{
                RunId          = $runId
                Mailbox        = $mbxUpn
                MailboxType    = $mailbox.RecipientTypeDetails
                DelegateUPN    = $trustee
                PermissionType = "SendOnBehalf"
                IsExternal     = $isExternal
                InBaseline     = ($null -ne $inBaseline)
                Flagged        = ($flagged -or $isExternal)
                FlagReason     = if ($isExternal) { "External delegate — high risk" }
                                 elseif ($flagged) { "Not present in approved baseline" }
                                 else { "" }
                Timestamp      = $runTimestamp
            }
            $counters.DelegationsFound++
            if ($flagged -or $isExternal) { $counters.NonBaselineFlags++ }
            if ($isExternal)              { $counters.ExternalDelegates++ }
            if ($inBaseline)              { $counters.BaselineMatches++   }
        }
    }
    catch {
        Write-Log "Failed to get SendOnBehalf permissions for '$mbxUpn': $_" -Level WARN
        $counters.Errors++
    }
}

Write-Log "Delegation collection complete. Total found: $($counters.DelegationsFound)" -Level INFO
Write-Log "Flagged (non-baseline or external): $($counters.NonBaselineFlags)" -Level $(
    if ($counters.NonBaselineFlags -gt 0) { "WARN" } else { "SUCCESS" }
)

#endregion

#region ── Step 4: Remediate Flagged Delegations (Optional) ───────────────────

Write-Log "--- Step 4: Remediation ---" -Level INFO

if (-not $Remediate) {
    Write-Log "Remediate switch not set. Skipping removal of flagged delegations." -Level INFO
}
else {
    $flaggedItems = $allFindings | Where-Object { $_.Flagged -eq $true }
    Write-Log "$($flaggedItems.Count) flagged delegation(s) queued for removal." -Level WARN

    foreach ($item in $flaggedItems) {
        try {
            switch ($item.PermissionType) {
                "FullAccess" {
                    if ($PSCmdlet.ShouldProcess($item.Mailbox, "Remove FullAccess delegation for '$($item.DelegateUPN)'")) {
                        Remove-MailboxPermission -Identity $item.Mailbox `
                                                 -User $item.DelegateUPN `
                                                 -AccessRights FullAccess `
                                                 -Confirm:$false `
                                                 -ErrorAction Stop
                        Write-Log "Removed FullAccess: $($item.DelegateUPN) → $($item.Mailbox)" -Level SUCCESS
                        $counters.Remediated++
                        $remediationActions += [PSCustomObject]@{
                            Action         = "Removed"
                            Mailbox        = $item.Mailbox
                            DelegateUPN    = $item.DelegateUPN
                            PermissionType = $item.PermissionType
                            Reason         = $item.FlagReason
                            Timestamp      = (Get-Date -Format "yyyy-MM-dd HH:mm:ss")
                        }
                    }
                }
                "SendAs" {
                    if ($PSCmdlet.ShouldProcess($item.Mailbox, "Remove SendAs delegation for '$($item.DelegateUPN)'")) {
                        Remove-RecipientPermission -Identity $item.Mailbox `
                                                   -Trustee $item.DelegateUPN `
                                                   -AccessRights SendAs `
                                                   -Confirm:$false `
                                                   -ErrorAction Stop
                        Write-Log "Removed SendAs: $($item.DelegateUPN) → $($item.Mailbox)" -Level SUCCESS
                        $counters.Remediated++
                        $remediationActions += [PSCustomObject]@{
                            Action         = "Removed"
                            Mailbox        = $item.Mailbox
                            DelegateUPN    = $item.DelegateUPN
                            PermissionType = $item.PermissionType
                            Reason         = $item.FlagReason
                            Timestamp      = (Get-Date -Format "yyyy-MM-dd HH:mm:ss")
                        }
                    }
                }
                "SendOnBehalf" {
                    # SendOnBehalf requires updating the mailbox object directly
                    if ($PSCmdlet.ShouldProcess($item.Mailbox, "Remove SendOnBehalf delegation for '$($item.DelegateUPN)'")) {
                        Set-Mailbox -Identity $item.Mailbox `
                                    -GrantSendOnBehalfTo @{ Remove = $item.DelegateUPN } `
                                    -ErrorAction Stop
                        Write-Log "Removed SendOnBehalf: $($item.DelegateUPN) → $($item.Mailbox)" -Level SUCCESS
                        $counters.Remediated++
                        $remediationActions += [PSCustomObject]@{
                            Action         = "Removed"
                            Mailbox        = $item.Mailbox
                            DelegateUPN    = $item.DelegateUPN
                            PermissionType = $item.PermissionType
                            Reason         = $item.FlagReason
                            Timestamp      = (Get-Date -Format "yyyy-MM-dd HH:mm:ss")
                        }
                    }
                }
            }
        }
        catch {
            $errMsg = "Failed to remove $($item.PermissionType) for '$($item.DelegateUPN)' on '$($item.Mailbox)': $_"
            Write-Log $errMsg -Level ERROR
            $counters.Errors++
        }
    }
}

#endregion

#region ── Step 5: Output Report ──────────────────────────────────────────────

Write-Log "=== Set-MailboxDelegationAudit COMPLETE ===" -Level SUCCESS
Write-Log "Mailboxes Scanned   : $($counters.MailboxesScanned)" -Level INFO
Write-Log "Delegations Found   : $($counters.DelegationsFound)" -Level INFO
Write-Log "Baseline Matches    : $($counters.BaselineMatches)" -Level INFO
Write-Log "Flagged             : $($counters.NonBaselineFlags)" -Level $(if ($counters.NonBaselineFlags -gt 0) { "WARN" } else { "SUCCESS" })
Write-Log "External Delegates  : $($counters.ExternalDelegates)" -Level $(if ($counters.ExternalDelegates -gt 0) { "WARN" } else { "SUCCESS" })
Write-Log "Remediated          : $($counters.Remediated)" -Level INFO
Write-Log "Errors              : $($counters.Errors)" -Level $(if ($counters.Errors -gt 0) { "WARN" } else { "INFO" })

$report = [PSCustomObject]@{
    RunId              = $runId
    GeneratedAt        = $runTimestamp
    Summary            = $counters
    BaselinePath       = $BaselineCsvPath
    RemediateMode      = $Remediate.IsPresent
    WhatIf             = $WhatIfPreference.ToString()
    Findings           = $allFindings
    RemediationActions = $remediationActions
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
        $allFindings |
            Select-Object Mailbox, MailboxType, DelegateUPN, PermissionType,
                          IsExternal, InBaseline, Flagged, FlagReason, Timestamp |
            Sort-Object Flagged, Mailbox |
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
