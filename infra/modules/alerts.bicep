targetScope = 'resourceGroup'

@description('Azure region for alert rules. Metric alerts are global; scheduled query alerts run in the specified region.')
param location string = resourceGroup().location

@description('Environment short name such as dev, test, or prod.')
param environmentName string

@description('Naming prefix for alert rules.')
param namePrefix string = 'varonis'

@description('Owner contact email used for resource tags.')
param ownerEmail string = 'owner@example.com'

@description('Function App resource ID (used as metric alert scope).')
param functionAppResourceId string

@description('Target Log Analytics workspace resource ID (scheduled query alert scope).')
param workspaceResourceId string

@description('Destination custom log table name. Must match the resolved table name from Invoke-TableLifecycle.ps1.')
param tableName string = 'VaronisAlerts_CL'

@description('Optional Action Group resource ID. If empty, alert rules are created without actions and can be wired up later.')
param actionGroupResourceId string = ''

@description('Disable all alert rules. Set true during bring-up to avoid noise before first successful ingestion.')
param alertsDisabled bool = false

@description('Evaluation window for no-ingestion scheduled query alert (ISO 8601 duration).')
param noIngestionWindow string = 'PT30M'

@description('Evaluation frequency for no-ingestion scheduled query alert (ISO 8601 duration).')
param noIngestionFrequency string = 'PT15M'

@description('Evaluation window for function failure metric alert.')
param failureWindow string = 'PT15M'

@description('Minimum number of failed function executions in the window that triggers the alert.')
param failureThreshold int = 1

var tags = {
  Environment: environmentName
  Owner: ownerEmail
  Workload: 'AzureFunctionVaronis'
}

var noActionGroups = empty(actionGroupResourceId)
var actions = noActionGroups ? [] : [
  {
    actionGroupId: actionGroupResourceId
    webHookProperties: {}
  }
]

// 1. Metric alert: Function App execution failures.
resource functionFailureAlert 'Microsoft.Insights/metricAlerts@2018-03-01' = {
  name: '${namePrefix}-${environmentName}-func-failures'
  location: 'global'
  tags: tags
  properties: {
    description: 'Varonis ingestion function has ${failureThreshold}+ failed executions in the last ${failureWindow}.'
    severity: 2
    enabled: !alertsDisabled
    scopes: [ functionAppResourceId ]
    evaluationFrequency: 'PT5M'
    windowSize: failureWindow
    targetResourceType: 'Microsoft.Web/sites'
    criteria: {
      'odata.type': 'Microsoft.Azure.Monitor.SingleResourceMultipleMetricCriteria'
      allOf: [
        {
          name: 'FunctionFailures'
          metricNamespace: 'Microsoft.Web/sites'
          metricName: 'FunctionExecutionCount'
          operator: 'GreaterThanOrEqual'
          threshold: failureThreshold
          timeAggregation: 'Total'
          criterionType: 'StaticThresholdCriterion'
          dimensions: [
            {
              name: 'Status'
              operator: 'Include'
              values: [ 'Failed' ]
            }
          ]
        }
      ]
    }
    autoMitigate: true
    actions: actions
  }
}

// 2. Scheduled query alert: no ingestion into the custom table.
resource noIngestionAlert 'Microsoft.Insights/scheduledQueryRules@2023-03-15-preview' = {
  name: '${namePrefix}-${environmentName}-no-ingestion'
  location: location
  tags: tags
  properties: {
    description: 'No Varonis alert records landed in ${tableName} during the evaluation window.'
    severity: 2
    enabled: !alertsDisabled
    scopes: [ workspaceResourceId ]
    evaluationFrequency: noIngestionFrequency
    windowSize: noIngestionWindow
    criteria: {
      allOf: [
        {
          query: '${tableName} | summarize Records = count() | where Records == 0'
          timeAggregation: 'Count'
          operator: 'GreaterThanOrEqual'
          threshold: 1
          failingPeriods: {
            numberOfEvaluationPeriods: 1
            minFailingPeriodsToAlert: 1
          }
        }
      ]
    }
    autoMitigate: true
    actions: {
      actionGroups: noActionGroups ? [] : [ actionGroupResourceId ]
      customProperties: {}
    }
  }
}

// 3. Scheduled query alert: DCR pipeline errors observed in the last hour.
resource dcrErrorAlert 'Microsoft.Insights/scheduledQueryRules@2023-03-15-preview' = {
  name: '${namePrefix}-${environmentName}-dcr-errors'
  location: location
  tags: tags
  properties: {
    description: 'DCR pipeline reported ingestion errors for this workspace in the last hour.'
    severity: 2
    enabled: !alertsDisabled
    scopes: [ workspaceResourceId ]
    evaluationFrequency: 'PT15M'
    windowSize: 'PT1H'
    criteria: {
      allOf: [
        {
          query: 'DCRLogErrors | where TimeGenerated > ago(1h) | summarize Errors = count() | where Errors > 0'
          timeAggregation: 'Count'
          operator: 'GreaterThanOrEqual'
          threshold: 1
          failingPeriods: {
            numberOfEvaluationPeriods: 1
            minFailingPeriodsToAlert: 1
          }
        }
      ]
    }
    autoMitigate: true
    actions: {
      actionGroups: noActionGroups ? [] : [ actionGroupResourceId ]
      customProperties: {}
    }
  }
}

output functionFailureAlertId string = functionFailureAlert.id
output noIngestionAlertId string = noIngestionAlert.id
output dcrErrorAlertId string = dcrErrorAlert.id
