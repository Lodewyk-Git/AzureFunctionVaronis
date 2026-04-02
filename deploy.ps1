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

    [string]$VaronisBaseUrl = "",

    [SecureString]$VaronisApiKey,

    [switch]$RunValidation
)

$scriptPath = Join-Path $PSScriptRoot "scripts/Deploy-Solution.ps1"

& $scriptPath `
    -ResourceGroupName $ResourceGroupName `
    -Location $Location `
    -EnvironmentName $EnvironmentName `
    -NamePrefix $NamePrefix `
    -OwnerEmail $OwnerEmail `
    -WorkspaceResourceId $WorkspaceResourceId `
    -AppInsightsWorkspaceResourceId $AppInsightsWorkspaceResourceId `
    -TableName $TableName `
    -VaronisBaseUrl $VaronisBaseUrl `
    -VaronisApiKey $VaronisApiKey `
    -RunValidation:$RunValidation
