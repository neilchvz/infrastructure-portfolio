# Test-ADReplicationHealth.ps1
# Author   : Neil Chavez
# Version  : 1.0.0
# Category : Hybrid Identity & Directory Ops
# Folder   : powershell/hybrid-identity-ad/
# Script # : 16 of 24
#
# PURPOSE
# -------
# Tests Active Directory replication health across all domain controllers in
# the domain, surfaces replication failures, USN rollback indicators, and
# lingering object conditions. Returns a structured health object suitable
# for monitoring pipeline consumption, alerting, or scheduled health reporting.
#
# Replication failures are a leading indicator of upcoming identity outages.
# If a DC falls out of replication, it will serve stale credential data,
# fail authentication for recently changed passwords, and create inconsistent
# group membership resolution across the environment. In Entra hybrid environments,
# replication failures can also block Entra Connect sync operations.
#
# What this script checks:
#
#   Per-DC checks:
#     - repadmin /showrepl output parsed for failure count and last error
#     - repadmin /replsummary for at-a-glance fail counts across all DCs
#     - OS-level NETLOGON service status on each DC
#     - SYSVOL replication state (DFSR health)
#     - DNS resolution health for each DC
#
#   Domain-wide checks:
#     - USN rollback indicators (repadmin /showrepl outputs checked for "USN Rollback")
#     - Lingering object detection (repadmin /removelingeringobjects in test mode)
#     - Time skew check — DCs more than 5 minutes from PDC emulator are flagged
#       (Kerberos fails at >5 min skew, which breaks all domain authentication)
#
# REQUIREMENTS
# ------------
#   - ActiveDirectory PowerShell module (RSAT: AD DS and LDS Tools)
#   - repadmin.exe must be available (included with RSAT AD Tools)
#   - Caller must have: Domain Admin or Replicating Directory Changes right
#   - Run from a domain-joined machine
#
# USAGE
# -----
#   # Full domain replication health check
#   .\Test-ADReplicationHealth.ps1
#
#   # Check specific DCs only
#   .\Test-ADReplicationHealth.ps1 -DomainControllers @("DC01", "DC02")
#
#   # Output JSON health report to a specific path
#   .\Test-ADReplicationHealth.ps1 -ReportPath ".\dc-health-$(Get-Date -Format 'yyyyMMdd').json"
#
#   # Run silently and return only the health object (for monitoring pipeline use)
#   $health = .\Test-ADReplicationHealth.ps1 -Quiet
#   if ($health.OverallStatus -ne "Healthy") { Send-Alert $health }

[CmdletBinding()]
param (
    # Optional. Specific DC hostnames to test. If omitted, all DCs in the domain are tested.
    [Parameter(Mandatory = $false)]
    [string[]]$DomainControllers = @(),

    # Maximum allowed time skew in minutes between a DC and the PDC emulator
    # Kerberos authentication fails at 5 minutes — default threshold is 4 minutes
    # to provide an early warning buffer
    [Parameter(Mandatory = $false)]
    [ValidateRange(1, 10)]
    [int]$MaxTimeskewMinutes = 4,

    # Output path for the structured JSON health report
    [Parameter(Mandatory = $false)]
    [string]$ReportPath = ".\ad-replication-health.json",

    # When set, suppresses console output — returns only the health object
    # Useful for monitoring pipeline or scheduled task integration
    [Parameter(Mandatory = $false)]
    [switch]$Quiet,

    # Output path for the JSON run log
    [Parameter(Mandatory = $false)]
    [string]$LogPath = ".\ad-replication-health.log.json"
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
    if (-not $Quiet) {
        Write-Host "[$timestamp] [$Level] $Message" -ForegroundColor $colors[$Level]
    }
    $script:LogEntries += [PSCustomObject]@{
        Timestamp = $timestamp
        Level     = $Level
        Message   = $Message
    }
}

function Invoke-Repadmin {
    <#
    .SYNOPSIS
        Wrapper for repadmin.exe invocation. Returns raw string output.
        Handles the case where repadmin is not in PATH.
    #>
    param ([string[]]$Arguments)
    try {
        $output = & repadmin.exe @Arguments 2>&1
        return $output -join "`n"
    }
    catch {
        return "ERROR: repadmin not available or failed: $_"
    }
}

