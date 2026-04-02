targetScope = 'resourceGroup'

@description('Azure region for all new resources.')
param location string = resourceGroup().location

@description('Environment short name such as dev, test, or prod.')
param environmentName string

@description('Naming prefix for all resources.')
param namePrefix string = 'varonis'

@description('Owner contact email used for resource tags.')
param ownerEmail string = 'Lood@buisecops.co.za'

@description('Existing Sentinel-enabled Log Analytics workspace resource ID.')
param workspaceResourceId string

@description('Optional existing Log Analytics workspace resource ID used for Application Insights linkage. Defaults to workspaceResourceId.')
param appInsightsWorkspaceResourceId string = ''

@description('Function App hosting SKU. Y1 = Consumption.')
param functionPlanSkuName string = 'Y1'

@description('Function App hosting tier.')
param functionPlanSkuTier string = 'Dynamic'

@description('Function timer schedule.')
param timerSchedule string = '0 */5 * * * *'

@description('Default WEBSITE_RUN_FROM_PACKAGE value. Set to a release package URL or use 1 for zipdeploy.')
param runFromPackageValue string = 'https://github.com/Lodewyk-Git/AzureFunctionVaronis/releases/latest/download/varonis-sentinel-functions.zip'

@description('The Key Vault secret name containing the Varonis API key.')
param varonisApiKeySecretName string = 'VaronisApiKey'

@description('Enable diagnostic settings for core resources.')
param enableDiagnostics bool = true

@description('Key Vault Secrets User role definition ID.')
param keyVaultSecretsUserRoleDefinitionId string = '4633458b-17de-408a-b874-0445c86b69e6'

var normalizedPrefix = toLower(replace(namePrefix, '-', ''))
var normalizedEnv = toLower(replace(environmentName, '-', ''))
var uniqueSuffix = toLower(uniqueString(resourceGroup().id, environmentName, namePrefix))

var functionStorageAccountName = take('${normalizedPrefix}${normalizedEnv}func${uniqueSuffix}', 24)
var packageStorageAccountName = take('${normalizedPrefix}${normalizedEnv}pkg${uniqueSuffix}', 24)
var appServicePlanName = '${namePrefix}-${environmentName}-func-plan'
var functionAppName = take('${namePrefix}-${environmentName}-varonis-func-${uniqueSuffix}', 60)
var keyVaultName = take('${namePrefix}-${environmentName}-kv-${uniqueSuffix}', 24)
var appInsightsName = '${namePrefix}-${environmentName}-appi'
var contentShareName = toLower(take(replace(functionAppName, '-', ''), 63))

var resolvedWorkspaceResourceId = workspaceResourceId
var resolvedWorkspaceName = last(split(workspaceResourceId, '/'))
var resolvedAppInsightsWorkspaceResourceId = empty(appInsightsWorkspaceResourceId) ? resolvedWorkspaceResourceId : appInsightsWorkspaceResourceId

resource functionStorage 'Microsoft.Storage/storageAccounts@2023-05-01' = {
  name: functionStorageAccountName
  location: location
  tags: {
    Environment: environmentName
    Owner: ownerEmail
    Workload: 'AzureFunctionVaronis'
  }
  sku: {
    name: 'Standard_LRS'
  }
  kind: 'StorageV2'
  properties: {
    allowBlobPublicAccess: false
    supportsHttpsTrafficOnly: true
    minimumTlsVersion: 'TLS1_2'
  }
}

resource packageStorage 'Microsoft.Storage/storageAccounts@2023-05-01' = {
  name: packageStorageAccountName
  location: location
  tags: {
    Environment: environmentName
    Owner: ownerEmail
    Workload: 'AzureFunctionVaronis'
  }
  sku: {
    name: 'Standard_LRS'
  }
  kind: 'StorageV2'
  properties: {
    allowBlobPublicAccess: false
    supportsHttpsTrafficOnly: true
    minimumTlsVersion: 'TLS1_2'
  }
}

resource checkpointContainer 'Microsoft.Storage/storageAccounts/blobServices/containers@2023-05-01' = {
  name: '${functionStorage.name}/default/varonis-checkpoints'
  properties: {
    publicAccess: 'None'
  }
}

resource failureContainer 'Microsoft.Storage/storageAccounts/blobServices/containers@2023-05-01' = {
  name: '${functionStorage.name}/default/varonis-failures'
  properties: {
    publicAccess: 'None'
  }
}

resource packageContainer 'Microsoft.Storage/storageAccounts/blobServices/containers@2023-05-01' = {
  name: '${packageStorage.name}/default/function-packages'
  properties: {
    publicAccess: 'None'
  }
}

var functionStorageConnection = 'DefaultEndpointsProtocol=https;AccountName=${functionStorage.name};AccountKey=${listKeys(functionStorage.id, functionStorage.apiVersion).keys[0].value};EndpointSuffix=${environment().suffixes.storage}'

resource appInsights 'Microsoft.Insights/components@2020-02-02' = {
  name: appInsightsName
  location: location
  kind: 'web'
  tags: {
    Environment: environmentName
    Owner: ownerEmail
    Workload: 'AzureFunctionVaronis'
  }
  properties: {
    Application_Type: 'web'
    WorkspaceResourceId: resolvedAppInsightsWorkspaceResourceId
  }
}

