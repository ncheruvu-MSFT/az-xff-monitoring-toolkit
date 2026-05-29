// ============================================================================
// Logs Ingestion API — Custom table + DCE + DCR + role assignment
// ============================================================================
// Provisions everything the .NET 4.7 sample needs to ship XFF events to a
// custom Log Analytics table via the Logs Ingestion API using the App
// Service system-assigned managed identity.
//
//   1. Custom table   XffEvents_CL   (typed columns, no JSON blob)
//   2. Data Collection Endpoint (DCE)
//   3. Data Collection Rule (DCR) — direct-ingest stream Custom-XffEvents_CL
//   4. Role assignment — Monitoring Metrics Publisher on DCR for the web
//      app's system-assigned managed identity
//
// After deployment, set these app settings on the web app (handled inline):
//   XFF_DCE_URI            = <dce.logsIngestion.endpoint>
//   XFF_DCR_IMMUTABLE_ID   = <dcr.immutableId>
//   XFF_DCR_STREAM         = Custom-XffEvents_CL
//
// References:
//   https://learn.microsoft.com/azure/azure-monitor/logs/logs-ingestion-api-overview
//   https://learn.microsoft.com/azure/azure-monitor/essentials/data-collection-endpoint-overview
//   https://learn.microsoft.com/azure/azure-monitor/essentials/data-collection-rule-overview
// ============================================================================

// ── Parameters ──────────────────────────────────────────────────────────────

@description('Name of the existing Log Analytics workspace that will own the custom table.')
param logAnalyticsWorkspaceName string

@description('Name of the existing Web App that will write to the DCR via its system-assigned MI.')
param webAppName string

@description('Azure region for the DCE and DCR. Must match the workspace region for direct ingest.')
param location string = resourceGroup().location

@description('Custom table name (must end in _CL).')
param tableName string = 'XffEvents_CL'

@description('Name for the Data Collection Endpoint.')
param dceName string = 'dce-xff-ingest'

@description('Name for the Data Collection Rule.')
param dcrName string = 'dcr-xff-ingest'

@description('Whether to set XFF_DCE_URI / XFF_DCR_IMMUTABLE_ID / XFF_DCR_STREAM app settings on the web app. Set to false if you manage app settings elsewhere.')
param configureAppSettings bool = true

// ── Existing resources ──────────────────────────────────────────────────────

resource workspace 'Microsoft.OperationalInsights/workspaces@2022-10-01' existing = {
  name: logAnalyticsWorkspaceName
}

resource webApp 'Microsoft.Web/sites@2023-12-01' existing = {
  name: webAppName
}

// ── Custom table ────────────────────────────────────────────────────────────
// Plan = Analytics so it is queryable in KQL like any other table.

resource xffTable 'Microsoft.OperationalInsights/workspaces/tables@2022-10-01' = {
  parent: workspace
  name: tableName
  properties: {
    plan: 'Analytics'
    schema: {
      name: tableName
      columns: [
        { name: 'TimeGenerated',    type: 'datetime' }
        { name: 'Path',             type: 'string' }
        { name: 'Method',           type: 'string' }
        { name: 'RemoteAddr',       type: 'string' }
        { name: 'XForwardedFor',    type: 'string' }
        { name: 'XForwardedProto',  type: 'string' }
        { name: 'XForwardedHost',   type: 'string' }
        { name: 'XRealClientIp',    type: 'string' }
        { name: 'XAzureClientIp',   type: 'string' }
        { name: 'XAzureSocketIp',   type: 'string' }
        { name: 'ResolvedClientIp', type: 'string' }
        { name: 'UserAgent',        type: 'string' }
        { name: 'HostHeader',       type: 'string' }
        { name: 'ComputerName',     type: 'string' }
      ]
    }
  }
}

// ── Data Collection Endpoint ────────────────────────────────────────────────

resource dce 'Microsoft.Insights/dataCollectionEndpoints@2023-03-11' = {
  name: dceName
  location: location
  kind: 'Linux'
  properties: {
    networkAcls: {
      publicNetworkAccess: 'Enabled'
    }
  }
}

// ── Data Collection Rule (direct-ingest) ────────────────────────────────────

var streamName = 'Custom-${tableName}'

resource dcr 'Microsoft.Insights/dataCollectionRules@2023-03-11' = {
  name: dcrName
  location: location
  kind: 'Direct'
  properties: {
    dataCollectionEndpointId: dce.id
    streamDeclarations: {
      '${streamName}': {
        columns: [
          { name: 'TimeGenerated',    type: 'datetime' }
          { name: 'Path',             type: 'string' }
          { name: 'Method',           type: 'string' }
          { name: 'RemoteAddr',       type: 'string' }
          { name: 'XForwardedFor',    type: 'string' }
          { name: 'XForwardedProto',  type: 'string' }
          { name: 'XForwardedHost',   type: 'string' }
          { name: 'XRealClientIp',    type: 'string' }
          { name: 'XAzureClientIp',   type: 'string' }
          { name: 'XAzureSocketIp',   type: 'string' }
          { name: 'ResolvedClientIp', type: 'string' }
          { name: 'UserAgent',        type: 'string' }
          { name: 'HostHeader',       type: 'string' }
          { name: 'ComputerName',     type: 'string' }
        ]
      }
    }
    destinations: {
      logAnalytics: [
        {
          name: 'law'
          workspaceResourceId: workspace.id
        }
      ]
    }
    dataFlows: [
      {
        streams: [ streamName ]
        destinations: [ 'law' ]
        outputStream: streamName
      }
    ]
  }
  dependsOn: [
    xffTable
  ]
}

// ── Role assignment: Monitoring Metrics Publisher on DCR for the web app MI ─
// Role definition ID for "Monitoring Metrics Publisher": 3913510d-42f4-4e42-8a64-420c390055eb
// This is the role required for the Logs Ingestion API.

var monitoringMetricsPublisherRoleId = '3913510d-42f4-4e42-8a64-420c390055eb'

resource dcrRoleAssignment 'Microsoft.Authorization/roleAssignments@2022-04-01' = {
  scope: dcr
  name: guid(dcr.id, webApp.id, monitoringMetricsPublisherRoleId)
  properties: {
    principalId: webApp.identity.principalId
    principalType: 'ServicePrincipal'
    roleDefinitionId: subscriptionResourceId('Microsoft.Authorization/roleDefinitions', monitoringMetricsPublisherRoleId)
  }
}

// ── App settings on the web app (merge with existing) ───────────────────────
// Note: this resource replaces ALL app settings on the web app. If you have
// other app settings to preserve, set configureAppSettings=false and configure
// them out-of-band (e.g. in deploy.ps1).

resource webAppSettings 'Microsoft.Web/sites/config@2023-12-01' = if (configureAppSettings) {
  parent: webApp
  name: 'appsettings'
  properties: union(
    list(resourceId('Microsoft.Web/sites/config', webApp.name, 'appsettings'), '2023-12-01').properties,
    {
      XFF_DCE_URI: dce.properties.logsIngestion.endpoint
      XFF_DCR_IMMUTABLE_ID: dcr.properties.immutableId
      XFF_DCR_STREAM: streamName
    }
  )
}

// ── Outputs ─────────────────────────────────────────────────────────────────

output dceEndpoint string = dce.properties.logsIngestion.endpoint
output dcrImmutableId string = dcr.properties.immutableId
output streamName string = streamName
output tableId string = xffTable.id
