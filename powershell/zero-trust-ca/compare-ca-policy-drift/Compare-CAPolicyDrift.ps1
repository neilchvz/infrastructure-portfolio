# Compare-CAPolicyDrift.ps1
# Author   : Neil Chavez
# Version  : 1.0.0
# Category : Zero Trust / Conditional Access
# Folder   : powershell/zero-trust-ca/
# Script # : 06 of 24
#
# PURPOSE
# -------
# Compares the live Conditional Access policy state in Entra ID against a stored
# JSON baseline produced by Export-CAPolicyBaseline.ps1 (Script 05).
#
# Detects three categories of drift:
#   Added     — Policies present in the live tenant but not in the baseline
#   Removed   — Policies present in the baseline but missing from the live tenant
#   Modified  — Policies present in both, but with differences in state, conditions,
#               grant controls, or session controls
#
# Outputs a structured drift report (JSON) with a per-policy diff summary.
# Exits with code 1 if any drift is detected — enabling use as a pipeline gate
# in CI/CD workflows (e.g. block a deployment if policy state has diverged from
# the approved baseline).
#
# REQUIREMENTS
# ------------
#   - Microsoft.Graph PowerShell SDK
#   - Connect-MgGraph with scopes: Policy.Read.All
#   - Caller must have: Security Reader or Global Reader role
#   - A baseline manifest produced by Export-CAPolicyBaseline.ps1
#
# USAGE
# -----
#   # Compare live state against a stored baseline manifest
#   .\Compare-CAPolicyDrift.ps1 -BaselinePath ".\ca-baseline\baseline-manifest.json"
#
#   # Compare and write the drift report to a specific path
#   .\Compare-CAPolicyDrift.ps1 `
#       -BaselinePath ".\ca-baseline\baseline-manifest.json" `
#       -ReportPath ".\ca-drift-report.json"
#
#   # Use in a CI/CD pipeline — exits 1 on drift, 0 if clean
#   .\Compare-CAPolicyDrift.ps1 -BaselinePath ".\ca-baseline\baseline-manifest.json"
#   if ($LASTEXITCODE -ne 0) { throw "CA policy drift detected. Review before deploying." }

[CmdletBinding()]
param (
    # Path to the baseline-manifest.json produced by Export-CAPolicyBaseline.ps1
    [Parameter(Mandatory = $true)]
    [ValidateScript({ Test-Path $_ -PathType Leaf })]
    [string]$BaselinePath,

    # Output path for the drift report JSON
    [Parameter(Mandatory = $false)]
    [string]$ReportPath = ".\ca-drift-report.json",

    # When set, also outputs a plain-text summary of drift to the console
    # Useful for pipeline log readability
    [Parameter(Mandatory = $false)]
    [switch]$Verbose
)

#region ── Initialization ─────────────────────────────────────────────────────

$runTimestamp = Get-Date -Format "yyyy-MM-dd HH:mm:ss"
$runId        = Get-Date -Format "yyyyMMdd-HHmmss"

# Drift accumulators
$driftAdded    = @()  # In live tenant, not in baseline
$driftRemoved  = @()  # In baseline, not in live tenant
$driftModified = @()  # In both, but content has changed

$driftDetected = $false

Write-Host "`n=== Compare-CAPolicyDrift START ===" -ForegroundColor Cyan
Write-Host "Run ID        : $runId" -ForegroundColor Cyan
Write-Host "Baseline File : $BaselinePath" -ForegroundColor Cyan
Write-Host "Report Output : $ReportPath`n" -ForegroundColor Cyan

#endregion

#region ── Step 0: Pre-flight ─────────────────────────────────────────────────

Write-Host "[Step 0] Pre-flight validation..." -ForegroundColor Cyan

if (-not (Get-Module -Name "Microsoft.Graph.Identity.SignIns" -ErrorAction SilentlyContinue)) {
    Write-Host "[ERROR] Module 'Microsoft.Graph.Identity.SignIns' is not loaded." -ForegroundColor Red
    exit 1
}

