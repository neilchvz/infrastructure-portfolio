# Get-SoftwareInventory.ps1
# Author   : Neil Chavez
# Version  : 1.0.0
# Category : Endpoint Configuration & Drift Remediation
# Folder   : powershell/endpoint-configuration/
# Script # : 19 of 24
#
# PURPOSE
# -------
# Collects installed software from Windows endpoints using three complementary
# sources — registry uninstall keys, Win32_Product WMI class, and AppX packages —
# deduplicates and normalizes the results, and outputs a structured JSON or CSV
# inventory. Supports remote execution across a list of hostnames for fleet-wide
# collection.
#
# Why three sources:
#   Registry uninstall keys  — Most accurate for MSI and traditional installers.
#                              Fastest source, no side effects.
#   Win32_Product WMI        — Catches some software missed by registry, but
#                              triggers MSI reconfiguration on query (use with caution
#                              on production servers — flagged in output).
#   AppX packages            — Covers Microsoft Store apps and modern UWP applications
#                              not visible in traditional installer sources.
#
# Output is structured JSON or CSV per machine, suitable for:
#   - SIEM ingestion for software compliance monitoring
#   - CMDB population and patch management tooling
#   - Vulnerability scanner correlation (Tenable, Qualys, Rapid7)
#   - License audit and software entitlement reviews
#
# REQUIREMENTS
# ------------
#   - Windows PowerShell 5.1+ or PowerShell 7+
#   - For remote targets: WinRM must be enabled on each target
#   - Local admin on each target for WMI and registry access
#   - Caller must have: Read access to HKLM registry hive
#
# USAGE
# -----
#   # Inventory local machine
#   .\Get-SoftwareInventory.ps1
#
#   # Inventory a list of remote machines
#   .\Get-SoftwareInventory.ps1 -ComputerNames @("SERVER01", "SERVER02", "WRK001")
#
#   # Inventory from a text file of hostnames (one per line)
#   .\Get-SoftwareInventory.ps1 -ComputerListPath ".\hostnames.txt"
#
#   # Skip WMI source (safer for sensitive production servers)
#   .\Get-SoftwareInventory.ps1 -SkipWMI -ComputerNames @("PRODSVR01")
#
#   # Export as CSV for spreadsheet review
#   .\Get-SoftwareInventory.ps1 -OutputFormat CSV -ReportPath ".\inventory.csv"

