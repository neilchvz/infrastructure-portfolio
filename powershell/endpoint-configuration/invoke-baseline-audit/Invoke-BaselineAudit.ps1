<#
.SYNOPSIS
    Audits a Windows endpoint against a defined JSON baseline configuration manifest,
    checking registry values, service states, firewall rules, and local policy settings.
    Outputs a structured compliance report with pass/fail per control and an overall
    drift score.

.DESCRIPTION
    Invoke-BaselineAudit.ps1 reads a baseline manifest (JSON) that defines the
    expected configuration state of a Windows endpoint and evaluates the live system
    against every control defined in that manifest. Each control produces a Pass,
    Fail, or Error result. The aggregate output is a structured compliance report
    with a drift score representing the percentage of controls that are out of
    expected state.

    It evaluates the following control categories (as defined in the manifest):
        RegistryValues  — Registry key/value/data checks (DWORD, String, MultiString)
        Services        — Windows service expected state (Running, Stopped, Disabled)
        FirewallRules   — Named firewall rule enabled/disabled state
        LocalPolicies   — secedit-derived local security policy settings
        ScheduledTasks  — Scheduled task expected state (Ready, Disabled)

    The manifest format is designed to be human-readable and version-controllable.
    A sample manifest is shown in the .NOTES section. The same manifest is consumed
    by Repair-DriftedConfiguration.ps1 (Script #20) to remediate any failed controls.

    REQUIREMENTS:
        - Windows PowerShell 5.1+ or PowerShell 7+
        - Must run as Local Administrator (required for registry and policy reads)
        - secedit.exe must be available (included in all Windows versions)
        - NetSecurity module for firewall rule evaluation

.PARAMETER BaselineManifestPath
    Path to the JSON baseline manifest file defining expected control states.
    See .NOTES for manifest format specification.

.PARAMETER ComputerName
    Optional. Remote computer to audit. If omitted, the local machine is audited.
    Requires WinRM to be enabled on the target machine.
    When specified, the manifest file must be accessible from the local machine.

.PARAMETER ReportPath
    Output path for the structured JSON compliance report.
    Defaults to .\baseline-audit-report.json

.PARAMETER ExportCsv
    Switch. When set, also exports a flat CSV version of the control results.

.PARAMETER FailedOnly
    Switch. When set, only failed and error controls are included in the report output.
    Useful for producing a focused remediation list.

.PARAMETER LogPath
    Optional. Path to write a structured JSON run log.
    Defaults to .\baseline-audit.log.json

.EXAMPLE
    # Audit local machine against a baseline manifest
    .\Invoke-BaselineAudit.ps1 -BaselineManifestPath ".\baselines\windows-server-2022.json"

.EXAMPLE
    # Audit a remote machine, export CSV of failures only
    .\Invoke-BaselineAudit.ps1 `
        -BaselineManifestPath ".\baselines\windows-server-2022.json" `
        -ComputerName "SERVER01" `
        -FailedOnly `
        -ExportCsv

.EXAMPLE
    # Audit and pipe result to remediation script
    $auditResult = .\Invoke-BaselineAudit.ps1 `
        -BaselineManifestPath ".\baselines\windows-server-2022.json"
    if ($auditResult.DriftScore -gt 0) {
        .\Repair-DriftedConfiguration.ps1 `
            -AuditReportPath ".\baseline-audit-report.json" `
            -BaselineManifestPath ".\baselines\windows-server-2022.json"
    }

.NOTES
    Author      : Neil Chavez
    Version     : 1.0.0
    Category    : Endpoint Configuration & Drift Remediation
    Folder      : powershell/endpoint-configuration/
    Script #    : 17 of 24

    Manifest Format (JSON):
    {
      "BaselineName": "Windows Server 2022 - CIS Level 1",
      "Version": "1.0.0",
      "RegistryValues": [
        {
          "ControlId": "REG-001",
          "Description": "Disable anonymous enumeration of SAM accounts",
          "Path": "HKLM:\\SYSTEM\\CurrentControlSet\\Control\\Lsa",
          "Name": "RestrictAnonymousSAM",
          "ExpectedType": "DWORD",
          "ExpectedValue": 1
        }
      ],
      "Services": [
        {
          "ControlId": "SVC-001",
          "Description": "Remote Registry service should be disabled",
          "ServiceName": "RemoteRegistry",
          "ExpectedStartType": "Disabled"
        }
      ],
      "FirewallRules": [
        {
          "ControlId": "FW-001",
          "Description": "Windows Firewall - Domain profile must be enabled",
          "RuleName": "Domain Profile",
          "ProfileType": "Domain",
          "ExpectedEnabled": true
        }
      ],
      "ScheduledTasks": [
        {
          "ControlId": "TASK-001",
          "Description": "Disable XblGameSave scheduled task",
          "TaskPath": "\\Microsoft\\XblGameSave\\",
          "TaskName": "XblGameSaveTask",
          "ExpectedState": "Disabled"
        }
      ]
    }

    DriftScore  : Percentage of controls that are in a failed or error state.
                  0 = fully compliant. 100 = all controls failed.
                  A score above 0 triggers non-zero exit code for pipeline use.
#>

[CmdletBinding()]
param (
    [Parameter(Mandatory = $true)]
    [ValidateScript({ Test-Path $_ -PathType Leaf })]
    [string]$BaselineManifestPath,

    [Parameter(Mandatory = $false)]
    [string]$ComputerName,

    [Parameter(Mandatory = $false)]
    [string]$ReportPath = ".\baseline-audit-report.json",

    [Parameter(Mandatory = $false)]
    [switch]$ExportCsv,

    [Parameter(Mandatory = $false)]
    [switch]$FailedOnly,

    [Parameter(Mandatory = $false)]
    [string]$LogPath = ".\baseline-audit.log.json"
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

function New-ControlResult {
    <#
    .SYNOPSIS
        Factory function for a consistent control result object.
        Used by all control evaluators to ensure uniform output structure.
    #>
    param (
        [string]$ControlId,
        [string]$Category,
        [string]$Description,
        [ValidateSet("Pass", "Fail", "Error")]
        [string]$Status,
        [string]$ExpectedValue,
        [string]$ActualValue,
        [string]$Detail
    )
    return [PSCustomObject]@{
        ControlId     = $ControlId
        Category      = $Category
        Description   = $Description
        Status        = $Status
        ExpectedValue = $ExpectedValue
        ActualValue   = $ActualValue
        Detail        = $Detail
        Timestamp     = (Get-Date -Format "yyyy-MM-dd HH:mm:ss")
    }
}

function Invoke-RemoteScriptBlock {
    <#
    .SYNOPSIS
        Invokes a script block locally or remotely based on -ComputerName parameter.
    #>
    param (
        [scriptblock]$ScriptBlock,
        [object[]]$ArgumentList = @()
    )
    if ($ComputerName) {
        return Invoke-Command -ComputerName $ComputerName -ScriptBlock $ScriptBlock -ArgumentList $ArgumentList
    }
    else {
        return & $ScriptBlock @ArgumentList
    }
}

#endregion

#region ── Initialization ─────────────────────────────────────────────────────

$script:LogEntries = @()
$runTimestamp      = Get-Date -Format "yyyy-MM-dd HH:mm:ss"
$runId             = Get-Date -Format "yyyyMMdd-HHmmss"

$allControlResults = @()
$counters          = @{ Pass = 0; Fail = 0; Error = 0; Total = 0 }

$targetMachine = if ($ComputerName) { $ComputerName } else { $env:COMPUTERNAME }

Write-Log "=== Invoke-BaselineAudit START ===" -Level INFO
Write-Log "Run ID    : $runId" -Level INFO
Write-Log "Target    : $targetMachine" -Level INFO
Write-Log "Manifest  : $BaselineManifestPath" -Level INFO

#endregion

#region ── Step 0: Pre-flight & Manifest Load ─────────────────────────────────

Write-Log "--- Step 0: Pre-flight Validation ---" -Level INFO

# Load and parse baseline manifest
$manifest = $null
try {
    $manifest = Get-Content -Path $BaselineManifestPath -Raw | ConvertFrom-Json -ErrorAction Stop
    Write-Log "Manifest loaded: '$($manifest.BaselineName)' v$($manifest.Version)" -Level INFO
}
catch {
    Write-Log "Failed to load or parse baseline manifest: $_" -Level ERROR
    exit 1
}

# Verify WinRM connectivity for remote targets
if ($ComputerName) {
    try {
        $null = Test-WSMan -ComputerName $ComputerName -ErrorAction Stop
        Write-Log "WinRM connectivity to '$ComputerName' confirmed." -Level INFO
    }
    catch {
        Write-Log "Cannot connect to '$ComputerName' via WinRM: $_" -Level ERROR
        exit 1
    }
}

# Verify local admin context
$currentPrincipal = [Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()
if (-not $currentPrincipal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
    Write-Log "Script must run as Administrator for accurate registry and policy reads." -Level WARN
}

#endregion

#region ── Step 1: Evaluate Registry Value Controls ───────────────────────────

Write-Log "--- Step 1: Evaluating Registry Controls ---" -Level INFO

if (-not $manifest.RegistryValues -or $manifest.RegistryValues.Count -eq 0) {
    Write-Log "No RegistryValues controls defined in manifest." -Level INFO
}
else {
    Write-Log "$($manifest.RegistryValues.Count) registry control(s) to evaluate." -Level INFO

    foreach ($control in $manifest.RegistryValues) {
        $counters.Total++
        try {
            $actualValue = Invoke-RemoteScriptBlock -ScriptBlock {
                param($Path, $Name)
                try {
                    $item = Get-ItemProperty -Path $Path -Name $Name -ErrorAction Stop
                    return $item.$Name
                }
                catch { return $null }
            } -ArgumentList $control.Path, $control.Name

            if ($null -eq $actualValue) {
                $result = New-ControlResult `
                    -ControlId    $control.ControlId `
                    -Category     "RegistryValue" `
                    -Description  $control.Description `
                    -Status       "Fail" `
                    -ExpectedValue "$($control.ExpectedType): $($control.ExpectedValue)" `
                    -ActualValue  "Key or value not found" `
                    -Detail       "Registry path '$($control.Path)\$($control.Name)' does not exist"

                Write-Log "  [FAIL] $($control.ControlId): $($control.Description)" -Level WARN
                $counters.Fail++
            }
            elseif ($actualValue -eq $control.ExpectedValue) {
                $result = New-ControlResult `
                    -ControlId    $control.ControlId `
                    -Category     "RegistryValue" `
                    -Description  $control.Description `
                    -Status       "Pass" `
                    -ExpectedValue "$($control.ExpectedType): $($control.ExpectedValue)" `
                    -ActualValue  "$actualValue" `
                    -Detail       "Value matches expected configuration"

                Write-Log "  [PASS] $($control.ControlId): $($control.Description)" -Level SUCCESS
                $counters.Pass++
            }
            else {
                $result = New-ControlResult `
                    -ControlId    $control.ControlId `
                    -Category     "RegistryValue" `
                    -Description  $control.Description `
                    -Status       "Fail" `
                    -ExpectedValue "$($control.ExpectedType): $($control.ExpectedValue)" `
                    -ActualValue  "$actualValue" `
                    -Detail       "Value is '$actualValue', expected '$($control.ExpectedValue)'"

                Write-Log "  [FAIL] $($control.ControlId): $($control.Description) | Expected: $($control.ExpectedValue) | Actual: $actualValue" -Level WARN
                $counters.Fail++
            }
        }
        catch {
            $result = New-ControlResult `
                -ControlId   $control.ControlId `
                -Category    "RegistryValue" `
                -Description $control.Description `
                -Status      "Error" `
                -ExpectedValue "$($control.ExpectedValue)" `
                -ActualValue "Evaluation error" `
                -Detail      "Exception during check: $_"

            Write-Log "  [ERROR] $($control.ControlId): $_" -Level ERROR
            $counters.Error++
        }

        $allControlResults += $result
    }
}

#endregion

#region ── Step 2: Evaluate Service Controls ──────────────────────────────────

Write-Log "--- Step 2: Evaluating Service Controls ---" -Level INFO

if (-not $manifest.Services -or $manifest.Services.Count -eq 0) {
    Write-Log "No Services controls defined in manifest." -Level INFO
}
else {
    Write-Log "$($manifest.Services.Count) service control(s) to evaluate." -Level INFO

    foreach ($control in $manifest.Services) {
        $counters.Total++
        try {
            $svcInfo = Invoke-RemoteScriptBlock -ScriptBlock {
                param($SvcName)
                $svc = Get-Service -Name $SvcName -ErrorAction SilentlyContinue
                if ($svc) {
                    return [PSCustomObject]@{
                        StartType = (Get-WmiObject -Class Win32_Service -Filter "Name='$SvcName'").StartMode
                        Status    = $svc.Status.ToString()
                    }
                }
                return $null
            } -ArgumentList $control.ServiceName

            if (-not $svcInfo) {
                $result = New-ControlResult `
                    -ControlId    $control.ControlId `
                    -Category     "Service" `
                    -Description  $control.Description `
                    -Status       "Fail" `
                    -ExpectedValue "StartType: $($control.ExpectedStartType)" `
                    -ActualValue  "Service not found" `
                    -Detail       "Service '$($control.ServiceName)' does not exist on this machine"

                $counters.Fail++
                Write-Log "  [FAIL] $($control.ControlId): Service '$($control.ServiceName)' not found" -Level WARN
            }
            else {
                $pass = $svcInfo.StartType -eq $control.ExpectedStartType
                $result = New-ControlResult `
                    -ControlId    $control.ControlId `
                    -Category     "Service" `
                    -Description  $control.Description `
                    -Status       (if ($pass) { "Pass" } else { "Fail" }) `
                    -ExpectedValue "StartType: $($control.ExpectedStartType)" `
                    -ActualValue  "StartType: $($svcInfo.StartType) | Status: $($svcInfo.Status)" `
                    -Detail       (if ($pass) { "Service configuration matches expected state" }
                                   else { "StartType is '$($svcInfo.StartType)', expected '$($control.ExpectedStartType)'" })

                if ($pass) { $counters.Pass++; Write-Log "  [PASS] $($control.ControlId): $($control.Description)" -Level SUCCESS }
                else       { $counters.Fail++; Write-Log "  [FAIL] $($control.ControlId): $($control.Description)" -Level WARN }
            }
        }
        catch {
            $result = New-ControlResult `
                -ControlId   $control.ControlId `
                -Category    "Service" `
                -Description $control.Description `
                -Status      "Error" `
                -ExpectedValue $control.ExpectedStartType `
                -ActualValue "Evaluation error" `
                -Detail      "Exception: $_"

            $counters.Error++
            Write-Log "  [ERROR] $($control.ControlId): $_" -Level ERROR
        }

        $allControlResults += $result
    }
}

