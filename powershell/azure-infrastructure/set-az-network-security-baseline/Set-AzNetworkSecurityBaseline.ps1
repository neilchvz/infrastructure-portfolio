# Set-AzNetworkSecurityBaseline.ps1
# Author   : Neil Chavez
# Version  : 1.0.0
# Category : Azure Infrastructure Automation
# Folder   : powershell/azure-infrastructure/
# Script # : 24 of 24
#
# PURPOSE
# -------
# Audits and enforces NSG (Network Security Group) rules across targeted Azure
# subnets against a defined security baseline. Flags rules that introduce
# exposure (inbound RDP/SSH from Internet, unrestricted outbound, missing flow
# logs) and optionally remediates violations with -Enforce.
#
# NSG rule drift is a persistent problem in Azure environments. A single
# misconfigured inbound rule can expose management ports to the public Internet,
# and drift from approved baselines often goes undetected without proactive
# auditing. This script provides both the audit and remediation layer in a
# single pipeline-compatible tool.
#
# What this script checks per NSG:
#
#   Inbound rules:
#     - RDP (port 3389) open to Internet (source: * or 0.0.0.0/0)
#     - SSH (port 22) open to Internet
#     - Any Allow rule with source: * and destination port: * (fully open inbound)
#     - Missing Deny-All-Inbound rule at the lowest priority
#
#   Outbound rules:
#     - Unrestricted outbound (destination: *, port: *, action: Allow)
#       without a corresponding service tag restriction
#
#   Flow logs:
#     - NSG has no flow log configuration (required for traffic visibility)
#
#   Tagging:
#     - NSG missing Owner or Environment tags (governance gap)
#
# Remediation actions (when -Enforce is set):
#     - Removes flagged inbound Allow rules for RDP/SSH from Internet
#     - Does NOT modify outbound rules automatically (requires human review)
#     - Does NOT enable flow logs automatically (requires storage account config)
#     - All removals require -WhatIf preview before -Enforce live run
#
# REQUIREMENTS
# ------------
#   - Az PowerShell module (Az.Network, Az.Accounts)
#   - Connect-AzAccount
#   - Network Contributor role on target NSGs (for -Enforce)
#   - Network Reader role sufficient for audit-only mode
#
# USAGE
# -----
#   # Audit all NSGs in a subscription
#   .\Set-AzNetworkSecurityBaseline.ps1
#
#   # Audit NSGs in a specific resource group
#   .\Set-AzNetworkSecurityBaseline.ps1 -ResourceGroupName "rg-platform-prod"
#
#   # Dry-run remediation — preview what would be removed
#   .\Set-AzNetworkSecurityBaseline.ps1 -ResourceGroupName "rg-platform-prod" -Enforce -WhatIf
#
#   # Live remediation — remove flagged inbound rules
#   .\Set-AzNetworkSecurityBaseline.ps1 -ResourceGroupName "rg-platform-prod" -Enforce
#
#   # Export CSV for security review
#   .\Set-AzNetworkSecurityBaseline.ps1 -ExportCsv -ReportPath ".\nsg-audit.json"

