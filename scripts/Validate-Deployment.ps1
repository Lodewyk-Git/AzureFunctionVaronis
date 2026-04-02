[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)]
    [string]$ResourceGroupName,

    [Parameter(Mandatory = $true)]
    [string]$FunctionAppName,

    [Parameter(Mandatory = $true)]
    [string]$WorkspaceResourceId,

    [Parameter(Mandatory = $true)]
    [string]$TableName,

    [Parameter(Mandatory = $true)]
    [string]$DcrResourceId,

    [Parameter(Mandatory = $true)]
    [string]$LogsIngestionEndpoint,

    [switch]$TriggerFunction
)

$ErrorActionPreference = "Stop"

$functionState = az functionapp show `
    --resource-group $ResourceGroupName `
    --name $FunctionAppName `
    --query "{state:state,defaultHostName:defaultHostName,kind:kind}" `
    --output json `
    --only-show-errors | ConvertFrom-Json

$hostStatus = $null
$invokeStatus = $null
$masterKey = az functionapp keys list `
    --resource-group $ResourceGroupName `
    --name $FunctionAppName `
    --query "masterKey" `
    --output tsv `
    --only-show-errors

if (-not [string]::IsNullOrWhiteSpace($masterKey)) {
    $hostStatusUri = "https://$($functionState.defaultHostName)/admin/host/status"
    $headers = @{
        "x-functions-key" = $masterKey
    }

    try {
        $hostStatus = Invoke-RestMethod -Uri $hostStatusUri -Headers $headers -Method Get -TimeoutSec 30
    }
    catch {
        $hostStatus = [pscustomobject]@{
            error = $_.Exception.Message
        }
    }

    if ($TriggerFunction) {
        $invokeUri = "https://$($functionState.defaultHostName)/admin/functions/VaronisAlertTimerFunction"
        try {
            Invoke-RestMethod -Uri $invokeUri -Headers $headers -Method Post -Body "{}" -ContentType "application/json" -TimeoutSec 60 | Out-Null
            $invokeStatus = "Triggered"
        }
        catch {
            $invokeStatus = "TriggerFailed: $($_.Exception.Message)"
        }
    }
}

$workspaceCustomerId = az monitor log-analytics workspace show `
    --ids $WorkspaceResourceId `
    --query "customerId" `
    --output tsv `
    --only-show-errors

$ingestionQuery = @"
$TableName
| where TimeGenerated > ago(60m)
| summarize Records=count(), Latest=max(TimeGenerated)
"@

$queryResult = $null
$queryError = $null
try {
    $queryRaw = az monitor log-analytics query `
        --workspace $workspaceCustomerId `
        --analytics-query $ingestionQuery `
        --timespan P1D `
        --output json `
        --only-show-errors 2>$null

    if ($LASTEXITCODE -eq 0 -and -not [string]::IsNullOrWhiteSpace($queryRaw)) {
        $queryResult = $queryRaw | ConvertFrom-Json
    }
    else {
        $queryError = "Unable to run az monitor log-analytics query in this shell context."
    }
}
catch {
    $queryError = $_.Exception.Message
}

$dcr = az resource show `
    --ids $DcrResourceId `
    --api-version 2023-03-11 `
    --output json `
    --only-show-errors | ConvertFrom-Json

$dcrStreams = @($dcr.properties.dataFlows[0].streams)

[pscustomobject]@{
    FunctionState = $functionState
    HostStatus = $hostStatus
    FunctionTriggered = $invokeStatus
    WorkspaceCustomerId = $workspaceCustomerId
    TableQuery = $queryResult
    TableQueryError = $queryError
    DcrStreamCount = $dcrStreams.Count
    DcrStreams = $dcrStreams
    LogsIngestionEndpoint = $LogsIngestionEndpoint
}
