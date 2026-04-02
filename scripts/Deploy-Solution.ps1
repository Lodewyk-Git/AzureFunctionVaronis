[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)]
    [string]$ResourceGroupName,

    [Parameter(Mandatory = $true)]
    [string]$Location,

    [Parameter(Mandatory = $true)]
    [string]$EnvironmentName,

    [string]$NamePrefix = "varonis",

    [string]$OwnerEmail = "Lood@buisecops.co.za",

    [string]$WorkspaceResourceId = "",

    [string]$AppInsightsWorkspaceResourceId = "",

    [string]$TableName = "VaronisAlerts_CL",

    [string]$StreamName = "",

    [string]$TimerSchedule = "0 */5 * * * *",

    [string]$VaronisBaseUrl = "",

    [SecureString]$VaronisApiKey,

    [string]$VaronisApiKeySecretName = "VaronisApiKey",

    [string]$PackagePath = "",

    [string]$PackageVersion = "",

    [ValidateSet("RunFromPackageUrl", "ZipDeploy")]
    [string]$PackageDeploymentMode = "ZipDeploy",

    [switch]$SkipPackageBuild,

    [switch]$SkipPackagePublish,

    [switch]$RunValidation,

    [string]$SubscriptionId = ""
)

$ErrorActionPreference = "Stop"

function Get-OutputValue {
    param(
        [Parameter(Mandatory = $true)] [object]$Outputs,
        [Parameter(Mandatory = $true)] [string]$Name
    )

    if ($null -eq $Outputs.$Name) {
        throw "Deployment output '$Name' was not found."
    }

    return $Outputs.$Name.value
}

function Test-SentinelEnabledWorkspace {
    param([Parameter(Mandatory = $true)][string]$WorkspaceResourceIdToCheck)

    $onboardingResourceId = "$WorkspaceResourceIdToCheck/providers/Microsoft.SecurityInsights/onboardingStates/default"
    try {
        az resource show `
            --ids $onboardingResourceId `
            --api-version 2024-03-01 `
            --only-show-errors `
            --output none 2>$null | Out-Null

        return ($LASTEXITCODE -eq 0)
    }
    catch {
        return $false
    }
}

function Resolve-SentinelWorkspaceResourceId {
    param(
        [Parameter(Mandatory = $true)][string]$ResourceGroupToSearch,
        [string]$ProvidedWorkspaceResourceId
    )

    if (-not [string]::IsNullOrWhiteSpace($ProvidedWorkspaceResourceId)) {
        if (-not (Test-SentinelEnabledWorkspace -WorkspaceResourceIdToCheck $ProvidedWorkspaceResourceId)) {
            throw "Provided workspace '$ProvidedWorkspaceResourceId' is not Sentinel-enabled."
        }

        return $ProvidedWorkspaceResourceId
    }

    $workspaceIds = az resource list `
        --resource-group $ResourceGroupToSearch `
        --resource-type Microsoft.OperationalInsights/workspaces `
        --query "[].id" `
        --output tsv `
        --only-show-errors

    if ($LASTEXITCODE -ne 0) {
        throw "Failed to list Log Analytics workspaces in resource group '$ResourceGroupToSearch'."
    }

    $sentinelWorkspaceIds = @()
    foreach ($workspaceId in ($workspaceIds -split "`n")) {
        if ([string]::IsNullOrWhiteSpace($workspaceId)) {
            continue
        }

        if (Test-SentinelEnabledWorkspace -WorkspaceResourceIdToCheck $workspaceId) {
            $sentinelWorkspaceIds += $workspaceId
        }
    }

    if ($sentinelWorkspaceIds.Count -eq 1) {
        return $sentinelWorkspaceIds[0]
    }

    if ($sentinelWorkspaceIds.Count -gt 1) {
        throw "Multiple Sentinel-enabled workspaces found. Re-run with -WorkspaceResourceId and choose one: $($sentinelWorkspaceIds -join ', ')"
    }

    throw "No Sentinel-enabled workspace found in '$ResourceGroupToSearch'. Provide -WorkspaceResourceId."
}

