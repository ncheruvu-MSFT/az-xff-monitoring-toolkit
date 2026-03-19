// ============================================================================
// Diagnostic Settings – App Gateway, APIM, App Service → Log Analytics
// ============================================================================
// Deploys diagnostic settings on each resource tier so that XFF-related
// telemetry flows to a single Log Analytics workspace.
//
// References:
//   https://learn.microsoft.com/en-us/azure/application-gateway/monitor-application-gateway
//   https://learn.microsoft.com/en-us/azure/api-management/api-management-howto-use-azure-monitor
//   https://learn.microsoft.com/en-us/azure/app-service/troubleshoot-diagnostic-logs
// ============================================================================

// ── Parameters ──────────────────────────────────────────────────────────────

@description('Resource ID of the central Log Analytics workspace.')
param logAnalyticsWorkspaceId string

@description('Name of the existing Application Gateway.')
param appGatewayName string

@description('Name of the existing API Management instance.')
param apimName string

@description('Name of the existing App Service.')
param appServiceName string

@description('Retention in days for diagnostic logs (0 = workspace default).')
param retentionDays int = 90

// ── Existing resources ──────────────────────────────────────────────────────

resource appGateway 'Microsoft.Network/applicationGateways@2023-11-01' existing = {
  name: appGatewayName
}

resource apim 'Microsoft.ApiManagement/service@2023-05-01-preview' existing = {
  name: apimName
}

resource appService 'Microsoft.Web/sites@2023-12-01' existing = {
  name: appServiceName
}

// ── Diagnostic Settings ─────────────────────────────────────────────────────

// App Gateway → AGWAccessLogs + AGWFirewallLogs (resource-specific tables)
resource appGwDiag 'Microsoft.Insights/diagnosticSettings@2021-05-01-preview' = {
  name: 'xff-diag-appgw'
  scope: appGateway
  properties: {
    workspaceId: logAnalyticsWorkspaceId
    logs: [
      {
        categoryGroup: 'allLogs'
        enabled: true
        retentionPolicy: {
          enabled: retentionDays > 0
          days: retentionDays
        }
      }
    ]
    metrics: [
      {
        category: 'AllMetrics'
        enabled: true
        retentionPolicy: {
          enabled: retentionDays > 0
          days: retentionDays
        }
      }
    ]
  }
}

// APIM → GatewayLogs + resource-specific tables
resource apimDiag 'Microsoft.Insights/diagnosticSettings@2021-05-01-preview' = {
  name: 'xff-diag-apim'
  scope: apim
  properties: {
    workspaceId: logAnalyticsWorkspaceId
    logs: [
      {
        categoryGroup: 'allLogs'
        enabled: true
        retentionPolicy: {
          enabled: retentionDays > 0
          days: retentionDays
        }
      }
    ]
    metrics: [
      {
        category: 'AllMetrics'
        enabled: true
        retentionPolicy: {
          enabled: retentionDays > 0
          days: retentionDays
        }
      }
    ]
  }
}

// App Service → AppServiceHTTPLogs + AppServiceConsoleLogs
resource appServiceDiag 'Microsoft.Insights/diagnosticSettings@2021-05-01-preview' = {
  name: 'xff-diag-appsvc'
  scope: appService
  properties: {
    workspaceId: logAnalyticsWorkspaceId
    logs: [
      {
        categoryGroup: 'allLogs'
        enabled: true
        retentionPolicy: {
          enabled: retentionDays > 0
          days: retentionDays
        }
      }
    ]
    metrics: [
      {
        category: 'AllMetrics'
        enabled: true
        retentionPolicy: {
          enabled: retentionDays > 0
          days: retentionDays
        }
      }
    ]
  }
}

// ── Outputs ─────────────────────────────────────────────────────────────────

output appGwDiagId string = appGwDiag.id
output apimDiagId string = apimDiag.id
output appServiceDiagId string = appServiceDiag.id
