<#
.SYNOPSIS
    Queries the Microsoft Purview Unified Audit Log with configurable operation
    filters, date ranges, and user scopes. Handles pagination and API rate-limiting
    automatically. Outputs structured JSON or CSV for SIEM ingestion or compliance
    reporting.

.DESCRIPTION
    Export-ComplianceAuditLog.ps1 extracts audit log records from the Microsoft
    Purview Unified Audit Log (UAL) at scale. The built-in compliance portal UI
    caps exports at 5,000 records and times out on large queries — this script
    removes both limitations by paginating automatically and handling the Search-
    UnifiedAuditLog API's session-based cursor model.

    It performs the following steps:
        1. Validates the active Security & Compliance session.
        2. Constructs the audit query from specified parameters.
        3. Executes paginated queries using ResultIndex/ResultCount until all
           matching records are retrieved.
        4. Applies backoff on API throttle responses (429 equivalent).
        5. Optionally filters results by RecordType or specific Operations.
        6. Flattens AuditData JSON payloads into structured output objects.
        7. Writes results to JSON and/or CSV, with chunking for large result sets.

    REQUIREMENTS:
        - ExchangeOnlineManagement module (includes Security & Compliance cmdlets)
        - Connect-IPPSSession (Security & Compliance PowerShell)
        - Unified Audit Log must be enabled in the tenant (Admin > Settings > Audit)
        - Caller must have: View-Only Audit Logs or Audit Logs role in compliance portal

.PARAMETER StartDate
    Start of the audit query window. Accepts any format parseable by [datetime].
    Minimum lookback depends on tenant license (90 days standard, 1 year E5/Audit Premium).

.PARAMETER EndDate
    End of the audit query window. Defaults to now if not specified.

.PARAMETER Operations
    Optional. Array of specific operation names to filter on.
    Examples: "FileAccessed", "UserLoggedIn", "Set-MailboxPermission"
    If omitted, all operations within the date range are returned.
    Run Search-UnifiedAuditLog -Operations * to see available operations.

.PARAMETER RecordType
    Optional. Filters results to a specific UAL record type category.
    Examples: "ExchangeAdmin", "SharePointFileOperation", "AzureActiveDirectory"
    Full list: https://docs.microsoft.com/en-us/microsoft-365/compliance/audit-log-activities

.PARAMETER UserIds
    Optional. Array of UPNs to scope the query to specific users.
    If omitted, all users are included.

.PARAMETER ResultOutputPath
    Directory where output files will be written. Will be created if not exists.
    Defaults to .\audit-export\

.PARAMETER OutputFormat
    Output format for results. JSON, CSV, or Both. Defaults to Both.

.PARAMETER ChunkSize
    Maximum records per output file. Large exports are chunked to avoid
    single files exceeding tool limits. Defaults to 50000.

.PARAMETER PageSize
    Number of records to request per API call. Max allowed by API is 5000.
    Defaults to 5000 for maximum efficiency.

.PARAMETER LogPath
    Optional. Path to write a structured JSON run log.
    Defaults to .\audit-export-run.log.json

.EXAMPLE
    # Export all audit events for the last 7 days
    .\Export-ComplianceAuditLog.ps1 `
        -StartDate (Get-Date).AddDays(-7) `
        -EndDate (Get-Date)

.EXAMPLE
    # Export specific operations for incident response
    .\Export-ComplianceAuditLog.ps1 `
        -StartDate "2024-11-01" `
        -EndDate "2024-11-30" `
        -Operations @("FileDeleted", "FileDownloaded", "SharingInvitationCreated") `
        -OutputFormat "CSV"

.EXAMPLE
    # Export Azure AD sign-in and admin operations for a specific user
    .\Export-ComplianceAuditLog.ps1 `
        -StartDate (Get-Date).AddDays(-30) `
        -RecordType "AzureActiveDirectory" `
        -UserIds @("jdoe@contoso.com") `
        -ResultOutputPath ".\audit-export\jdoe-investigation\"

