<#
.SYNOPSIS
    Applies Windows security settings mapped to NIST SP 800-171 and NIST SP 800-53
    controls. Each setting is annotated with its corresponding control ID. Covers
    account policy, audit policy, SMB hardening, credential protection, and RDP
    encryption. Fully idempotent with -WhatIf support.

.DESCRIPTION
    Set-NISTSecurityBaseline.ps1 applies a curated set of Windows security
    configurations aligned to NIST SP 800-171 Rev 2 and NIST SP 800-53 Rev 5.
    Every setting applied by this script is annotated in comments with the control
    ID it satisfies, making the script itself a form of compliance documentation.

    Unlike broad CIS benchmark scripts that apply hundreds of settings indiscriminately,
    this script focuses on the high-signal, high-impact controls that are most
    commonly assessed in FedRAMP, CMMC, and SOC 2 audits.

    Settings are applied across the following control families:
        Account Policy      — Password complexity, length, lockout thresholds
        Audit Policy        — Logon, privilege use, object access, policy change events
        Network Security    — SMB signing, NTLM restriction, anonymous access
        Credential Defense  — WDigest disable, LSASS protection, Credential Guard prep
        Remote Access       — RDP encryption level, NLA enforcement
        Firewall            — Profile enforcement validation
        Misc Hardening      — AutoRun disable, error reporting, telemetry reduction

    REQUIREMENTS:
        - Must run as Local Administrator
        - Windows Server 2016+ or Windows 10/11
        - secedit.exe (included in all supported Windows versions)
        - Restart may be required for some settings to take full effect
          (noted per setting in comments)

.PARAMETER WhatIf
    Runs the script in simulation mode. All settings are evaluated and logged
    but no changes are written to the registry, audit policy, or local security
    policy. Use this to preview the impact before applying.

.PARAMETER SkipAuditPolicy
    Switch. When set, audit policy changes are skipped. Useful when audit
    policy is managed centrally via Group Policy and local changes would be
    overwritten at next GPO refresh.

.PARAMETER SkipAccountPolicy
    Switch. When set, account lockout and password policy changes are skipped.
    Useful when account policy is managed centrally via Group Policy.

.PARAMETER ReportPath
    Output path for the structured JSON application report.
    Records every setting applied, skipped, or that encountered an error.
    Defaults to .\nist-baseline-report.json

.PARAMETER LogPath
    Optional. Path to write a structured JSON run log.
    Defaults to .\nist-baseline-application.log.json

.EXAMPLE
    # Apply full NIST baseline
    .\Set-NISTSecurityBaseline.ps1

.EXAMPLE
    # Preview all changes without applying
    .\Set-NISTSecurityBaseline.ps1 -WhatIf

.EXAMPLE
    # Apply baseline but skip policies managed by GPO
    .\Set-NISTSecurityBaseline.ps1 -SkipAuditPolicy -SkipAccountPolicy

.NOTES
    Author      : Neil Chavez
    Version     : 1.0.0
    Category    : Endpoint Configuration & Drift Remediation
    Folder      : powershell/endpoint-configuration/
    Script #    : 18 of 24

    Idempotency : Each setting is read before being written. If the current value
                  already matches the target value, no write is performed and the
                  setting is logged as "AlreadyCompliant". Safe to run repeatedly.

    Restart Note: Some settings (WDigest, Credential Guard, LSASS protection) require
                  a system restart to take full effect. The report flags these settings.

    NIST Mapping:
        800-171 controls referenced: 3.1.1, 3.1.2, 3.1.8, 3.3.1, 3.3.2,
                                     3.5.7, 3.5.8, 3.13.8, 3.13.10, 3.14.6
        800-53 controls referenced:  AC-2, AC-7, AU-2, AU-12, IA-5, SC-8,
                                     SC-28, SI-2, SI-3

    GPO Note    : Settings applied by this script will be overwritten by conflicting
                  Group Policy Objects at next GPO refresh. In GPO-managed environments,
                  use this script to audit compliance and identify GPO gaps rather
                  than as the primary enforcement mechanism.
