targetScope = 'resourceGroup'

@description('Azure region for deployment.')
param location string = resourceGroup().location

@description('Environment short name such as dev, test, or prod.')
param environmentName string

@description('Naming prefix for all resources.')
param namePrefix string = 'varonis'

@description('Owner contact email used for resource tags.')
param ownerEmail string = 'Lood@buisecops.co.za'

@description('Existing Sentinel-enabled Log Analytics workspace resource ID.')
param workspaceResourceId string

@description('Optional existing Log Analytics workspace resource ID for Application Insights.')
param appInsightsWorkspaceResourceId string = ''

@description('Function timer schedule expression.')
param timerSchedule string = '0 */5 * * * *'

@description('Default WEBSITE_RUN_FROM_PACKAGE value. Keep default to use latest GitHub release package.')
param runFromPackageValue string = 'https://github.com/Lodewyk-Git/AzureFunctionVaronis/releases/latest/download/varonis-sentinel-functions.zip'

@description('Destination custom table name.')
param tableName string = 'VaronisAlerts_CL'

@description('Data stream name used in DCR.')
param streamName string = 'Custom-VaronisAlerts_CL'

@description('Function App hosting plan SKU.')
param functionPlanSkuName string = 'Y1'

@description('Function App hosting plan tier.')
param functionPlanSkuTier string = 'Dynamic'

@description('Enable diagnostic settings.')
param enableDiagnostics bool = true

var tableColumns = [
  {
    name: 'TimeGenerated'
    type: 'datetime'
  }
  {
    name: 'AlertId'
    type: 'string'
  }
  {
    name: 'AlertTimeUtc'
    type: 'datetime'
  }
  {
    name: 'Severity'
    type: 'string'
  }
  {
    name: 'Status'
    type: 'string'
  }
  {
    name: 'ThreatDetectionPolicy'
    type: 'string'
  }
  {
    name: 'Description'
    type: 'string'
  }
  {
    name: 'Actor'
    type: 'string'
  }
  {
    name: 'Asset'
    type: 'string'
  }
  {
    name: 'SourceSystem'
    type: 'string'
  }
  {
    name: 'RawRecord'
    type: 'dynamic'
  }
  {
    name: 'IngestedAtUtc'
    type: 'datetime'
  }
  {
    name: 'CorrelationId'
    type: 'string'
  }
]

module core './modules/core.bicep' = {
  name: 'coreDeployment'
  params: {
    location: location
    environmentName: environmentName
    namePrefix: namePrefix
    ownerEmail: ownerEmail
    workspaceResourceId: workspaceResourceId
    appInsightsWorkspaceResourceId: appInsightsWorkspaceResourceId
    functionPlanSkuName: functionPlanSkuName
    functionPlanSkuTier: functionPlanSkuTier
    timerSchedule: timerSchedule
    runFromPackageValue: runFromPackageValue
    enableDiagnostics: enableDiagnostics
  }
}

module monitoring './modules/monitoring.bicep' = {
  name: 'monitoringDeployment'
  params: {
    location: location
    environmentName: environmentName
    namePrefix: namePrefix
    ownerEmail: ownerEmail
    workspaceResourceId: core.outputs.workspaceResourceId
    functionPrincipalId: core.outputs.functionPrincipalId
    tableName: tableName
    streamName: streamName
    tableColumns: tableColumns
  }
}

output functionAppName string = core.outputs.functionAppName
output functionAppResourceId string = core.outputs.functionAppResourceId
output packageStorageAccountName string = core.outputs.packageStorageAccountName
output packageContainerName string = core.outputs.packageContainerName
output keyVaultName string = core.outputs.keyVaultName
output keyVaultUri string = core.outputs.keyVaultUri
output workspaceName string = core.outputs.workspaceName
output workspaceResourceId string = core.outputs.workspaceResourceId
output dcrResourceId string = monitoring.outputs.dcrResourceId
output dcrImmutableId string = monitoring.outputs.dcrImmutableId
output dceResourceId string = monitoring.outputs.dceResourceId
output logsIngestionEndpoint string = monitoring.outputs.logsIngestionEndpoint
output tableOutputName string = monitoring.outputs.tableName
output streamOutputName string = monitoring.outputs.streamName
