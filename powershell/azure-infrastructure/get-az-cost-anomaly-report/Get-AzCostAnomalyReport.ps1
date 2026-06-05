# Get-AzCostAnomalyReport.ps1
# Author   : Neil Chavez
# Version  : 1.0.0
# Category : Azure Infrastructure Automation
# Folder   : powershell/azure-infrastructure/
# Script # : 22 of 24
#
# PURPOSE
# -------
# Queries Azure Cost Management APIs for daily spend per subscription and resource
# group, compares actual spend against a rolling 30-day baseline, and flags
# anomalies exceeding a configurable percentage threshold. Outputs structured JSON
# suitable for alert routing, dashboard ingestion, or Slack/Teams webhook delivery.
#
# FinOps awareness is increasingly expected at Platform Engineer and Staff Engineer
# level at SaaS companies. Cost spikes from misconfigured resources, runaway
# autoscale events, or forgotten dev environments often go undetected until the
# monthly invoice arrives. This script enables proactive anomaly detection on
# a daily or scheduled basis.
#
# Anomaly logic:
#   1. Query actual daily spend for the last N days (default: 7 days)
#   2. Query rolling 30-day average as the baseline
#   3. For each subscription and resource group, calculate deviation %
#   4. Flag any day/scope where deviation exceeds -AnomalyThresholdPercent (default: 20%)
#   5. Output a ranked anomaly list with actual spend, baseline, deviation, and currency
#
# REQUIREMENTS
# ------------
#   - Az PowerShell module (Az.CostManagement, Az.Accounts, Az.Resources)
#   - Connect-AzAccount
#   - Cost Management Reader role on target subscription(s)
#
# USAGE
# -----
#   # Check current subscription for cost anomalies (last 7 days vs 30-day baseline)
#   .\Get-AzCostAnomalyReport.ps1
#
#   # Check specific subscriptions
#   .\Get-AzCostAnomalyReport.ps1 -SubscriptionIds @("sub-id-1", "sub-id-2")
#
#   # Custom threshold and lookback window
#   .\Get-AzCostAnomalyReport.ps1 -AnomalyThresholdPercent 30 -LookbackDays 14
#
#   # Include resource group level breakdown
#   .\Get-AzCostAnomalyReport.ps1 -IncludeResourceGroupBreakdown -ExportCsv