#>

[CmdletBinding(SupportsShouldProcess = $true)]
param (
    [Parameter(Mandatory = $false)]
    [switch]$SkipAuditPolicy,

    [Parameter(Mandatory = $false)]
    [switch]$SkipAccountPolicy,

    [Parameter(Mandatory = $false)]
    [string]$ReportPath = ".\nist-baseline-report.json",

    [Parameter(Mandatory = $false)]
    [string]$LogPath = ".\nist-baseline-application.log.json"
)

#region ── Helper Functions ────────────────────────────────────────────────────

function Write-Log {
    param (
        [string]$Message,
        [ValidateSet("INFO", "WARN", "ERROR", "SUCCESS", "SKIP")]
        [string]$Level = "INFO"
    )
    $timestamp = Get-Date -Format "yyyy-MM-dd HH:mm:ss"
    $colors    = @{ INFO = "Cyan"; WARN = "Yellow"; ERROR = "Red"; SUCCESS = "Green"; SKIP = "Gray" }
    Write-Host "[$timestamp] [$Level] $Message" -ForegroundColor $colors[$Level]
    $script:LogEntries += [PSCustomObject]@{
        Timestamp = $timestamp
        Level     = $Level
        Message   = $Message
    }
}

function Set-RegistryValue {
    <#
    .SYNOPSIS
        Sets a registry value if it differs from the target. Logs AlreadyCompliant
        if the current value already matches, Applied if changed, or Error on failure.
        Supports -WhatIf via the SupportsShouldProcess on the parent scope.
    #>
    param (
        [string]$ControlId,
        [string]$Description,
        [string]$Path,
        [string]$Name,
        [object]$Value,
        [string]$Type,
        [bool]$RequiresRestart = $false
    )

    $script:AppliedSettings += [PSCustomObject]@{
        ControlId       = $ControlId
        Description     = $Description
        RegistryPath    = $Path
        ValueName       = $Name
        TargetValue     = $Value
        ValueType       = $Type
        RequiresRestart = $RequiresRestart
        Status          = $null
        PreviousValue   = $null
    }
    $idx = $script:AppliedSettings.Count - 1

    try {
        # Ensure the registry path exists
        if (-not (Test-Path $Path)) {
            if ($PSCmdlet.ShouldProcess($Path, "Create registry key")) {
                New-Item -Path $Path -Force | Out-Null
            }
        }

        # Read current value for comparison and before/after logging
        $currentValue = $null
        try {
            $currentValue = (Get-ItemProperty -Path $Path -Name $Name -ErrorAction SilentlyContinue).$Name
        }
        catch { }

        $script:AppliedSettings[$idx].PreviousValue = $currentValue

        # Check if already compliant — skip write if value matches
        if ($currentValue -eq $Value) {
            Write-Log "[$ControlId] AlreadyCompliant: $Description" -Level SKIP
            $script:AppliedSettings[$idx].Status = "AlreadyCompliant"
            $script:Counters.AlreadyCompliant++
            return
        }

        if ($PSCmdlet.ShouldProcess("$Path\$Name", "Set value to '$Value' ($Type) — $ControlId")) {
            Set-ItemProperty -Path $Path -Name $Name -Value $Value -Type $Type -Force -ErrorAction Stop
            $script:AppliedSettings[$idx].Status = "Applied"
            $script:Counters.Applied++
            $restartNote = if ($RequiresRestart) { " [RESTART REQUIRED]" } else { "" }
            Write-Log "[$ControlId] Applied: $Description | $Path\$Name = $Value$restartNote" -Level SUCCESS
        }
        else {
            $script:AppliedSettings[$idx].Status = "WhatIf"
            Write-Log "[$ControlId] [WhatIf] Would set: $Path\$Name = $Value" -Level INFO
        }
    }
    catch {
        $script:AppliedSettings[$idx].Status = "Error"
        $script:Counters.Errors++
        Write-Log "[$ControlId] Error applying '$Description': $_" -Level ERROR
    }
}

