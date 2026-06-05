# Repair-DriftedConfiguration.ps1
# Author   : Neil Chavez
# Version  : 1.0.0
# Category : Endpoint Configuration & Drift Remediation
# Folder   : powershell/endpoint-configuration/
# Script # : 20 of 24
#
# PURPOSE
# -------
# Reads the output of Invoke-BaselineAudit.ps1 (Script #17) and remediates all
# failed controls by re-applying their expected values from the baseline manifest.
# Logs every remediation action with before/after state. Supports -WhatIf to
# preview all changes without applying them.
#
# This script closes the audit-remediate loop. Rather than manually fixing each
# failed control identified by Invoke-BaselineAudit.ps1, this script reads the
# structured audit report, identifies every Fail/Error control, looks up the
# expected value in the manifest, and applies it — making drift recovery
# automated and repeatable.
#
# Supported control categories (must match categories in Invoke-BaselineAudit.ps1):
#   RegistryValue   — Re-applies expected registry key/value/data
#   Service         — Sets service StartType to expected state (and optionally starts/stops)
#   FirewallRule    — Sets firewall profile enabled/disabled state
#   ScheduledTask   — Sets scheduled task state (Enable or Disable)
#
# Workflow:
#   1. Load the audit report produced by Invoke-BaselineAudit.ps1
#   2. Load the baseline manifest to retrieve expected values for failed controls
#   3. For each Fail or Error control, look up expected configuration in manifest
#   4. Apply the expected value with before/after logging
#   5. Output a structured remediation report
#
# REQUIREMENTS
# ------------
#   - Windows PowerShell 5.1+ or PowerShell 7+
#   - Must run as Local Administrator
#   - Audit report from Invoke-BaselineAudit.ps1 (-ReportPath output)
#   - The same baseline manifest used for the audit
#
# USAGE
# -----
#   # Dry run — preview what would be fixed
#   .\Repair-DriftedConfiguration.ps1 `
#       -AuditReportPath ".\baseline-audit-report.json" `
#       -BaselineManifestPath ".\baselines\windows-server-2022.json" `
#       -WhatIf
#
#   # Live remediation — apply all fixes
#   .\Repair-DriftedConfiguration.ps1 `
#       -AuditReportPath ".\baseline-audit-report.json" `
#       -BaselineManifestPath ".\baselines\windows-server-2022.json"
#
#   # Remediate specific control categories only
#   .\Repair-DriftedConfiguration.ps1 `
#       -AuditReportPath ".\baseline-audit-report.json" `
#       -BaselineManifestPath ".\baselines\windows-server-2022.json" `
#       -IncludeCategories @("RegistryValue", "Service")
#
#   # Full pipeline — audit then remediate if drift detected
#   $audit = .\Invoke-BaselineAudit.ps1 -BaselineManifestPath ".\baselines\win22.json"
#   if ($audit.DriftScore -gt 0) {
#       .\Repair-DriftedConfiguration.ps1 `
#           -AuditReportPath ".\baseline-audit-report.json" `
#           -BaselineManifestPath ".\baselines\win22.json"
#   }