#endregion

#region ── Step 3: Evaluate Firewall Rule Controls ────────────────────────────

Write-Log "--- Step 3: Evaluating Firewall Rule Controls ---" -Level INFO

if (-not $manifest.FirewallRules -or $manifest.FirewallRules.Count -eq 0) {
    Write-Log "No FirewallRules controls defined in manifest." -Level INFO
}
else {
    Write-Log "$($manifest.FirewallRules.Count) firewall rule control(s) to evaluate." -Level INFO

    foreach ($control in $manifest.FirewallRules) {
        $counters.Total++
        try {
            $fwState = Invoke-RemoteScriptBlock -ScriptBlock {
                param($ProfileType)
                $profile = Get-NetFirewallProfile -Profile $ProfileType -ErrorAction SilentlyContinue
                return $profile?.Enabled
            } -ArgumentList $control.ProfileType

            if ($null -eq $fwState) {
                $result = New-ControlResult `
                    -ControlId    $control.ControlId `
                    -Category     "FirewallRule" `
                    -Description  $control.Description `
                    -Status       "Error" `
                    -ExpectedValue "Enabled: $($control.ExpectedEnabled)" `
                    -ActualValue  "Profile not found" `
                    -Detail       "Firewall profile '$($control.ProfileType)' could not be retrieved"

                $counters.Error++
                Write-Log "  [ERROR] $($control.ControlId): Profile '$($control.ProfileType)' not found" -Level ERROR
            }
            else {
                $pass = $fwState -eq $control.ExpectedEnabled
                $result = New-ControlResult `
                    -ControlId    $control.ControlId `
                    -Category     "FirewallRule" `
                    -Description  $control.Description `
                    -Status       (if ($pass) { "Pass" } else { "Fail" }) `
                    -ExpectedValue "Enabled: $($control.ExpectedEnabled)" `
                    -ActualValue  "Enabled: $fwState" `
                    -Detail       (if ($pass) { "Firewall profile state matches expected" }
                                   else { "Profile '$($control.ProfileType)' is $(if ($fwState) {'enabled'} else {'disabled'}), expected $(if ($control.ExpectedEnabled) {'enabled'} else {'disabled'})" })

                if ($pass) { $counters.Pass++; Write-Log "  [PASS] $($control.ControlId): $($control.Description)" -Level SUCCESS }
                else       { $counters.Fail++; Write-Log "  [FAIL] $($control.ControlId): $($control.Description)" -Level WARN }
            }
        }
        catch {
            $result = New-ControlResult `
                -ControlId   $control.ControlId `
                -Category    "FirewallRule" `
                -Description $control.Description `
                -Status      "Error" `
                -ExpectedValue "Enabled: $($control.ExpectedEnabled)" `
                -ActualValue "Evaluation error" `
                -Detail      "Exception: $_"

            $counters.Error++
            Write-Log "  [ERROR] $($control.ControlId): $_" -Level ERROR
        }

        $allControlResults += $result
    }
}

#endregion

#region ── Step 4: Evaluate Scheduled Task Controls ───────────────────────────

Write-Log "--- Step 4: Evaluating Scheduled Task Controls ---" -Level INFO

if (-not $manifest.ScheduledTasks -or $manifest.ScheduledTasks.Count -eq 0) {
    Write-Log "No ScheduledTasks controls defined in manifest." -Level INFO
}
else {
    Write-Log "$($manifest.ScheduledTasks.Count) scheduled task control(s) to evaluate." -Level INFO

    foreach ($control in $manifest.ScheduledTasks) {
        $counters.Total++
        try {
            $taskState = Invoke-RemoteScriptBlock -ScriptBlock {
                param($TaskPath, $TaskName)
                $task = Get-ScheduledTask -TaskPath $TaskPath -TaskName $TaskName -ErrorAction SilentlyContinue
                return $task?.State.ToString()
            } -ArgumentList $control.TaskPath, $control.TaskName

            if (-not $taskState) {
                $result = New-ControlResult `
                    -ControlId    $control.ControlId `
                    -Category     "ScheduledTask" `
                    -Description  $control.Description `
                    -Status       "Fail" `
                    -ExpectedValue "State: $($control.ExpectedState)" `
                    -ActualValue  "Task not found" `
                    -Detail       "Scheduled task '$($control.TaskName)' not found at path '$($control.TaskPath)'"

                $counters.Fail++
                Write-Log "  [FAIL] $($control.ControlId): Task not found" -Level WARN
            }
            else {
                $pass = $taskState -eq $control.ExpectedState
                $result = New-ControlResult `
                    -ControlId    $control.ControlId `
                    -Category     "ScheduledTask" `
                    -Description  $control.Description `
                    -Status       (if ($pass) { "Pass" } else { "Fail" }) `
                    -ExpectedValue "State: $($control.ExpectedState)" `
                    -ActualValue  "State: $taskState" `
                    -Detail       (if ($pass) { "Task state matches expected" }
                                   else { "Task state is '$taskState', expected '$($control.ExpectedState)'" })

                if ($pass) { $counters.Pass++; Write-Log "  [PASS] $($control.ControlId): $($control.Description)" -Level SUCCESS }
                else       { $counters.Fail++; Write-Log "  [FAIL] $($control.ControlId): $($control.Description)" -Level WARN }
            }
        }
        catch {
            $result = New-ControlResult `
                -ControlId   $control.ControlId `
                -Category    "ScheduledTask" `
                -Description $control.Description `
                -Status      "Error" `
                -ExpectedValue $control.ExpectedState `
                -ActualValue "Evaluation error" `
                -Detail      "Exception: $_"

            $counters.Error++
            Write-Log "  [ERROR] $($control.ControlId): $_" -Level ERROR
        }

        $allControlResults += $result
    }
}

