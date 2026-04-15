[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)]
    [string]$ResourceGroupName,

    [Parameter(Mandatory = $true)]
    [string]$FunctionAppName,

    [string]$SubscriptionId = "",
    [string]$ExpectedWorkerRuntime = "dotnet-isolated",
    [string]$ExpectedFunctionsExtensionVersion = "~4",
    [string]$HealthEndpointPath = "/api/health",
    [int]$TimeoutSec = 30,
    [switch]$IncludeDeploymentHistory,
    [switch]$OutputJson,
    [switch]$FailOnWarnings
)

$ErrorActionPreference = "Stop"

if (-not (Get-Command az -ErrorAction SilentlyContinue)) {
    throw "Azure CLI ('az') was not found in PATH."
}

$checks = [System.Collections.Generic.List[object]]::new()

function Add-Check {
    param(
        [Parameter(Mandatory = $true)][string]$Name,
        [Parameter(Mandatory = $true)][ValidateSet("Pass", "Warn", "Fail")][string]$Status,
        [Parameter(Mandatory = $true)][string]$Details
    )

    $script:checks.Add([pscustomobject]@{
        Name = $Name
        Status = $Status
        Details = $Details
    }) | Out-Null
}

function Invoke-AzJson {
    param([Parameter(Mandatory = $true)][string[]]$Arguments)

    $raw = az @Arguments --only-show-errors --output json 2>&1
    if ($LASTEXITCODE -ne 0) {
        throw "az $($Arguments -join ' ') failed. $raw"
    }

    if ([string]::IsNullOrWhiteSpace($raw)) {
        return $null
    }

    return ($raw | ConvertFrom-Json)
}

function Invoke-AzTsv {
    param([Parameter(Mandatory = $true)][string[]]$Arguments)

    $raw = az @Arguments --only-show-errors --output tsv 2>&1
    if ($LASTEXITCODE -ne 0) {
        throw "az $($Arguments -join ' ') failed. $raw"
    }

    return ($raw | Out-String).Trim()
}

function Get-HttpStatusCode {
    param(
        [Parameter(Mandatory = $true)][string]$Uri,
        [Parameter(Mandatory = $true)][int]$TimeoutSeconds
    )

    try {
        $response = Invoke-WebRequest -Uri $Uri -Method GET -TimeoutSec $TimeoutSeconds -MaximumRedirection 0 -ErrorAction Stop
        return [int]$response.StatusCode
    }
    catch {
        if ($_.Exception.Response) {
            return [int]$_.Exception.Response.StatusCode
        }

        throw
    }
}

if (-not [string]::IsNullOrWhiteSpace($SubscriptionId)) {
    az account set --subscription $SubscriptionId --only-show-errors | Out-Null
    if ($LASTEXITCODE -ne 0) {
        throw "Failed to set Azure subscription context to '$SubscriptionId'."
    }
}

$account = Invoke-AzJson -Arguments @("account", "show")
$subscriptionScopeArgs = @()
if (-not [string]::IsNullOrWhiteSpace($SubscriptionId)) {
    $subscriptionScopeArgs = @("--subscription", $SubscriptionId)
}

$functionApp = Invoke-AzJson -Arguments (@("functionapp", "show") + $subscriptionScopeArgs + @(
        "--resource-group", $ResourceGroupName,
        "--name", $FunctionAppName
    ))

if ($functionApp.state -eq "Running") {
    Add-Check -Name "FunctionAppState" -Status "Pass" -Details "state=$($functionApp.state)"
}
else {
    Add-Check -Name "FunctionAppState" -Status "Fail" -Details "state=$($functionApp.state)"
}

if ($functionApp.availabilityState -eq "Normal") {
    Add-Check -Name "AvailabilityState" -Status "Pass" -Details "availabilityState=$($functionApp.availabilityState)"
}
else {
    Add-Check -Name "AvailabilityState" -Status "Warn" -Details "availabilityState=$($functionApp.availabilityState)"
}

