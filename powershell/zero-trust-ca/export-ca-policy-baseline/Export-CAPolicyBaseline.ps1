<#
.SYNOPSIS
    Exports all Entra ID Conditional Access policies to versioned JSON files,
    creating a policy-as-code baseline suitable for Git storage, drift detection,
    and rollback reference.

.DESCRIPTION
    Export-CAPolicyBaseline.ps1 queries the full Conditional Access policy set from
    Microsoft Graph and serializes each policy to an individual JSON file. The output
    is structured for use as a baseline snapshot — intended to be committed to source
    control so that any future deviation from the approved state can be detected.

    It performs the following steps:
        1. Validates required modules and active Graph session.
        2. Retrieves all CA policies including named locations, conditions,
           grant controls, and session controls.
        3. Enriches each policy with human-readable metadata (created date,
           modified date, state, included/excluded users and groups).
        4. Writes one JSON file per policy, named by sanitized policy display name.
        5. Writes a manifest file (baseline-manifest.json) listing all exported
           policies with their IDs, states, and export timestamp.
        6. Optionally writes a single consolidated JSON file containing all policies.

    The manifest file is the anchor for downstream drift detection. It records the
    exact policy set and state at the time of export, and is what Compare-CAPolicyDrift.ps1
    reads to establish the approved baseline.

    REQUIREMENTS:
        - Microsoft.Graph PowerShell SDK
        - Connect-MgGraph with scopes:
            Policy.Read.All, Directory.Read.All
        - Caller must have: Security Reader or Global Reader role in Entra ID

.PARAMETER OutputPath
    Directory where exported JSON files will be written.
    Will be created if it does not exist. Defaults to .\ca-baseline\

.PARAMETER Consolidate
    Switch. When set, also writes a single all-policies.json file containing
    the full policy set as a JSON array. Useful for bulk comparison tools.

.PARAMETER IncludeDisabled
    Switch. When set, includes policies in a Disabled state in the export.
    By default, only Enabled and EnabledForReportingButNotEnforced policies
    are exported. Disabled policies are excluded to keep the baseline clean.

.PARAMETER WhatIf
    Runs the script in simulation mode. Queries Graph and logs what would be
    exported, but does not write any files to disk.

.PARAMETER LogPath
    Optional. Path to write a structured JSON log for this export run.
    Defaults to .\ca-baseline-export.log.json

.EXAMPLE
    # Standard export to default output path
    .\Export-CAPolicyBaseline.ps1

.EXAMPLE
    # Export to a specific directory for Git commit
    .\Export-CAPolicyBaseline.ps1 -OutputPath ".\zero-trust-ca\baseline\"