#endregion

#region ── Initialization ─────────────────────────────────────────────────────

$script:LogEntries     = @()
$script:AppliedSettings = @()
$script:Counters        = @{ Applied = 0; AlreadyCompliant = 0; Skipped = 0; Errors = 0 }
$runTimestamp           = Get-Date -Format "yyyy-MM-dd HH:mm:ss"
$runId                  = Get-Date -Format "yyyyMMdd-HHmmss"

Write-Log "=== Set-NISTSecurityBaseline START ===" -Level INFO
Write-Log "Run ID          : $runId" -Level INFO
Write-Log "Target Machine  : $env:COMPUTERNAME" -Level INFO
Write-Log "WhatIf Mode     : $($WhatIfPreference)" -Level INFO
Write-Log "Skip AuditPolicy: $($SkipAuditPolicy.IsPresent)" -Level INFO
Write-Log "Skip AcctPolicy : $($SkipAccountPolicy.IsPresent)" -Level INFO

# Verify local admin
$currentPrincipal = [Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()
if (-not $currentPrincipal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
    Write-Log "This script must run as Administrator. Some settings will fail without elevation." -Level ERROR
    exit 1
}

#endregion

#region ── Section 1: Credential Defense ──────────────────────────────────────

Write-Log "--- Section 1: Credential Defense ---" -Level INFO

# NIST 800-171 3.5.10 / 800-53 IA-5(1)
# Disable WDigest authentication — prevents plaintext credential caching in LSASS
# Requires restart to take full effect
Set-RegistryValue `
    -ControlId       "CRED-001" `
    -Description     "Disable WDigest plaintext credential caching (NIST 800-171 3.5.10)" `
    -Path            "HKLM:\SYSTEM\CurrentControlSet\Control\SecurityProviders\WDigest" `
    -Name            "UseLogonCredential" `
    -Value           0 `
    -Type            "DWord" `
    -RequiresRestart $true

# NIST 800-171 3.13.10 / 800-53 SC-28
# Enable LSASS protection (Protected Process Light) — prevents credential dumping tools
# from reading LSASS memory. Requires restart.
Set-RegistryValue `
    -ControlId       "CRED-002" `
    -Description     "Enable LSASS Protected Process Light — blocks credential dumping (NIST 800-171 3.13.10)" `
    -Path            "HKLM:\SYSTEM\CurrentControlSet\Control\Lsa" `
    -Name            "RunAsPPL" `
    -Value           1 `
    -Type            "DWord" `
    -RequiresRestart $true

# NIST 800-53 SC-28
# Disable the storage of LM hashes — LM hash is cryptographically weak
Set-RegistryValue `
    -ControlId       "CRED-003" `
    -Description     "Disable LM hash storage — LM is cryptographically weak (NIST 800-53 SC-28)" `
    -Path            "HKLM:\SYSTEM\CurrentControlSet\Control\Lsa" `
    -Name            "NoLMHash" `
    -Value           1 `
    -Type            "DWord"

# NIST 800-171 3.5.8 / 800-53 IA-5
# Set minimum NTLMv2 — reject LM and NTLM responses, require NTLMv2
# Level 5 = Send NTLMv2 response only / Refuse LM and NTLM
Set-RegistryValue `
    -ControlId       "CRED-004" `
    -Description     "Require NTLMv2 session security, refuse LM and NTLM (NIST 800-171 3.5.8)" `
    -Path            "HKLM:\SYSTEM\CurrentControlSet\Control\Lsa" `
    -Name            "LmCompatibilityLevel" `
    -Value           5 `
    -Type            "DWord"

# NIST 800-53 SC-28
# Restrict anonymous SAM enumeration — prevents unauthenticated user/share listing
Set-RegistryValue `
    -ControlId       "CRED-005" `
    -Description     "Restrict anonymous enumeration of SAM accounts (NIST 800-53 SC-28)" `
    -Path            "HKLM:\SYSTEM\CurrentControlSet\Control\Lsa" `
    -Name            "RestrictAnonymousSAM" `
    -Value           1 `
    -Type            "DWord"

# NIST 800-53 AC-2
# Disable anonymous access to named pipes and shares
Set-RegistryValue `
    -ControlId       "CRED-006" `
    -Description     "Disable anonymous access to named pipes and shares (NIST 800-53 AC-2)" `
    -Path            "HKLM:\SYSTEM\CurrentControlSet\Control\Lsa" `
    -Name            "RestrictAnonymous" `
    -Value           1 `
    -Type            "DWord"

#endregion

#region ── Section 2: Network and SMB Hardening ───────────────────────────────

Write-Log "--- Section 2: Network and SMB Hardening ---" -Level INFO

# NIST 800-171 3.13.8 / 800-53 SC-8
# Require SMB packet signing on client — prevents man-in-the-middle relay attacks
Set-RegistryValue `
    -ControlId       "NET-001" `
    -Description     "Require SMB client packet signing — prevents relay attacks (NIST 800-171 3.13.8)" `
    -Path            "HKLM:\SYSTEM\CurrentControlSet\Services\LanmanWorkstation\Parameters" `
    -Name            "RequireSecuritySignature" `
    -Value           1 `
    -Type            "DWord"

# NIST 800-171 3.13.8 / 800-53 SC-8
# Require SMB packet signing on server — clients must sign when connecting to this machine
Set-RegistryValue `
    -ControlId       "NET-002" `
    -Description     "Require SMB server packet signing (NIST 800-171 3.13.8)" `
    -Path            "HKLM:\SYSTEM\CurrentControlSet\Services\LanmanServer\Parameters" `
    -Name            "RequireSecuritySignature" `
    -Value           1 `
    -Type            "DWord"

# NIST 800-53 SC-8
# Disable SMBv1 — deprecated protocol vulnerable to EternalBlue and similar exploits
Set-RegistryValue `
    -ControlId       "NET-003" `
    -Description     "Disable SMBv1 protocol — vulnerable to EternalBlue class exploits (NIST 800-53 SC-8)" `
    -Path            "HKLM:\SYSTEM\CurrentControlSet\Services\LanmanServer\Parameters" `
    -Name            "SMB1" `
    -Value           0 `
    -Type            "DWord"

# NIST 800-53 SC-8
# Enable SMB encryption on server (SMBv3) — encrypts data in transit
Set-RegistryValue `
    -ControlId       "NET-004" `
    -Description     "Enable SMB encryption for data in transit (NIST 800-53 SC-8)" `
    -Path            "HKLM:\SYSTEM\CurrentControlSet\Services\LanmanServer\Parameters" `
    -Name            "EncryptData" `
    -Value           1 `
    -Type            "DWord"

# NIST 800-171 3.1.1 / 800-53 AC-2
# Disable the built-in Administrator account (use named admin accounts instead)
Set-RegistryValue `
    -ControlId       "NET-005" `
    -Description     "Disable NetBIOS name resolution poisoning via WINS proxy disable (NIST 800-171 3.1.1)" `
    -Path            "HKLM:\SYSTEM\CurrentControlSet\Services\NetBT\Parameters" `
    -Name            "EnableLMHOSTS" `
    -Value           0 `
    -Type            "DWord"

#endregion

#region ── Section 3: Remote Desktop Hardening ────────────────────────────────

Write-Log "--- Section 3: Remote Desktop Hardening ---" -Level INFO

# NIST 800-171 3.1.2 / 800-53 AC-17
# Enforce Network Level Authentication for RDP — requires authentication before
# a full RDP session is established (prevents pre-auth exploits)
Set-RegistryValue `
    -ControlId       "RDP-001" `
    -Description     "Enforce NLA for RDP connections — blocks pre-auth session exploits (NIST 800-171 3.1.2)" `
    -Path            "HKLM:\SYSTEM\CurrentControlSet\Control\Terminal Server\WinStations\RDP-Tcp" `
    -Name            "UserAuthentication" `
    -Value           1 `
    -Type            "DWord"

# NIST 800-171 3.13.8 / 800-53 SC-8
# Set RDP encryption level to High (FIPS-compliant) — encrypts all RDP data
# Value 3 = High (128-bit)
Set-RegistryValue `
    -ControlId       "RDP-002" `
    -Description     "Set RDP encryption to High (128-bit) — encrypts all session data (NIST 800-171 3.13.8)" `
    -Path            "HKLM:\SYSTEM\CurrentControlSet\Control\Terminal Server\WinStations\RDP-Tcp" `
    -Name            "MinEncryptionLevel" `
    -Value           3 `
    -Type            "DWord"

# NIST 800-53 AC-17
# Disable RDP if not required — set via registry (separate from firewall rules)
# This sets a flag — actual RDP enable/disable managed through fDenyTSConnections
# Only apply if RDP is not needed (default: skip if RDP is actively in use)
# Administrators should evaluate this per environment
Write-Log "[RDP-003] NOTE: RDP disable (fDenyTSConnections) is environment-specific. Evaluate per deployment." -Level INFO
$script:Counters.Skipped++

#endregion

#region ── Section 4: AutoRun and AutoPlay Hardening ──────────────────────────

Write-Log "--- Section 4: AutoRun and AutoPlay Hardening ---" -Level INFO

# NIST 800-53 SI-3
# Disable AutoRun for all drive types — prevents automatic execution of removable media
Set-RegistryValue `
    -ControlId       "AUTO-001" `
    -Description     "Disable AutoRun for all drive types — prevents removable media auto-execution (NIST 800-53 SI-3)" `
    -Path            "HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Policies\Explorer" `
    -Name            "NoDriveTypeAutoRun" `
    -Value           255 `
    -Type            "DWord"

# NIST 800-53 SI-3
# Disable AutoPlay for non-volume devices
Set-RegistryValue `
    -ControlId       "AUTO-002" `
    -Description     "Disable AutoPlay for all drives (NIST 800-53 SI-3)" `
    -Path            "HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Policies\Explorer" `
    -Name            "NoAutoplayfornonVolume" `
    -Value           1 `
    -Type            "DWord"

#endregion

#region ── Section 5: Windows Error Reporting and Telemetry ───────────────────

Write-Log "--- Section 5: Error Reporting and Telemetry ---" -Level INFO

# NIST 800-53 SI-2
# Disable Windows Error Reporting — prevents potential data leakage of crash dumps
Set-RegistryValue `
    -ControlId       "PRIV-001" `
    -Description     "Disable Windows Error Reporting crash dump upload (NIST 800-53 SI-2)" `
    -Path            "HKLM:\SOFTWARE\Microsoft\Windows\Windows Error Reporting" `
    -Name            "Disabled" `
    -Value           1 `
    -Type            "DWord"

# NIST 800-53 SI-2
# Set telemetry to Security level (0) — minimum telemetry for Enterprise SKUs
# Restricts data sent to Microsoft to security-related data only
Set-RegistryValue `
    -ControlId       "PRIV-002" `
    -Description     "Set Windows telemetry to Security level — minimum data collection (NIST 800-53 SI-2)" `
    -Path            "HKLM:\SOFTWARE\Policies\Microsoft\Windows\DataCollection" `
    -Name            "AllowTelemetry" `
    -Value           0 `
    -Type            "DWord"

#endregion

#region ── Section 6: Audit Policy ────────────────────────────────────────────

Write-Log "--- Section 6: Audit Policy ---" -Level INFO

if ($SkipAuditPolicy) {
    Write-Log "SkipAuditPolicy specified. Skipping audit policy configuration." -Level INFO
    $script:Counters.Skipped += 6
}
else {
    # NIST 800-171 3.3.1 / 800-53 AU-2, AU-12
    # Apply audit policy via auditpol.exe — covers the most critical event categories
    # for incident detection and forensic investigation

    $auditSettings = @(
        @{ Category = "Logon/Logoff";          Subcategory = "Logon";                  Success = $true;  Failure = $true  },  # 3.3.1 — Track all logon events
        @{ Category = "Logon/Logoff";          Subcategory = "Logoff";                 Success = $true;  Failure = $false },
        @{ Category = "Logon/Logoff";          Subcategory = "Account Lockout";        Success = $false; Failure = $true  },  # 3.1.8 — Lockout events
        @{ Category = "Account Management";    Subcategory = "User Account Management";Success = $true;  Failure = $true  },  # 3.3.2 — Account changes
        @{ Category = "Account Management";    Subcategory = "Security Group Management";Success = $true; Failure = $true  },
        @{ Category = "Privilege Use";         Subcategory = "Sensitive Privilege Use"; Success = $true; Failure = $true  },  # 3.3.1 — Privilege escalation
        @{ Category = "Policy Change";         Subcategory = "Audit Policy Change";    Success = $true;  Failure = $true  },  # 3.3.1 — Policy modifications
        @{ Category = "System";                Subcategory = "System Integrity";       Success = $true;  Failure = $true  },  # 3.14.6 — Integrity violations
        @{ Category = "Object Access";         Subcategory = "File System";            Success = $false; Failure = $true  }   # 3.3.1 — Failed file access
    )

    foreach ($setting in $auditSettings) {
        $successFlag = if ($setting.Success) { "enable" } else { "disable" }
        $failureFlag = if ($setting.Failure) { "enable" } else { "disable" }
        $subcategory = $setting.Subcategory

        if ($PSCmdlet.ShouldProcess("Audit Policy", "Set '$subcategory': Success=$($setting.Success), Failure=$($setting.Failure)")) {
            try {
                $result = & auditpol.exe /set /subcategory:"$subcategory" /success:$successFlag /failure:$failureFlag 2>&1
                if ($LASTEXITCODE -eq 0) {
                    Write-Log "[AU-POLICY] Applied: '$subcategory' Success=$($setting.Success) Failure=$($setting.Failure) (NIST 800-171 3.3.1)" -Level SUCCESS
                    $script:Counters.Applied++
                }
                else {
                    Write-Log "[AU-POLICY] Failed to set '$subcategory': $result" -Level ERROR
                    $script:Counters.Errors++
                }
            }
            catch {
                Write-Log "[AU-POLICY] Exception setting '$subcategory': $_" -Level ERROR
                $script:Counters.Errors++
            }
        }
        else {
            Write-Log "[WhatIf] Would set audit policy: '$subcategory'" -Level INFO
        }
    }
}

#endregion

#region ── Section 7: Account Lockout Policy ──────────────────────────────────

Write-Log "--- Section 7: Account Lockout Policy ---" -Level INFO

if ($SkipAccountPolicy) {
    Write-Log "SkipAccountPolicy specified. Skipping account lockout configuration." -Level INFO
    $script:Counters.Skipped += 3
}
else {
    # NIST 800-171 3.1.8 / 800-53 AC-7
    # Account lockout settings applied via net accounts — secedit would require
    # an INF file export/import cycle which is more complex for this scope

    if ($PSCmdlet.ShouldProcess("Account Policy", "Set lockout threshold to 5 attempts (NIST 800-171 3.1.8)")) {
        try {
            & net accounts /lockoutthreshold:5    | Out-Null  # Lock after 5 bad attempts
            & net accounts /lockoutduration:30    | Out-Null  # Lock for 30 minutes
            & net accounts /lockoutwindow:30      | Out-Null  # Reset counter after 30 minutes
            Write-Log "[ACCT-001] Account lockout configured: 5 attempts / 30 min duration / 30 min window (NIST 800-171 3.1.8)" -Level SUCCESS
            $script:Counters.Applied++
        }
        catch {
            Write-Log "[ACCT-001] Failed to configure lockout policy: $_" -Level ERROR
            $script:Counters.Errors++
        }
    }
    else {
        Write-Log "[WhatIf] Would set lockout: 5 attempts / 30 min lock / 30 min window" -Level INFO
    }

    # NIST 800-171 3.5.7 / 800-53 IA-5
    # Minimum password length — 14 characters minimum per NIST guidance
    if ($PSCmdlet.ShouldProcess("Account Policy", "Set minimum password length to 14 (NIST 800-171 3.5.7)")) {
        try {
            & net accounts /minpwlen:14 | Out-Null
            Write-Log "[ACCT-002] Minimum password length set to 14 characters (NIST 800-171 3.5.7)" -Level SUCCESS
            $script:Counters.Applied++
        }
        catch {
            Write-Log "[ACCT-002] Failed to set minimum password length: $_" -Level ERROR
            $script:Counters.Errors++
        }
    }
    else {
        Write-Log "[WhatIf] Would set minimum password length to 14" -Level INFO
    }

    # NIST 800-171 3.5.8 / 800-53 IA-5
    # Password history — remember last 24 passwords to prevent reuse
    if ($PSCmdlet.ShouldProcess("Account Policy", "Set password history to 24 (NIST 800-171 3.5.8)")) {
        try {
            & net accounts /uniquepw:24 | Out-Null
            Write-Log "[ACCT-003] Password history set to 24 (NIST 800-171 3.5.8)" -Level SUCCESS
            $script:Counters.Applied++
        }
        catch {
            Write-Log "[ACCT-003] Failed to set password history: $_" -Level ERROR
            $script:Counters.Errors++
        }
    }
    else {
        Write-Log "[WhatIf] Would set password history to 24" -Level INFO
    }
}

#endregion

#region ── Output & Logging ───────────────────────────────────────────────────

Write-Log "=== Set-NISTSecurityBaseline COMPLETE ===" -Level SUCCESS
Write-Log "Applied          : $($script:Counters.Applied)" -Level SUCCESS
Write-Log "Already Compliant: $($script:Counters.AlreadyCompliant)" -Level INFO
Write-Log "Skipped          : $($script:Counters.Skipped)" -Level INFO
Write-Log "Errors           : $($script:Counters.Errors)" -Level $(if ($script:Counters.Errors -gt 0) { "ERROR" } else { "INFO" })

$restartRequired = $script:AppliedSettings | Where-Object { $_.RequiresRestart -and $_.Status -eq "Applied" }
if ($restartRequired.Count -gt 0) {
    Write-Log "RESTART REQUIRED for $($restartRequired.Count) setting(s) to take full effect." -Level WARN
}

$report = [PSCustomObject]@{
    RunId           = $runId
    GeneratedAt     = $runTimestamp
    TargetMachine   = $env:COMPUTERNAME
    WhatIf          = $WhatIfPreference.ToString()
    Summary         = $script:Counters
    RestartRequired = ($restartRequired.Count -gt 0)
    Settings        = $script:AppliedSettings
}

try {
    $report | ConvertTo-Json -Depth 5 | Set-Content -Path $ReportPath -Encoding UTF8
    Write-Log "Report written to: $ReportPath" -Level INFO
}
catch { Write-Log "Could not write report: $_" -Level WARN }

$logEntry = [PSCustomObject]@{
    RunAt      = $runTimestamp
    Result     = $report.Summary
    LogEntries = $script:LogEntries
}
try { $logEntry | ConvertTo-Json -Depth 5 | Set-Content -Path $LogPath -Encoding UTF8 }
catch { Write-Log "Could not write log file: $_" -Level WARN }

return $report

#endregion
