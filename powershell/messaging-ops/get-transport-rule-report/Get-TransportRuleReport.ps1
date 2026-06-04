# Get-TransportRuleReport.ps1
# Author   : Neil Chavez
# Version  : 1.0.0
# Category : Messaging Infrastructure Ops
# Folder   : powershell/messaging-ops/
# Script # : 10 of 24
#
# PURPOSE
# -------
# Exports all Exchange Online transport (mail flow) rules with their full
# configuration — conditions, exceptions, actions, and priority order — into
# a structured report for documentation, security review, and compliance auditing.
#
# Transport rules accumulate over time and often lose their original owners and
# business justification. This script surfaces the full rule inventory and flags
# conditions that represent elevated risk or require review:
#
#   Flagged conditions:
#     - Rules that bypass spam filtering (SCL -1)
#     - Rules in a Disabled state (dead config — should be removed or documented)
#     - Rules with no description or comment (no owner/purpose documented)
#     - Rules that redirect or blind-copy email to external addresses
#     - Rules that modify subject lines or add headers (potential exfil indicators)
#
# Output: structured JSON report + optional CSV, suitable for:
#   - Change management documentation
#   - Security review and insider threat analysis
#   - Auditor evidence packages
#   - Periodic mail flow hygiene reviews
#
# REQUIREMENTS
# ------------
#   - ExchangeOnlineManagement module (Connect-ExchangeOnline)
#   - Caller must have: View-Only Organization Management or Exchange Administrator
#
# USAGE
# -----
#   # Export all rules to default output path
#   .\Get-TransportRuleReport.ps1
#
#   # Export with CSV for sharing with compliance team
#   .\Get-TransportRuleReport.ps1 -ExportCsv
#
#   # Report only flagged/high-risk rules
#   .\Get-TransportRuleReport.ps1 -FlaggedOnly -ExportCsv
#
#   # Export to specific output path
#   .\Get-TransportRuleReport.ps1 -ReportPath ".\audit\transport-rules-$(Get-Date -Format 'yyyyMMdd').json"