if (-not [string]::IsNullOrWhiteSpace($SubscriptionId)) {
    az account set --subscription $SubscriptionId | Out-Null
}

if ([string]::IsNullOrWhiteSpace($StreamName)) {
    $StreamName = "Custom-$TableName"
}

$WorkspaceResourceId = Resolve-SentinelWorkspaceResourceId `
    -ResourceGroupToSearch $ResourceGroupName `
    -ProvidedWorkspaceResourceId $WorkspaceResourceId

$repoRoot = Resolve-Path (Join-Path $PSScriptRoot "..")
$coreTemplate = Join-Path $repoRoot "infra/modules/core.bicep"
$monitoringTemplate = Join-Path $repoRoot "infra/modules/monitoring.bicep"
$tableLifecycleScript = Join-Path $PSScriptRoot "Invoke-TableLifecycle.ps1"
$buildPackageScript = Join-Path $PSScriptRoot "Build-Package.ps1"
$publishPackageScript = Join-Path $PSScriptRoot "Publish-Package.ps1"
$validateScript = Join-Path $PSScriptRoot "Validate-Deployment.ps1"

az group create --name $ResourceGroupName --location $Location --only-show-errors | Out-Null

$coreOutputsRaw = az deployment group create `
    --resource-group $ResourceGroupName `
    --name "$NamePrefix-$EnvironmentName-core-$(Get-Date -Format 'yyyyMMddHHmmss')" `
    --template-file $coreTemplate `
    --parameters `
        location=$Location `
        environmentName=$EnvironmentName `
        namePrefix=$NamePrefix `
        ownerEmail=$OwnerEmail `
        workspaceResourceId=$WorkspaceResourceId `
        appInsightsWorkspaceResourceId=$AppInsightsWorkspaceResourceId `
        timerSchedule=$TimerSchedule `
        varonisApiKeySecretName=$VaronisApiKeySecretName `
    --query "properties.outputs" `
    --output json `
    --only-show-errors

if ($LASTEXITCODE -ne 0 -or [string]::IsNullOrWhiteSpace($coreOutputsRaw)) {
    throw "Core infrastructure deployment failed."
}

$coreOutputs = $coreOutputsRaw | ConvertFrom-Json

$functionAppName = Get-OutputValue -Outputs $coreOutputs -Name "functionAppName"
$functionPrincipalId = Get-OutputValue -Outputs $coreOutputs -Name "functionPrincipalId"
$workspaceName = Get-OutputValue -Outputs $coreOutputs -Name "workspaceName"
$workspaceResourceIdResolved = Get-OutputValue -Outputs $coreOutputs -Name "workspaceResourceId"
$packageStorageAccountName = Get-OutputValue -Outputs $coreOutputs -Name "packageStorageAccountName"
$packageContainerName = Get-OutputValue -Outputs $coreOutputs -Name "packageContainerName"
$keyVaultName = Get-OutputValue -Outputs $coreOutputs -Name "keyVaultName"

if ($VaronisApiKey) {
    $bstr = [Runtime.InteropServices.Marshal]::SecureStringToBSTR($VaronisApiKey)
    try {
        $plainApiKey = [Runtime.InteropServices.Marshal]::PtrToStringBSTR($bstr)
    }
    finally {
        [Runtime.InteropServices.Marshal]::ZeroFreeBSTR($bstr)
    }

    if ([string]::IsNullOrWhiteSpace($plainApiKey)) {
        throw "The provided VaronisApiKey value was empty."
    }

    az keyvault secret set `
        --vault-name $keyVaultName `
        --name $VaronisApiKeySecretName `
        --value $plainApiKey `
        --only-show-errors | Out-Null
}

$tableLifecycleJson = & $tableLifecycleScript `
    -ResourceGroupName $ResourceGroupName `
    -WorkspaceName $workspaceName `
    -TableName $TableName `
    -SchemaFilePath "infra/table-schema.json" `
    -AutoMigrateClassic `
    -AllowBreakingChangeWithV2Table `
    -AsJson

$tableLifecycle = $tableLifecycleJson | ConvertFrom-Json
$resolvedTableName = $tableLifecycle.ResolvedTableName
$resolvedStreamName = $tableLifecycle.ResolvedStreamName