.EXAMPLE
    # Export all policies including disabled, with consolidated file
    .\Export-CAPolicyBaseline.ps1 `
        -OutputPath ".\zero-trust-ca\baseline\" `
        -IncludeDisabled `
        -Consolidate

.EXAMPLE
    # Dry run — see what would be exported without writing files
    .\Export-CAPolicyBaseline.ps1 -WhatIf

.NOTES
    Author      : Neil Chavez
    Version     : 1.0.0
    Category    : Zero Trust / Conditional Access
    Folder      : powershell/zero-trust-ca/
    Script #    : 05 of 24

    Git Workflow : After running this script, commit the output directory to your
                   policy-as-code repository. Tag the commit with the date or change
                   ticket number. Use Compare-CAPolicyDrift.ps1 (Script 06) to diff
                   live state against this baseline at any time.

    File Naming  : Policy files are named using the sanitized policy DisplayName.
                   Special characters and spaces are replaced with hyphens.
                   Example: "Require MFA for All Users" → require-mfa-for-all-users.json

    Manifest     : baseline-manifest.json is always written regardless of -Consolidate.
                   It is the authoritative index used by downstream drift detection.

    Dependencies:
        Install-Module Microsoft.Graph -Scope CurrentUser

    Connect before running:
        Connect-MgGraph -Scopes "Policy.Read.All","Directory.Read.All"
#>

[CmdletBinding(SupportsShouldProcess = $true)]
param (
    [Parameter(Mandatory = $false)]
    [string]$OutputPath = ".\ca-baseline",

    [Parameter(Mandatory = $false)]
    [switch]$Consolidate,

    [Parameter(Mandatory = $false)]
    [switch]$IncludeDisabled,

    [Parameter(Mandatory = $false)]
    [string]$LogPath = ".\ca-baseline-export.log.json"
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

function Get-SafeFileName {
    <#
    .SYNOPSIS
        Converts a policy display name into a safe, lowercase filename.
        Spaces and special characters are replaced with hyphens.
    #>
    param ([string]$Name)
    return ($Name.ToLower() -replace '[^a-z0-9\-]', '-' -replace '-{2,}', '-').Trim('-')
}

function Resolve-GroupDisplayName {
    <#
    .SYNOPSIS
        Resolves an Entra ID Object ID to a display name.
        Returns the raw ID if the lookup fails (e.g. deleted group).
    #>
    param ([string]$ObjectId)
    try {
        $obj = Get-MgDirectoryObject -DirectoryObjectId $ObjectId -ErrorAction SilentlyContinue
        return $obj.AdditionalProperties['displayName'] ?? $ObjectId
    }
    catch {
        return $ObjectId
    }
}

#endregion

#region ── Initialization ─────────────────────────────────────────────────────

$script:LogEntries = @()
$runTimestamp      = Get-Date -Format "yyyy-MM-dd HH:mm:ss"
$runId             = Get-Date -Format "yyyyMMdd-HHmmss"

$result = [PSCustomObject]@{
    RunId          = $runId
    ExportedAt     = $runTimestamp
    OutputPath     = $OutputPath
    PoliciesFound  = 0
    PoliciesExported = 0
    PoliciesSkipped  = 0
    ManifestPath   = $null
    WhatIfMode     = $WhatIfPreference.ToString()
    Errors         = @()
}

Write-Log "=== Export-CAPolicyBaseline START ===" -Level INFO
Write-Log "Run ID       : $runId" -Level INFO
Write-Log "Output Path  : $OutputPath" -Level INFO
Write-Log "Consolidate  : $($Consolidate.IsPresent)" -Level INFO
Write-Log "Inc. Disabled: $($IncludeDisabled.IsPresent)" -Level INFO
Write-Log "WhatIf Mode  : $($WhatIfPreference)" -Level INFO

#endregion

#region ── Step 0: Pre-flight Validation ──────────────────────────────────────

Write-Log "--- Step 0: Pre-flight Validation ---" -Level INFO

if (-not (Get-Module -Name "Microsoft.Graph.Identity.SignIns" -ErrorAction SilentlyContinue)) {
    Write-Log "Required module 'Microsoft.Graph.Identity.SignIns' is not loaded." -Level ERROR
    exit 1
}

$ctx = Get-MgContext
if (-not $ctx) {
    Write-Log "No active Microsoft Graph session. Run Connect-MgGraph first." -Level ERROR
    exit 1
}

# Verify required scope is present
$requiredScope = "Policy.Read.All"
if ($ctx.Scopes -notcontains $requiredScope) {
    Write-Log "Graph session is missing required scope: $requiredScope" -Level WARN
    Write-Log "Re-run: Connect-MgGraph -Scopes 'Policy.Read.All','Directory.Read.All'" -Level WARN
}

Write-Log "Graph session active. Tenant: $($ctx.TenantId) | Account: $($ctx.Account)" -Level INFO

#endregion

#region ── Step 1: Create Output Directory ────────────────────────────────────

Write-Log "--- Step 1: Prepare Output Directory ---" -Level INFO

if ($PSCmdlet.ShouldProcess($OutputPath, "Create output directory")) {
    if (-not (Test-Path $OutputPath)) {
        try {
            New-Item -ItemType Directory -Path $OutputPath -Force | Out-Null
            Write-Log "Output directory created: $OutputPath" -Level SUCCESS
        }
        catch {
            Write-Log "Failed to create output directory '$OutputPath': $_" -Level ERROR
            exit 1
        }
    }
    else {
        Write-Log "Output directory already exists: $OutputPath" -Level INFO
    }
}
else {
    Write-Log "[WhatIf] Would create output directory: $OutputPath" -Level INFO
}

#endregion

#region ── Step 2: Retrieve Conditional Access Policies ───────────────────────

Write-Log "--- Step 2: Retrieve CA Policies from Graph ---" -Level INFO

$allPolicies = @()
try {
    $allPolicies = Get-MgIdentityConditionalAccessPolicy -All -ErrorAction Stop
    $result.PoliciesFound = $allPolicies.Count
    Write-Log "Retrieved $($allPolicies.Count) Conditional Access policy/policies from tenant." -Level INFO
}
catch {
    Write-Log "Failed to retrieve CA policies: $_" -Level ERROR
    exit 1
}

if ($allPolicies.Count -eq 0) {
    Write-Log "No Conditional Access policies found in tenant. Nothing to export." -Level WARN
    exit 0
}

#endregion

#region ── Step 3: Filter and Enrich Policies ─────────────────────────────────

Write-Log "--- Step 3: Filter and Enrich Policies ---" -Level INFO

$exportQueue  = @()
$manifestList = @()

foreach ($policy in $allPolicies) {

    # Apply state filter — skip disabled policies unless -IncludeDisabled is set
    if (-not $IncludeDisabled -and $policy.State -eq "disabled") {
        Write-Log "Skipping disabled policy: '$($policy.DisplayName)'" -Level INFO
        $result.PoliciesSkipped++
        continue
    }

    Write-Log "Processing policy: '$($policy.DisplayName)' | State: $($policy.State)" -Level INFO

    # Resolve included/excluded group names for readability
    $includedGroupNames = @()
    $excludedGroupNames = @()

    if ($policy.Conditions.Users.IncludeGroups) {
        $includedGroupNames = $policy.Conditions.Users.IncludeGroups |
                              ForEach-Object { Resolve-GroupDisplayName $_ }
    }

    if ($policy.Conditions.Users.ExcludeGroups) {
        $excludedGroupNames = $policy.Conditions.Users.ExcludeGroups |
                              ForEach-Object { Resolve-GroupDisplayName $_ }
    }

    # Build enriched policy export object — preserves all raw Graph data
    # plus adds human-readable resolved fields for readability
    $enrichedPolicy = [PSCustomObject]@{
        ExportMetadata = [PSCustomObject]@{
            ExportedAt    = $runTimestamp
            ExportRunId   = $runId
            ExportedBy    = $ctx.Account
            TenantId      = $ctx.TenantId
        }
        PolicyId          = $policy.Id
        DisplayName       = $policy.DisplayName
        State             = $policy.State
        CreatedDateTime   = $policy.CreatedDateTime
        ModifiedDateTime  = $policy.ModifiedDateTime
        Conditions        = $policy.Conditions
        GrantControls     = $policy.GrantControls
        SessionControls   = $policy.SessionControls
        ResolvedMetadata  = [PSCustomObject]@{
            IncludedGroupNames = $includedGroupNames
            ExcludedGroupNames = $excludedGroupNames
            IncludesAllUsers   = ($policy.Conditions.Users.IncludeUsers -contains "All")
            IncludesGuestUsers = ($policy.Conditions.Users.IncludeGuestsOrExternalUsers -ne $null)
            PlatformsTargeted  = $policy.Conditions.Platforms.IncludePlatforms
            AppsTargeted       = $policy.Conditions.Applications.IncludeApplications
        }
    }

    $exportQueue  += $enrichedPolicy

    # Build manifest entry — lightweight summary for the index file
    $manifestList += [PSCustomObject]@{
        PolicyId        = $policy.Id
        DisplayName     = $policy.DisplayName
        State           = $policy.State
        CreatedDateTime = $policy.CreatedDateTime
        ModifiedDateTime = $policy.ModifiedDateTime
        FileName        = "$(Get-SafeFileName $policy.DisplayName).json"
    }
}

Write-Log "$($exportQueue.Count) policy/policies queued for export." -Level INFO

#endregion

#region ── Step 4: Write Individual Policy Files ──────────────────────────────

Write-Log "--- Step 4: Write Policy JSON Files ---" -Level INFO

foreach ($policy in $exportQueue) {
    $fileName    = "$(Get-SafeFileName $policy.DisplayName).json"
    $filePath    = Join-Path $OutputPath $fileName

    if ($PSCmdlet.ShouldProcess($filePath, "Write policy JSON: '$($policy.DisplayName)'")) {
        try {
            $policy | ConvertTo-Json -Depth 10 | Set-Content -Path $filePath -Encoding UTF8
            Write-Log "Exported: $fileName" -Level SUCCESS
            $result.PoliciesExported++
        }
        catch {
            $errMsg = "Failed to write policy file '$fileName': $_"
            Write-Log $errMsg -Level ERROR
            $result.Errors += $errMsg
        }
    }
    else {
        Write-Log "[WhatIf] Would write: $filePath" -Level INFO
    }
}

#endregion

#region ── Step 5: Write Manifest File ────────────────────────────────────────

Write-Log "--- Step 5: Write Baseline Manifest ---" -Level INFO

$manifest = [PSCustomObject]@{
    RunId         = $runId
    ExportedAt    = $runTimestamp
    ExportedBy    = $ctx.Account
    TenantId      = $ctx.TenantId
    PolicyCount   = $manifestList.Count
    Policies      = $manifestList
}

$manifestPath      = Join-Path $OutputPath "baseline-manifest.json"
$result.ManifestPath = $manifestPath

if ($PSCmdlet.ShouldProcess($manifestPath, "Write baseline manifest")) {
    try {
        $manifest | ConvertTo-Json -Depth 5 | Set-Content -Path $manifestPath -Encoding UTF8
        Write-Log "Manifest written: $manifestPath" -Level SUCCESS
    }
    catch {
        $errMsg = "Failed to write manifest file: $_"
        Write-Log $errMsg -Level ERROR
        $result.Errors += $errMsg
    }
}
else {
    Write-Log "[WhatIf] Would write manifest: $manifestPath" -Level INFO
}

#endregion

#region ── Step 6: Write Consolidated File (Optional) ─────────────────────────

if ($Consolidate) {
    Write-Log "--- Step 6: Write Consolidated Policy File ---" -Level INFO

    $consolidatedPath = Join-Path $OutputPath "all-policies.json"

    if ($PSCmdlet.ShouldProcess($consolidatedPath, "Write consolidated policy file")) {
        try {
            $exportQueue | ConvertTo-Json -Depth 10 |
                Set-Content -Path $consolidatedPath -Encoding UTF8
            Write-Log "Consolidated file written: $consolidatedPath" -Level SUCCESS
        }
        catch {
            $errMsg = "Failed to write consolidated file: $_"
            Write-Log $errMsg -Level ERROR
            $result.Errors += $errMsg
        }
    }
    else {
        Write-Log "[WhatIf] Would write consolidated file: $consolidatedPath" -Level INFO
    }
}

#endregion

#region ── Step 7: Output & Logging ───────────────────────────────────────────

Write-Log "=== Export-CAPolicyBaseline COMPLETE ===" -Level SUCCESS
Write-Log "Policies Found   : $($result.PoliciesFound)" -Level SUCCESS
Write-Log "Policies Exported: $($result.PoliciesExported)" -Level SUCCESS
Write-Log "Policies Skipped : $($result.PoliciesSkipped)" -Level SUCCESS
Write-Log "Output Path      : $($result.OutputPath)" -Level SUCCESS
Write-Log "Manifest         : $($result.ManifestPath)" -Level SUCCESS

if ($result.Errors.Count -gt 0) {
    Write-Log "Completed with $($result.Errors.Count) error(s). Review output object." -Level WARN
}

$logEntry = [PSCustomObject]@{
    RunAt      = $runTimestamp
    Result     = $result
    LogEntries = $script:LogEntries
}

try {
    $logEntry | ConvertTo-Json -Depth 5 | Set-Content -Path $LogPath -Encoding UTF8
    Write-Log "Log written to: $LogPath" -Level INFO
}
catch {
    Write-Log "Warning: Could not write log file: $_" -Level WARN
}

return $result

#endregion