.EXAMPLE
    # Export Exchange admin operations for monthly compliance review
    .\Export-ComplianceAuditLog.ps1 `
        -StartDate (Get-Date).AddMonths(-1).Date `
        -EndDate (Get-Date).Date `
        -RecordType "ExchangeAdmin" `
        -OutputFormat "Both" `
        -ResultOutputPath ".\audit-export\exchange-admin-monthly\"

.NOTES
    Author      : Neil Chavez
    Version     : 1.0.0
    Category    : Data Governance & Compliance Automation
    Folder      : powershell/data-governance/
    Script #    : 13 of 24

    Pagination  : Search-UnifiedAuditLog returns up to 5,000 records per call.
                  This script uses the SessionId + ResultIndex pattern to walk
                  through all pages until ResultCount matches retrieved records.
                  Each page request increments ResultIndex by PageSize.

    Throttling  : The UAL API throttles aggressive queries. This script implements
                  an exponential backoff strategy — on throttle detection it waits
                  progressively longer before retrying (5s, 10s, 20s, 40s max).

    AuditData   : Each UAL record contains a JSON string in the AuditData field.
                  This script parses and flattens it into the output object so
                  downstream tools (SIEM, SOAR, Splunk) can ingest without
                  additional parsing.

    Chunking    : Output is chunked at -ChunkSize records per file to avoid
                  producing single files that exceed SIEM ingest limits or
                  spreadsheet row limits for CSV review.

    Dependencies:
        Install-Module ExchangeOnlineManagement -Scope CurrentUser

    Connect before running:
        Connect-IPPSSession -UserPrincipalName admin@contoso.com
#>

[CmdletBinding()]
param (
    [Parameter(Mandatory = $true)]
    [datetime]$StartDate,

    [Parameter(Mandatory = $false)]
    [datetime]$EndDate = (Get-Date),

    [Parameter(Mandatory = $false)]
    [string[]]$Operations,

    [Parameter(Mandatory = $false)]
    [string]$RecordType,

    [Parameter(Mandatory = $false)]
    [string[]]$UserIds,

    [Parameter(Mandatory = $false)]
    [string]$ResultOutputPath = ".\audit-export",

    [Parameter(Mandatory = $false)]
    [ValidateSet("JSON", "CSV", "Both")]
    [string]$OutputFormat = "Both",

    [Parameter(Mandatory = $false)]
    [ValidateRange(1000, 50000)]
    [int]$ChunkSize = 50000,

    [Parameter(Mandatory = $false)]
    [ValidateRange(100, 5000)]
    [int]$PageSize = 5000,

    [Parameter(Mandatory = $false)]
    [string]$LogPath = ".\audit-export-run.log.json"
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

function Export-ResultChunk {
    <#
    .SYNOPSIS
        Writes a chunk of audit records to disk in the specified format(s).
        Called each time the in-memory buffer hits ChunkSize to avoid OOM on
        large exports.
    #>
    param (
        [array]$Records,
        [string]$OutputPath,
        [string]$Format,
        [int]$ChunkNumber,
        [string]$RunId
    )

    $baseName = "audit-export-$RunId-chunk$($ChunkNumber.ToString('000'))"

    if ($Format -in "JSON", "Both") {
        $jsonPath = Join-Path $OutputPath "$baseName.json"
        try {
            $Records | ConvertTo-Json -Depth 8 | Set-Content -Path $jsonPath -Encoding UTF8
            Write-Log "Chunk $ChunkNumber written (JSON): $jsonPath ($($Records.Count) records)" -Level SUCCESS
        }
        catch {
            Write-Log "Failed to write JSON chunk $ChunkNumber: $_" -Level ERROR
        }
    }

    if ($Format -in "CSV", "Both") {
        $csvPath = Join-Path $OutputPath "$baseName.csv"
        try {
            $Records | Export-Csv -Path $csvPath -NoTypeInformation -Encoding UTF8
            Write-Log "Chunk $ChunkNumber written (CSV): $csvPath ($($Records.Count) records)" -Level SUCCESS
        }
        catch {
            Write-Log "Failed to write CSV chunk $ChunkNumber: $_" -Level ERROR
        }
    }
}

#endregion

#region ── Initialization ─────────────────────────────────────────────────────

$script:LogEntries = @()
$runTimestamp      = Get-Date -Format "yyyy-MM-dd HH:mm:ss"
$runId             = Get-Date -Format "yyyyMMdd-HHmmss"

# Validate date range
if ($StartDate -gt $EndDate) {
    Write-Error "StartDate ($StartDate) cannot be after EndDate ($EndDate)."
    exit 1
}

$result = [PSCustomObject]@{
    RunId          = $runId
    StartDate      = $StartDate.ToString("yyyy-MM-dd HH:mm:ss")
    EndDate        = $EndDate.ToString("yyyy-MM-dd HH:mm:ss")
    RecordType     = $RecordType
    Operations     = $Operations -join ", "
    UserIds        = $UserIds -join ", "
    TotalRecords   = 0
    ChunksWritten  = 0
    OutputPath     = $ResultOutputPath
    OutputFormat   = $OutputFormat
    Errors         = @()
    CompletedAt    = $null
}

Write-Log "=== Export-ComplianceAuditLog START ===" -Level INFO
Write-Log "Run ID       : $runId" -Level INFO
Write-Log "Date Range   : $($StartDate.ToString('yyyy-MM-dd')) → $($EndDate.ToString('yyyy-MM-dd'))" -Level INFO
Write-Log "RecordType   : $(if ($RecordType) { $RecordType } else { 'All' })" -Level INFO
Write-Log "Operations   : $(if ($Operations) { $Operations -join ', ' } else { 'All' })" -Level INFO
Write-Log "User Scope   : $(if ($UserIds) { $UserIds -join ', ' } else { 'All users' })" -Level INFO
Write-Log "Page Size    : $PageSize | Chunk Size: $ChunkSize" -Level INFO
Write-Log "Output Format: $OutputFormat" -Level INFO

#endregion

#region ── Step 0: Pre-flight Validation ──────────────────────────────────────

Write-Log "--- Step 0: Pre-flight Validation ---" -Level INFO

try {
    # Verify compliance session with a lightweight probe query
    $probe = Search-UnifiedAuditLog -StartDate (Get-Date).AddMinutes(-5) `
                                    -EndDate (Get-Date) `
                                    -ResultSize 1 `
                                    -ErrorAction Stop
    Write-Log "Security & Compliance (IPPS) session confirmed." -Level INFO
}
catch {
    Write-Log "No active IPPS session or Unified Audit Log access denied." -Level ERROR
    Write-Log "Run: Connect-IPPSSession -UserPrincipalName admin@contoso.com" -Level ERROR
    Write-Log "Also verify: Unified Audit Log is enabled in the compliance portal." -Level ERROR
    exit 1
}

