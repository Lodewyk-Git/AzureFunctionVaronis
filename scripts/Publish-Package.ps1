[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)]
    [string]$ResourceGroupName,

    [Parameter(Mandatory = $true)]
    [string]$FunctionAppName,

    [Parameter(Mandatory = $true)]
    [string]$PackageStorageAccountName,

    [Parameter(Mandatory = $true)]
    [string]$PackagePath,

    [string]$PackageContainerName = "function-packages",

    [ValidateSet("RunFromPackageUrl", "ZipDeploy")]
    [string]$DeploymentMode = "ZipDeploy",

    [int]$SasExpiryHours = 720,

    [string]$PackageVersion = "",

    [string]$SlotName = "",

    [string]$SubscriptionId = "",

    [string[]]$ExpectedFunctionNames = @("HealthCheck", "VaronisAlertTimerFunction"),

    [string]$ValidationAppInsightsAppName = "",

    [int]$StartupValidationWindowMinutes = 30,

    [switch]$SkipPackageVerification,

    [switch]$SkipPostRolloutValidation
)

$ErrorActionPreference = "Stop"

if (-not [string]::IsNullOrWhiteSpace($SubscriptionId)) {
    az account set --subscription $SubscriptionId | Out-Null
}

if (-not (Test-Path -LiteralPath $PackagePath)) {
    throw "Package file not found: $PackagePath"
}

$verifyPackageScript = Join-Path $PSScriptRoot "Verify-FunctionPackage.ps1"
$healthCheckScript = Join-Path $PSScriptRoot "Test-FunctionAppHealth.ps1"

if (-not $SkipPackageVerification) {
    if (-not (Test-Path -LiteralPath $verifyPackageScript)) {
        throw "Package verification script not found: $verifyPackageScript"
    }

    & $verifyPackageScript -PackagePath $PackagePath -ExpectedFunctionNames $ExpectedFunctionNames | Out-Null
}

if ([string]::IsNullOrWhiteSpace($PackageVersion)) {
    $PackageVersion = [IO.Path]::GetFileNameWithoutExtension($PackagePath)
}

$blobName = [IO.Path]::GetFileName($PackagePath)
$subscriptionScopeArgs = @()
if (-not [string]::IsNullOrWhiteSpace($SubscriptionId)) {
    $subscriptionScopeArgs = @("--subscription", $SubscriptionId)
}

function Invoke-PostRolloutValidation {
    param(
        [Parameter(Mandatory = $true)][string]$ResourceGroup,
        [Parameter(Mandatory = $true)][string]$AppName
    )

    if ($SkipPostRolloutValidation) {
        return
    }

    if (-not (Test-Path -LiteralPath $healthCheckScript)) {
        throw "Post-rollout validation script not found: $healthCheckScript"
    }

    $healthArgs = @(
        "-ResourceGroupName", $ResourceGroup,
        "-FunctionAppName", $AppName,
        "-ExpectedFunctionNames",
        "-SyncTriggers",
        "-FailOnWarnings",
        "-StrictStartupValidation",
        "-StartupWindowMinutes", $StartupValidationWindowMinutes
    )

    $healthArgs += $ExpectedFunctionNames

    if (-not [string]::IsNullOrWhiteSpace($SubscriptionId)) {
        $healthArgs += @("-SubscriptionId", $SubscriptionId)
    }

    if (-not [string]::IsNullOrWhiteSpace($ValidationAppInsightsAppName)) {
        $healthArgs += @("-AppInsightsAppName", $ValidationAppInsightsAppName)
    }

    & $healthCheckScript @healthArgs | Out-Null
    if ($LASTEXITCODE -ne 0) {
        throw "Post-rollout validation failed for '$AppName'. Check Test-FunctionAppHealth output."
    }
}

az storage container create `
    --account-name $PackageStorageAccountName `
    --auth-mode login `
    --name $PackageContainerName `
    --public-access off `
    --only-show-errors | Out-Null

az storage blob upload `
    --account-name $PackageStorageAccountName `
    --auth-mode login `
    --container-name $PackageContainerName `
    --file $PackagePath `
    --name $blobName `
    --overwrite true `
    --only-show-errors | Out-Null