[CmdletBinding(SupportsShouldProcess = $true)]
param (
    # Path to the JSON audit report produced by Invoke-BaselineAudit.ps1
    [Parameter(Mandatory = $true)]
    [ValidateScript({ Test-Path $_ -PathType Leaf })]
    [string]$AuditReportPath,

    # Path to the JSON baseline manifest (same file used for the audit)
    [Parameter(Mandatory = $true)]
    [ValidateScript({ Test-Path $_ -PathType Leaf })]
    [string]$BaselineManifestPath,

    # Optional. Only remediate controls in these categories.
    # If omitted, all failed control categories are remediated.
    [Parameter(Mandatory = $false)]
    [ValidateSet("RegistryValue", "Service", "FirewallRule", "ScheduledTask")]
    [string[]]$IncludeCategories = @("RegistryValue", "Service", "FirewallRule", "ScheduledTask"),

    # Output path for the structured JSON remediation report
    [Parameter(Mandatory = $false)]
    [string]$ReportPath = ".\drift-remediation-report.json",

    # When set, also exports a flat CSV of remediation actions
    [Parameter(Mandatory = $false)]
    [switch]$ExportCsv,

    # Output path for structured JSON run log
    [Parameter(Mandatory = $false)]
    [string]$LogPath = ".\drift-remediation.log.json"
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

function New-RemediationRecord {
    <#
    .SYNOPSIS
        Factory for consistent remediation action records.
        Captures before/after state for every remediation attempt.
    #>
    param (
        [string]$ControlId,
        [string]$Category,
        [string]$Description,
        [string]$Action,         # Applied, Skipped, Error, WhatIf
        [string]$PreviousValue,
        [string]$AppliedValue,
        [string]$Detail
    )
    return [PSCustomObject]@{
        ControlId     = $ControlId
        Category      = $Category
        Description   = $Description
        Action        = $Action
        PreviousValue = $PreviousValue
        AppliedValue  = $AppliedValue
        Detail        = $Detail
        Timestamp     = (Get-Date -Format "yyyy-MM-dd HH:mm:ss")
    }
}

#endregion

#region ── Initialization ─────────────────────────────────────────────────────

$script:LogEntries  = @()
$runTimestamp       = Get-Date -Format "yyyy-MM-dd HH:mm:ss"
$runId              = Get-Date -Format "yyyyMMdd-HHmmss"

$remediationRecords = @()
$counters           = @{ Applied = 0; Skipped = 0; Errors = 0; WhatIf = 0 }

Write-Log "=== Repair-DriftedConfiguration START ===" -Level INFO
Write-Log "Run ID        : $runId" -Level INFO
Write-Log "Audit Report  : $AuditReportPath" -Level INFO
Write-Log "Manifest      : $BaselineManifestPath" -Level INFO
Write-Log "Categories    : $($IncludeCategories -join ', ')" -Level INFO
Write-Log "WhatIf Mode   : $($WhatIfPreference)" -Level INFO

# Verify local admin
$currentPrincipal = [Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()
if (-not $currentPrincipal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
    Write-Log "This script must run as Administrator." -Level ERROR
    exit 1
}

#endregion

#region ── Step 0: Load Audit Report and Manifest ─────────────────────────────

Write-Log "--- Step 0: Load Audit Report and Manifest ---" -Level INFO

# Load the audit report
$auditReport = $null
try {
    $auditReport = Get-Content -Path $AuditReportPath -Raw | ConvertFrom-Json -ErrorAction Stop
    Write-Log "Audit report loaded. Baseline: '$($auditReport.BaselineName)' | Drift Score: $($auditReport.DriftScore)%" -Level INFO
}
catch {
    Write-Log "Failed to load audit report: $_" -Level ERROR
    exit 1
}

# Load the baseline manifest
$manifest = $null
try {
    $manifest = Get-Content -Path $BaselineManifestPath -Raw | ConvertFrom-Json -ErrorAction Stop
    Write-Log "Manifest loaded: '$($manifest.BaselineName)' v$($manifest.Version)" -Level INFO
}
catch {
    Write-Log "Failed to load baseline manifest: $_" -Level ERROR
    exit 1
}

# Extract only the failed and error controls from the audit report
$failedControls = $auditReport.Controls | Where-Object { $_.Status -in "Fail", "Error" }

if ($failedControls.Count -eq 0) {
    Write-Log "No failed controls found in audit report. System may already be compliant." -Level SUCCESS
    Write-Log "Drift score in report: $($auditReport.DriftScore)%. Nothing to remediate." -Level INFO
    exit 0
}

Write-Log "$($failedControls.Count) failed control(s) identified for remediation." -Level WARN

#endregion

#region ── Step 1: Build Manifest Lookup Tables ───────────────────────────────

Write-Log "--- Step 1: Building Manifest Lookup Tables ---" -Level INFO

# Index manifest controls by ControlId for O(1) lookup during remediation
$registryLookup  = @{}
$serviceLookup   = @{}
$firewallLookup  = @{}
$taskLookup      = @{}

foreach ($c in $manifest.RegistryValues)  { $registryLookup[$c.ControlId]  = $c }
foreach ($c in $manifest.Services)        { $serviceLookup[$c.ControlId]   = $c }
foreach ($c in $manifest.FirewallRules)   { $firewallLookup[$c.ControlId]  = $c }
foreach ($c in $manifest.ScheduledTasks)  { $taskLookup[$c.ControlId]      = $c }

Write-Log "Lookup tables built. Registry: $($registryLookup.Count) | Services: $($serviceLookup.Count) | Firewall: $($firewallLookup.Count) | Tasks: $($taskLookup.Count)" -Level INFO

#endregion

#region ── Step 2: Remediate Failed Controls ──────────────────────────────────

Write-Log "--- Step 2: Remediating Failed Controls ---" -Level INFO

foreach ($control in $failedControls) {

    # Skip if this category is not in the included list
    if ($IncludeCategories -notcontains $control.Category) {
        Write-Log "  [SKIP] $($control.ControlId) — Category '$($control.Category)' not in IncludeCategories" -Level INFO
        $remediationRecords += New-RemediationRecord `
            -ControlId    $control.ControlId `
            -Category     $control.Category `
            -Description  $control.Description `
            -Action       "Skipped" `
            -PreviousValue $control.ActualValue `
            -AppliedValue  "N/A" `
            -Detail        "Category excluded via -IncludeCategories parameter"
        $counters.Skipped++
        continue
    }

    Write-Log "  Remediating [$($control.Status)] $($control.ControlId): $($control.Description)" -Level INFO

    switch ($control.Category) {

        # ── Registry Value Remediation ─────────────────────────────────────────
        "RegistryValue" {
            $manifest_ctrl = $registryLookup[$control.ControlId]
            if (-not $manifest_ctrl) {
                Write-Log "  [WARN] No manifest entry found for ControlId '$($control.ControlId)'. Skipping." -Level WARN
                $counters.Skipped++
                continue
            }

            # Read current (pre-remediation) value for before/after logging
            $previousValue = $null
            try {
                $previousValue = (Get-ItemProperty -Path $manifest_ctrl.Path -Name $manifest_ctrl.Name -ErrorAction SilentlyContinue).$($manifest_ctrl.Name)
            }
            catch { }

            if ($PSCmdlet.ShouldProcess("$($manifest_ctrl.Path)\$($manifest_ctrl.Name)", "Set value to '$($manifest_ctrl.ExpectedValue)' ($($manifest_ctrl.ExpectedType))")) {
                try {
                    # Create registry path if it doesn't exist
                    if (-not (Test-Path $manifest_ctrl.Path)) {
                        New-Item -Path $manifest_ctrl.Path -Force | Out-Null
                    }

                    Set-ItemProperty `
                        -Path  $manifest_ctrl.Path `
                        -Name  $manifest_ctrl.Name `
                        -Value $manifest_ctrl.ExpectedValue `
                        -Type  $manifest_ctrl.ExpectedType `
                        -Force `
                        -ErrorAction Stop

                    Write-Log "  [APPLIED] $($control.ControlId): $($manifest_ctrl.Path)\$($manifest_ctrl.Name) = $($manifest_ctrl.ExpectedValue) (was: $previousValue)" -Level SUCCESS

                    $remediationRecords += New-RemediationRecord `
                        -ControlId    $control.ControlId `
                        -Category     "RegistryValue" `
                        -Description  $control.Description `
                        -Action       "Applied" `
                        -PreviousValue "$previousValue" `
                        -AppliedValue  "$($manifest_ctrl.ExpectedValue)" `
                        -Detail        "Registry value updated: $($manifest_ctrl.Path)\$($manifest_ctrl.Name)"
                    $counters.Applied++
                }
                catch {
                    Write-Log "  [ERROR] $($control.ControlId): $_" -Level ERROR
                    $remediationRecords += New-RemediationRecord `
                        -ControlId    $control.ControlId `
                        -Category     "RegistryValue" `
                        -Description  $control.Description `
                        -Action       "Error" `
                        -PreviousValue "$previousValue" `
                        -AppliedValue  "Failed" `
                        -Detail        "Exception: $_"
                    $counters.Errors++
                }
            }
            else {
                Write-Log "  [WhatIf] Would set: $($manifest_ctrl.Path)\$($manifest_ctrl.Name) = $($manifest_ctrl.ExpectedValue)" -Level INFO
                $remediationRecords += New-RemediationRecord `
                    -ControlId    $control.ControlId `
                    -Category     "RegistryValue" `
                    -Description  $control.Description `
                    -Action       "WhatIf" `
                    -PreviousValue "$previousValue" `
                    -AppliedValue  "$($manifest_ctrl.ExpectedValue)" `
                    -Detail        "WhatIf: no change made"
                $counters.WhatIf++
            }
        }

        # ── Service Remediation ────────────────────────────────────────────────
        "Service" {
            $manifest_ctrl = $serviceLookup[$control.ControlId]
            if (-not $manifest_ctrl) {
                Write-Log "  [WARN] No manifest entry found for ControlId '$($control.ControlId)'. Skipping." -Level WARN
                $counters.Skipped++
                continue
            }

            $svc = Get-Service -Name $manifest_ctrl.ServiceName -ErrorAction SilentlyContinue
            $previousStartType = if ($svc) {
                (Get-WmiObject -Class Win32_Service -Filter "Name='$($manifest_ctrl.ServiceName)'" -ErrorAction SilentlyContinue)?.StartMode
            } else { "NotFound" }

            if ($PSCmdlet.ShouldProcess($manifest_ctrl.ServiceName, "Set StartType to '$($manifest_ctrl.ExpectedStartType)'")) {
                try {
                    Set-Service -Name $manifest_ctrl.ServiceName `
                                -StartupType $manifest_ctrl.ExpectedStartType `
                                -ErrorAction Stop

                    # Stop the service if it's running and should be disabled
                    if ($manifest_ctrl.ExpectedStartType -eq "Disabled" -and $svc?.Status -eq "Running") {
                        Stop-Service -Name $manifest_ctrl.ServiceName -Force -ErrorAction SilentlyContinue
                        Write-Log "  Stopped running service '$($manifest_ctrl.ServiceName)' (now Disabled)" -Level INFO
                    }

                    Write-Log "  [APPLIED] $($control.ControlId): '$($manifest_ctrl.ServiceName)' StartType → $($manifest_ctrl.ExpectedStartType) (was: $previousStartType)" -Level SUCCESS
                    $remediationRecords += New-RemediationRecord `
                        -ControlId    $control.ControlId `
                        -Category     "Service" `
                        -Description  $control.Description `
                        -Action       "Applied" `
                        -PreviousValue "StartType: $previousStartType" `
                        -AppliedValue  "StartType: $($manifest_ctrl.ExpectedStartType)" `
                        -Detail        "Service StartupType updated"
                    $counters.Applied++
                }
                catch {
                    Write-Log "  [ERROR] $($control.ControlId): $_" -Level ERROR
                    $remediationRecords += New-RemediationRecord `
                        -ControlId    $control.ControlId `
                        -Category     "Service" `
                        -Description  $control.Description `
                        -Action       "Error" `
                        -PreviousValue "StartType: $previousStartType" `
                        -AppliedValue  "Failed" `
                        -Detail        "Exception: $_"
                    $counters.Errors++
                }
            }
            else {
                Write-Log "  [WhatIf] Would set '$($manifest_ctrl.ServiceName)' to StartType: $($manifest_ctrl.ExpectedStartType)" -Level INFO
                $counters.WhatIf++
            }
        }

        # ── Firewall Rule Remediation ──────────────────────────────────────────
        "FirewallRule" {
            $manifest_ctrl = $firewallLookup[$control.ControlId]
            if (-not $manifest_ctrl) {
                Write-Log "  [WARN] No manifest entry found for ControlId '$($control.ControlId)'. Skipping." -Level WARN
                $counters.Skipped++
                continue
            }

            $currentProfile  = Get-NetFirewallProfile -Profile $manifest_ctrl.ProfileType -ErrorAction SilentlyContinue
            $previousEnabled = $currentProfile?.Enabled

            if ($PSCmdlet.ShouldProcess("Firewall $($manifest_ctrl.ProfileType) profile", "Set Enabled = $($manifest_ctrl.ExpectedEnabled)")) {
                try {
                    Set-NetFirewallProfile -Profile $manifest_ctrl.ProfileType `
                                           -Enabled $manifest_ctrl.ExpectedEnabled `
                                           -ErrorAction Stop

                    Write-Log "  [APPLIED] $($control.ControlId): Firewall '$($manifest_ctrl.ProfileType)' Enabled → $($manifest_ctrl.ExpectedEnabled) (was: $previousEnabled)" -Level SUCCESS
                    $remediationRecords += New-RemediationRecord `
                        -ControlId    $control.ControlId `
                        -Category     "FirewallRule" `
                        -Description  $control.Description `
                        -Action       "Applied" `
                        -PreviousValue "Enabled: $previousEnabled" `
                        -AppliedValue  "Enabled: $($manifest_ctrl.ExpectedEnabled)" `
                        -Detail        "Firewall profile state updated"
                    $counters.Applied++
                }
                catch {
                    Write-Log "  [ERROR] $($control.ControlId): $_" -Level ERROR
                    $counters.Errors++
                }
            }
            else {
                Write-Log "  [WhatIf] Would set Firewall '$($manifest_ctrl.ProfileType)' Enabled = $($manifest_ctrl.ExpectedEnabled)" -Level INFO
                $counters.WhatIf++
            }
        }

        # ── Scheduled Task Remediation ─────────────────────────────────────────
        "ScheduledTask" {
            $manifest_ctrl = $taskLookup[$control.ControlId]
            if (-not $manifest_ctrl) {
                Write-Log "  [WARN] No manifest entry found for ControlId '$($control.ControlId)'. Skipping." -Level WARN
                $counters.Skipped++
                continue
            }

            $task          = Get-ScheduledTask -TaskPath $manifest_ctrl.TaskPath -TaskName $manifest_ctrl.TaskName -ErrorAction SilentlyContinue
            $previousState = $task?.State.ToString()

            if ($PSCmdlet.ShouldProcess("$($manifest_ctrl.TaskPath)$($manifest_ctrl.TaskName)", "Set state to '$($manifest_ctrl.ExpectedState)'")) {
                try {
                    if ($manifest_ctrl.ExpectedState -eq "Disabled") {
                        Disable-ScheduledTask -TaskPath $manifest_ctrl.TaskPath -TaskName $manifest_ctrl.TaskName -ErrorAction Stop | Out-Null
                    }
                    else {
                        Enable-ScheduledTask  -TaskPath $manifest_ctrl.TaskPath -TaskName $manifest_ctrl.TaskName -ErrorAction Stop | Out-Null
                    }

                    Write-Log "  [APPLIED] $($control.ControlId): Task '$($manifest_ctrl.TaskName)' → $($manifest_ctrl.ExpectedState) (was: $previousState)" -Level SUCCESS
                    $remediationRecords += New-RemediationRecord `
                        -ControlId    $control.ControlId `
                        -Category     "ScheduledTask" `
                        -Description  $control.Description `
                        -Action       "Applied" `
                        -PreviousValue "State: $previousState" `
                        -AppliedValue  "State: $($manifest_ctrl.ExpectedState)" `
                        -Detail        "Scheduled task state updated"
                    $counters.Applied++
                }
                catch {
                    Write-Log "  [ERROR] $($control.ControlId): $_" -Level ERROR
                    $counters.Errors++
                }
            }
            else {
                Write-Log "  [WhatIf] Would set task '$($manifest_ctrl.TaskName)' state to $($manifest_ctrl.ExpectedState)" -Level INFO
                $counters.WhatIf++
            }
        }

        default {
            Write-Log "  [SKIP] Unsupported category '$($control.Category)' for ControlId $($control.ControlId)" -Level WARN
            $counters.Skipped++
        }
    }
}