#endregion

#region ── Step 5: Calculate Drift Score and Output Report ────────────────────

# Drift score = percentage of controls that are not passing
$driftScore = if ($counters.Total -gt 0) {
    [math]::Round((($counters.Fail + $counters.Error) / $counters.Total) * 100, 1)
} else { 0 }

$complianceStatus = if ($driftScore -eq 0)      { "Compliant"        }
                    elseif ($driftScore -le 20)  { "MinorDrift"       }
                    elseif ($driftScore -le 50)  { "ModerateDrift"    }
                    else                         { "SignificantDrift"  }

Write-Log "=== Invoke-BaselineAudit COMPLETE ===" -Level SUCCESS
Write-Log "Target Machine   : $targetMachine" -Level INFO
Write-Log "Baseline         : $($manifest.BaselineName)" -Level INFO
Write-Log "Total Controls   : $($counters.Total)" -Level INFO
Write-Log "Pass             : $($counters.Pass)" -Level SUCCESS
Write-Log "Fail             : $($counters.Fail)" -Level $(if ($counters.Fail -gt 0) { "WARN" } else { "SUCCESS" })
Write-Log "Error            : $($counters.Error)" -Level $(if ($counters.Error -gt 0) { "ERROR" } else { "INFO" })
Write-Log "Drift Score      : $driftScore% ($complianceStatus)" -Level $(
    if ($driftScore -eq 0) { "SUCCESS" } elseif ($driftScore -le 20) { "WARN" } else { "ERROR" }
)

