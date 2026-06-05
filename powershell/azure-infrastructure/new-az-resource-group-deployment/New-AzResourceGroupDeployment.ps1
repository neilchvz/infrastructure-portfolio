<#
.SYNOPSIS
    Orchestrates Azure resource group and resource deployments via ARM/Bicep templates
    using parameterized inputs. Handles pre-flight validation, mandatory resource
    tagging, and structured deployment output for CI/CD pipeline integration.

.DESCRIPTION
    New-AzResourceGroupDeployment.ps1 wraps ARM/Bicep template deployments in an
    opinionated, auditable shell. Rather than calling New-AzResourceGroupDeployment
    directly, this script enforces pre-deployment validation, mandatory tagging
    standards, and structured output — making it suitable as the deployment step
    in a CI/CD pipeline without additional wrapper logic.

    It performs the following steps:
        1. Validates the active Azure session and target subscription context.
        2. Ensures the target resource group exists — creates it if not.
        3. Enforces mandatory tags (Environment, Owner, CostCenter, ManagedBy)
           on the resource group before deployment.
        4. Runs Test-AzResourceGroupDeployment (pre-flight validation) against
           the template and parameters — exits non-zero on validation failure.
        5. Executes the deployment with a timestamped deployment name.
        6. Waits for completion and retrieves structured deployment output.
        7. Writes a deployment record to the log for audit trail.

    REQUIREMENTS:
        - Az PowerShell module (Az.Resources, Az.Accounts)
        - Connect-AzAccount with appropriate permissions
        - Contributor or Owner role on the target resource group (or subscription
          for resource group creation)

.PARAMETER ResourceGroupName
    Name of the target Azure resource group. Created if it does not exist.

.PARAMETER Location
    Azure region for the resource group (if creation is needed).
    Example: "eastus", "westus2", "centralus"
    Ignored if the resource group already exists.

.PARAMETER TemplateFile
    Path to the ARM JSON or Bicep template file to deploy.
    Bicep files are compiled automatically by the Az module if Bicep CLI is installed.

.PARAMETER TemplateParameterFile
    Optional. Path to a parameters file (.json or .bicepparam) for the template.
    Use either -TemplateParameterFile or -TemplateParameters, not both.

.PARAMETER TemplateParameters
    Optional. Hashtable of parameter name/value pairs passed directly to the template.
    Example: @{ storageAccountName = "mystorageacct"; sku = "Standard_LRS" }

.PARAMETER SubscriptionId
    Optional. The Azure subscription ID to target. If omitted, the current
    Az context subscription is used.

.PARAMETER Environment
    Mandatory tag — the environment this deployment targets.
    Accepted values: dev, staging, prod

.PARAMETER Owner
    Mandatory tag — the team or individual responsible for this deployment.
    Example: "platform-engineering" or "neil.chavez@contoso.com"

.PARAMETER CostCenter
    Mandatory tag — the cost center code for billing attribution.
    Example: "CC-1234"

.PARAMETER DeploymentMode
    ARM deployment mode. Incremental adds/updates resources without removing
    existing ones. Complete removes any resources in the group not in the template.
    Default: Incremental (safer for most deployments).

.PARAMETER WhatIf
    Runs the script in simulation mode. Executes pre-flight validation but does
    not apply the deployment. Outputs what would be created/modified.

.PARAMETER LogPath
    Optional. Path to write a structured JSON deployment log.
    Defaults to .\az-deployment.log.json