[CmdletBinding()]
param (
    # Specific machine hostnames to inventory. Defaults to local machine if omitted.
    [Parameter(Mandatory = $false)]
    [string[]]$ComputerNames = @(),

    # Path to a plain text file with one hostname per line
    [Parameter(Mandatory = $false)]
    [ValidateScript({ Test-Path $_ -PathType Leaf })]
    [string]$ComputerListPath,

    # Output path for the inventory report
    [Parameter(Mandatory = $false)]
    [string]$ReportPath = ".\software-inventory.json",

    # Output format — JSON, CSV, or Both
    [Parameter(Mandatory = $false)]
    [ValidateSet("JSON", "CSV", "Both")]
    [string]$OutputFormat = "Both",

    # When set, skips Win32_Product WMI query to avoid MSI reconfigure side effect
    [Parameter(Mandatory = $false)]
    [switch]$SkipWMI,

    # When set, skips AppX/Store app collection
    [Parameter(Mandatory = $false)]
    [switch]$SkipAppX,

    # Output path for structured JSON run log
    [Parameter(Mandatory = $false)]
    [string]$LogPath = ".\software-inventory.log.json"
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

function Get-SoftwareFromRegistry {
    <#
    .SYNOPSIS
        Reads installed software from the standard uninstall registry keys.
        Covers both 64-bit and 32-bit software (WOW6432Node).
    #>
    $uninstallPaths = @(
        "HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall\*",
        "HKLM:\SOFTWARE\WOW6432Node\Microsoft\Windows\CurrentVersion\Uninstall\*"
    )

    $results = @()
    foreach ($path in $uninstallPaths) {
        $entries = Get-ItemProperty -Path $path -ErrorAction SilentlyContinue |
                   Where-Object { $_.DisplayName -and $_.DisplayName.Trim() -ne "" }

        foreach ($entry in $entries) {
            $results += [PSCustomObject]@{
                Name        = $entry.DisplayName?.Trim()
                Version     = $entry.DisplayVersion?.Trim()
                Publisher   = $entry.Publisher?.Trim()
                InstallDate = $entry.InstallDate
                InstallLocation = $entry.InstallLocation
                Source      = "Registry"
            }
        }
    }
    return $results
}

function Get-SoftwareFromWMI {
    <#
    .SYNOPSIS
        Queries Win32_Product for installed software.
        NOTE: This triggers MSI reconfiguration validation on some systems.
        Use -SkipWMI on production servers where this is a concern.
    #>
    $results = @()
    try {
        $wmiApps = Get-WmiObject -Class Win32_Product -ErrorAction SilentlyContinue |
                   Where-Object { $_.Name -and $_.Name.Trim() -ne "" }

        foreach ($app in $wmiApps) {
            $results += [PSCustomObject]@{
                Name        = $app.Name?.Trim()
                Version     = $app.Version?.Trim()
                Publisher   = $app.Vendor?.Trim()
                InstallDate = $app.InstallDate
                InstallLocation = $app.InstallLocation
                Source      = "WMI-Win32Product"
            }
        }
    }
    catch {
        # WMI query failure is non-fatal — log and continue
        Write-Log "WMI Win32_Product query failed: $_" -Level WARN
    }
    return $results
}

function Get-SoftwareFromAppX {
    <#
    .SYNOPSIS
        Retrieves installed AppX / Microsoft Store packages for all users.
    #>
    $results = @()
    try {
        $appxPackages = Get-AppxPackage -AllUsers -ErrorAction SilentlyContinue |
                        Where-Object { $_.Name -notlike "Microsoft.Windows.*" -and
                                       $_.SignatureKind -ne "System" }

        foreach ($pkg in $appxPackages) {
            $results += [PSCustomObject]@{
                Name        = $pkg.Name
                Version     = $pkg.Version.ToString()
                Publisher   = $pkg.Publisher
                InstallDate = $null
                InstallLocation = $pkg.InstallLocation
                Source      = "AppX"
            }
        }
    }
    catch {
        Write-Log "AppX package query failed: $_" -Level WARN
    }
    return $results
}

function Invoke-InventoryOnMachine {
    <#
    .SYNOPSIS
        Executes the full inventory collection on a single machine (local or remote).
        Returns a normalized, deduplicated list of installed software entries.
    #>
    param (
        [string]$ComputerName,
        [bool]$SkipWMI,
        [bool]$SkipAppX
    )

    $scriptBlock = {
        param($SkipWMI, $SkipAppX)

        $allSoftware = @()

        # ── Registry source ────────────────────────────────────────────────────
        $uninstallPaths = @(
            "HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall\*",
            "HKLM:\SOFTWARE\WOW6432Node\Microsoft\Windows\CurrentVersion\Uninstall\*"
        )
        foreach ($path in $uninstallPaths) {
            $entries = Get-ItemProperty -Path $path -ErrorAction SilentlyContinue |
                       Where-Object { $_.DisplayName -and $_.DisplayName.Trim() -ne "" }
            foreach ($entry in $entries) {
                $allSoftware += [PSCustomObject]@{
                    Name        = $entry.DisplayName?.Trim()
                    Version     = $entry.DisplayVersion?.Trim()
                    Publisher   = $entry.Publisher?.Trim()
                    InstallDate = $entry.InstallDate
                    Source      = "Registry"
                }
            }
        }

        # ── WMI source ─────────────────────────────────────────────────────────
        if (-not $SkipWMI) {
            try {
                $wmiApps = Get-WmiObject -Class Win32_Product -ErrorAction SilentlyContinue |
                           Where-Object { $_.Name }
                foreach ($app in $wmiApps) {
                    $allSoftware += [PSCustomObject]@{
                        Name        = $app.Name?.Trim()
                        Version     = $app.Version?.Trim()
                        Publisher   = $app.Vendor?.Trim()
                        InstallDate = $app.InstallDate
                        Source      = "WMI"
                    }
                }
            }
            catch { }
        }

        # ── AppX source ────────────────────────────────────────────────────────
        if (-not $SkipAppX) {
            try {
                $pkgs = Get-AppxPackage -AllUsers -ErrorAction SilentlyContinue |
                        Where-Object { $_.SignatureKind -ne "System" }
                foreach ($pkg in $pkgs) {
                    $allSoftware += [PSCustomObject]@{
                        Name        = $pkg.Name
                        Version     = $pkg.Version.ToString()
                        Publisher   = $pkg.Publisher
                        InstallDate = $null
                        Source      = "AppX"
                    }
                }
            }
            catch { }
        }

        # Deduplicate by Name + Version — prefer Registry entry over WMI duplicate
        $deduplicated = $allSoftware |
            Where-Object { $_.Name } |
            Group-Object -Property Name, Version |
            ForEach-Object {
                # If multiple sources have the same app, prefer Registry entry
                $preferred = $_.Group | Where-Object { $_.Source -eq "Registry" } | Select-Object -First 1
                if (-not $preferred) { $preferred = $_.Group | Select-Object -First 1 }
                $preferred
            } |
            Sort-Object Name

        return $deduplicated
    }

    if ($ComputerName -and $ComputerName -ne $env:COMPUTERNAME) {
        try {
            return Invoke-Command -ComputerName $ComputerName `
                                  -ScriptBlock $scriptBlock `
                                  -ArgumentList $SkipWMI, $SkipAppX `
                                  -ErrorAction Stop
        }
        catch {
            Write-Log "Failed to connect to '$ComputerName' via WinRM: $_" -Level ERROR
            return $null
        }
    }
    else {
        return & $scriptBlock $SkipWMI $SkipAppX
    }
}

#endregion

#region ── Initialization ─────────────────────────────────────────────────────

$script:LogEntries = @()
$runTimestamp      = Get-Date -Format "yyyy-MM-dd HH:mm:ss"
$runId             = Get-Date -Format "yyyyMMdd-HHmmss"

# Resolve target machine list
$targetMachines = @()

if ($ComputerListPath) {
    $targetMachines = Get-Content -Path $ComputerListPath |
                      Where-Object { $_ -match '\S' } |
                      ForEach-Object { $_.Trim() }
    Write-Log "Loaded $($targetMachines.Count) hostname(s) from: $ComputerListPath" -Level INFO
}
elseif ($ComputerNames.Count -gt 0) {
    $targetMachines = $ComputerNames
}
else {
    $targetMachines = @($env:COMPUTERNAME)
    Write-Log "No remote targets specified. Inventorying local machine." -Level INFO
}

$allMachineResults = @()
$counters          = @{ MachinesSuccess = 0; MachinesFailed = 0; TotalPackages = 0 }

Write-Log "=== Get-SoftwareInventory START ===" -Level INFO
Write-Log "Run ID      : $runId" -Level INFO
Write-Log "Targets     : $($targetMachines.Count) machine(s)" -Level INFO
Write-Log "Skip WMI    : $($SkipWMI.IsPresent)" -Level INFO
Write-Log "Skip AppX   : $($SkipAppX.IsPresent)" -Level INFO
Write-Log "Output      : $OutputFormat" -Level INFO

if (-not $SkipWMI) {
    Write-Log "NOTE: Win32_Product WMI query can trigger MSI reconfiguration on some systems. Use -SkipWMI on sensitive servers." -Level WARN
}

#endregion

#region ── Step 1: Collect Inventory Per Machine ──────────────────────────────

Write-Log "--- Step 1: Collecting Software Inventory ---" -Level INFO

foreach ($machine in $targetMachines) {
    Write-Log "Inventorying: $machine" -Level INFO

    $softwareList = Invoke-InventoryOnMachine `
                        -ComputerName $machine `
                        -SkipWMI $SkipWMI.IsPresent `
                        -SkipAppX $SkipAppX.IsPresent

    if ($null -eq $softwareList) {
        $counters.MachinesFailed++
        $allMachineResults += [PSCustomObject]@{
            RunId        = $runId
            ComputerName = $machine
            CollectedAt  = $runTimestamp
            Status       = "Failed"
            PackageCount = 0
            Software     = @()
        }
        continue
    }

    $packageCount = @($softwareList).Count
    $counters.TotalPackages   += $packageCount
    $counters.MachinesSuccess++

    Write-Log "  Found $packageCount unique package(s) on $machine" -Level SUCCESS

    $allMachineResults += [PSCustomObject]@{
        RunId        = $runId
        ComputerName = $machine
        CollectedAt  = $runTimestamp
        Status       = "Success"
        PackageCount = $packageCount
        Software     = $softwareList
    }
}

#endregion

#region ── Step 2: Output Report ──────────────────────────────────────────────

Write-Log "=== Get-SoftwareInventory COMPLETE ===" -Level SUCCESS
Write-Log "Machines Success : $($counters.MachinesSuccess)" -Level SUCCESS
Write-Log "Machines Failed  : $($counters.MachinesFailed)" -Level $(if ($counters.MachinesFailed -gt 0) { "WARN" } else { "INFO" })
Write-Log "Total Packages   : $($counters.TotalPackages)" -Level INFO

$report = [PSCustomObject]@{
    RunId       = $runId
    GeneratedAt = $runTimestamp
    Summary     = $counters
    SkipWMI     = $SkipWMI.IsPresent
    SkipAppX    = $SkipAppX.IsPresent
    Results     = $allMachineResults
}

if ($OutputFormat -in "JSON", "Both") {
    $jsonPath = if ($ReportPath -notlike "*.json") { "$ReportPath.json" } else { $ReportPath }
    try {
        $report | ConvertTo-Json -Depth 8 | Set-Content -Path $jsonPath -Encoding UTF8
        Write-Log "JSON report written to: $jsonPath" -Level INFO
    }
    catch { Write-Log "Could not write JSON report: $_" -Level WARN }
}

if ($OutputFormat -in "CSV", "Both") {
    $csvPath = $ReportPath -replace '\.json$', '.csv'
    try {
        # Flatten per-machine results for CSV — one row per software entry
        $flatRows = @()
        foreach ($machine in $allMachineResults) {
            foreach ($sw in $machine.Software) {
                $flatRows += [PSCustomObject]@{
                    ComputerName = $machine.ComputerName
                    Status       = $machine.Status
                    CollectedAt  = $machine.CollectedAt
                    Name         = $sw.Name
                    Version      = $sw.Version
                    Publisher    = $sw.Publisher
                    InstallDate  = $sw.InstallDate
                    Source       = $sw.Source
                }
            }
        }
        $flatRows | Export-Csv -Path $csvPath -NoTypeInformation -Encoding UTF8
        Write-Log "CSV report written to: $csvPath ($($flatRows.Count) rows)" -Level INFO
    }
    catch { Write-Log "Could not write CSV report: $_" -Level WARN }
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