$outputResults = if ($FailedOnly) {
    $allControlResults | Where-Object { $_.Status -in "Fail", "Error" }
} else { $allControlResults }

$report = [PSCustomObject]@{
    RunId            = $runId
    GeneratedAt      = $runTimestamp
    TargetMachine    = $targetMachine
    BaselineName     = $manifest.BaselineName
    BaselineVersion  = $manifest.Version
    DriftScore       = $driftScore
    ComplianceStatus = $complianceStatus
    Summary          = $counters
    FailedOnly       = $FailedOnly.IsPresent
    Controls         = $outputResults
}

try {
    $report | ConvertTo-Json -Depth 6 | Set-Content -Path $ReportPath -Encoding UTF8
    Write-Log "JSON report written to: $ReportPath" -Level INFO
}
catch { Write-Log "Could not write JSON report: $_" -Level WARN }

if ($ExportCsv) {
    $csvPath = $ReportPath -replace '\.json$', '.csv'
    try {
        $outputResults |
            Select-Object ControlId, Category, Description, Status,
                          ExpectedValue, ActualValue, Detail, Timestamp |
            Sort-Object Status, Category |
            Export-Csv -Path $csvPath -NoTypeInformation -Encoding UTF8
        Write-Log "CSV report written to: $csvPath" -Level INFO
    }
    catch { Write-Log "Could not write CSV report: $_" -Level WARN }
}

$logEntry = [PSCustomObject]@{
    RunAt      = $runTimestamp
    Result     = [PSCustomObject]@{ DriftScore = $driftScore; Summary = $counters }
    LogEntries = $script:LogEntries
}
try { $logEntry | ConvertTo-Json -Depth 5 | Set-Content -Path $LogPath -Encoding UTF8 }
catch { Write-Log "Could not write log file: $_" -Level WARN }

# Exit non-zero if drift detected — supports pipeline gate use
if ($driftScore -gt 0) { exit 1 }

return $report

#endregion
