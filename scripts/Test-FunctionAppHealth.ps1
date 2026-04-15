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
    [int]$StartupWindowMinutes = 30,
    [int]$RecentErrorWindowMinutes = 30,
    [int]$RunSuccessLookbackMinutes = 180,
    [int]$RecentRowsWindowMinutes = 30,
    [int]$MinRecentRows = 5,
    [string]$AppInsightsAppName = "",
    [string]$WorkspaceResourceId = "",
    [string]$LogTableName = "",
    [string[]]$ExpectedFunctionNames = @("HealthCheck", "VaronisAlertTimerFunction"),
    [switch]$SyncTriggers,
    [switch]$StrictStartupValidation,
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

function Resolve-AppInsightsTarget {
    param(
        [string]$ExplicitAppName,
        [string]$ConnectionString,
        [string]$ResourceGroup,
        [string[]]$SubscriptionArgs,
        [string]$FunctionAppResourceId
    )

    if (-not [string]::IsNullOrWhiteSpace($ExplicitAppName)) {
        return [pscustomobject]@{
            App = $ExplicitAppName
            ResourceGroup = $ResourceGroup
        }
    }

    $appIdFallback = ""
    if (-not [string]::IsNullOrWhiteSpace($ConnectionString)) {
        $appIdMatch = [Regex]::Match($ConnectionString, 'ApplicationId=([^;]+)', [Text.RegularExpressions.RegexOptions]::IgnoreCase)
        if ($appIdMatch.Success -and -not [string]::IsNullOrWhiteSpace($appIdMatch.Groups[1].Value)) {
            $appIdFallback = $appIdMatch.Groups[1].Value
        }
    }

    try {
        $components = Invoke-AzJson -Arguments (@("resource", "list") + $SubscriptionArgs + @(
                "--resource-group", $ResourceGroup,
                "--resource-type", "Microsoft.Insights/components"
            ))

        foreach ($component in @($components)) {
            if ($null -eq $component.tags) {
                continue
            }

            foreach ($tag in $component.tags.PSObject.Properties) {
                if ($tag.Name -eq "hidden-link:$FunctionAppResourceId") {
                    return [pscustomobject]@{
                        App = $component.name
                        ResourceGroup = $component.resourceGroup
                    }
                }
            }
        }

        $workloadMatches = @($components | Where-Object {
                $null -ne $_.tags -and
                ($_.tags.Workload -eq "AzureFunctionVaronis" -or $_.tags.workload -eq "AzureFunctionVaronis")
            })
        if ($workloadMatches.Count -eq 1) {
            return [pscustomobject]@{
                App = $workloadMatches[0].name
                ResourceGroup = $workloadMatches[0].resourceGroup
            }
        }

        if (@($components).Count -eq 1) {
            return [pscustomobject]@{
                App = @($components)[0].name
                ResourceGroup = @($components)[0].resourceGroup
            }
        }
    }
    catch {
        # Fall through to appId fallback.
    }

    if (-not [string]::IsNullOrWhiteSpace($appIdFallback)) {
        try {
            $allComponents = Invoke-AzJson -Arguments (@("resource", "list") + $SubscriptionArgs + @(
                    "--resource-type", "Microsoft.Insights/components",
                    "--query", "[].{name:name,resourceGroup:resourceGroup}"
                ))

            foreach ($component in @($allComponents)) {
                if ([string]::IsNullOrWhiteSpace($component.name) -or [string]::IsNullOrWhiteSpace($component.resourceGroup)) {
                    continue
                }

                $candidateAppId = Invoke-AzTsv -Arguments (@("monitor", "app-insights", "component", "show") + $SubscriptionArgs + @(
                        "--app", $component.name,
                        "--resource-group", $component.resourceGroup,
                        "--query", "appId"
                    ))

                if ($candidateAppId -eq $appIdFallback) {
                    return [pscustomobject]@{
                        App = $component.name
                        ResourceGroup = $component.resourceGroup
                    }
                }
            }
        }
        catch {
            # Fall through.
        }
    }

    if (-not [string]::IsNullOrWhiteSpace($appIdFallback)) {
        return [pscustomobject]@{
            App = $appIdFallback
            ResourceGroup = $ResourceGroup
        }
    }

    return [pscustomobject]@{
        App = ""
        ResourceGroup = $ResourceGroup
    }
}