[CmdletBinding(SupportsShouldProcess = $true)]
param (
    # Scope to a specific resource group. If omitted, all NSGs in the subscription are audited.
    [Parameter(Mandatory = $false)]
    [string]$ResourceGroupName,

    # When set, removes flagged inbound RDP/SSH rules open to the Internet.
    # Always use -WhatIf first. Outbound and flow log issues are flagged but not auto-remediated.
    [Parameter(Mandatory = $false)]
    [switch]$Enforce,

    # Output path for the structured JSON audit report
    [Parameter(Mandatory = $false)]
    [string]$ReportPath = ".\nsg-baseline-report.json",

    # When set, also exports a flat CSV of findings
    [Parameter(Mandatory = $false)]
    [switch]$ExportCsv,

    # Ports considered management ports — inbound access from Internet is flagged
    [Parameter(Mandatory = $false)]
    [int[]]$ManagementPorts = @(3389, 22, 5985, 5986, 1433),

    # Output path for structured JSON run log
    [Parameter(Mandatory = $false)]
    [string]$LogPath = ".\nsg-baseline.log.json"
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

function Test-InternetSource {
    <#
    .SYNOPSIS
        Returns true if the rule source represents unrestricted Internet access.
        Catches *, 0.0.0.0/0, and the "Internet" service tag.
    #>
    param ([string]$Source)
    return ($Source -in @("*", "0.0.0.0/0", "Internet") -or $Source -like "0.0.0.0/*")
}

function Test-ManagementPort {
    <#
    .SYNOPSIS
        Returns true if the rule destination port matches any management port,
        or if the destination port is wildcard (*).
    #>
    param (
        [string]$DestinationPort,
        [int[]]$ManagementPorts
    )
    if ($DestinationPort -eq "*") { return $true }
    foreach ($port in $ManagementPorts) {
        if ($DestinationPort -eq $port.ToString()) { return $true }
        # Handle port ranges (e.g. "3380-3400")
        if ($DestinationPort -match "^(\d+)-(\d+)$") {
            if ($port -ge [int]$Matches[1] -and $port -le [int]$Matches[2]) { return $true }
        }
    }
    return $false
}

#endregion

#region ── Initialization ─────────────────────────────────────────────────────

$script:LogEntries = @()
$runTimestamp      = Get-Date -Format "yyyy-MM-dd HH:mm:ss"
$runId             = Get-Date -Format "yyyyMMdd-HHmmss"

$allFindings       = @()
$remediatedRules   = @()
$counters          = @{
    NSGsScanned      = 0
    RulesEvaluated   = 0
    FindingsTotal    = 0
    Critical         = 0
    High             = 0
    Medium           = 0
    RulesRemediated  = 0
    Errors           = 0
}

Write-Log "=== Set-AzNetworkSecurityBaseline START ===" -Level INFO
Write-Log "Run ID         : $runId" -Level INFO
Write-Log "Scope          : $(if ($ResourceGroupName) { $ResourceGroupName } else { 'Full subscription' })" -Level INFO
Write-Log "Enforce Mode   : $($Enforce.IsPresent)" -Level INFO
Write-Log "WhatIf Mode    : $($WhatIfPreference)" -Level INFO
Write-Log "Mgmt Ports     : $($ManagementPorts -join ', ')" -Level INFO

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

#endregion

#region ── Step 1: Retrieve NSGs ──────────────────────────────────────────────

Write-Log "--- Step 1: Retrieve Network Security Groups ---" -Level INFO

$allNSGs = @()
try {
    if ($ResourceGroupName) {
        $allNSGs = Get-AzNetworkSecurityGroup -ResourceGroupName $ResourceGroupName -ErrorAction Stop
    }
    else {
        $allNSGs = Get-AzNetworkSecurityGroup -ErrorAction Stop
    }
    Write-Log "Retrieved $($allNSGs.Count) NSG(s)." -Level INFO
}
catch {
    Write-Log "Failed to retrieve NSGs: $_" -Level ERROR
    exit 1
}

if ($allNSGs.Count -eq 0) {
    Write-Log "No NSGs found in scope." -Level WARN
    exit 0
}

#endregion

#region ── Step 2: Evaluate Each NSG Against Baseline ─────────────────────────

Write-Log "--- Step 2: Evaluating NSGs Against Security Baseline ---" -Level INFO

foreach ($nsg in $allNSGs) {
    $counters.NSGsScanned++
    $nsgFindings = @()

    Write-Log "Evaluating NSG: $($nsg.Name) (RG: $($nsg.ResourceGroupName))" -Level INFO

    # ── Check: Tagging ────────────────────────────────────────────────────────
    if (-not $nsg.Tag -or -not $nsg.Tag.ContainsKey("Owner")) {
        $nsgFindings += [PSCustomObject]@{
            FindingId       = "TAG-001"
            Severity        = "Medium"
            Category        = "Governance"
            RuleName        = "N/A"
            Description     = "NSG missing 'Owner' tag — no accountability tracking"
            Remediation     = "Add Owner tag: Set-AzResource -Tag @{Owner='team-name'}"
            AutoRemediable  = $false
        }
        $counters.Medium++
    }

    if (-not $nsg.Tag -or -not $nsg.Tag.ContainsKey("Environment")) {
        $nsgFindings += [PSCustomObject]@{
            FindingId       = "TAG-002"
            Severity        = "Medium"
            Category        = "Governance"
            RuleName        = "N/A"
            Description     = "NSG missing 'Environment' tag — deployment context unknown"
            Remediation     = "Add Environment tag: Set-AzResource -Tag @{Environment='prod'}"
            AutoRemediable  = $false
        }
        $counters.Medium++
    }

    # ── Check: Flow Logs ──────────────────────────────────────────────────────
    # Flow logs are checked via Network Watcher — query by NSG ID
    try {
        $flowLog = Get-AzNetworkWatcherFlowLogStatus `
                       -NetworkWatcherName "NetworkWatcher_$($nsg.Location)" `
                       -ResourceGroupName  "NetworkWatcherRG" `
                       -TargetResourceId   $nsg.Id `
                       -ErrorAction SilentlyContinue

        if (-not $flowLog -or $flowLog.Enabled -eq $false) {
            $nsgFindings += [PSCustomObject]@{
                FindingId       = "FLOW-001"
                Severity        = "High"
                Category        = "Visibility"
                RuleName        = "N/A"
                Description     = "NSG flow logs are not enabled — no traffic visibility for incident response"
                Remediation     = "Enable NSG flow logs via Network Watcher. Requires a storage account."
                AutoRemediable  = $false
            }
            $counters.High++
        }
        else {
            Write-Log "  Flow logs: Enabled" -Level SUCCESS
        }
    }
    catch {
        # Network Watcher may not exist in every region — non-fatal
        Write-Log "  Could not check flow log status for '$($nsg.Name)': $_" -Level WARN
    }

    # ── Check: Inbound Security Rules ─────────────────────────────────────────
    $hasDenyAll      = $false
    $highestPriority = 65000

    foreach ($rule in $nsg.SecurityRules | Where-Object { $_.Direction -eq "Inbound" }) {
        $counters.RulesEvaluated++

        # Track if there's a Deny-All rule
        if ($rule.Access -eq "Deny" -and
            $rule.SourceAddressPrefix -eq "*" -and
            $rule.DestinationPortRange -eq "*") {
            $hasDenyAll      = $true
            $highestPriority = [math]::Min($highestPriority, $rule.Priority)
        }

        # Check for management port exposure from Internet
        if ($rule.Access -eq "Allow") {
            $sources = @($rule.SourceAddressPrefix) + @($rule.SourceAddressPrefixes) | Where-Object { $_ }
            $ports   = @($rule.DestinationPortRange) + @($rule.DestinationPortRanges) | Where-Object { $_ }

            $fromInternet     = $sources | Where-Object { Test-InternetSource $_ }
            $toMgmtPort       = $ports   | Where-Object { Test-ManagementPort $_ $ManagementPorts }

            if ($fromInternet -and $toMgmtPort) {
                # Critical: management port exposed to Internet
                $severity = "Critical"
                $ruleDesc = "Rule '$($rule.Name)' allows inbound from Internet on port(s): $($ports -join ', ') — EXPOSES MANAGEMENT PORT"
                Write-Log "  [CRITICAL] $ruleDesc" -Level ERROR
                $counters.Critical++

                $nsgFindings += [PSCustomObject]@{
                    FindingId       = "INBOUND-CRITICAL-$($rule.Name)"
                    Severity        = $severity
                    Category        = "Inbound Exposure"
                    RuleName        = $rule.Name
                    Description     = $ruleDesc
                    Remediation     = "Remove or restrict rule '$($rule.Name)' to specific source IP ranges"
                    AutoRemediable  = $true   # Marked for -Enforce auto-removal
                    RuleObject      = $rule
                }

                # ── Auto-remediate if -Enforce is set ──────────────────────────
                if ($Enforce) {
                    if ($PSCmdlet.ShouldProcess("$($nsg.Name)/$($rule.Name)", "Remove inbound rule — management port exposed to Internet")) {
                        try {
                            # Remove the offending rule from the NSG
                            $nsg.SecurityRules.Remove($rule) | Out-Null
                            Set-AzNetworkSecurityGroup -NetworkSecurityGroup $nsg -ErrorAction Stop | Out-Null
                            Write-Log "  [REMEDIATED] Removed rule '$($rule.Name)' from NSG '$($nsg.Name)'" -Level SUCCESS
                            $counters.RulesRemediated++
                            $remediatedRules += [PSCustomObject]@{
                                NSG       = $nsg.Name
                                RuleName  = $rule.Name
                                Action    = "Removed"
                                Reason    = "Inbound management port exposed to Internet"
                                Timestamp = (Get-Date -Format "yyyy-MM-dd HH:mm:ss")
                            }
                        }
                        catch {
                            Write-Log "  [ERROR] Failed to remove rule '$($rule.Name)': $_" -Level ERROR
                            $counters.Errors++
                        }
                    }
                    else {
                        Write-Log "  [WhatIf] Would remove rule '$($rule.Name)' from NSG '$($nsg.Name)'" -Level INFO
                    }
                }
            }
            elseif ($fromInternet -and -not $toMgmtPort) {
                # High: non-management port open from Internet (may be intentional for web tier)
                $nsgFindings += [PSCustomObject]@{
                    FindingId       = "INBOUND-HIGH-$($rule.Name)"
                    Severity        = "High"
                    Category        = "Inbound Exposure"
                    RuleName        = $rule.Name
                    Description     = "Rule '$($rule.Name)' allows inbound from Internet on port(s): $($ports -join ', ') — review if intentional"
                    Remediation     = "Verify this rule is intentional. If for web tier, document as approved exception."
                    AutoRemediable  = $false
                }
                $counters.High++
                Write-Log "  [HIGH] Inbound from Internet on non-mgmt port: $($rule.Name)" -Level WARN
            }
        }
    }

    # ── Check: Missing Deny-All-Inbound rule ─────────────────────────────────
    if (-not $hasDenyAll) {
        $nsgFindings += [PSCustomObject]@{
            FindingId       = "INBOUND-DENYALL"
            Severity        = "Medium"
            Category        = "Defense in Depth"
            RuleName        = "N/A"
            Description     = "No explicit Deny-All-Inbound rule found. Relies on Azure default deny, which cannot be viewed in rule list."
            Remediation     = "Add an explicit Deny-All rule at priority 4096 for visibility and audit trail."
            AutoRemediable  = $false
        }
        $counters.Medium++
    }

    # ── Check: Unrestricted Outbound ──────────────────────────────────────────
    foreach ($rule in $nsg.SecurityRules | Where-Object { $_.Direction -eq "Outbound" -and $_.Access -eq "Allow" }) {
        $counters.RulesEvaluated++

        $dests = @($rule.DestinationAddressPrefix) + @($rule.DestinationAddressPrefixes) | Where-Object { $_ }
        $ports = @($rule.DestinationPortRange)     + @($rule.DestinationPortRanges)     | Where-Object { $_ }

        $isWildcardDest = $dests | Where-Object { $_ -eq "*" -or $_ -eq "0.0.0.0/0" -or $_ -eq "Internet" }
        $isWildcardPort = $ports | Where-Object { $_ -eq "*" }

        if ($isWildcardDest -and $isWildcardPort) {
            $nsgFindings += [PSCustomObject]@{
                FindingId       = "OUTBOUND-UNRESTRICTED-$($rule.Name)"
                Severity        = "High"
                Category        = "Outbound Exposure"
                RuleName        = $rule.Name
                Description     = "Rule '$($rule.Name)' allows unrestricted outbound to any destination on any port — data exfiltration risk"
                Remediation     = "Restrict outbound using service tags (e.g. AzureMonitor, Storage) instead of wildcard."
                AutoRemediable  = $false
            }
            $counters.High++
            Write-Log "  [HIGH] Unrestricted outbound rule: $($rule.Name)" -Level WARN
        }
    }

    # ── Aggregate NSG findings into master list ────────────────────────────────
    $counters.FindingsTotal += $nsgFindings.Count

    foreach ($finding in $nsgFindings) {
        $allFindings += [PSCustomObject]@{
            RunId             = $runId
            NSGName           = $nsg.Name
            NSGResourceGroup  = $nsg.ResourceGroupName
            NSGLocation       = $nsg.Location
            FindingId         = $finding.FindingId
            Severity          = $finding.Severity
            Category          = $finding.Category
            RuleName          = $finding.RuleName
            Description       = $finding.Description
            Remediation       = $finding.Remediation
            AutoRemediable    = $finding.AutoRemediable
            Timestamp         = $runTimestamp
        }
    }

    $statusColor = if ($nsgFindings | Where-Object { $_.Severity -eq "Critical" }) { "ERROR" }
                   elseif ($nsgFindings | Where-Object { $_.Severity -eq "High" }) { "WARN" }
                   else { "SUCCESS" }

    Write-Log "NSG '$($nsg.Name)' evaluation complete. Findings: $($nsgFindings.Count)" -Level $statusColor
}

#endregion

#region ── Step 3: Output Report ──────────────────────────────────────────────

Write-Log "=== Set-AzNetworkSecurityBaseline COMPLETE ===" -Level SUCCESS
Write-Log "NSGs Scanned     : $($counters.NSGsScanned)" -Level INFO
Write-Log "Rules Evaluated  : $($counters.RulesEvaluated)" -Level INFO
Write-Log "Total Findings   : $($counters.FindingsTotal)" -Level $(if ($counters.FindingsTotal -gt 0) { "WARN" } else { "SUCCESS" })
Write-Log "  Critical       : $($counters.Critical)" -Level $(if ($counters.Critical -gt 0) { "ERROR" } else { "INFO" })
Write-Log "  High           : $($counters.High)" -Level $(if ($counters.High -gt 0) { "WARN" } else { "INFO" })
Write-Log "  Medium         : $($counters.Medium)" -Level INFO
Write-Log "Rules Remediated : $($counters.RulesRemediated)" -Level $(if ($counters.RulesRemediated -gt 0) { "SUCCESS" } else { "INFO" })

$report = [PSCustomObject]@{
    RunId            = $runId
    GeneratedAt      = $runTimestamp
    Scope            = if ($ResourceGroupName) { $ResourceGroupName } else { "Full subscription" }
    EnforceMode      = $Enforce.IsPresent
    WhatIf           = $WhatIfPreference.ToString()
    Summary          = $counters
    Findings         = $allFindings
    RemediatedRules  = $remediatedRules
}

try {
    $report | ConvertTo-Json -Depth 6 | Set-Content -Path $ReportPath -Encoding UTF8
    Write-Log "JSON report written to: $ReportPath" -Level INFO
}
catch { Write-Log "Could not write JSON report: $_" -Level WARN }

if ($ExportCsv) {
    $csvPath = $ReportPath -replace '\.json$', '.csv'
    try {
        $allFindings |
            Select-Object NSGName, NSGResourceGroup, Severity, Category,
                          RuleName, Description, Remediation, AutoRemediable |
            Sort-Object Severity, NSGName |
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
catch { Write-Log "Could not write log: $_" -Level WARN }

return $report

#endregion