[CmdletBinding()]
param (
    # Output path for the structured JSON report
    [Parameter(Mandatory = $false)]
    [string]$ReportPath = ".\transport-rule-report.json",

    # When set, also exports a flat CSV version of the report
    [Parameter(Mandatory = $false)]
    [switch]$ExportCsv,

    # When set, only includes rules that have been flagged for review
    # Useful for producing a focused remediation list
    [Parameter(Mandatory = $false)]
    [switch]$FlaggedOnly,

    # Output path for structured JSON log
    [Parameter(Mandatory = $false)]
    [string]$LogPath = ".\transport-rule-report.log.json"
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

function Get-RuleFlags {
    <#
    .SYNOPSIS
        Evaluates a transport rule object and returns a list of flag reasons
        based on conditions that warrant security or compliance review.
    #>
    param ($Rule)

    $flags = @()

    # Disabled rules — dead config that should be removed or documented
    if ($Rule.State -eq "Disabled") {
        $flags += "Rule is disabled — remove or document if still required"
    }

    # No description — no owner or business justification recorded
    if ([string]::IsNullOrWhiteSpace($Rule.Description) -and
        [string]::IsNullOrWhiteSpace($Rule.Comments)) {
        $flags += "No description or comments — owner/purpose unknown"
    }

    # Spam filter bypass — SCL set to -1 bypasses all spam filtering
    if ($Rule.SetSCL -eq -1) {
        $flags += "Bypasses spam filtering (SCL = -1) — verify sender legitimacy"
    }

    # External redirect — BCC or redirect to an external domain
    if ($Rule.BlindCopyTo) {
        $externalBcc = $Rule.BlindCopyTo | Where-Object { $_ -notlike "*@contoso.com" }
        if ($externalBcc) {
            $flags += "Blind copies email to external address(es): $($externalBcc -join ', ')"
        }
    }

    if ($Rule.RedirectMessageTo) {
        $externalRedirect = $Rule.RedirectMessageTo | Where-Object { $_ -notlike "*@contoso.com" }
        if ($externalRedirect) {
            $flags += "Redirects email to external address(es): $($externalRedirect -join ', ')"
        }
    }

    # Subject modification — masking, spoofing, or exfil indicator
    if ($Rule.PrependSubject -or $Rule.SetHeaderName) {
        $flags += "Modifies message subject or headers — review for data handling risk"
    }

    # Catch-all forward — forwards all mail matching broad conditions
    if ($Rule.CopyTo -or $Rule.AddToRecipients) {
        $forwardTargets = @($Rule.CopyTo) + @($Rule.AddToRecipients) | Where-Object { $_ }
        $externalForwards = $forwardTargets | Where-Object { $_ -notlike "*@contoso.com" }
        if ($externalForwards) {
            $flags += "Forwards or copies to external recipient(s): $($externalForwards -join ', ')"
        }
    }

    return $flags
}

#endregion

#region ── Initialization ─────────────────────────────────────────────────────

$script:LogEntries = @()
$runTimestamp      = Get-Date -Format "yyyy-MM-dd HH:mm:ss"
$runId             = Get-Date -Format "yyyyMMdd-HHmmss"

$ruleReports = @()
$counters    = @{
    TotalRules    = 0
    EnabledRules  = 0
    DisabledRules = 0
    FlaggedRules  = 0
    Errors        = 0
}

Write-Log "=== Get-TransportRuleReport START ===" -Level INFO
Write-Log "Run ID      : $runId" -Level INFO
Write-Log "Report Path : $ReportPath" -Level INFO
Write-Log "Flagged Only: $($FlaggedOnly.IsPresent)" -Level INFO

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

#region ── Step 1: Retrieve All Transport Rules ────────────────────────────────

Write-Log "--- Step 1: Retrieve Transport Rules ---" -Level INFO

$allRules = @()
try {
    # Get-TransportRule retrieves the full rule configuration including all conditions,
    # exceptions, and actions — no property filtering needed here
    $allRules = Get-TransportRule -ErrorAction Stop | Sort-Object Priority
    $counters.TotalRules = $allRules.Count
    Write-Log "Retrieved $($allRules.Count) transport rule(s)." -Level INFO
}
catch {
    Write-Log "Failed to retrieve transport rules: $_" -Level ERROR
    exit 1
}

if ($allRules.Count -eq 0) {
    Write-Log "No transport rules found in tenant." -Level WARN
    exit 0
}

#endregion

#region ── Step 2: Evaluate and Document Each Rule ────────────────────────────

Write-Log "--- Step 2: Evaluating Rules ---" -Level INFO

foreach ($rule in $allRules) {

    # Track enabled vs disabled counts
    if ($rule.State -eq "Enabled") { $counters.EnabledRules++ }
    else                           { $counters.DisabledRules++ }

    # Run flag evaluation
    $flags = Get-RuleFlags -Rule $rule
    $isFlagged = $flags.Count -gt 0

    if ($isFlagged) {
        $counters.FlaggedRules++
        Write-Log "[$($rule.Priority)] FLAGGED: '$($rule.Name)' — $($flags -join ' | ')" -Level WARN
    }
    else {
        Write-Log "[$($rule.Priority)] OK: '$($rule.Name)' | State: $($rule.State)" -Level INFO
    }

    # Build structured rule document
    # Captures all operationally significant fields without the raw PS object noise
    $ruleDoc = [PSCustomObject]@{
        RunId            = $runId
        Priority         = $rule.Priority
        Name             = $rule.Name
        State            = $rule.State
        Mode             = $rule.Mode           # Enforce, Audit, AuditAndNotify
        Description      = $rule.Description
        Comments         = $rule.Comments

        # Conditions — what triggers the rule
        Conditions       = [PSCustomObject]@{
            From                    = $rule.From
            FromMemberOf            = $rule.FromMemberOf
            SentTo                  = $rule.SentTo
            SentToMemberOf          = $rule.SentToMemberOf
            SubjectContains         = $rule.SubjectContainsWords
            SubjectOrBodyContains   = $rule.SubjectOrBodyContainsWords
            HasAttachment           = $rule.AttachmentHasExecutableContent
            RecipientDomainIs       = $rule.RecipientDomainIs
            SenderDomainIs          = $rule.SenderDomainIs
            SenderIPRanges          = $rule.SenderIpRanges
        }

        # Actions — what the rule does when triggered
        Actions          = [PSCustomObject]@{
            SetSCL                  = $rule.SetSCL
            RejectMessage           = $rule.RejectMessageReasonText
            RedirectTo              = $rule.RedirectMessageTo
            BlindCopyTo             = $rule.BlindCopyTo
            CopyTo                  = $rule.CopyTo
            AddRecipients           = $rule.AddToRecipients
            PrependSubject          = $rule.PrependSubject
            SetHeader               = $rule.SetHeaderName
            AddDisclaimerText       = if ($rule.ApplyHtmlDisclaimerText) { "[Disclaimer configured]" } else { $null }
            QuarantineMessage       = $rule.QuarantineMessageAction
        }

        # Exceptions — who or what the rule skips
        Exceptions       = [PSCustomObject]@{
            ExceptFrom              = $rule.ExceptIfFrom
            ExceptSentTo            = $rule.ExceptIfSentTo
            ExceptSubjectContains   = $rule.ExceptIfSubjectContainsWords
        }

        # Risk and governance flags
        IsFlagged        = $isFlagged
        FlagReasons      = $flags
        CreatedBy        = $rule.CreatedBy
        WhenCreated      = $rule.WhenCreated
        WhenChanged      = $rule.WhenChanged
        Timestamp        = $runTimestamp
    }

    $ruleReports += $ruleDoc
}

Write-Log "Rule evaluation complete." -Level INFO
Write-Log "Enabled : $($counters.EnabledRules) | Disabled: $($counters.DisabledRules) | Flagged: $($counters.FlaggedRules)" -Level INFO

#endregion

#region ── Step 3: Output Report ──────────────────────────────────────────────

Write-Log "=== Get-TransportRuleReport COMPLETE ===" -Level SUCCESS
Write-Log "Total Rules   : $($counters.TotalRules)" -Level INFO
Write-Log "Enabled       : $($counters.EnabledRules)" -Level INFO
Write-Log "Disabled      : $($counters.DisabledRules)" -Level $(if ($counters.DisabledRules -gt 0) { "WARN" } else { "INFO" })
Write-Log "Flagged       : $($counters.FlaggedRules)" -Level $(if ($counters.FlaggedRules -gt 0) { "WARN" } else { "SUCCESS" })

# Apply FlaggedOnly filter if requested
$outputRules = if ($FlaggedOnly) {
    $ruleReports | Where-Object { $_.IsFlagged -eq $true }
} else {
    $ruleReports
}

$report = [PSCustomObject]@{
    RunId       = $runId
    GeneratedAt = $runTimestamp
    Summary     = $counters
    FlaggedOnly = $FlaggedOnly.IsPresent
    Rules       = $outputRules
}

try {
    $report | ConvertTo-Json -Depth 8 | Set-Content -Path $ReportPath -Encoding UTF8
    Write-Log "JSON report written to: $ReportPath" -Level INFO
}
catch {
    Write-Log "Could not write JSON report: $_" -Level WARN
}

if ($ExportCsv) {
    $csvPath = $ReportPath -replace '\.json$', '.csv'
    try {
        $outputRules |
            Select-Object Priority, Name, State, Mode,
                          @{ Name = "SetSCL";       Expression = { $_.Actions.SetSCL } },
                          @{ Name = "RedirectTo";   Expression = { $_.Actions.RedirectTo -join "; " } },
                          @{ Name = "BlindCopyTo";  Expression = { $_.Actions.BlindCopyTo -join "; " } },
                          IsFlagged,
                          @{ Name = "FlagReasons";  Expression = { $_.FlagReasons -join " | " } },
                          WhenCreated, WhenChanged, CreatedBy |
            Sort-Object Priority |
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