function Invoke-AppInsightsQuery {
    param(
        [Parameter(Mandatory = $true)][string]$AppIdentifier,
        [Parameter(Mandatory = $true)][string]$ResourceGroup,
        [Parameter(Mandatory = $true)][string]$QueryText,
        # AllowEmptyCollection: when -SubscriptionId is omitted at the script entry point,
        # the caller passes an empty array. Mandatory + [string[]] alone rejects that.
        [Parameter(Mandatory = $true)][AllowEmptyCollection()][string[]]$SubscriptionArgs
    )

    $normalizedQuery = (($QueryText -replace "`r", " ") -replace "`n", " ").Trim()

    $raw = az monitor app-insights query `
        @SubscriptionArgs `
        --app $AppIdentifier `
        --resource-group $ResourceGroup `
        --analytics-query $normalizedQuery `
        --output json `
        --only-show-errors 2>&1

    if ($LASTEXITCODE -ne 0) {
        throw "App Insights query failed for '$AppIdentifier'. $raw"
    }

    if ([string]::IsNullOrWhiteSpace($raw)) {
        return @()
    }

    $queryResult = $raw | ConvertFrom-Json

    if ($null -eq $queryResult -or $queryResult.tables.Count -eq 0) {
        return @()
    }

    return @($queryResult.tables[0].rows)
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

if ($SyncTriggers) {
    $syncSucceeded = $false
    $syncDetails = ""

    try {
        az functionapp sync-function-triggers `
            @subscriptionScopeArgs `
            --resource-group $ResourceGroupName `
            --name $FunctionAppName `
            --only-show-errors 2>$null | Out-Null

        if ($LASTEXITCODE -eq 0) {
            $syncSucceeded = $true
            $syncDetails = "sync-function-triggers completed successfully"
        }
    }
    catch {
        $syncDetails = "sync-function-triggers command unavailable, using ARM syncfunctiontriggers."
    }

    if (-not $syncSucceeded) {
        try {
            $syncUri = "https://management.azure.com$($functionApp.id)/syncfunctiontriggers?api-version=2022-03-01"
            az rest `
                @subscriptionScopeArgs `
                --method post `
                --uri $syncUri `
                --only-show-errors | Out-Null

            if ($LASTEXITCODE -eq 0) {
                $syncSucceeded = $true
                if ([string]::IsNullOrWhiteSpace($syncDetails)) {
                    $syncDetails = "ARM syncfunctiontriggers completed successfully"
                }
                else {
                    $syncDetails += " ARM syncfunctiontriggers completed successfully."
                }
            }
        }
        catch {
            if ([string]::IsNullOrWhiteSpace($syncDetails)) {
                $syncDetails = "Trigger sync failed. $($_.Exception.Message)"
            }
            else {
                $syncDetails += " Trigger sync failed. $($_.Exception.Message)"
            }
        }
    }

    if ($syncSucceeded) {
        Add-Check -Name "TriggerSync" -Status "Pass" -Details $syncDetails
    }
    else {
        Add-Check -Name "TriggerSync" -Status "Fail" -Details $syncDetails
    }
}

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

if ([string]::IsNullOrWhiteSpace($WorkspaceResourceId) -and -not [string]::IsNullOrWhiteSpace($settingsByName["WORKSPACE_RESOURCE_ID"])) {
    $WorkspaceResourceId = $settingsByName["WORKSPACE_RESOURCE_ID"]
}

if ([string]::IsNullOrWhiteSpace($LogTableName) -and -not [string]::IsNullOrWhiteSpace($settingsByName["TABLE_NAME"])) {
    $LogTableName = $settingsByName["TABLE_NAME"]
}

if ([string]::IsNullOrWhiteSpace($WorkspaceResourceId) -and -not [string]::IsNullOrWhiteSpace($settingsByName["DCR_RESOURCE_ID"])) {
    try {
        $WorkspaceResourceId = Invoke-AzTsv -Arguments (@("resource", "show") + $subscriptionScopeArgs + @(
                "--ids", $settingsByName["DCR_RESOURCE_ID"],
                "--api-version", "2023-03-11",
                "--query", "properties.destinations.logAnalytics[0].workspaceResourceId"
            ))
    }
    catch {
        # Leave empty; validated later.
    }
}

if ([string]::IsNullOrWhiteSpace($LogTableName) -and -not [string]::IsNullOrWhiteSpace($settingsByName["Ingestion__StreamName"])) {
    $streamName = $settingsByName["Ingestion__StreamName"]
    if ($streamName.StartsWith("Custom-", [StringComparison]::OrdinalIgnoreCase)) {
        $LogTableName = $streamName.Substring(7)
    }
}

if ([string]::IsNullOrWhiteSpace($WorkspaceResourceId)) {
    try {
        $workspaceCandidates = Invoke-AzJson -Arguments (@("resource", "list") + $subscriptionScopeArgs + @(
                "--resource-group", $ResourceGroupName,
                "--resource-type", "Microsoft.OperationalInsights/workspaces",
                "--query", "[].{id:id}"
            ))

        if (@($workspaceCandidates).Count -eq 1 -and -not [string]::IsNullOrWhiteSpace($workspaceCandidates[0].id)) {
            $WorkspaceResourceId = $workspaceCandidates[0].id
        }
    }
    catch {
        # Leave empty; validated later.
    }
}

if ([string]::IsNullOrWhiteSpace($LogTableName)) {
    $LogTableName = "VaronisAlerts_CL"
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

$functionList = Invoke-AzJson -Arguments (@("functionapp", "function", "list") + $subscriptionScopeArgs + @(
        "--resource-group", $ResourceGroupName,
        "--name", $FunctionAppName
    ))

$discoveredFunctions = @()
foreach ($f in @($functionList)) {
    if (-not [string]::IsNullOrWhiteSpace($f.name)) {
        $discoveredFunctions += (($f.name -split "/")[-1])
    }
}

if ($discoveredFunctions.Count -eq 0) {
    Add-Check -Name "FunctionList" -Status "Fail" -Details "No functions returned by az functionapp function list"
}
else {
    Add-Check -Name "FunctionList" -Status "Pass" -Details ("Discovered: " + ($discoveredFunctions -join ", "))
}

$missingExpectedFunctions = @($ExpectedFunctionNames | Where-Object { $discoveredFunctions -notcontains $_ })
if ($missingExpectedFunctions.Count -eq 0) {
    Add-Check -Name "ExpectedFunctions" -Status "Pass" -Details "All expected functions discovered"
}
else {
    Add-Check -Name "ExpectedFunctions" -Status "Fail" -Details "Missing: $($missingExpectedFunctions -join ', ')"
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
    if ($healthStatusCode -eq 200) {
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

$appInsightsConnectionString = $settingsByName["APPLICATIONINSIGHTS_CONNECTION_STRING"]
$appInsightsTarget = Resolve-AppInsightsTarget `
    -ExplicitAppName $AppInsightsAppName `
    -ConnectionString $appInsightsConnectionString `
    -ResourceGroup $ResourceGroupName `
    -SubscriptionArgs $subscriptionScopeArgs `
    -FunctionAppResourceId $functionApp.id
$appInsightsIdentifier = $appInsightsTarget.App
$appInsightsResourceGroup = $appInsightsTarget.ResourceGroup

$windowStartUtc = (Get-Date).ToUniversalTime().AddMinutes(-1 * [Math]::Abs($StartupWindowMinutes))
if ($functionApp.lastModifiedTimeUtc) {
    try {
        $lastModifiedUtc = [DateTimeOffset]::Parse($functionApp.lastModifiedTimeUtc).ToUniversalTime()
        if ($lastModifiedUtc -gt $windowStartUtc) {
            $windowStartUtc = $lastModifiedUtc
        }
    }
    catch {
        # Ignore parse issues and keep fallback window.
    }
}

if ([string]::IsNullOrWhiteSpace($appInsightsIdentifier)) {
    $status = if ($StrictStartupValidation) { "Fail" } else { "Warn" }
    Add-Check -Name "StartupExceptions" -Status $status -Details "Unable to resolve App Insights component/app identifier."
    Add-Check -Name "FailureClassification" -Status $status -Details "Unable to run classification without App Insights identifier."
}
else {
    $statusWhenQueryFails = if ($StrictStartupValidation) { "Fail" } else { "Warn" }

    $startupQuery = @"
exceptions
| where timestamp > datetime($($windowStartUtc.ToString("O")))
| where outerMessage !has 'Exception while executing function'
| where outerMessage !has 'Result: Function'
| where outerMessage has_any ('startup','host','initializ','failed to start')
   or tostring(details) has_any ('ValidateOnStart','OptionsValidationException','Host initialization','Could not find the .azurefunctions')
| project timestamp, type, outerMessage
| order by timestamp desc
| take 20
"@

    try {
        $startupRows = Invoke-AppInsightsQuery `
            -AppIdentifier $appInsightsIdentifier `
            -ResourceGroup $appInsightsResourceGroup `
            -QueryText $startupQuery `
            -SubscriptionArgs $subscriptionScopeArgs

        if ($startupRows.Count -eq 0) {
            Add-Check -Name "StartupExceptions" -Status "Pass" -Details "No startup exceptions since $($windowStartUtc.ToString("O"))"
        }
        else {
            $first = $startupRows[0]
            Add-Check -Name "StartupExceptions" -Status "Fail" -Details "Startup exceptions found ($($startupRows.Count)); latest: $($first[0]) $($first[2])"
        }
    }
    catch {
        Add-Check -Name "StartupExceptions" -Status $statusWhenQueryFails -Details "Failed querying startup exceptions. $($_.Exception.Message)"
    }

    $classificationQuery = @"
let startTime = datetime($($windowStartUtc.ToString("O")));
traces
| where timestamp > startTime and severityLevel >= 2
| extend text = tostring(message)
| extend bucket = case(
    text has 'Search request must contain a query field', 'payload_contract_mismatch',
    text has 'VaronisSearchResponse', 'response_shape_mismatch',
    text has 'Search URL host' or text has 'BuildSearchUri' or text has 'Rejected search URL with unexpected host', 'continuation_path_failure',
    text has 'VaronisAlertMapper' or text has 'MapRowsToObject', 'source_retrieval_succeeded_transform_failed',
    text has 'LogIngestionService.UploadAlertsAsync' or text has 'Azure.Monitor.Ingestion' or text has 'UploadAlertsAsync', 'transform_succeeded_log_ingestion_write_failed',
    'unclassified')
| summarize hits=count() by bucket
| order by hits desc
"@

    try {
        $classificationRows = Invoke-AppInsightsQuery `
            -AppIdentifier $appInsightsIdentifier `
            -ResourceGroup $appInsightsResourceGroup `
            -QueryText $classificationQuery `
            -SubscriptionArgs $subscriptionScopeArgs

        if ($classificationRows.Count -eq 0) {
            Add-Check -Name "FailureClassification" -Status "Pass" -Details "No warning/error signatures found since $($windowStartUtc.ToString("O"))"
        }
        else {
            $summary = ($classificationRows | ForEach-Object { "$($_[0])=$($_[1])" }) -join "; "
            Add-Check -Name "FailureClassification" -Status "Pass" -Details "Observed buckets: $summary"
        }
    }
    catch {
        Add-Check -Name "FailureClassification" -Status $statusWhenQueryFails -Details "Failed to classify recent failures. $($_.Exception.Message)"
    }

    $recentErrorStartUtc = (Get-Date).ToUniversalTime().AddMinutes(-1 * [Math]::Abs($RecentErrorWindowMinutes))
    $jsonExceptionQuery = @"
exceptions
| where timestamp > datetime($($recentErrorStartUtc.ToString("O")))
| where tostring(outerMessage) has 'JsonException' or tostring(details) has 'JsonException'
| where tostring(details) has 'SearchAlertsAsync'
| count
"@

    try {
        $jsonExceptionRows = Invoke-AppInsightsQuery `
            -AppIdentifier $appInsightsIdentifier `
            -ResourceGroup $appInsightsResourceGroup `
            -QueryText $jsonExceptionQuery `
            -SubscriptionArgs $subscriptionScopeArgs

        $jsonExceptionHits = 0
        if ($jsonExceptionRows.Count -gt 0 -and $null -ne $jsonExceptionRows[0][0]) {
            $jsonExceptionHits = [int]$jsonExceptionRows[0][0]
        }

        if ($jsonExceptionHits -eq 0) {
            Add-Check -Name "NoJsonExceptionSearchAlertsAsync30m" -Status "Pass" -Details "No SearchAlertsAsync JsonException in last $RecentErrorWindowMinutes minute(s)"
        }
        else {
            Add-Check -Name "NoJsonExceptionSearchAlertsAsync30m" -Status "Fail" -Details "$jsonExceptionHits JsonException event(s) in last $RecentErrorWindowMinutes minute(s)"
        }
    }
    catch {
        Add-Check -Name "NoJsonExceptionSearchAlertsAsync30m" -Status $statusWhenQueryFails -Details "Failed querying JsonException signals. $($_.Exception.Message)"
    }

    $terminal400Query = @"
exceptions
| where timestamp > datetime($($recentErrorStartUtc.ToString("O")))
| extend text = strcat(tostring(outerMessage), ' ', tostring(details))
| where text has '400' and (text has 'legacy payload' or text has 'InvalidSearchRequest')
| count
"@

    try {
        $terminal400Rows = Invoke-AppInsightsQuery `
            -AppIdentifier $appInsightsIdentifier `
            -ResourceGroup $appInsightsResourceGroup `
            -QueryText $terminal400Query `
            -SubscriptionArgs $subscriptionScopeArgs

        $terminal400Hits = 0
        if ($terminal400Rows.Count -gt 0 -and $null -ne $terminal400Rows[0][0]) {
            $terminal400Hits = [int]$terminal400Rows[0][0]
        }

        if ($terminal400Hits -eq 0) {
            Add-Check -Name "NoTerminal400AfterFallback30m" -Status "Pass" -Details "No terminal 400/fallback loop signals in last $RecentErrorWindowMinutes minute(s)"
        }
        else {
            Add-Check -Name "NoTerminal400AfterFallback30m" -Status "Fail" -Details "$terminal400Hits terminal 400/fallback signal(s) in last $RecentErrorWindowMinutes minute(s)"
        }
    }
    catch {
        Add-Check -Name "NoTerminal400AfterFallback30m" -Status $statusWhenQueryFails -Details "Failed querying terminal-400 signals. $($_.Exception.Message)"
    }

    $runWindowStartUtc = (Get-Date).ToUniversalTime().AddMinutes(-1 * [Math]::Abs($RunSuccessLookbackMinutes))
    $consecutiveRunsQuery = @"
let startTime = datetime($($runWindowStartUtc.ToString("O")));
let runLogs = traces
| where timestamp > startTime
| where message startswith 'Starting Varonis ingestion run.'
    or message startswith 'Completed Varonis ingestion run.'
    or message startswith 'Varonis ingestion run failed.'
| extend CorrelationId = extract('CorrelationId=([0-9a-fA-F-]{36})', 1, message)
| where isnotempty(CorrelationId)
| extend EventType = case(
    message startswith 'Varonis ingestion run failed.', 'failed',
    message startswith 'Completed Varonis ingestion run.', 'completed',
    'started');
runLogs
| summarize LastTimestamp=max(timestamp), FailureCount=countif(EventType == 'failed'), SuccessCount=countif(EventType == 'completed') by CorrelationId
| extend Outcome = case(FailureCount > 0, 'failed', SuccessCount > 0, 'completed', 'incomplete')
| order by LastTimestamp desc
| take 3
| project LastTimestamp, CorrelationId, Outcome
"@

    try {
        $consecutiveRows = Invoke-AppInsightsQuery `
            -AppIdentifier $appInsightsIdentifier `
            -ResourceGroup $appInsightsResourceGroup `
            -QueryText $consecutiveRunsQuery `
            -SubscriptionArgs $subscriptionScopeArgs

        $recentRuns = @($consecutiveRows)
        $threeRunsFound = ($recentRuns.Count -ge 3)
        $allCompleted = $false
        if ($threeRunsFound) {
            $allCompleted = (@($recentRuns | Where-Object { $_[2] -eq "completed" }).Count -eq 3)
        }

        if ($threeRunsFound -and $allCompleted) {
            Add-Check -Name "ThreeConsecutiveScheduledRuns" -Status "Pass" -Details "Last 3 correlated runs completed successfully"
        }
        elseif (-not $threeRunsFound) {
            Add-Check -Name "ThreeConsecutiveScheduledRuns" -Status "Fail" -Details "Only $($recentRuns.Count) correlated run(s) found in last $RunSuccessLookbackMinutes minute(s)"
        }
        else {
            $outcomes = ($recentRuns | ForEach-Object { "$($_[1])=$($_[2])" }) -join "; "
            Add-Check -Name "ThreeConsecutiveScheduledRuns" -Status "Fail" -Details "Last 3 runs were not all successful: $outcomes"
        }
    }
    catch {
        Add-Check -Name "ThreeConsecutiveScheduledRuns" -Status $statusWhenQueryFails -Details "Failed validating consecutive runs. $($_.Exception.Message)"
    }
}

if ([string]::IsNullOrWhiteSpace($WorkspaceResourceId) -or [string]::IsNullOrWhiteSpace($LogTableName)) {
    $status = if ($StrictStartupValidation) { "Fail" } else { "Warn" }
    Add-Check -Name "RecentTableRows" -Status $status -Details "WorkspaceResourceId or LogTableName missing; cannot validate recent table volume."
}
else {
    try {
        $workspaceCustomerId = Invoke-AzTsv -Arguments (@("monitor", "log-analytics", "workspace", "show") + $subscriptionScopeArgs + @(
                "--ids", $WorkspaceResourceId,
                "--query", "customerId"
            ))

        if ([string]::IsNullOrWhiteSpace($workspaceCustomerId)) {
            Add-Check -Name "RecentTableRows" -Status "Fail" -Details "Unable to resolve workspace customerId from $WorkspaceResourceId"
        }
        else {
            $tableQuery = @"
$LogTableName
| where TimeGenerated > ago($([Math]::Abs($RecentRowsWindowMinutes))m)
| extend AlertKey = coalesce(tostring(AlertId), tostring(AlertId_s), tostring(['Alert.ID']))
| summarize Records=count(), DistinctAlerts=dcount(AlertKey), Latest=max(TimeGenerated)
"@

            $tableRaw = az monitor log-analytics query `
                @subscriptionScopeArgs `
                --workspace $workspaceCustomerId `
                --analytics-query $tableQuery `
                --timespan P1D `
                --output json `
                --only-show-errors

            if ($LASTEXITCODE -ne 0) {
                throw "Log Analytics query failed."
            }

            $tableResult = $tableRaw | ConvertFrom-Json

            $tableRows = @()
            if ($null -ne $tableResult.tables -and $tableResult.tables.Count -gt 0) {
                $tableRows = @($tableResult.tables[0].rows)
            }

            $records = 0
            $distinctAlerts = 0
            $latest = ""
            if ($tableRows.Count -gt 0) {
                $records = [int]$tableRows[0][0]
                $distinctAlerts = [int]$tableRows[0][1]
                $latest = "$($tableRows[0][2])"
            }

            if ($records -lt $MinRecentRows) {
                Add-Check -Name "RecentTableRows" -Status "Fail" -Details "Records=$records, DistinctAlerts=$distinctAlerts in last $RecentRowsWindowMinutes minute(s) for $LogTableName (minimum expected $MinRecentRows)"
            }
            else {
                Add-Check -Name "RecentTableRows" -Status "Pass" -Details "Records=$records, DistinctAlerts=$distinctAlerts, Latest=$latest"
            }
        }
    }
    catch {
        $status = if ($StrictStartupValidation) { "Fail" } else { "Warn" }
        Add-Check -Name "RecentTableRows" -Status $status -Details "Failed querying Log Analytics table volume. $($_.Exception.Message)"
    }
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
