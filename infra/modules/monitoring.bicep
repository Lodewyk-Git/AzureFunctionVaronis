targetScope = 'resourceGroup'

@description('Azure region for monitoring resources.')
param location string = resourceGroup().location

@description('Environment short name such as dev, test, or prod.')
param environmentName string

@description('Naming prefix for monitoring resources.')
param namePrefix string = 'varonis'

@description('Owner contact email used for resource tags.')
param ownerEmail string = 'Lood@buisecops.co.za'

@description('Target Log Analytics workspace resource ID.')
param workspaceResourceId string

@description('Function App managed identity principal ID.')
param functionPrincipalId string

@description('Destination custom log table name.')
param tableName string = 'VaronisAlerts_CL'

@description('Log stream name used in DCR declarations.')
param streamName string = 'Custom-VaronisAlerts_CL'

@description('Custom table columns to enforce.')
param tableColumns array = [
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

@description('Table retention in days.')
param tableRetentionInDays int = 30

@description('Table total retention in days.')
param tableTotalRetentionInDays int = 90

@description('Create Data Collection Endpoint. Keep true for stable Logs Ingestion endpoint behavior.')
param createDataCollectionEndpoint bool = true

@description('Data Collection Rule Data Sender role definition ID. Defaults to Monitoring Metrics Publisher.')
param dcrDataSenderRoleDefinitionId string = '3913510d-42f4-4e42-8a64-420c390055eb'

var uniqueSuffix = toLower(uniqueString(resourceGroup().id, environmentName, tableName))

var workspaceName = last(split(workspaceResourceId, '/'))
var workspaceSubscriptionId = split(workspaceResourceId, '/')[2]
var workspaceResourceGroupName = split(workspaceResourceId, '/')[4]

var dceName = take('${namePrefix}-${environmentName}-dce-${uniqueSuffix}', 60)
var dcrName = take('${namePrefix}-${environmentName}-dcr-${uniqueSuffix}', 60)

resource workspace 'Microsoft.OperationalInsights/workspaces@2023-09-01' existing = {
  scope: resourceGroup(workspaceSubscriptionId, workspaceResourceGroupName)
  name: workspaceName
}

resource table 'Microsoft.OperationalInsights/workspaces/tables@2023-09-01' = {
  name: '${workspace.name}/${tableName}'
  properties: {
    plan: 'Analytics'
    retentionInDays: tableRetentionInDays
    totalRetentionInDays: tableTotalRetentionInDays
    schema: {
      name: tableName
      columns: tableColumns
    }
  }
}

resource dataCollectionEndpoint 'Microsoft.Insights/dataCollectionEndpoints@2023-03-11' = if (createDataCollectionEndpoint) {
  name: dceName
  location: location
  kind: 'Linux'
  tags: {
    Environment: environmentName
    Owner: ownerEmail
    Workload: 'AzureFunctionVaronis'
  }
  properties: {
    networkAcls: {
      publicNetworkAccess: 'Enabled'
    }
  }
}

resource dataCollectionRule 'Microsoft.Insights/dataCollectionRules@2023-03-11' = {
  name: dcrName
  location: location
  kind: 'Direct'
  tags: {
    Environment: environmentName
    Owner: ownerEmail
    Workload: 'AzureFunctionVaronis'
  }
  properties: {
    dataCollectionEndpointId: createDataCollectionEndpoint ? dataCollectionEndpoint.id : null
    streamDeclarations: {
      '${streamName}': {
        columns: tableColumns
      }
    }
    destinations: {
      logAnalytics: [
        {
          name: 'logAnalyticsDestination'
          workspaceResourceId: workspaceResourceId
        }
      ]
    }
    dataFlows: [
      {
        streams: [
          streamName
        ]
        destinations: [
          'logAnalyticsDestination'
        ]
        transformKql: 'source'
        outputStream: streamName
      }
    ]
  }
  dependsOn: [
    table
  ]
}

resource dcrDataSenderAssignment 'Microsoft.Authorization/roleAssignments@2022-04-01' = {
  name: guid(dataCollectionRule.id, functionPrincipalId, dcrDataSenderRoleDefinitionId)
  scope: dataCollectionRule
  properties: {
    roleDefinitionId: subscriptionResourceId('Microsoft.Authorization/roleDefinitions', dcrDataSenderRoleDefinitionId)
    principalId: functionPrincipalId
    principalType: 'ServicePrincipal'
  }
}

output tableName string = tableName
output streamName string = streamName
output dcrResourceId string = dataCollectionRule.id
output dcrImmutableId string = dataCollectionRule.properties.immutableId
output dceResourceId string = createDataCollectionEndpoint ? dataCollectionEndpoint.id : ''
output logsIngestionEndpoint string = createDataCollectionEndpoint ? reference(dataCollectionEndpoint.id, '2023-03-11', 'full').properties.logsIngestion.endpoint : ''