$ctx = Get-MgContext
if (-not $ctx) {
    Write-Host "[ERROR] No active Microsoft Graph session. Run Connect-MgGraph first." -ForegroundColor Red
    exit 1
}
Write-Host "[INFO] Graph session active. Tenant: $($ctx.TenantId)" -ForegroundColor Cyan

#endregion

#region ── Step 1: Load Baseline Manifest ─────────────────────────────────────

Write-Host "[Step 1] Loading baseline manifest: $BaselinePath" -ForegroundColor Cyan

$baseline = $null
try {
    $baseline = Get-Content -Path $BaselinePath -Raw -ErrorAction Stop | ConvertFrom-Json
}
catch {
    Write-Host "[ERROR] Failed to load or parse baseline manifest: $_" -ForegroundColor Red
    exit 1
}

# Validate manifest structure
if (-not $baseline.Policies -or -not $baseline.TenantId) {
    Write-Host "[ERROR] Baseline manifest is missing required fields (Policies, TenantId)." -ForegroundColor Red
    exit 1
}

# Warn if the baseline is from a different tenant
if ($baseline.TenantId -ne $ctx.TenantId) {
    Write-Host "[WARN] Baseline tenant ID ($($baseline.TenantId)) does not match current session tenant ($($ctx.TenantId))." -ForegroundColor Yellow
    Write-Host "[WARN] Proceeding, but results may not be meaningful across tenant boundaries." -ForegroundColor Yellow
}

Write-Host "[INFO] Baseline loaded. Exported at: $($baseline.ExportedAt) | Policy count: $($baseline.PolicyCount)" -ForegroundColor Cyan

# Build a lookup hashtable from the baseline — keyed by PolicyId
$baselineLookup = @{}
foreach ($p in $baseline.Policies) {
    $baselineLookup[$p.PolicyId] = $p
}

#endregion

#region ── Step 2: Retrieve Live CA Policies ──────────────────────────────────

Write-Host "[Step 2] Retrieving live CA policies from Entra ID..." -ForegroundColor Cyan

$livePolicies = @()
try {
    $livePolicies = Get-MgIdentityConditionalAccessPolicy -All -ErrorAction Stop
    Write-Host "[INFO] Retrieved $($livePolicies.Count) live policy/policies." -ForegroundColor Cyan
}
catch {
    Write-Host "[ERROR] Failed to retrieve live CA policies: $_" -ForegroundColor Red
    exit 1
}

# Build a lookup hashtable from live policies — keyed by PolicyId
$liveLookup = @{}
foreach ($p in $livePolicies) {
    $liveLookup[$p.Id] = $p
}

#endregion

#region ── Step 3: Detect Added Policies ──────────────────────────────────────

Write-Host "[Step 3] Checking for policies added since baseline..." -ForegroundColor Cyan

foreach ($livePolicy in $livePolicies) {
    if (-not $baselineLookup.ContainsKey($livePolicy.Id)) {
        # Policy exists in live tenant but was not in the baseline
        $driftAdded += [PSCustomObject]@{
            PolicyId    = $livePolicy.Id
            DisplayName = $livePolicy.DisplayName
            State       = $livePolicy.State
            DriftType   = "Added"
            Detail      = "Policy not present in baseline. Created after baseline was captured."
            ModifiedDateTime = $livePolicy.ModifiedDateTime
        }
        Write-Host "[DRIFT-ADDED] '$($livePolicy.DisplayName)' ($($livePolicy.Id))" -ForegroundColor Yellow
        $driftDetected = $true
    }
}

if ($driftAdded.Count -eq 0) {
    Write-Host "[INFO] No added policies detected." -ForegroundColor Gray
}

#endregion

#region ── Step 4: Detect Removed Policies ────────────────────────────────────

Write-Host "[Step 4] Checking for policies removed since baseline..." -ForegroundColor Cyan

