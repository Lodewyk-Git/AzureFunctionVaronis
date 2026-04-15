<#
.SYNOPSIS
    Rolls back a Function App to the previously deployed package.

.DESCRIPTION
    Publish-Package.ps1 stores the outgoing package URL in the app setting
    WEBSITE_RUN_FROM_PACKAGE_PREVIOUS before switching WEBSITE_RUN_FROM_PACKAGE
    to the new value. This script reverses that: it swaps the two settings back
    and restarts the Function App so the prior package activates.

    Only the RunFromPackageUrl deployment mode is supported because ZipDeploy
    rollback requires restoring the previous ZIP payload, which is not trivially
    recoverable from app settings alone. For ZipDeploy rollback, redeploy a
    previous known-good package zip via Deploy-Solution.ps1 or the release
    workflow.

.PARAMETER ResourceGroupName
    Function App resource group.

.PARAMETER FunctionAppName
    Function App name.

.PARAMETER SlotName
    Optional deployment slot name. If omitted, the production slot is used.

.PARAMETER SubscriptionId
    Optional subscription override.

.PARAMETER Force
    Skip the interactive confirmation.

.EXAMPLE
    ./scripts/Rollback-Package.ps1 -ResourceGroupName rg-varonis-prod -FunctionAppName varonis-prod-varonis-func-xxxx -Force
#>
[CmdletBinding(SupportsShouldProcess = $true, ConfirmImpact = 'High')]
param(
    [Parameter(Mandatory = $true)]
    [string]$ResourceGroupName,

    [Parameter(Mandatory = $true)]
    [string]$FunctionAppName,

    [string]$SlotName = "",

    [string]$SubscriptionId = "",

    [switch]$Force
)

$ErrorActionPreference = "Stop"

if (-not (Get-Command az -ErrorAction SilentlyContinue)) {
    throw "Azure CLI ('az') was not found in PATH."
}

if (-not [string]::IsNullOrWhiteSpace($SubscriptionId)) {
    az account set --subscription $SubscriptionId --only-show-errors | Out-Null
    if ($LASTEXITCODE -ne 0) {
        throw "Failed to set Azure subscription context to '$SubscriptionId'."
    }
}

$listArgs = @(
    "functionapp", "config", "appsettings", "list",
    "--resource-group", $ResourceGroupName,
    "--name", $FunctionAppName,
    "--only-show-errors",
    "--output", "json"
)
if (-not [string]::IsNullOrWhiteSpace($SlotName)) {
    $listArgs += @("--slot", $SlotName)
}

$settingsRaw = az @listArgs
if ($LASTEXITCODE -ne 0 -or [string]::IsNullOrWhiteSpace($settingsRaw)) {
    throw "Failed to list app settings for '$FunctionAppName'."
}

$settings = $settingsRaw | ConvertFrom-Json
$currentValue = ($settings | Where-Object { $_.name -eq "WEBSITE_RUN_FROM_PACKAGE" } | Select-Object -First 1).value
$previousValue = ($settings | Where-Object { $_.name -eq "WEBSITE_RUN_FROM_PACKAGE_PREVIOUS" } | Select-Object -First 1).value
$currentVersion = ($settings | Where-Object { $_.name -eq "PACKAGE_VERSION" } | Select-Object -First 1).value

if ([string]::IsNullOrWhiteSpace($previousValue)) {
    throw "WEBSITE_RUN_FROM_PACKAGE_PREVIOUS is not set on '$FunctionAppName'. Rollback is only available when the previous deployment used RunFromPackageUrl mode via Publish-Package.ps1."
}

if ($previousValue -eq "1") {
    throw "WEBSITE_RUN_FROM_PACKAGE_PREVIOUS='1' indicates the previous deployment used ZipDeploy. Rollback this by redeploying a known-good package ZIP instead."
}

Write-Host "Current WEBSITE_RUN_FROM_PACKAGE : $currentValue"
Write-Host "Rolling back to WEBSITE_RUN_FROM_PACKAGE_PREVIOUS : $previousValue"
Write-Host "Current PACKAGE_VERSION : $currentVersion"

$target = "$FunctionAppName$(if ($SlotName) { " (slot: $SlotName)" })"
if (-not $Force -and -not $PSCmdlet.ShouldProcess($target, "Swap WEBSITE_RUN_FROM_PACKAGE with WEBSITE_RUN_FROM_PACKAGE_PREVIOUS and restart")) {
    Write-Host "Aborted by user."
    return
}

$setArgs = @(
    "functionapp", "config", "appsettings", "set",
    "--resource-group", $ResourceGroupName,
    "--name", $FunctionAppName,
    "--settings",
    "WEBSITE_RUN_FROM_PACKAGE=$previousValue",
    "WEBSITE_RUN_FROM_PACKAGE_PREVIOUS=$currentValue",
    "PACKAGE_VERSION_PREVIOUS=$currentVersion",
    "ROLLBACK_APPLIED_AT=$((Get-Date).ToUniversalTime().ToString('O'))",
    "--only-show-errors"
)
if (-not [string]::IsNullOrWhiteSpace($SlotName)) {
    $setArgs += @("--slot", $SlotName)
}

az @setArgs --output none
if ($LASTEXITCODE -ne 0) {
    throw "Failed to update app settings on '$FunctionAppName'."
}

$restartArgs = @(
    "functionapp", "restart",
    "--resource-group", $ResourceGroupName,
    "--name", $FunctionAppName,
    "--only-show-errors"
)
if (-not [string]::IsNullOrWhiteSpace($SlotName)) {
    $restartArgs += @("--slot", $SlotName)
}
az @restartArgs --output none
if ($LASTEXITCODE -ne 0) {
    throw "Rollback succeeded but restart failed on '$FunctionAppName'. Investigate and restart manually."
}

[pscustomobject]@{
    ResourceGroupName = $ResourceGroupName
    FunctionAppName = $FunctionAppName
    SlotName = $SlotName
    RolledBackFrom = $currentValue
    RolledBackTo = $previousValue
    PreviousPackageVersion = $currentVersion
    RolledBackAtUtc = (Get-Date).ToUniversalTime().ToString("O")
}