# Create output directory
if (-not (Test-Path $ResultOutputPath)) {
    try {
        New-Item -ItemType Directory -Path $ResultOutputPath -Force | Out-Null
        Write-Log "Output directory created: $ResultOutputPath" -Level INFO
    }
    catch {
        Write-Log "Failed to create output directory: $_" -Level ERROR
        exit 1
    }
}

#endregion

#region ── Step 1: Build Query Parameters ─────────────────────────────────────

Write-Log "--- Step 1: Building Query Parameters ---" -Level INFO

# Base query parameters — date range is always required
$queryParams = @{
    StartDate  = $StartDate
    EndDate    = $EndDate
    ResultSize = $PageSize
}

# Apply optional filters — only add if specified to keep query efficient
if ($RecordType)  { $queryParams["RecordType"]  = $RecordType  }
if ($Operations)  { $queryParams["Operations"]  = $Operations  }
if ($UserIds)     { $queryParams["UserIds"]     = $UserIds     }

Write-Log "Query parameters configured." -Level INFO

#endregion

#region ── Step 2: Paginated Audit Log Extraction ─────────────────────────────

Write-Log "--- Step 2: Executing Paginated Audit Query ---" -Level INFO

# UAL pagination uses a SessionId (consistent per query) + ResultIndex (page offset)
# Each call returns up to PageSize records starting at ResultIndex
$sessionId     = [System.Guid]::NewGuid().ToString()
$resultIndex   = 1
$totalRetrieved = 0
$chunkBuffer   = @()
$chunkNumber   = 1

# Throttle backoff settings
$maxRetries    = 4
$backoffSeconds = 5

Write-Log "Session ID: $sessionId" -Level INFO
Write-Log "Starting paginated extraction..." -Level INFO