foreach ($baselinePolicy in $baseline.Policies) {
    if (-not $liveLookup.ContainsKey($baselinePolicy.PolicyId)) {
        # Policy was in the baseline but is no longer in the live tenant
        $driftRemoved += [PSCustomObject]@{
            PolicyId    = $baselinePolicy.PolicyId
            DisplayName = $baselinePolicy.DisplayName
            State       = $baselinePolicy.State
            DriftType   = "Removed"
            Detail      = "Policy present in baseline but not found in live tenant. May have been deleted."
            ModifiedDateTime = $baselinePolicy.ModifiedDateTime
        }
        Write-Host "[DRIFT-REMOVED] '$($baselinePolicy.DisplayName)' ($($baselinePolicy.PolicyId))" -ForegroundColor Red
        $driftDetected = $true
    }
}

if ($driftRemoved.Count -eq 0) {
    Write-Host "[INFO] No removed policies detected." -ForegroundColor Gray
}

#endregion

#region ── Step 5: Detect Modified Policies ───────────────────────────────────

Write-Host "[Step 5] Checking for modified policies..." -ForegroundColor Cyan

foreach ($baselinePolicy in $baseline.Policies) {

    # Only compare policies that exist in both baseline and live state
    if (-not $liveLookup.ContainsKey($baselinePolicy.PolicyId)) { continue }

    $livePolicy = $liveLookup[$baselinePolicy.PolicyId]

    # Load the full baseline policy JSON file for deep comparison
    # The manifest only holds summary fields — the per-policy file has full detail
    $baselineDir      = Split-Path $BaselinePath -Parent
    $baselinePolicyFile = Join-Path $baselineDir $baselinePolicy.FileName
    $baselineFull     = $null

    if (Test-Path $baselinePolicyFile) {
        try {
            $baselineFull = Get-Content -Path $baselinePolicyFile -Raw | ConvertFrom-Json
        }
        catch {
            Write-Host "[WARN] Could not load baseline policy file '$baselinePolicyFile': $_" -ForegroundColor Yellow
        }
    }
    else {
        Write-Host "[WARN] Baseline file not found for '$($baselinePolicy.DisplayName)': $baselinePolicyFile" -ForegroundColor Yellow
    }

    $changedFields = @()

    # Compare state — most critical field (Enabled vs Disabled vs ReportOnly)
    if ($livePolicy.State -ne $baselinePolicy.State) {
        $changedFields += "State: '$($baselinePolicy.State)' → '$($livePolicy.State)'"
    }

    # Compare display name — rename is meaningful for policy governance
    if ($livePolicy.DisplayName -ne $baselinePolicy.DisplayName) {
        $changedFields += "DisplayName: '$($baselinePolicy.DisplayName)' → '$($livePolicy.DisplayName)'"
    }

    # Deep compare conditions, grant controls, and session controls using JSON serialization
    # This catches any nested field change regardless of depth
    if ($baselineFull) {
        $liveConditionsJson     = $livePolicy.Conditions    | ConvertTo-Json -Depth 10 -Compress
        $baselineConditionsJson = $baselineFull.Conditions  | ConvertTo-Json -Depth 10 -Compress

        if ($liveConditionsJson -ne $baselineConditionsJson) {
            $changedFields += "Conditions (scope, users, platforms, apps, or locations changed)"
        }

        $liveGrantJson     = $livePolicy.GrantControls   | ConvertTo-Json -Depth 10 -Compress
        $baselineGrantJson = $baselineFull.GrantControls | ConvertTo-Json -Depth 10 -Compress

        if ($liveGrantJson -ne $baselineGrantJson) {
            $changedFields += "GrantControls (MFA, compliant device, or other requirements changed)"
        }

        $liveSessionJson     = $livePolicy.SessionControls   | ConvertTo-Json -Depth 10 -Compress
        $baselineSessionJson = $baselineFull.SessionControls | ConvertTo-Json -Depth 10 -Compress

        if ($liveSessionJson -ne $baselineSessionJson) {
            $changedFields += "SessionControls (sign-in frequency, persistent session, or app restrictions changed)"
        }
    }

    if ($changedFields.Count -gt 0) {
        $driftModified += [PSCustomObject]@{
            PolicyId        = $livePolicy.Id
            DisplayName     = $livePolicy.DisplayName
            DriftType       = "Modified"
            ChangedFields   = $changedFields
            Detail          = "Policy exists in both baseline and live state but content has changed."
            LiveModifiedAt  = $livePolicy.ModifiedDateTime
            BaselineState   = $baselinePolicy.State
            LiveState       = $livePolicy.State
        }
        Write-Host "[DRIFT-MODIFIED] '$($livePolicy.DisplayName)' | Changes: $($changedFields -join ' | ')" -ForegroundColor Yellow
        $driftDetected = $true
    }
}