[CmdletBinding()]
param (
    # Subscription IDs to analyze. Defaults to the current Az context subscription.
    [Parameter(Mandatory = $false)]
    [string[]]$SubscriptionIds = @(),

    # Percentage deviation from the 30-day rolling average that triggers an anomaly flag
    [Parameter(Mandatory = $false)]
    [ValidateRange(1, 500)]
    [int]$AnomalyThresholdPercent = 20,

    # Number of recent days to evaluate for anomalies
    [Parameter(Mandatory = $false)]
    [ValidateRange(1, 90)]
    [int]$LookbackDays = 7,

    # When set, also evaluates spend at the resource group level (slower, more granular)
    [Parameter(Mandatory = $false)]
    [switch]$IncludeResourceGroupBreakdown,

    # Output path for the structured JSON anomaly report
    [Parameter(Mandatory = $false)]
    [string]$ReportPath = ".\az-cost-anomaly-report.json",

    # When set, also exports a flat CSV of anomaly findings
    [Parameter(Mandatory = $false)]
    [switch]$ExportCsv,

    # Output path for structured JSON run log
    [Parameter(Mandatory = $false)]
    [string]$LogPath = ".\az-cost-anomaly.log.json"
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

function Get-DailySpend {
    <#
    .SYNOPSIS
        Queries Azure Cost Management for daily spend within a date range
        for a given subscription scope. Returns an array of day/cost pairs.
    #>
    param (
        [string]$SubscriptionId,
        [datetime]$StartDate,
        [datetime]$EndDate
    )

    $scope = "/subscriptions/$SubscriptionId"

    # Cost Management query body — group by day, sum PreTaxCost
    $queryBody = @{
        type       = "Usage"
        timeframe  = "Custom"
        timePeriod = @{
            from = $StartDate.ToString("yyyy-MM-dd")
            to   = $EndDate.ToString("yyyy-MM-dd")
        }
        dataset    = @{
            granularity = "Daily"
            aggregation = @{
                totalCost = @{
                    name     = "PreTaxCost"
                    function = "Sum"
                }
            }
        }
    } | ConvertTo-Json -Depth 10

    try {
        $response = Invoke-AzRestMethod `
            -Path "/subscriptions/$SubscriptionId/providers/Microsoft.CostManagement/query?api-version=2023-11-01" `
            -Method POST `
            -Payload $queryBody `
            -ErrorAction Stop

        $content = $response.Content | ConvertFrom-Json

        # Parse rows — Cost Management returns [ [cost, date, currency], ... ]
        $results = @()
        foreach ($row in $content.properties.rows) {
            $results += [PSCustomObject]@{
                Date     = [datetime]::ParseExact($row[1].ToString(), "yyyyMMdd", $null)
                Cost     = [math]::Round([double]$row[0], 4)
                Currency = $row[2]
            }
        }
        return $results
    }
    catch {
        Write-Log "Cost query failed for subscription '$SubscriptionId': $_" -Level ERROR
        return @()
    }
}

function Get-ResourceGroupSpend {
    <#
    .SYNOPSIS
        Queries daily spend grouped by resource group for a given subscription.
    #>
    param (
        [string]$SubscriptionId,
        [datetime]$StartDate,
        [datetime]$EndDate
    )

    $queryBody = @{
        type       = "Usage"
        timeframe  = "Custom"
        timePeriod = @{
            from = $StartDate.ToString("yyyy-MM-dd")
            to   = $EndDate.ToString("yyyy-MM-dd")
        }
        dataset    = @{
            granularity = "Daily"
            aggregation = @{
                totalCost = @{
                    name     = "PreTaxCost"
                    function = "Sum"
                }
            }
            grouping    = @(
                @{ type = "Dimension"; name = "ResourceGroupName" }
            )
        }
    } | ConvertTo-Json -Depth 10

    try {
        $response = Invoke-AzRestMethod `
            -Path "/subscriptions/$SubscriptionId/providers/Microsoft.CostManagement/query?api-version=2023-11-01" `
            -Method POST `
            -Payload $queryBody `
            -ErrorAction Stop

        $content = $response.Content | ConvertFrom-Json

        $results = @()
        foreach ($row in $content.properties.rows) {
            $results += [PSCustomObject]@{
                Date              = [datetime]::ParseExact($row[2].ToString(), "yyyyMMdd", $null)
                Cost              = [math]::Round([double]$row[0], 4)
                Currency          = $row[3]
                ResourceGroupName = $row[1]
            }
        }
        return $results
    }
    catch {
        Write-Log "Resource group cost query failed for '$SubscriptionId': $_" -Level ERROR
        return @()
    }
}

#endregion

#region ── Initialization ─────────────────────────────────────────────────────

$script:LogEntries = @()
$runTimestamp      = Get-Date -Format "yyyy-MM-dd HH:mm:ss"
$runId             = Get-Date -Format "yyyyMMdd-HHmmss"

# Date ranges
$today          = (Get-Date).Date
$lookbackStart  = $today.AddDays(-$LookbackDays)
$baselineStart  = $today.AddDays(-30)
$yesterday      = $today.AddDays(-1)  # Cost data lags by ~1 day

$anomalyFindings = @()
$counters        = @{ SubscriptionsScanned = 0; AnomaliesFound = 0; Errors = 0 }

Write-Log "=== Get-AzCostAnomalyReport START ===" -Level INFO
Write-Log "Run ID              : $runId" -Level INFO
Write-Log "Lookback Window     : $LookbackDays days ($($lookbackStart.ToString('yyyy-MM-dd')) → $($yesterday.ToString('yyyy-MM-dd')))" -Level INFO
Write-Log "Baseline Window     : 30 days ($($baselineStart.ToString('yyyy-MM-dd')) → $($yesterday.ToString('yyyy-MM-dd')))" -Level INFO
Write-Log "Anomaly Threshold   : $AnomalyThresholdPercent%" -Level INFO
Write-Log "RG Breakdown        : $($IncludeResourceGroupBreakdown.IsPresent)" -Level INFO

#endregion

#region ── Step 0: Pre-flight ─────────────────────────────────────────────────

Write-Log "--- Step 0: Pre-flight Validation ---" -Level INFO

try {
    $context = Get-AzContext -ErrorAction Stop
    if (-not $context) {
        Write-Log "No active Azure session. Run Connect-AzAccount first." -Level ERROR
        exit 1
    }
    Write-Log "Azure session: $($context.Account) | Subscription: $($context.Subscription.Name)" -Level INFO
}
catch {
    Write-Log "Failed to get Azure context: $_" -Level ERROR
    exit 1
}

# Resolve subscription list
if ($SubscriptionIds.Count -eq 0) {
    $SubscriptionIds = @($context.Subscription.Id)
    Write-Log "No subscriptions specified. Using current context: $($SubscriptionIds[0])" -Level INFO
}

#endregion

#region ── Step 1: Analyze Subscription-Level Spend ───────────────────────────

Write-Log "--- Step 1: Subscription-Level Cost Analysis ---" -Level INFO

foreach ($subId in $SubscriptionIds) {
    $counters.SubscriptionsScanned++

    # Get subscription display name for readable output
    $sub = Get-AzSubscription -SubscriptionId $subId -ErrorAction SilentlyContinue
    $subName = $sub?.Name ?? $subId
    Write-Log "Analyzing subscription: $subName ($subId)" -Level INFO

    # ── Retrieve daily spend for baseline period (30 days) ─────────────────────
    $baselineData = Get-DailySpend -SubscriptionId $subId -StartDate $baselineStart -EndDate $yesterday

    if ($baselineData.Count -eq 0) {
        Write-Log "No cost data returned for baseline period on '$subName'. Skipping." -Level WARN
        $counters.Errors++
        continue
    }

    # Calculate rolling 30-day average daily spend
    $baselineAvg = ($baselineData | Measure-Object -Property Cost -Average).Average
    $baselineAvg = [math]::Round($baselineAvg, 4)
    $currency    = $baselineData[0].Currency

    Write-Log "  30-day average daily spend: $baselineAvg $currency" -Level INFO

    # ── Retrieve daily spend for lookback evaluation window ────────────────────
    $recentData = $baselineData | Where-Object { $_.Date -ge $lookbackStart }

    foreach ($day in $recentData) {
        $deviation = if ($baselineAvg -gt 0) {
            [math]::Round((($day.Cost - $baselineAvg) / $baselineAvg) * 100, 1)
        } else { 0 }

        $isAnomaly = [math]::Abs($deviation) -ge $AnomalyThresholdPercent

        if ($isAnomaly) {
            $direction = if ($deviation -gt 0) { "spike" } else { "drop" }
            Write-Log "  [ANOMALY] $($day.Date.ToString('yyyy-MM-dd')): $($day.Cost) $currency ($deviation% $direction vs baseline $baselineAvg)" -Level WARN

            $anomalyFindings += [PSCustomObject]@{
                RunId             = $runId
                Scope             = "Subscription"
                SubscriptionId    = $subId
                SubscriptionName  = $subName
                ResourceGroup     = "N/A"
                Date              = $day.Date.ToString("yyyy-MM-dd")
                ActualCost        = $day.Cost
                BaselineAvgCost   = $baselineAvg
                DeviationPercent  = $deviation
                Direction         = $direction
                Currency          = $currency
                AnomalyThreshold  = $AnomalyThresholdPercent
                Timestamp         = $runTimestamp
            }
            $counters.AnomaliesFound++
        }
    }

    # ── Resource Group Breakdown (Optional) ────────────────────────────────────
    if ($IncludeResourceGroupBreakdown) {
        Write-Log "  Fetching resource group breakdown for '$subName'..." -Level INFO

        $rgBaselineData = Get-ResourceGroupSpend -SubscriptionId $subId -StartDate $baselineStart -EndDate $yesterday

        if ($rgBaselineData.Count -gt 0) {
            # Group by resource group and compute per-RG baseline average
            $rgGroups = $rgBaselineData | Group-Object -Property ResourceGroupName

            foreach ($rgGroup in $rgGroups) {
                $rgName    = $rgGroup.Name
                $rgAvg     = [math]::Round(($rgGroup.Group | Measure-Object -Property Cost -Average).Average, 4)
                $rgRecent  = $rgGroup.Group | Where-Object { $_.Date -ge $lookbackStart }

                foreach ($day in $rgRecent) {
                    $deviation = if ($rgAvg -gt 0) {
                        [math]::Round((($day.Cost - $rgAvg) / $rgAvg) * 100, 1)
                    } else { 0 }

                    if ([math]::Abs($deviation) -ge $AnomalyThresholdPercent) {
                        $direction = if ($deviation -gt 0) { "spike" } else { "drop" }
                        Write-Log "  [RG-ANOMALY] $rgName | $($day.Date.ToString('yyyy-MM-dd')): $($day.Cost) $currency ($deviation% $direction)" -Level WARN

                        $anomalyFindings += [PSCustomObject]@{
                            RunId             = $runId
                            Scope             = "ResourceGroup"
                            SubscriptionId    = $subId
                            SubscriptionName  = $subName
                            ResourceGroup     = $rgName
                            Date              = $day.Date.ToString("yyyy-MM-dd")
                            ActualCost        = $day.Cost
                            BaselineAvgCost   = $rgAvg
                            DeviationPercent  = $deviation
                            Direction         = $direction
                            Currency          = $currency
                            AnomalyThreshold  = $AnomalyThresholdPercent
                            Timestamp         = $runTimestamp
                        }
                        $counters.AnomaliesFound++
                    }
                }
            }
        }
    }
}

#endregion

#region ── Step 2: Output Report ──────────────────────────────────────────────

Write-Log "=== Get-AzCostAnomalyReport COMPLETE ===" -Level SUCCESS
Write-Log "Subscriptions Scanned : $($counters.SubscriptionsScanned)" -Level INFO
Write-Log "Anomalies Found       : $($counters.AnomaliesFound)" -Level $(if ($counters.AnomaliesFound -gt 0) { "WARN" } else { "SUCCESS" })
Write-Log "Errors                : $($counters.Errors)" -Level $(if ($counters.Errors -gt 0) { "WARN" } else { "INFO" })

# Sort anomalies by severity — highest deviation first
$sortedAnomalies = $anomalyFindings | Sort-Object { [math]::Abs($_.DeviationPercent) } -Descending

$report = [PSCustomObject]@{
    RunId              = $runId
    GeneratedAt        = $runTimestamp
    LookbackDays       = $LookbackDays
    BaselineDays       = 30
    AnomalyThreshold   = $AnomalyThresholdPercent
    Summary            = $counters
    Anomalies          = $sortedAnomalies
}

try {
    $report | ConvertTo-Json -Depth 6 | Set-Content -Path $ReportPath -Encoding UTF8
    Write-Log "JSON report written to: $ReportPath" -Level INFO
}
catch { Write-Log "Could not write JSON report: $_" -Level WARN }

if ($ExportCsv) {
    $csvPath = $ReportPath -replace '\.json$', '.csv'
    try {
        $sortedAnomalies |
            Select-Object Scope, SubscriptionName, ResourceGroup, Date,
                          ActualCost, BaselineAvgCost, DeviationPercent,
                          Direction, Currency, AnomalyThreshold |
            Export-Csv -Path $csvPath -NoTypeInformation -Encoding UTF8
        Write-Log "CSV report written to: $csvPath" -Level INFO
    }
    catch { Write-Log "Could not write CSV report: $_" -Level WARN }
}

$logEntry = [PSCustomObject]@{
    RunAt      = $runTimestamp
    Result     = $report.Summary
    LogEntries = $script:LogEntries
}
try { $logEntry | ConvertTo-Json -Depth 5 | Set-Content -Path $LogPath -Encoding UTF8 }
catch { Write-Log "Could not write log: $_" -Level WARN }

return $report

#endregion