do {
    $queryParams["SessionId"]    = $sessionId
    $queryParams["ResultIndex"]  = $resultIndex
    $queryParams["SessionCommand"] = "ReturnLargeSet"

    $pageRecords   = $null
    $retryCount    = 0
    $success       = $false

    # Retry loop with exponential backoff for throttle handling
    while (-not $success -and $retryCount -le $maxRetries) {
        try {
            $pageRecords = Search-UnifiedAuditLog @queryParams -ErrorAction Stop
            $success     = $true
        }
        catch {
            if ($_.Exception.Message -match "throttl|429|too many") {
                $waitTime = $backoffSeconds * [math]::Pow(2, $retryCount)
                Write-Log "API throttle detected. Waiting $waitTime seconds before retry $($retryCount + 1)/$maxRetries..." -Level WARN
                Start-Sleep -Seconds $waitTime
                $retryCount++
            }
            else {
                Write-Log "Audit query failed (non-throttle): $_" -Level ERROR
                $result.Errors += "Query error at ResultIndex $resultIndex`: $_"
                break
            }
        }
    }

    if (-not $success -or -not $pageRecords) {
        Write-Log "No more records returned or query failed. Ending pagination." -Level INFO
        break
    }

    Write-Log "Page retrieved: $($pageRecords.Count) record(s) | Total so far: $($totalRetrieved + $pageRecords.Count)" -Level INFO

    # Process each record — flatten the AuditData JSON payload
    foreach ($record in $pageRecords) {
        $auditDataParsed = $null
        try {
            $auditDataParsed = $record.AuditData | ConvertFrom-Json -ErrorAction SilentlyContinue
        }
        catch { <# AuditData may be malformed in rare cases — leave null #> }

        $flatRecord = [PSCustomObject]@{
            RunId           = $runId
            CreationDate    = $record.CreationDate
            UserIds         = $record.UserIds
            Operations      = $record.Operations
            RecordType      = $record.RecordType
            ResultIndex     = $record.ResultIndex
            # Flattened AuditData fields — most common operational fields
            ClientIP        = $auditDataParsed?.ClientIP
            ObjectId        = $auditDataParsed?.ObjectId
            Workload        = $auditDataParsed?.Workload
            SiteUrl         = $auditDataParsed?.SiteUrl
            SourceFileName  = $auditDataParsed?.SourceFileName
            ItemType        = $auditDataParsed?.ItemType
            TargetUserOrGroupName = $auditDataParsed?.TargetUserOrGroupName
            ModifiedProperties = ($auditDataParsed?.ModifiedProperties | ConvertTo-Json -Compress -ErrorAction SilentlyContinue)
            # Raw AuditData preserved for SIEM ingestion
            AuditDataRaw    = $record.AuditData
        }

        $chunkBuffer += $flatRecord
        $totalRetrieved++

        # Flush chunk to disk when buffer hits ChunkSize
        if ($chunkBuffer.Count -ge $ChunkSize) {
            Export-ResultChunk -Records $chunkBuffer `
                               -OutputPath $ResultOutputPath `
                               -Format $OutputFormat `
                               -ChunkNumber $chunkNumber `
                               -RunId $runId
            $result.ChunksWritten++
            $chunkNumber++
            $chunkBuffer = @()
        }
    }

    $resultIndex += $PageSize

    # Exit condition: fewer records returned than requested = last page
} while ($pageRecords.Count -eq $PageSize)

#endregion

#region ── Step 3: Flush Final Chunk ──────────────────────────────────────────

Write-Log "--- Step 3: Writing Final Chunk ---" -Level INFO

if ($chunkBuffer.Count -gt 0) {
    Export-ResultChunk -Records $chunkBuffer `
                       -OutputPath $ResultOutputPath `
                       -Format $OutputFormat `
                       -ChunkNumber $chunkNumber `
                       -RunId $runId
    $result.ChunksWritten++
}
else {
    Write-Log "No remaining records in buffer." -Level INFO
}

#endregion

#region ── Step 4: Output & Logging ───────────────────────────────────────────

$result.TotalRecords = $totalRetrieved
$result.CompletedAt  = (Get-Date -Format "yyyy-MM-dd HH:mm:ss")

Write-Log "=== Export-ComplianceAuditLog COMPLETE ===" -Level SUCCESS
Write-Log "Total Records Retrieved : $totalRetrieved" -Level SUCCESS
Write-Log "Output Chunks Written   : $($result.ChunksWritten)" -Level SUCCESS
Write-Log "Output Path             : $ResultOutputPath" -Level SUCCESS

if ($totalRetrieved -eq 0) {
    Write-Log "No records matched the query. Verify date range and filter parameters." -Level WARN
}

if ($result.Errors.Count -gt 0) {
    Write-Log "Completed with $($result.Errors.Count) error(s). Review output object." -Level WARN
}

# Write run summary manifest alongside the chunk files
$manifest = [PSCustomObject]@{
    RunId        = $runId
    ExportedAt   = $runTimestamp
    CompletedAt  = $result.CompletedAt
    QueryParams  = [PSCustomObject]@{
        StartDate  = $result.StartDate
        EndDate    = $result.EndDate
        RecordType = $result.RecordType
        Operations = $result.Operations
        UserIds    = $result.UserIds
    }
    TotalRecords  = $totalRetrieved
    ChunksWritten = $result.ChunksWritten
    OutputFormat  = $OutputFormat
    Errors        = $result.Errors
}

$manifestPath = Join-Path $ResultOutputPath "export-manifest-$runId.json"
try {
    $manifest | ConvertTo-Json -Depth 5 | Set-Content -Path $manifestPath -Encoding UTF8
    Write-Log "Export manifest written: $manifestPath" -Level INFO
}
catch {
    Write-Log "Could not write manifest: $_" -Level WARN
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
    Write-Log "Could not write log file: $_" -Level WARN
}

return $result

#endregion