#endregion

#region ── Step 3: Output Report ──────────────────────────────────────────────

Write-Log "=== Repair-DriftedConfiguration COMPLETE ===" -Level SUCCESS
Write-Log "Controls Processed : $($failedControls.Count)" -Level INFO
Write-Log "Applied            : $($counters.Applied)" -Level SUCCESS
Write-Log "WhatIf (preview)   : $($counters.WhatIf)" -Level INFO
Write-Log "Skipped            : $($counters.Skipped)" -Level INFO
Write-Log "Errors             : $($counters.Errors)" -Level $(if ($counters.Errors -gt 0) { "ERROR" } else { "INFO" })

if ($counters.Applied -gt 0) {
    Write-Log "Re-run Invoke-BaselineAudit.ps1 to verify remediation was successful." -Level INFO
}

$report = [PSCustomObject]@{
    RunId             = $runId
    GeneratedAt       = $runTimestamp
    TargetMachine     = $auditReport.TargetMachine
    BaselineName      = $manifest.BaselineName
    SourceAuditReport = $AuditReportPath
    WhatIf            = $WhatIfPreference.ToString()
    Summary           = $counters
    RemediationActions = $remediationRecords
}

try {
    $report | ConvertTo-Json -Depth 6 | Set-Content -Path $ReportPath -Encoding UTF8
    Write-Log "JSON report written to: $ReportPath" -Level INFO
}
catch { Write-Log "Could not write JSON report: $_" -Level WARN }

if ($ExportCsv) {
    $csvPath = $ReportPath -replace '\.json$', '.csv'
    try {
        $remediationRecords |
            Select-Object ControlId, Category, Description, Action,
                          PreviousValue, AppliedValue, Detail, Timestamp |
            Sort-Object Action, Category |
            Export-Csv -Path $csvPath -NoTypeInformation -Encoding UTF8
        Write-Log "CSV report written to: $csvPath" -Level INFO
    }
    catch { Write-Log "Could not write CSV: $_" -Level WARN }
}

$logEntry = [PSCustomObject]@{
    RunAt      = $runTimestamp
    Result     = $report.Summary
    LogEntries = $script:LogEntries
}
try { $logEntry | ConvertTo-Json -Depth 5 | Set-Content -Path $LogPath -Encoding UTF8 }
catch { Write-Log "Could not write log file: $_" -Level WARN }

return $report

#endregion