$monitoringOutputsRaw = az deployment group create `
    --resource-group $ResourceGroupName `
    --name "$NamePrefix-$EnvironmentName-monitoring-$(Get-Date -Format 'yyyyMMddHHmmss')" `
    --template-file $monitoringTemplate `
    --parameters `
        location=$Location `
        environmentName=$EnvironmentName `
        namePrefix=$NamePrefix `
        ownerEmail=$OwnerEmail `
        workspaceResourceId=$workspaceResourceIdResolved `
        functionPrincipalId=$functionPrincipalId `
        tableName=$resolvedTableName `
        streamName=$resolvedStreamName `
    --query "properties.outputs" `
    --output json `
    --only-show-errors

if ($LASTEXITCODE -ne 0 -or [string]::IsNullOrWhiteSpace($monitoringOutputsRaw)) {
    throw "Monitoring deployment failed."
}

$monitoringOutputs = $monitoringOutputsRaw | ConvertFrom-Json
$dcrImmutableId = Get-OutputValue -Outputs $monitoringOutputs -Name "dcrImmutableId"
$dcrResourceId = Get-OutputValue -Outputs $monitoringOutputs -Name "dcrResourceId"
$logsIngestionEndpoint = Get-OutputValue -Outputs $monitoringOutputs -Name "logsIngestionEndpoint"

$settings = @(
    "Ingestion__Endpoint=$logsIngestionEndpoint",
    "Ingestion__DcrImmutableId=$dcrImmutableId",
    "Ingestion__StreamName=$resolvedStreamName",
    "TABLE_NAME=$resolvedTableName",
    "DCR_RESOURCE_ID=$dcrResourceId",
    "WORKSPACE_RESOURCE_ID=$workspaceResourceIdResolved",
    "Varonis__ApiKeySecretName=$VaronisApiKeySecretName"
)

if (-not [string]::IsNullOrWhiteSpace($VaronisBaseUrl)) {
    $settings += "Varonis__BaseUrl=$VaronisBaseUrl"
}

az functionapp config appsettings set `
    --resource-group $ResourceGroupName `
    --name $functionAppName `
    --settings $settings `
    --only-show-errors | Out-Null

$packagePublishResult = $null
if (-not $SkipPackagePublish) {
    if ([string]::IsNullOrWhiteSpace($PackagePath) -and -not $SkipPackageBuild) {
        $buildResult = & $buildPackageScript -Version $PackageVersion
        $PackagePath = $buildResult.PackagePath
        $PackageVersion = $buildResult.Version
    }

    if ([string]::IsNullOrWhiteSpace($PackagePath)) {
        throw "PackagePath is empty. Provide -PackagePath or omit -SkipPackageBuild."
    }

    $packagePublishResult = & $publishPackageScript `
        -ResourceGroupName $ResourceGroupName `
        -FunctionAppName $functionAppName `
        -PackageStorageAccountName $packageStorageAccountName `
        -PackageContainerName $packageContainerName `
        -PackagePath $PackagePath `
        -PackageVersion $PackageVersion `
        -DeploymentMode $PackageDeploymentMode
}

if ($RunValidation) {
    & $validateScript `
        -ResourceGroupName $ResourceGroupName `
        -FunctionAppName $functionAppName `
        -WorkspaceResourceId $workspaceResourceIdResolved `
        -TableName $resolvedTableName `
        -DcrResourceId $dcrResourceId `
        -LogsIngestionEndpoint $logsIngestionEndpoint
}

[pscustomobject]@{
    ResourceGroupName = $ResourceGroupName
    FunctionAppName = $functionAppName
    WorkspaceName = $workspaceName
    WorkspaceResourceId = $workspaceResourceIdResolved
    KeyVaultName = $keyVaultName
    TableName = $resolvedTableName
    StreamName = $resolvedStreamName
    DcrImmutableId = $dcrImmutableId
    DcrResourceId = $dcrResourceId
    LogsIngestionEndpoint = $logsIngestionEndpoint
    Package = $packagePublishResult
}