if ($functionApp.httpsOnly) {
    Add-Check -Name "HttpsOnly" -Status "Pass" -Details "httpsOnly=true"
}
else {
    Add-Check -Name "HttpsOnly" -Status "Warn" -Details "httpsOnly=false"
}

$hostName = "$($functionApp.defaultHostName)"
$rootUrl = "https://$hostName/"
$rootStatusCode = Get-HttpStatusCode -Uri $rootUrl -TimeoutSeconds $TimeoutSec
if ($rootStatusCode -lt 500) {
    Add-Check -Name "PublicEndpoint" -Status "Pass" -Details "$rootUrl returned HTTP $rootStatusCode"
}
else {
    Add-Check -Name "PublicEndpoint" -Status "Fail" -Details "$rootUrl returned HTTP $rootStatusCode"
}

$appSettings = Invoke-AzJson -Arguments (@("functionapp", "config", "appsettings", "list") + $subscriptionScopeArgs + @(
        "--resource-group", $ResourceGroupName,
        "--name", $FunctionAppName
    ))

$settingsByName = @{}
foreach ($setting in @($appSettings)) {
    if (-not [string]::IsNullOrWhiteSpace($setting.name)) {
        $settingsByName[$setting.name] = $setting.value
    }
}

$workerRuntime = $settingsByName["FUNCTIONS_WORKER_RUNTIME"]
if ([string]::IsNullOrWhiteSpace($workerRuntime)) {
    Add-Check -Name "WorkerRuntime" -Status "Fail" -Details "FUNCTIONS_WORKER_RUNTIME is missing"
}
elseif ($workerRuntime -eq $ExpectedWorkerRuntime) {
    Add-Check -Name "WorkerRuntime" -Status "Pass" -Details "FUNCTIONS_WORKER_RUNTIME=$workerRuntime"
}
else {
    Add-Check -Name "WorkerRuntime" -Status "Fail" -Details "FUNCTIONS_WORKER_RUNTIME=$workerRuntime (expected $ExpectedWorkerRuntime)"
}

$extensionVersion = $settingsByName["FUNCTIONS_EXTENSION_VERSION"]
if ([string]::IsNullOrWhiteSpace($extensionVersion)) {
    Add-Check -Name "FunctionsExtensionVersion" -Status "Fail" -Details "FUNCTIONS_EXTENSION_VERSION is missing"
}
elseif ($extensionVersion -eq $ExpectedFunctionsExtensionVersion) {
    Add-Check -Name "FunctionsExtensionVersion" -Status "Pass" -Details "FUNCTIONS_EXTENSION_VERSION=$extensionVersion"
}
else {
    Add-Check -Name "FunctionsExtensionVersion" -Status "Warn" -Details "FUNCTIONS_EXTENSION_VERSION=$extensionVersion (expected $ExpectedFunctionsExtensionVersion)"
}

$runFromPackage = $settingsByName["WEBSITE_RUN_FROM_PACKAGE"]
if ([string]::IsNullOrWhiteSpace($runFromPackage)) {
    Add-Check -Name "RunFromPackage" -Status "Fail" -Details "WEBSITE_RUN_FROM_PACKAGE is missing"
}
else {
    Add-Check -Name "RunFromPackage" -Status "Pass" -Details "WEBSITE_RUN_FROM_PACKAGE is configured"

    if ($runFromPackage -match '^https?://') {
        try {
            $packageResponse = Invoke-WebRequest -Uri $runFromPackage -Method Head -MaximumRedirection 5 -TimeoutSec $TimeoutSec -ErrorAction Stop
            $packageStatusCode = [int]$packageResponse.StatusCode
        }
        catch {
            if ($_.Exception.Response) {
                $packageStatusCode = [int]$_.Exception.Response.StatusCode
            }
            else {
                throw
            }
        }

        if ($packageStatusCode -ge 200 -and $packageStatusCode -lt 400) {
            Add-Check -Name "PackageUrlReachability" -Status "Pass" -Details "Package URL returned HTTP $packageStatusCode"
        }
        else {
            Add-Check -Name "PackageUrlReachability" -Status "Fail" -Details "Package URL returned HTTP $packageStatusCode"
        }
    }
}