.EXAMPLE
    # Deploy a storage account template to a dev resource group
    .\New-AzResourceGroupDeployment.ps1 `
        -ResourceGroupName "rg-platform-dev" `
        -Location "eastus" `
        -TemplateFile ".\templates\storage-account.bicep" `
        -TemplateParameterFile ".\templates\storage-account.dev.parameters.json" `
        -Environment "dev" `
        -Owner "platform-engineering" `
        -CostCenter "CC-1234"

.EXAMPLE
    # Deploy with inline parameters
    .\New-AzResourceGroupDeployment.ps1 `
        -ResourceGroupName "rg-platform-prod" `
        -Location "eastus" `
        -TemplateFile ".\templates\vnet.bicep" `
        -TemplateParameters @{ vnetName = "vnet-prod-eus"; addressPrefix = "10.0.0.0/16" } `
        -Environment "prod" `
        -Owner "platform-engineering" `
        -CostCenter "CC-5678" `
        -DeploymentMode "Incremental"

.EXAMPLE
    # Dry run — validate template and show what would deploy
    .\New-AzResourceGroupDeployment.ps1 `
        -ResourceGroupName "rg-platform-staging" `
        -Location "eastus" `
        -TemplateFile ".\templates\app-service.bicep" `
        -TemplateParameterFile ".\templates\app-service.staging.parameters.json" `
        -Environment "staging" `
        -Owner "platform-engineering" `
        -CostCenter "CC-1234" `
        -WhatIf

.NOTES
    Author      : Neil Chavez
    Version     : 1.0.0
    Category    : Azure Infrastructure Automation
    Folder      : powershell/azure-infrastructure/
    Script #    : 21 of 24

    Tagging     : Tags are applied to the resource group. Individual resources
                  within the template should also carry these tags — enforce this
                  via Azure Policy (see Invoke-AzPolicyComplianceScan.ps1, Script 23).

    Deployment Name:
                  Each deployment is named with a timestamp suffix to ensure
                  uniqueness and traceability:
                  Format: deploy-<ResourceGroupName>-<yyyyMMdd-HHmmss>

    Pipeline Use: This script exits with code 0 on success, 1 on pre-flight
                  failure, and 2 on deployment failure — allowing CI/CD pipelines
                  to distinguish between validation and runtime failures.

    Dependencies:
        Install-Module Az -Scope CurrentUser

    Connect before running:
        Connect-AzAccount
        Set-AzContext -SubscriptionId "<subscription-id>"
#>

[CmdletBinding(SupportsShouldProcess = $true)]
param (
    [Parameter(Mandatory = $true)]
    [ValidateNotNullOrEmpty()]
    [string]$ResourceGroupName,

    [Parameter(Mandatory = $true)]
    [ValidateNotNullOrEmpty()]
    [string]$Location,

    [Parameter(Mandatory = $true)]
    [ValidateScript({ Test-Path $_ -PathType Leaf })]
    [string]$TemplateFile,

    [Parameter(Mandatory = $false)]
    [ValidateScript({ -not $_ -or (Test-Path $_ -PathType Leaf) })]
    [string]$TemplateParameterFile,

    [Parameter(Mandatory = $false)]
    [hashtable]$TemplateParameters,

    [Parameter(Mandatory = $false)]
    [string]$SubscriptionId,

    [Parameter(Mandatory = $true)]
    [ValidateSet("dev", "staging", "prod")]
    [string]$Environment,

    [Parameter(Mandatory = $true)]
    [ValidateNotNullOrEmpty()]
    [string]$Owner,

    [Parameter(Mandatory = $true)]
    [ValidateNotNullOrEmpty()]
    [string]$CostCenter,

    [Parameter(Mandatory = $false)]
    [ValidateSet("Incremental", "Complete")]
    [string]$DeploymentMode = "Incremental",

    [Parameter(Mandatory = $false)]
    [string]$LogPath = ".\az-deployment.log.json"
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

#endregion

#region ── Initialization ─────────────────────────────────────────────────────

$script:LogEntries = @()
$runTimestamp      = Get-Date -Format "yyyy-MM-dd HH:mm:ss"
$runId             = Get-Date -Format "yyyyMMdd-HHmmss"
$deploymentName    = "deploy-$ResourceGroupName-$runId"

$result = [PSCustomObject]@{
    RunId              = $runId
    DeploymentName     = $deploymentName
    ResourceGroupName  = $ResourceGroupName
    TemplateFile       = $TemplateFile
    Environment        = $Environment
    Owner              = $Owner
    CostCenter         = $CostCenter
    DeploymentMode     = $DeploymentMode
    PreFlightPassed    = $false
    DeploymentStatus   = $null
    DeploymentOutputs  = $null
    WhatIfMode         = $WhatIfPreference.ToString()
    CompletedAt        = $null
    Errors             = @()
}

# Mandatory tags applied to the resource group
$mandatoryTags = @{
    Environment = $Environment
    Owner       = $Owner
    CostCenter  = $CostCenter
    ManagedBy   = "PowerShell-IaC"
    DeployedAt  = $runTimestamp
}

Write-Log "=== New-AzResourceGroupDeployment START ===" -Level INFO
Write-Log "Run ID          : $runId" -Level INFO
Write-Log "Deployment Name : $deploymentName" -Level INFO
Write-Log "Resource Group  : $ResourceGroupName" -Level INFO
Write-Log "Template        : $TemplateFile" -Level INFO
Write-Log "Environment     : $Environment" -Level INFO
Write-Log "Mode            : $DeploymentMode" -Level INFO
Write-Log "WhatIf          : $($WhatIfPreference)" -Level INFO

#endregion

#region ── Step 0: Pre-flight — Az Session and Subscription ───────────────────

Write-Log "--- Step 0: Pre-flight Validation ---" -Level INFO

try {
    $context = Get-AzContext -ErrorAction Stop
    if (-not $context) {
        Write-Log "No active Azure session. Run Connect-AzAccount first." -Level ERROR
        exit 1
    }
    Write-Log "Azure session active. Account: $($context.Account) | Subscription: $($context.Subscription.Name)" -Level INFO
}
catch {
    Write-Log "Failed to retrieve Azure context: $_" -Level ERROR
    exit 1
}

# Switch subscription context if specified
if ($SubscriptionId) {
    try {
        Set-AzContext -SubscriptionId $SubscriptionId -ErrorAction Stop | Out-Null
        Write-Log "Switched to subscription: $SubscriptionId" -Level INFO
    }
    catch {
        Write-Log "Failed to set subscription context '$SubscriptionId': $_" -Level ERROR
        exit 1
    }
}

# Validate that only one parameter input method is used
if ($TemplateParameterFile -and $TemplateParameters) {
    Write-Log "Use either -TemplateParameterFile or -TemplateParameters, not both." -Level ERROR
    exit 1
}

#endregion

#region ── Step 1: Ensure Resource Group Exists ───────────────────────────────

Write-Log "--- Step 1: Resource Group ---" -Level INFO

$rg = Get-AzResourceGroup -Name $ResourceGroupName -ErrorAction SilentlyContinue

if ($rg) {
    Write-Log "Resource group '$ResourceGroupName' exists. Location: $($rg.Location)" -Level INFO
}
else {
    if ($PSCmdlet.ShouldProcess($ResourceGroupName, "Create resource group in '$Location'")) {
        try {
            $rg = New-AzResourceGroup -Name $ResourceGroupName -Location $Location -Tag $mandatoryTags -ErrorAction Stop
            Write-Log "Resource group '$ResourceGroupName' created in '$Location'." -Level SUCCESS
        }
        catch {
            Write-Log "Failed to create resource group '$ResourceGroupName': $_" -Level ERROR
            exit 1
        }
    }
    else {
        Write-Log "[WhatIf] Would create resource group: $ResourceGroupName in $Location" -Level INFO
    }
}

#endregion

#region ── Step 2: Apply Mandatory Tags ───────────────────────────────────────

Write-Log "--- Step 2: Apply Mandatory Tags ---" -Level INFO

if ($PSCmdlet.ShouldProcess($ResourceGroupName, "Apply mandatory tags")) {
    try {
        # Merge mandatory tags with any existing tags — don't overwrite custom tags
        $existingTags = $rg.Tags ?? @{}
        $mergedTags   = $existingTags + $mandatoryTags  # mandatory tags win on conflict

        Update-AzTag -ResourceId $rg.ResourceId -Tag $mergedTags -Operation Merge -ErrorAction Stop | Out-Null
        Write-Log "Mandatory tags applied: Environment=$Environment | Owner=$Owner | CostCenter=$CostCenter" -Level SUCCESS
    }
    catch {
        Write-Log "Failed to apply tags to resource group: $_" -Level WARN
        # Non-fatal — deployment proceeds but tag enforcement should be reviewed
    }
}
else {
    Write-Log "[WhatIf] Would apply tags: $($mandatoryTags | ConvertTo-Json -Compress)" -Level INFO
}

#endregion

#region ── Step 3: Pre-flight Template Validation ─────────────────────────────

Write-Log "--- Step 3: Template Pre-flight Validation ---" -Level INFO

# Build the validation parameter set
$validationParams = @{
    ResourceGroupName = $ResourceGroupName
    TemplateFile      = $TemplateFile
    Mode              = $DeploymentMode
}

if ($TemplateParameterFile) { $validationParams["TemplateParameterFile"] = $TemplateParameterFile }
if ($TemplateParameters)    { $validationParams["TemplateParameterObject"] = $TemplateParameters }

Write-Log "Running Test-AzResourceGroupDeployment..." -Level INFO

try {
    $validationResult = Test-AzResourceGroupDeployment @validationParams -ErrorAction Stop

    if ($validationResult) {
        # Validation returned errors
        Write-Log "Pre-flight validation FAILED. Deployment will not proceed." -Level ERROR
        foreach ($err in $validationResult) {
            Write-Log "  Validation error: $($err.Message)" -Level ERROR
            $result.Errors += $err.Message
        }
        $result.CompletedAt = (Get-Date -Format "yyyy-MM-dd HH:mm:ss")
        $result | ConvertTo-Json -Depth 5 | Add-Content -Path $LogPath -Encoding UTF8
        exit 1  # Exit code 1 = pre-flight failure
    }
    else {
        $result.PreFlightPassed = $true
        Write-Log "Pre-flight validation PASSED. Template is valid." -Level SUCCESS
    }
}
catch {
    Write-Log "Pre-flight validation threw an exception: $_" -Level ERROR
    $result.Errors += $_
    exit 1
}

#endregion

#region ── Step 4: Execute Deployment ─────────────────────────────────────────

Write-Log "--- Step 4: Execute Deployment ---" -Level INFO

# Build deployment parameter set
$deploymentParams = @{
    Name              = $deploymentName
    ResourceGroupName = $ResourceGroupName
    TemplateFile      = $TemplateFile
    Mode              = $DeploymentMode
}

if ($TemplateParameterFile) { $deploymentParams["TemplateParameterFile"]   = $TemplateParameterFile }
if ($TemplateParameters)    { $deploymentParams["TemplateParameterObject"] = $TemplateParameters }

if ($PSCmdlet.ShouldProcess($ResourceGroupName, "Deploy template: $TemplateFile")) {
    try {
        Write-Log "Starting deployment '$deploymentName'..." -Level INFO

        $deployment = New-AzResourceGroupDeployment @deploymentParams `
                                                    -ErrorAction Stop `
                                                    -Verbose:$false

        $result.DeploymentStatus  = $deployment.ProvisioningState
        $result.DeploymentOutputs = $deployment.Outputs

        if ($deployment.ProvisioningState -eq "Succeeded") {
            Write-Log "Deployment '$deploymentName' completed successfully." -Level SUCCESS
            Write-Log "Provisioning state: $($deployment.ProvisioningState)" -Level SUCCESS

            if ($deployment.Outputs -and $deployment.Outputs.Count -gt 0) {
                Write-Log "Deployment outputs:" -Level INFO
                foreach ($key in $deployment.Outputs.Keys) {
                    Write-Log "  $key = $($deployment.Outputs[$key].Value)" -Level INFO
                }
            }
        }
        else {
            Write-Log "Deployment completed with state: $($deployment.ProvisioningState)" -Level WARN
            $result.Errors += "Deployment state: $($deployment.ProvisioningState)"
        }
    }
    catch {
        $errMsg = "Deployment failed: $_"
        Write-Log $errMsg -Level ERROR
        $result.Errors    += $errMsg
        $result.DeploymentStatus = "Failed"
        $result.CompletedAt = (Get-Date -Format "yyyy-MM-dd HH:mm:ss")
        $result | ConvertTo-Json -Depth 5 | Add-Content -Path $LogPath -Encoding UTF8
        exit 2  # Exit code 2 = deployment runtime failure
    }
}
else {
    Write-Log "[WhatIf] Would execute deployment: $deploymentName" -Level INFO
    Write-Log "[WhatIf] Template: $TemplateFile | Mode: $DeploymentMode" -Level INFO
    $result.DeploymentStatus = "WhatIf"
}

#endregion

#region ── Step 5: Output & Logging ───────────────────────────────────────────

$result.CompletedAt = (Get-Date -Format "yyyy-MM-dd HH:mm:ss")

Write-Log "=== New-AzResourceGroupDeployment COMPLETE ===" -Level SUCCESS
Write-Log "Deployment Name  : $($result.DeploymentName)" -Level SUCCESS
Write-Log "Resource Group   : $($result.ResourceGroupName)" -Level SUCCESS
Write-Log "Status           : $($result.DeploymentStatus)" -Level SUCCESS
Write-Log "Pre-flight Passed: $($result.PreFlightPassed)" -Level SUCCESS

if ($result.Errors.Count -gt 0) {
    Write-Log "Completed with $($result.Errors.Count) error(s)." -Level WARN
}

$logEntry = [PSCustomObject]@{
    RunAt      = $runTimestamp
    Result     = $result
    LogEntries = $script:LogEntries
}

try {
    $logEntry | ConvertTo-Json -Depth 8 | Add-Content -Path $LogPath -Encoding UTF8
    Write-Log "Log written to: $LogPath" -Level INFO
}
catch {
    Write-Log "Could not write log file: $_" -Level WARN
}

return $result

#endregion
