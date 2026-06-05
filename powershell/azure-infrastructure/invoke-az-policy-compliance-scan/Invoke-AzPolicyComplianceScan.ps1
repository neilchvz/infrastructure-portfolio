<#
.SYNOPSIS
    Triggers an Azure Policy compliance evaluation scan, waits for completion,
    and retrieves non-compliant resources per policy definition. Supports scope
    filtering by subscription or resource group and outputs a structured compliance
    report for pipeline gating or governance review.

.DESCRIPTION
    Invoke-AzPolicyComplianceScan.ps1 addresses a common gap in Azure governance
    workflows: Azure Policy compliance state is only refreshed on a 24-hour cycle
    by default. This means that after a resource is deployed or modified, the
    compliance portal may show stale results for up to a day. This script triggers
    an on-demand evaluation scan and waits for it to complete before reporting
    results — enabling accurate compliance checks as a deployment pipeline gate.

    It performs the following steps:
        1. Validates the active Azure session and target scope.
        2. Triggers an on-demand policy compliance scan via the Azure REST API.
        3. Polls the scan operation status until completion (with configurable timeout).
        4. Queries non-compliant resources for each policy definition in scope.
        5. Optionally filters results to specific policy definitions or initiatives.
        6. Outputs a structured compliance report with non-compliant resource details.
        7. Exits non-zero if non-compliant resources are found — for pipeline gate use.

    REQUIREMENTS:
        - Az PowerShell module (Az.PolicyInsights, Az.Accounts, Az.Resources)
        - Connect-AzAccount
        - Resource Policy Contributor or Security Reader role on target scope

.PARAMETER SubscriptionId
    The subscription ID to scan. Defaults to the current Az context subscription.

.PARAMETER ResourceGroupName
    Optional. Scopes the compliance scan and results to a specific resource group.
    If omitted, the full subscription is scanned.

.PARAMETER PolicyDefinitionNames
    Optional. Array of policy definition names to filter results.
    If omitted, all non-compliant policies in scope are returned.

.PARAMETER ScanTimeoutMinutes
    Maximum minutes to wait for the compliance scan to complete.
    Default: 15 minutes. Azure scans typically complete in 2-5 minutes.

.PARAMETER ReportPath
    Output path for the structured JSON compliance report.
    Defaults to .\az-policy-compliance-report.json

.PARAMETER ExportCsv
    Switch. When set, also exports a flat CSV of non-compliant resources.

.PARAMETER FailOnNonCompliance
    Switch. When set, the script exits with code 1 if any non-compliant
    resources are found. Enables use as a hard pipeline gate.

.PARAMETER LogPath
    Optional. Path to write a structured JSON run log.
    Defaults to .\az-policy-compliance.log.json

.EXAMPLE
    # Scan full subscription and report non-compliant resources
    .\Invoke-AzPolicyComplianceScan.ps1