resource appServicePlan 'Microsoft.Web/serverfarms@2023-12-01' = {
  name: appServicePlanName
  location: location
  tags: {
    Environment: environmentName
    Owner: ownerEmail
    Workload: 'AzureFunctionVaronis'
  }
  sku: {
    name: functionPlanSkuName
    tier: functionPlanSkuTier
  }
  kind: 'functionapp'
  properties: {
    reserved: false
  }
}

resource keyVault 'Microsoft.KeyVault/vaults@2023-07-01' = {
  name: keyVaultName
  location: location
  tags: {
    Environment: environmentName
    Owner: ownerEmail
    Workload: 'AzureFunctionVaronis'
  }
  properties: {
    tenantId: tenant().tenantId
    sku: {
      name: 'standard'
      family: 'A'
    }
    enableRbacAuthorization: true
    enablePurgeProtection: true
    softDeleteRetentionInDays: 90
    publicNetworkAccess: 'Enabled'
    networkAcls: {
      defaultAction: 'Allow'
      bypass: 'AzureServices'
    }
  }
}

resource functionApp 'Microsoft.Web/sites@2023-12-01' = {
  name: functionAppName
  location: location
  kind: 'functionapp'
  tags: {
    Environment: environmentName
    Owner: ownerEmail
    Workload: 'AzureFunctionVaronis'
  }
  identity: {
    type: 'SystemAssigned'
  }
  properties: {
    serverFarmId: appServicePlan.id
    httpsOnly: true
    clientAffinityEnabled: false
    siteConfig: {
      alwaysOn: false
      minTlsVersion: '1.2'
      ftpsState: 'Disabled'
      appSettings: [
        {
          name: 'FUNCTIONS_WORKER_RUNTIME'
          value: 'dotnet-isolated'
        }
        {
          name: 'FUNCTIONS_EXTENSION_VERSION'
          value: '~4'
        }
        {
          name: 'AzureWebJobsStorage'
          value: functionStorageConnection
        }
        {
          name: 'WEBSITE_CONTENTAZUREFILECONNECTIONSTRING'
          value: functionStorageConnection
        }
        {
          name: 'WEBSITE_CONTENTSHARE'
          value: contentShareName
        }
        {
          name: 'WEBSITE_RUN_FROM_PACKAGE'
          value: runFromPackageValue
        }
        {
          name: 'APPINSIGHTS_CONNECTION_STRING'
          value: appInsights.properties.ConnectionString
        }
        {
          name: 'APPLICATIONINSIGHTS_CONNECTION_STRING'
          value: appInsights.properties.ConnectionString
        }
        {
          name: 'TimerSchedule'
          value: timerSchedule
        }
        {
          name: 'Checkpoint__ContainerName'
          value: 'varonis-checkpoints'
        }
        {
          name: 'Checkpoint__BlobName'
          value: 'varonis-alerts-checkpoint.json'
        }
        {
          name: 'Checkpoint__InitialLookback'
          value: '14.00:00:00'
        }
        {
          name: 'FailureStore__ContainerName'
          value: 'varonis-failures'
        }
        {
          name: 'Varonis__ApiKey'
          value: '@Microsoft.KeyVault(SecretUri=${keyVault.properties.vaultUri}secrets/${varonisApiKeySecretName}/)'
        }
        {
          name: 'Varonis__ApiKeySecretName'
          value: varonisApiKeySecretName
        }
        {
          name: 'KeyVault__VaultUri'
          value: keyVault.properties.vaultUri
        }
      ]
    }
  }
}

resource keyVaultSecretsUserAssignment 'Microsoft.Authorization/roleAssignments@2022-04-01' = {
  name: guid(keyVault.id, functionApp.name, keyVaultSecretsUserRoleDefinitionId)
  scope: keyVault
  properties: {
    roleDefinitionId: subscriptionResourceId('Microsoft.Authorization/roleDefinitions', keyVaultSecretsUserRoleDefinitionId)
    principalId: functionApp.identity.principalId
    principalType: 'ServicePrincipal'
  }
}

resource functionDiagnostics 'Microsoft.Insights/diagnosticSettings@2021-05-01-preview' = if (enableDiagnostics) {
  name: 'send-to-workspace'
  scope: functionApp
  properties: {
    workspaceId: resolvedWorkspaceResourceId
    logs: [
      {
        categoryGroup: 'allLogs'
        enabled: true
      }
    ]
    metrics: [
      {
        category: 'AllMetrics'
        enabled: true
      }
    ]
  }
}

output functionAppName string = functionApp.name
output functionPrincipalId string = functionApp.identity.principalId
output functionAppResourceId string = functionApp.id
output functionStorageAccountName string = functionStorage.name
output packageStorageAccountName string = packageStorage.name
output packageContainerName string = 'function-packages'
output keyVaultName string = keyVault.name
output keyVaultUri string = keyVault.properties.vaultUri
output workspaceName string = resolvedWorkspaceName
output workspaceResourceId string = resolvedWorkspaceResourceId
output appInsightsName string = appInsights.name