$effectiveHealthPath = $HealthEndpointPath
if ([string]::IsNullOrWhiteSpace($effectiveHealthPath)) {
    if (-not [string]::IsNullOrWhiteSpace($functionApp.siteConfig.healthCheckPath)) {
        $effectiveHealthPath = "$($functionApp.siteConfig.healthCheckPath)"
    }
    elseif (-not [string]::IsNullOrWhiteSpace($settingsByName["WEBSITE_HEALTHCHECK_PATH"])) {
        $effectiveHealthPath = $settingsByName["WEBSITE_HEALTHCHECK_PATH"]
    }
}

if (-not [string]::IsNullOrWhiteSpace($effectiveHealthPath)) {
    if (-not $effectiveHealthPath.StartsWith("/")) {
        $effectiveHealthPath = "/$effectiveHealthPath"
    }

    $healthUrl = "https://$hostName$effectiveHealthPath"
    $healthStatusCode = Get-HttpStatusCode -Uri $healthUrl -TimeoutSeconds $TimeoutSec
    if ($healthStatusCode -ge 200 -and $healthStatusCode -lt 400) {
        Add-Check -Name "HealthEndpoint" -Status "Pass" -Details "$healthUrl returned HTTP $healthStatusCode"
    }
    else {
        Add-Check -Name "HealthEndpoint" -Status "Fail" -Details "$healthUrl returned HTTP $healthStatusCode"
    }
}
else {
    Add-Check -Name "HealthEndpoint" -Status "Warn" -Details "No health endpoint path configured or provided"
}

try {
    $masterKey = Invoke-AzTsv -Arguments (@("functionapp", "keys", "list") + $subscriptionScopeArgs + @(
            "--resource-group", $ResourceGroupName,
            "--name", $FunctionAppName,
            "--query", "masterKey"
        ))
}
catch {
    $masterKey = ""
    Add-Check -Name "MasterKeyAccess" -Status "Warn" -Details "Could not retrieve master key. $($_.Exception.Message)"
}

$adminFunctionCount = $null
if (-not [string]::IsNullOrWhiteSpace($masterKey)) {
    $headers = @{ "x-functions-key" = $masterKey }

    try {
        $hostStatus = Invoke-RestMethod -Uri "https://$hostName/admin/host/status" -Headers $headers -Method Get -TimeoutSec $TimeoutSec
        if ($hostStatus.state -eq "Running") {
            Add-Check -Name "HostStatus" -Status "Pass" -Details "admin host status is Running (version $($hostStatus.version))"
        }
        else {
            Add-Check -Name "HostStatus" -Status "Fail" -Details "admin host status is $($hostStatus.state)"
        }
    }
    catch {
        Add-Check -Name "HostStatus" -Status "Fail" -Details "Failed to query admin host status. $($_.Exception.Message)"
    }

    try {
        $adminFunctions = Invoke-RestMethod -Uri "https://$hostName/admin/functions" -Headers $headers -Method Get -TimeoutSec $TimeoutSec
        $adminFunctionCount = @($adminFunctions).Count
        if ($adminFunctionCount -gt 0) {
            Add-Check -Name "FunctionDiscovery" -Status "Pass" -Details "$adminFunctionCount function(s) discovered by host"
        }
        else {
            Add-Check -Name "FunctionDiscovery" -Status "Warn" -Details "0 functions discovered by host"
        }
    }
    catch {
        Add-Check -Name "FunctionDiscovery" -Status "Warn" -Details "Failed to query /admin/functions. $($_.Exception.Message)"
    }
}
else {
    Add-Check -Name "HostStatus" -Status "Warn" -Details "Skipped host-level checks because master key is unavailable"
    Add-Check -Name "FunctionDiscovery" -Status "Warn" -Details "Skipped function discovery because master key is unavailable"
}