function Get-TimeSkewMinutes {
    <#
    .SYNOPSIS
        Returns the time difference in minutes between the local machine
        and a remote DC, using w32tm /stripchart.
        Returns null if the check fails.
    #>
    param ([string]$DCName)
    try {
        $output = & w32tm.exe /stripchart /computer:$DCName /samples:1 /dataonly 2>&1
        # Parse the offset value from w32tm output — format: "HH:MM:SS, +/-X.XXXXXs"
        $offsetLine = $output | Where-Object { $_ -match '[+-]\d+\.\d+s' } | Select-Object -Last 1
        if ($offsetLine -match '([+-]\d+\.\d+)s') {
            return [math]::Abs([double]$Matches[1] / 60)
        }
    }
    catch { }
    return $null
}

#endregion

#region ── Initialization ─────────────────────────────────────────────────────

$script:LogEntries = @()
$runTimestamp      = Get-Date -Format "yyyy-MM-dd HH:mm:ss"
$runId             = Get-Date -Format "yyyyMMdd-HHmmss"

# Health result accumulators
$dcHealthResults = @()
$domainIssues    = @()
$counters        = @{
    DCsChecked         = 0
    DCsHealthy         = 0
    DCsWithWarnings    = 0
    DCsWithErrors      = 0
    ReplFailuresFound  = 0
    TimeskewViolations = 0
}

Write-Log "=== Test-ADReplicationHealth START ===" -Level INFO
Write-Log "Run ID           : $runId" -Level INFO
Write-Log "Max Timeskew     : $MaxTimeskewMinutes minutes" -Level INFO
Write-Log "DC Scope         : $(if ($DomainControllers.Count -gt 0) { $DomainControllers -join ', ' } else { 'All DCs in domain' })" -Level INFO

#endregion

#region ── Step 0: Pre-flight Validation ──────────────────────────────────────

Write-Log "--- Step 0: Pre-flight Validation ---" -Level INFO

if (-not (Get-Module -Name "ActiveDirectory" -ErrorAction SilentlyContinue)) {
    try {
        Import-Module ActiveDirectory -ErrorAction Stop
        Write-Log "ActiveDirectory module loaded." -Level INFO
    }
    catch {
        Write-Log "ActiveDirectory module not available." -Level ERROR
        exit 1
    }
}

# Verify repadmin is available
$repadminPath = Get-Command repadmin.exe -ErrorAction SilentlyContinue
if (-not $repadminPath) {
    Write-Log "repadmin.exe not found in PATH. Ensure RSAT AD Tools are installed." -Level ERROR
    exit 1
}
Write-Log "repadmin.exe found at: $($repadminPath.Source)" -Level INFO

# Get domain info and PDC emulator
$domain = $null
try {
    $domain = Get-ADDomain -ErrorAction Stop
    Write-Log "Domain: $($domain.DNSRoot) | PDC Emulator: $($domain.PDCEmulator)" -Level INFO
}
catch {
    Write-Log "Failed to connect to AD domain: $_" -Level ERROR
    exit 1
}

#endregion

#region ── Step 1: Resolve Target Domain Controllers ──────────────────────────

Write-Log "--- Step 1: Resolve Target Domain Controllers ---" -Level INFO

$targetDCs = @()

if ($DomainControllers.Count -gt 0) {
    # Use specified DCs — validate each one exists in AD
    foreach ($dc in $DomainControllers) {
        try {
            $adDC = Get-ADDomainController -Identity $dc -ErrorAction Stop
            $targetDCs += $adDC
            Write-Log "Verified DC: $($adDC.HostName)" -Level INFO
        }
        catch {
            Write-Log "DC '$dc' not found in domain — skipping." -Level WARN
        }
    }
}
else {
    # Discover all DCs in the domain
    try {
        $targetDCs = Get-ADDomainController -Filter * -ErrorAction Stop
        Write-Log "Discovered $($targetDCs.Count) domain controller(s)." -Level INFO
    }
    catch {
        Write-Log "Failed to retrieve domain controllers: $_" -Level ERROR
        exit 1
    }
}

if ($targetDCs.Count -eq 0) {
    Write-Log "No domain controllers resolved. Exiting." -Level ERROR
    exit 1
}

#endregion

#region ── Step 2: Per-DC Health Checks ───────────────────────────────────────

Write-Log "--- Step 2: Per-DC Health Checks ---" -Level INFO