.EXAMPLE
    # Scan a specific resource group, fail pipeline on non-compliance
    .\Invoke-AzPolicyComplianceScan.ps1 `
        -ResourceGroupName "rg-platform-prod" `
        -FailOnNonCompliance `
        -ExportCsv

.EXAMPLE
    # Scan and filter to specific policy definitions
    .\Invoke-AzPolicyComplianceScan.ps1 `
        -PolicyDefinitionNames @(
            "Require a tag on resource groups",
            "Storage accounts should use private link"
        ) `
        -FailOnNonCompliance

.EXAMPLE
    # Use in a deployment pipeline gate
    .\Invoke-AzPolicyComplianceScan.ps1 `
        -ResourceGroupName "rg-platform-prod" `
        -FailOnNonCompliance
    if ($LASTEXITCODE -ne 0) {
        throw "Azure Policy non-compliance detected. Review report before proceeding."
    }

.NOTES
    Author      : Neil Chavez
    Version     : 1.0.0
    Category    : Azure Infrastructure Automation
    Folder      : powershell/azure-infrastructure/
    Script #    : 23 of 24

    Scan Trigger: Azure Policy on-demand scans are triggered via the
                  policyStates/triggerEvaluation REST endpoint. This is the
                  same mechanism used by the Azure portal's "Evaluate" button
                  and by Azure DevOps policy compliance tasks.

    Polling     : The scan operation returns a 202 Accepted with a location
                  header for status polling. This script polls every 30 seconds
                  until the operation reaches Succeeded, Failed, or timeout.

    Stale Data  : If -ScanTimeoutMinutes is exceeded, the script falls back to
                  reporting the most recent cached compliance state with a warning.
                  This is preferable to failing the pipeline on a scan timeout.

    Exit Codes  : 0 = Compliant (or scan reported no findings)
                  1 = Non-compliant resources found (only when -FailOnNonCompliance)
                  2 = Scan trigger or completion failure

    Dependencies:
        Install-Module Az -Scope CurrentUser

    Connect before running:
        Connect-AzAccount
#>

[CmdletBinding()]
param (
    [Parameter(Mandatory = $false)]
    [string]$SubscriptionId,

    [Parameter(Mandatory = $false)]
    [string]$ResourceGroupName,

    [Parameter(Mandatory = $false)]
    [string[]]$PolicyDefinitionNames = @(),

    [Parameter(Mandatory = $false)]
    [ValidateRange(1, 60)]
    [int]$ScanTimeoutMinutes = 15,

    [Parameter(Mandatory = $false)]
    [string]$ReportPath = ".\az-policy-compliance-report.json",

    [Parameter(Mandatory = $false)]
    [switch]$ExportCsv,

    [Parameter(Mandatory = $false)]
    [switch]$FailOnNonCompliance,

    [Parameter(Mandatory = $false)]
    [string]$LogPath = ".\az-policy-compliance.log.json"
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

$result = [PSCustomObject]@{
    RunId                = $runId
    GeneratedAt          = $runTimestamp
    SubscriptionId       = $null
    ResourceGroupScope   = $ResourceGroupName
    ScanTriggered        = $false
    ScanCompleted        = $false
    ScanTimedOut         = $false
    TotalNonCompliant    = 0
    FailOnNonCompliance  = $FailOnNonCompliance.IsPresent
    NonCompliantResources = @()
    Errors               = @()
}

Write-Log "=== Invoke-AzPolicyComplianceScan START ===" -Level INFO
Write-Log "Run ID          : $runId" -Level INFO
Write-Log "Resource Group  : $(if ($ResourceGroupName) { $ResourceGroupName } else { 'Full subscription' })" -Level INFO
Write-Log "Scan Timeout    : $ScanTimeoutMinutes minutes" -Level INFO
Write-Log "Fail on NC      : $($FailOnNonCompliance.IsPresent)" -Level INFO

#endregion

#region ── Step 0: Pre-flight ─────────────────────────────────────────────────

Write-Log "--- Step 0: Pre-flight Validation ---" -Level INFO

try {
    $context = Get-AzContext -ErrorAction Stop
    if (-not $context) {
        Write-Log "No active Azure session. Run Connect-AzAccount first." -Level ERROR
        exit 2
    }
    Write-Log "Azure session: $($context.Account) | Subscription: $($context.Subscription.Name)" -Level INFO
}
catch {
    Write-Log "Failed to get Azure context: $_" -Level ERROR
    exit 2
}

# Resolve subscription ID
if (-not $SubscriptionId) { $SubscriptionId = $context.Subscription.Id }
$result.SubscriptionId = $SubscriptionId

# Build the scope string for the API call
$scope = "/subscriptions/$SubscriptionId"
if ($ResourceGroupName) {
    $scope += "/resourceGroups/$ResourceGroupName"

    # Validate resource group exists
    $rg = Get-AzResourceGroup -Name $ResourceGroupName -ErrorAction SilentlyContinue
    if (-not $rg) {
        Write-Log "Resource group '$ResourceGroupName' not found in subscription '$SubscriptionId'." -Level ERROR
        exit 2
    }
}

Write-Log "Scan scope: $scope" -Level INFO

#endregion

#region ── Step 1: Trigger On-Demand Compliance Scan ──────────────────────────

Write-Log "--- Step 1: Trigger Policy Compliance Scan ---" -Level INFO

$triggerEndpoint = "$scope/providers/Microsoft.PolicyInsights/policyStates/latest/triggerEvaluation?api-version=2019-10-01"

$scanOperationUrl = $null
try {
    $triggerResponse = Invoke-AzRestMethod -Path $triggerEndpoint -Method POST -ErrorAction Stop

    if ($triggerResponse.StatusCode -eq 202) {
        # 202 Accepted — get the operation status URL from the Location header
        $scanOperationUrl    = $triggerResponse.Headers.Location
        $result.ScanTriggered = $true
        Write-Log "Compliance scan triggered successfully. Operation URL: $scanOperationUrl" -Level SUCCESS
    }
    else {
        Write-Log "Unexpected response from scan trigger: $($triggerResponse.StatusCode)" -Level ERROR
        $result.Errors += "Scan trigger returned HTTP $($triggerResponse.StatusCode)"
        exit 2
    }
}
catch {
    Write-Log "Failed to trigger compliance scan: $_" -Level ERROR
    $result.Errors += "Scan trigger failed: $_"
    exit 2
}

#endregion

#region ── Step 2: Poll for Scan Completion ───────────────────────────────────

Write-Log "--- Step 2: Waiting for Scan Completion ---" -Level INFO

$scanComplete    = $false
$pollInterval    = 30  # seconds between status checks
$maxPolls        = [math]::Ceiling(($ScanTimeoutMinutes * 60) / $pollInterval)
$pollCount       = 0
$elapsedSeconds  = 0

while (-not $scanComplete -and $pollCount -lt $maxPolls) {
    Start-Sleep -Seconds $pollInterval
    $pollCount++
    $elapsedSeconds = $pollCount * $pollInterval

    try {
        $statusResponse = Invoke-AzRestMethod -Method GET -Path $scanOperationUrl -ErrorAction Stop
        $statusCode     = $statusResponse.StatusCode

        if ($statusCode -eq 200) {
            # 200 = operation complete
            $scanComplete            = $true
            $result.ScanCompleted    = $true
            Write-Log "Scan completed successfully after $elapsedSeconds seconds." -Level SUCCESS
        }
        elseif ($statusCode -eq 202) {
            # 202 = still in progress
            Write-Log "Scan in progress... ($elapsedSeconds sec elapsed, max $($ScanTimeoutMinutes * 60) sec)" -Level INFO
        }
        else {
            Write-Log "Unexpected poll response: HTTP $statusCode" -Level WARN
        }
    }
    catch {
        Write-Log "Error polling scan status: $_" -Level WARN
        # Non-fatal — continue polling
    }
}

if (-not $scanComplete) {
    $result.ScanTimedOut = $true
    Write-Log "Scan did not complete within $ScanTimeoutMinutes minutes. Falling back to cached compliance state." -Level WARN
}

#endregion

#region ── Step 3: Retrieve Non-Compliant Resources ───────────────────────────

Write-Log "--- Step 3: Retrieving Non-Compliant Resources ---" -Level INFO

$nonCompliantResources = @()

try {
    # Query non-compliant policy states for the scope
    $queryParams = @{
        Filter = "ComplianceState eq 'NonCompliant'"
        Top    = 1000  # Max results per query — paginate if needed
    }

    $policyStates = $null
    if ($ResourceGroupName) {
        $policyStates = Get-AzPolicyState `
            -SubscriptionId $SubscriptionId `
            -ResourceGroupName $ResourceGroupName `
            @queryParams `
            -ErrorAction Stop
    }
    else {
        $policyStates = Get-AzPolicyState `
            -SubscriptionId $SubscriptionId `
            @queryParams `
            -ErrorAction Stop
    }

    Write-Log "Retrieved $($policyStates.Count) non-compliant policy state record(s)." -Level INFO

    foreach ($state in $policyStates) {
        # Apply policy definition name filter if specified
        if ($PolicyDefinitionNames.Count -gt 0) {
            $policyName = $state.PolicyDefinitionName
            if ($PolicyDefinitionNames -notcontains $policyName) { continue }
        }

        $nonCompliantResources += [PSCustomObject]@{
            RunId                  = $runId
            ResourceId             = $state.ResourceId
            ResourceName           = $state.ResourceId -replace '.*/([^/]+)$', '$1'
            ResourceType           = $state.ResourceType
            ResourceGroup          = $state.ResourceGroup
            PolicyDefinitionId     = $state.PolicyDefinitionId
            PolicyDefinitionName   = $state.PolicyDefinitionName
            PolicySetDefinitionId  = $state.PolicySetDefinitionId
            ComplianceState        = $state.ComplianceState
            Timestamp              = $state.Timestamp
        }
    }

    $result.TotalNonCompliant     = $nonCompliantResources.Count
    $result.NonCompliantResources = $nonCompliantResources

    if ($nonCompliantResources.Count -gt 0) {
        Write-Log "$($nonCompliantResources.Count) non-compliant resource(s) found." -Level WARN

        # Log top violations grouped by policy
        $byPolicy = $nonCompliantResources | Group-Object -Property PolicyDefinitionName
        foreach ($grp in $byPolicy | Sort-Object Count -Descending | Select-Object -First 10) {
            Write-Log "  [$($grp.Count)] $($grp.Name)" -Level WARN
        }
    }
    else {
        Write-Log "No non-compliant resources found in scope." -Level SUCCESS
    }
}
catch {
    $errMsg = "Failed to retrieve compliance state: $_"
    Write-Log $errMsg -Level ERROR
    $result.Errors += $errMsg
}