if ($IncludeDeploymentHistory) {
    try {
        $publishingProfilesXml = az webapp deployment list-publishing-profiles `
            @subscriptionScopeArgs `
            --resource-group $ResourceGroupName `
            --name $FunctionAppName `
            --xml `
            --only-show-errors

        [xml]$publishingProfilesDoc = $publishingProfilesXml
        $msDeployProfile = $publishingProfilesDoc.publishData.publishProfile |
            Where-Object { $_.publishMethod -eq "MSDeploy" } |
            Select-Object -First 1

        if ($null -eq $msDeployProfile) {
            Add-Check -Name "DeploymentHistory" -Status "Warn" -Details "No MSDeploy publishing profile was returned"
        }
        else {
            $scmHost = ($msDeployProfile.publishUrl -split ":")[0]
            $credentialPair = "$($msDeployProfile.userName):$($msDeployProfile.userPWD)"
            $encodedCreds = [Convert]::ToBase64String([Text.Encoding]::ASCII.GetBytes($credentialPair))
            $kuduHeaders = @{ Authorization = "Basic $encodedCreds" }
            $deployments = Invoke-RestMethod -Uri "https://$scmHost/api/deployments" -Headers $kuduHeaders -Method Get -TimeoutSec $TimeoutSec
            $deploymentCount = @($deployments).Count

            if ($deploymentCount -eq 0 -and $runFromPackage -match '^https?://') {
                Add-Check -Name "DeploymentHistory" -Status "Pass" -Details "No Kudu deployments found (expected for URL-based run-from-package deployments)"
            }
            elseif ($deploymentCount -eq 0) {
                Add-Check -Name "DeploymentHistory" -Status "Warn" -Details "No deployments found in Kudu history"
            }
            else {
                $latestDeployment = @($deployments | Select-Object -First 1)[0]
                if ($latestDeployment.status -eq 4) {
                    Add-Check -Name "DeploymentHistory" -Status "Pass" -Details "Latest deployment succeeded (id=$($latestDeployment.id))"
                }
                elseif ($latestDeployment.status -eq 3) {
                    Add-Check -Name "DeploymentHistory" -Status "Fail" -Details "Latest deployment failed (id=$($latestDeployment.id))"
                }
                else {
                    Add-Check -Name "DeploymentHistory" -Status "Warn" -Details "Latest deployment status=$($latestDeployment.status) (id=$($latestDeployment.id))"
                }
            }
        }
    }
    catch {
        Add-Check -Name "DeploymentHistory" -Status "Warn" -Details "Could not query deployment history. $($_.Exception.Message)"
    }
}

$hasFail = @($checks | Where-Object { $_.Status -eq "Fail" }).Count -gt 0
$hasWarn = @($checks | Where-Object { $_.Status -eq "Warn" }).Count -gt 0

$overallStatus = "Pass"
if ($hasFail) {
    $overallStatus = "Fail"
}
elseif ($hasWarn) {
    $overallStatus = "Warn"
}

$result = [pscustomobject]@{
    checkedAtUtc = (Get-Date).ToUniversalTime().ToString("O")
    subscriptionId = $account.id
    resourceGroupName = $ResourceGroupName
    functionAppName = $FunctionAppName
    hostName = $hostName
    adminFunctionCount = $adminFunctionCount
    overallStatus = $overallStatus
    checks = $checks
}

if ($OutputJson) {
    $result | ConvertTo-Json -Depth 8
}
else {
    Write-Host ""
    Write-Host "Azure Function App health check"
    Write-Host "Subscription: $($result.subscriptionId)"
    Write-Host "Resource Group: $($result.resourceGroupName)"
    Write-Host "Function App: $($result.functionAppName)"
    Write-Host "Host Name: $($result.hostName)"
    Write-Host "Checked At (UTC): $($result.checkedAtUtc)"
    Write-Host ""
    $checks | Format-Table -AutoSize | Out-String | Write-Host
    Write-Host "OverallStatus: $overallStatus"
}

if ($overallStatus -eq "Fail" -or ($FailOnWarnings -and $overallStatus -eq "Warn")) {
    exit 1
}
