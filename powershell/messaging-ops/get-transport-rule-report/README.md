# Get-TransportRuleReport.ps1

## Overview
Exports all Exchange Online transport rules with their full configuration — 
conditions, exceptions, actions, and priority order — into a structured 
report for documentation, security review, and compliance auditing. 
Automatically flags rules that represent elevated risk.

## What this script does

- Retrieves all transport rules sorted by priority
- Evaluates each rule against a set of risk conditions
- Documents conditions, exceptions, and actions per rule
- Outputs a structured JSON report with optional CSV export

## Flagged conditions

| Flag | Risk |
|------|------|
| Rule is disabled | Dead config — remove or document |
| No description or comments | No owner or business justification recorded |
| SCL set to -1 | Bypasses all spam filtering |
| BCC or redirect to external address | Potential data exfiltration indicator |
| Forwards or copies to external recipient | Potential data exfiltration indicator |
| Modifies subject or headers | Data handling risk |

## Why this script exists
Transport rules accumulate over years and frequently lose their original 
owners and business justification. Auditors regularly require a current-state 
inventory. This script produces a complete, documented rule inventory on 
demand — and surfaces the rules that most warrant a security review.

## Key features

- **-FlaggedOnly flag** — output only rules that triggered a risk flag
- **-ExportCsv flag** — flat CSV for compliance team sharing
- **Priority ordering** — rules output in enforcement order
- **Structured documentation** — captures all conditions, exceptions, and actions

## Requirements

Connect before running:

Connect-ExchangeOnline -UserPrincipalName admin@contoso.com

Required role: View-Only Organization Management or Exchange Administrator

## Usage

**Full export:**

.\Get-TransportRuleReport.ps1 -ExportCsv

**Flagged rules only:**

.\Get-TransportRuleReport.ps1 -FlaggedOnly -ExportCsv

## Part of the Messaging Infrastructure Ops category
Script 10 of 24 in the PowerShell Infrastructure Library.

## File
[Get-TransportRuleReport.ps1](./Get-TransportRuleReport.ps1)