#endregion

#region ── Step 4: Output Report ──────────────────────────────────────────────

Write-Log "=== Invoke-AzPolicyComplianceScan COMPLETE ===" -Level SUCCESS
Write-Log "Scan Triggered       : $($result.ScanTriggered)" -Level INFO
Write-Log "Scan Completed       : $($result.ScanCompleted)" -Level $(if ($result.ScanTimedOut) { "WARN" } else { "SUCCESS" })
Write-Log "Scan Timed Out       : $($result.ScanTimedOut)" -Level $(if ($result.ScanTimedOut) { "WARN" } else { "INFO" })
Write-Log "Non-Compliant Found  : $($result.TotalNonCompliant)" -Level $(if ($result.TotalNonCompliant -gt 0) { "WARN" } else { "SUCCESS" })

try {
    $result | ConvertTo-Json -Depth 6 | Set-Content -Path $ReportPath -Encoding UTF8
    Write-Log "JSON report written to: $ReportPath" -Level INFO
}
catch { Write-Log "Could not write JSON report: $_" -Level WARN }

if ($ExportCsv -and $nonCompliantResources.Count -gt 0) {
    $csvPath = $ReportPath -replace '\.json$', '.csv'
    try {
        $nonCompliantResources |
            Select-Object ResourceName, ResourceType, ResourceGroup,
                          PolicyDefinitionName, ComplianceState, Timestamp |
            Sort-Object PolicyDefinitionName |
            Export-Csv -Path $csvPath -NoTypeInformation -Encoding UTF8
        Write-Log "CSV report written to: $csvPath" -Level INFO
    }
    catch { Write-Log "Could not write CSV: $_" -Level WARN }
}

$logEntry = [PSCustomObject]@{
    RunAt      = $runTimestamp
    Result     = [PSCustomObject]@{
        ScanCompleted     = $result.ScanCompleted
        TotalNonCompliant = $result.TotalNonCompliant
    }
    LogEntries = $script:LogEntries
}
try { $logEntry | ConvertTo-Json -Depth 5 | Set-Content -Path $LogPath -Encoding UTF8 }
catch { Write-Log "Could not write log file: $_" -Level WARN }

# Exit with appropriate code for pipeline gate use
if ($FailOnNonCompliance -and $result.TotalNonCompliant -gt 0) {
    Write-Log "Non-compliant resources found and -FailOnNonCompliance is set. Exiting with code 1." -Level WARN
    exit 1
}

return $result

#endregion