if ($DeploymentMode -eq "ZipDeploy") {
    if ([string]::IsNullOrWhiteSpace($SlotName)) {
        az functionapp deployment source config-zip `
            --resource-group $ResourceGroupName `
            --name $FunctionAppName `
            --src $PackagePath `
            --only-show-errors | Out-Null
    }
    else {
        az functionapp deployment source config-zip `
            --resource-group $ResourceGroupName `
            --name $FunctionAppName `
            --slot $SlotName `
            --src $PackagePath `
            --only-show-errors | Out-Null
    }

    $appSettingsArgs = @(
        "functionapp", "config", "appsettings", "set",
        "--resource-group", $ResourceGroupName,
        "--name", $FunctionAppName,
        "--settings", "WEBSITE_RUN_FROM_PACKAGE=1", "PACKAGE_VERSION=$PackageVersion", "PACKAGE_BLOB_NAME=$blobName",
        "--only-show-errors"
    )

    if (-not [string]::IsNullOrWhiteSpace($SlotName)) {
        $appSettingsArgs += @("--slot", $SlotName)
    }

    az @appSettingsArgs | Out-Null

    Invoke-PostRolloutValidation -ResourceGroup $ResourceGroupName -AppName $FunctionAppName

    [pscustomobject]@{
        DeploymentMode = $DeploymentMode
        PackageVersion = $PackageVersion
        PackageBlobName = $blobName
        RunFromPackageValue = "1"
    }
    return
}

$expiryUtc = (Get-Date).ToUniversalTime().AddHours($SasExpiryHours).ToString("yyyy-MM-ddTHH:mmZ")
$sasToken = az storage blob generate-sas `
    --account-name $PackageStorageAccountName `
    --auth-mode login `
    --as-user `
    --container-name $PackageContainerName `
    --name $blobName `
    --permissions r `
    --expiry $expiryUtc `
    --https-only `
    --output tsv `
    --only-show-errors

if ([string]::IsNullOrWhiteSpace($sasToken)) {
    throw "Failed to generate SAS token for package blob."
}

$packageUrl = "https://$PackageStorageAccountName.blob.core.windows.net/$PackageContainerName/$blobName`?$sasToken"

$listSettingsArgs = @(
    "functionapp", "config", "appsettings", "list",
    "--resource-group", $ResourceGroupName,
    "--name", $FunctionAppName,
    "--only-show-errors",
    "--output", "json"
)

if (-not [string]::IsNullOrWhiteSpace($SlotName)) {
    $listSettingsArgs += @("--slot", $SlotName)
}

$currentSettings = az @listSettingsArgs | ConvertFrom-Json
$previousRunFromPackage = $currentSettings | Where-Object { $_.name -eq "WEBSITE_RUN_FROM_PACKAGE" } | Select-Object -ExpandProperty value -First 1

$setSettingsArgs = @(
    "functionapp", "config", "appsettings", "set",
    "--resource-group", $ResourceGroupName,
    "--name", $FunctionAppName,
    "--settings",
    "WEBSITE_RUN_FROM_PACKAGE_PREVIOUS=$previousRunFromPackage",
    "WEBSITE_RUN_FROM_PACKAGE=$packageUrl",
    "PACKAGE_VERSION=$PackageVersion",
    "PACKAGE_BLOB_NAME=$blobName",
    "--only-show-errors"
)

if (-not [string]::IsNullOrWhiteSpace($SlotName)) {
    $setSettingsArgs += @("--slot", $SlotName)
}

az @setSettingsArgs | Out-Null

$restartArgs = @("functionapp", "restart", "--resource-group", $ResourceGroupName, "--name", $FunctionAppName, "--only-show-errors")
if (-not [string]::IsNullOrWhiteSpace($SlotName)) {
    $restartArgs += @("--slot", $SlotName)
}
az @restartArgs | Out-Null

Invoke-PostRolloutValidation -ResourceGroup $ResourceGroupName -AppName $FunctionAppName

[pscustomobject]@{
    DeploymentMode = $DeploymentMode
    PackageVersion = $PackageVersion
    PackageBlobName = $blobName
    PackageUrl = $packageUrl
    PreviousRunFromPackage = $previousRunFromPackage
}