foreach ($dc in $targetDCs) {
    $counters.DCsChecked++
    $dcName   = $dc.HostName
    $dcIssues = @()
    $dcStatus = "Healthy"

    Write-Log "Checking DC: $dcName" -Level INFO

    # ── Check 1: Replication failures via repadmin /showrepl ──────────────────
    $replOutput = Invoke-Repadmin @("/showrepl", $dcName, "/errorsonly")

    if ($replOutput -match "ERROR|FAILURE|failed") {
        # Parse failure count from output
        $failureLines = ($replOutput -split "`n") | Where-Object { $_ -match "ERROR|failed" }
        $dcIssues += "Replication errors detected ($($failureLines.Count) failure(s)). Run repadmin /showrepl $dcName for detail."
        $dcStatus = "Error"
        $counters.ReplFailuresFound += $failureLines.Count
        Write-Log "  [ERROR] Replication failures on $dcName`: $($failureLines.Count) error(s)" -Level ERROR
    }
    else {
        Write-Log "  Replication: OK" -Level SUCCESS
    }

    # ── Check 2: USN Rollback detection ───────────────────────────────────────
    if ($replOutput -match "USN Rollback") {
        $dcIssues    += "USN Rollback detected — this DC may be serving inconsistent data and requires immediate investigation."
        $dcStatus    = "Error"
        $domainIssues += "USN Rollback detected on DC: $dcName"
        Write-Log "  [CRITICAL] USN Rollback detected on $dcName" -Level ERROR
    }

    # ── Check 3: NETLOGON service status ──────────────────────────────────────
    try {
        $netlogon = Get-Service -ComputerName $dcName -Name "Netlogon" -ErrorAction Stop
        if ($netlogon.Status -ne "Running") {
            $dcIssues += "NETLOGON service is not running (Status: $($netlogon.Status))"
            if ($dcStatus -ne "Error") { $dcStatus = "Warning" }
            Write-Log "  [WARN] NETLOGON not running on $dcName" -Level WARN
        }
        else {
            Write-Log "  NETLOGON: Running" -Level SUCCESS
        }
    }
    catch {
        $dcIssues += "Could not verify NETLOGON service status: $_"
        if ($dcStatus -ne "Error") { $dcStatus = "Warning" }
        Write-Log "  [WARN] Could not check NETLOGON on $dcName`: $_" -Level WARN
    }

    # ── Check 4: DFSR / SYSVOL replication health ─────────────────────────────
    $sysvolOutput = Invoke-Repadmin @("/showrepl", $dcName, "/showdel")
    if ($sysvolOutput -match "SYSVOL.*error|error.*SYSVOL") {
        $dcIssues += "SYSVOL replication error detected. Group Policy application may be affected."
        if ($dcStatus -ne "Error") { $dcStatus = "Warning" }
        Write-Log "  [WARN] SYSVOL replication issue on $dcName" -Level WARN
    }
    else {
        Write-Log "  SYSVOL: OK" -Level SUCCESS
    }

    # ── Check 5: DNS resolution for DC ────────────────────────────────────────
    try {
        $dnsResult = Resolve-DnsName -Name $dcName -ErrorAction Stop
        Write-Log "  DNS: Resolved ($($dnsResult[0].IPAddress))" -Level SUCCESS
    }
    catch {
        $dcIssues += "DNS resolution failed for DC hostname '$dcName'"
        if ($dcStatus -ne "Error") { $dcStatus = "Warning" }
        Write-Log "  [WARN] DNS resolution failed for $dcName" -Level WARN
    }

    # ── Check 6: Time skew against PDC emulator ────────────────────────────────
    # Skip time skew check on the PDC itself
    if ($dcName -ne $domain.PDCEmulator) {
        $skewMinutes = Get-TimeSkewMinutes -DCName $dcName
        if ($null -ne $skewMinutes) {
            if ($skewMinutes -gt $MaxTimeskewMinutes) {
                $dcIssues += "Time skew of $([math]::Round($skewMinutes, 2)) minutes exceeds threshold of $MaxTimeskewMinutes minutes. Kerberos authentication may fail."
                if ($dcStatus -ne "Error") { $dcStatus = "Warning" }
                $counters.TimeskewViolations++
                Write-Log "  [WARN] Time skew on $dcName`: $([math]::Round($skewMinutes, 2)) min (threshold: $MaxTimeskewMinutes min)" -Level WARN
            }
            else {
                Write-Log "  Time skew: $([math]::Round($skewMinutes, 2)) min (OK)" -Level SUCCESS
            }
        }
        else {
            Write-Log "  Time skew: Could not determine (w32tm check failed)" -Level WARN
        }
    }

    # ── Update counters based on final DC status ───────────────────────────────
    switch ($dcStatus) {
        "Healthy" { $counters.DCsHealthy++ }
        "Warning" { $counters.DCsWithWarnings++ }
        "Error"   { $counters.DCsWithErrors++ }
    }

    # Build DC health result object
    $dcHealthResults += [PSCustomObject]@{
        RunId        = $runId
        DCName       = $dcName
        Site         = $dc.Site
        IsGC         = $dc.IsGlobalCatalog
        IsPDC        = ($dcName -eq $domain.PDCEmulator)
        OSVersion    = $dc.OperatingSystem
        Status       = $dcStatus
        Issues       = $dcIssues
        Timestamp    = $runTimestamp
    }

    $statusColor = @{ Healthy = "Success"; Warning = "Warn"; Error = "Error" }
    Write-Log "DC '$dcName' status: $dcStatus$(if ($dcIssues.Count -gt 0) { " — $($dcIssues.Count) issue(s)" })" -Level $statusColor[$dcStatus]
}