if ($driftModified.Count -eq 0) {
    Write-Host "[INFO] No modified policies detected." -ForegroundColor Gray
}

#endregion

#region ── Step 6: Output Report ──────────────────────────────────────────────

$totalDrift = $driftAdded.Count + $driftRemoved.Count + $driftModified.Count

Write-Host "`n=== Compare-CAPolicyDrift COMPLETE ===" -ForegroundColor $(if ($driftDetected) { "Yellow" } else { "Green" })
Write-Host "Baseline exported at : $($baseline.ExportedAt)" -ForegroundColor Cyan
Write-Host "Compared at          : $runTimestamp" -ForegroundColor Cyan
Write-Host "Policies in baseline : $($baseline.PolicyCount)" -ForegroundColor Cyan
Write-Host "Policies in live     : $($livePolicies.Count)" -ForegroundColor Cyan
Write-Host "Drift - Added        : $($driftAdded.Count)" -ForegroundColor $(if ($driftAdded.Count -gt 0) { "Yellow" } else { "Green" })
Write-Host "Drift - Removed      : $($driftRemoved.Count)" -ForegroundColor $(if ($driftRemoved.Count -gt 0) { "Red" } else { "Green" })
Write-Host "Drift - Modified     : $($driftModified.Count)" -ForegroundColor $(if ($driftModified.Count -gt 0) { "Yellow" } else { "Green" })
Write-Host "Total drift items    : $totalDrift" -ForegroundColor $(if ($totalDrift -gt 0) { "Yellow" } else { "Green" })

# Build structured report
$report = [PSCustomObject]@{
    RunId            = $runId
    ComparedAt       = $runTimestamp
    BaselineExportedAt = $baseline.ExportedAt
    TenantId         = $ctx.TenantId
    DriftDetected    = $driftDetected
    Summary          = [PSCustomObject]@{
        BaselinePolicyCount = $baseline.PolicyCount
        LivePolicyCount     = $livePolicies.Count
        Added               = $driftAdded.Count
        Removed             = $driftRemoved.Count
        Modified            = $driftModified.Count
        TotalDrift          = $totalDrift
    }
    Added            = $driftAdded
    Removed          = $driftRemoved
    Modified         = $driftModified
}

try {
    $report | ConvertTo-Json -Depth 8 | Set-Content -Path $ReportPath -Encoding UTF8
    Write-Host "Drift report written to: $ReportPath" -ForegroundColor Cyan
}
catch {
    Write-Host "[WARN] Could not write drift report: $_" -ForegroundColor Yellow
}

# Exit with code 1 if drift was detected — supports pipeline gate usage
if ($driftDetected) {
    Write-Host "`n[ACTION REQUIRED] Conditional Access policy drift detected. Review the report at: $ReportPath" -ForegroundColor Red
    exit 1
}
else {
    Write-Host "`n[CLEAN] No drift detected. Live CA policy state matches baseline." -ForegroundColor Green
    exit 0
}

#endregion
