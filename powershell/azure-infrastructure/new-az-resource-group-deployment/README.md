# New-AzResourceGroupDeployment.ps1

## Overview
Wraps Azure ARM/Bicep template deployments in an opinionated, auditable shell. Enforces mandatory resource tagging, runs a validation check before deploying, and outputs structured results for CI/CD pipeline use. Rather than calling the Azure deployment cmdlet directly, this script adds the guardrails a production environment needs.

## What this script does

1. **Pre-checks** — verifies an active Azure session and switches subscription context if specified
2. **Resource group** — checks if the target resource group exists, creates it if not
3. **Mandatory tags** — applies Environment, Owner, CostCenter, and ManagedBy tags to the resource group before deploying
4. **Template validation** — runs a pre-deployment check against the template and parameters, exits immediately if validation fails
5. **Deployment** — executes the ARM/Bicep deployment with a timestamped name for traceability
6. **Output** — captures deployment outputs and writes a structured log entry for audit trail
7. **WhatIf support** — validates the template and previews what would deploy without touching anything

## Problem solved
Ad-hoc resource deployments bypassed tagging standards and had no pre-deployment validation, making it easy to push broken templates or untagged resources into production. This script wraps every deployment in the same opinionated process — consistent tagging, pre-flight validation, and a clean audit trail every time.

## Usage

```powershell
# Deploy a storage account template
.\New-AzResourceGroupDeployment.ps1 `
    -ResourceGroupName "rg-platform-dev" `
    -Location "eastus" `
    -TemplateFile ".\templates\storage-account.bicep" `
    -TemplateParameterFile ".\templates\storage-account.dev.parameters.json" `
    -Environment "dev" `
    -Owner "platform-engineering" `
    -CostCenter "CC-1234"

# Deploy with inline parameters
.\New-AzResourceGroupDeployment.ps1 `
    -ResourceGroupName "rg-platform-prod" `
    -Location "eastus" `
    -TemplateFile ".\templates\vnet.bicep" `
    -TemplateParameters @{ vnetName = "vnet-prod-eus"; addressPrefix = "10.0.0.0/16" } `
    -Environment "prod" `
    -Owner "platform-engineering" `
    -CostCenter "CC-5678"

# Dry run — validate and preview without deploying
.\New-AzResourceGroupDeployment.ps1 `
    -ResourceGroupName "rg-platform-staging" `
    -Location "eastus" `
    -TemplateFile ".\templates\app-service.bicep" `
    -TemplateParameterFile ".\templates\app-service.staging.parameters.json" `
    -Environment "staging" `
    -Owner "platform-engineering" `
    -CostCenter "CC-1234" `
    -WhatIf
```

## Requirements
- Az PowerShell module (Az.Resources, Az.Accounts)
- Active Azure session: `Connect-AzAccount`
- Contributor or Owner role on the target resource group

## Note on pipeline exit codes
Exits 0 on success, 1 on pre-flight validation failure, 2 on deployment runtime failure — so CI/CD pipelines can tell the difference between a bad template and a deployment error.

## Part of the Azure Infrastructure Automation category
Script 21 of 24 in the PowerShell Infrastructure Library.

## File
[New-AzResourceGroupDeployment.ps1](./New-AzResourceGroupDeployment.ps1)