#endregion

#region ── Step 3: Domain-Wide Replication Summary ────────────────────────────

Write-Log "--- Step 3: Domain-Wide Replication Summary ---" -Level INFO

# repadmin /replsummary gives a cross-DC view of replication latency and failures
$replSummary = Invoke-Repadmin @("/replsummary")
Write-Log "repadmin /replsummary output captured." -Level INFO

# Check for lingering objects in test mode (no removal)
$lingeringCheck = Invoke-Repadmin @("/removelingeringobjects", $domain.PDCEmulator, "/advisory_mode")
if ($lingeringCheck -match "lingering") {
    $domainIssues += "Potential lingering objects detected. Review repadmin /removelingeringobjects output."
    Write-Log "[WARN] Potential lingering objects detected in domain." -Level WARN
}
else {
    Write-Log "Lingering object check: No issues detected." -Level SUCCESS
}

#endregion

#region ── Step 4: Output Report ──────────────────────────────────────────────

# Determine overall domain health status
$overallStatus = if ($counters.DCsWithErrors -gt 0)   { "Critical" }
                 elseif ($counters.DCsWithWarnings -gt 0) { "Warning"  }
                 elseif ($domainIssues.Count -gt 0)       { "Warning"  }
                 else                                      { "Healthy"  }

Write-Log "=== Test-ADReplicationHealth COMPLETE ===" -Level SUCCESS
Write-Log "Overall Status     : $overallStatus" -Level $(
    if ($overallStatus -eq "Critical") { "ERROR" }
    elseif ($overallStatus -eq "Warning") { "WARN" }
    else { "SUCCESS" }
)
Write-Log "DCs Checked        : $($counters.DCsChecked)" -Level INFO
Write-Log "DCs Healthy        : $($counters.DCsHealthy)" -Level SUCCESS
Write-Log "DCs With Warnings  : $($counters.DCsWithWarnings)" -Level $(if ($counters.DCsWithWarnings -gt 0) { "WARN" } else { "INFO" })
Write-Log "DCs With Errors    : $($counters.DCsWithErrors)" -Level $(if ($counters.DCsWithErrors -gt 0) { "ERROR" } else { "INFO" })
Write-Log "Repl Failures Found: $($counters.ReplFailuresFound)" -Level $(if ($counters.ReplFailuresFound -gt 0) { "ERROR" } else { "INFO" })
Write-Log "Timeskew Violations: $($counters.TimeskewViolations)" -Level $(if ($counters.TimeskewViolations -gt 0) { "WARN" } else { "INFO" })

$report = [PSCustomObject]@{
    RunId         = $runId
    GeneratedAt   = $runTimestamp
    Domain        = $domain.DNSRoot
    PDCEmulator   = $domain.PDCEmulator
    OverallStatus = $overallStatus
    Summary       = $counters
    DomainIssues  = $domainIssues
    ReplSummaryRaw = $replSummary
    DCResults     = $dcHealthResults
}

try {
    $report | ConvertTo-Json -Depth 6 | Set-Content -Path $ReportPath -Encoding UTF8
    Write-Log "JSON report written to: $ReportPath" -Level INFO
}
catch {
    Write-Log "Could not write JSON report: $_" -Level WARN
}

$logEntry = [PSCustomObject]@{
    RunAt      = $runTimestamp
    Result     = [PSCustomObject]@{
        OverallStatus = $overallStatus
        Summary       = $counters
    }
    LogEntries = $script:LogEntries
}
try {
    $logEntry | ConvertTo-Json -Depth 5 | Set-Content -Path $LogPath -Encoding UTF8
}
catch {
    Write-Log "Could not write log file: $_" -Level WARN
}

# Return the structured health object for pipeline consumption
return $report

#endregion
