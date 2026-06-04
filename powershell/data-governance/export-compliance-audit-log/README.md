# Export-ComplianceAuditLog.ps1

## Overview
Queries the Microsoft Purview Unified Audit Log at scale with configurable operation filters, date ranges, and user scopes. Handles pagination and API rate-limiting automatically. Outputs structured JSON or CSV for SIEM ingestion or compliance reporting — bypassing the 5,000-record UI limitation entirely.

## What this script does

1. **Pre-flight validation** — verifies active Security & Compliance session
2. **Query construction** — builds the audit query from specified parameters (date range, operations, record type, user scope)
3. **Paginated extraction** — uses the SessionId + ResultIndex pattern to walk all pages until all matching records are retrieved
4. **Throttle handling** — exponential backoff on API throttle responses (5s → 10s → 20s → 40s)
5. **AuditData flattening** — parses the nested JSON payload in each record into structured output fields for direct SIEM ingestion
6. **Chunked output** — writes results in configurable chunks to avoid single files exceeding SIEM ingest or spreadsheet limits
7. **Export manifest** — writes a run summary JSON alongside the chunk files for pipeline traceability

## Problem solved
The Purview compliance portal UI caps exports at 5,000 records and times out on large queries. Incident response and periodic compliance reviews required full-volume extraction. This script handles it reliably and outputs data ready for Splunk, Sentinel, or any SIEM without additional parsing.

## Usage

```powershell
# Export all audit events for the last 7 days
.\Export-ComplianceAuditLog.ps1 `
    -StartDate (Get-Date).AddDays(-7) `
    -EndDate (Get-Date)

# Incident response — specific operations over a date range
.\Export-ComplianceAuditLog.ps1 `
    -StartDate "2024-11-01" `
    -EndDate "2024-11-30" `
    -Operations @("FileDeleted", "FileDownloaded", "SharingInvitationCreated") `
    -OutputFormat "CSV"

# Scope to a specific user
.\Export-ComplianceAuditLog.ps1 `
    -StartDate (Get-Date).AddDays(-30) `
    -RecordType "AzureActiveDirectory" `
    -UserIds @("jdoe@org.com") `
    -ResultOutputPath ".\audit-export\jdoe-investigation\"
```

## Requirements
- `ExchangeOnlineManagement` module
- Active IPPS session: `Connect-IPPSSession -UserPrincipalName admin@org.com`
- Unified Audit Log enabled in the tenant
- View-Only Audit Logs or Audit Logs role in the Purview compliance portal

## Compliance mapping
- NIST 800-53 AU-2 (Event Logging)
- NIST 800-53 AU-6 (Audit Review, Analysis, and Reporting)
- SOC 2 CC7.2 (Monitoring)

## Part of the Identity Lifecycle Automation category
Script 13 of 24 in the PowerShell Infrastructure Library.

## File
[Export-ComplianceAuditLog.ps1](./Export-ComplianceAuditLog.ps1)