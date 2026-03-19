// ============================================================================
// Main Bicep – XFF Monitoring Infrastructure
// ============================================================================
// Orchestrates deployment of:
//   1. App Gateway XFF rewrite rule normalization
//   2. Diagnostic Settings for App Gateway, APIM, and App Service
//   3. APIM XFF header logging via Application Insights
//
// Usage:
//   az deployment group create \
//     --resource-group <rg-name> \
//     --template-file main.bicep \
//     --parameters main.bicepparam
// ============================================================================

targetScope = 'resourceGroup'

// ── Parameters ──────────────────────────────────────────────────────────────

@description('Name of the existing Application Gateway (v2).')
param appGatewayName string

@description('Name of the existing API Management instance.')
param apimName string

@description('Name of the existing App Service.')
param appServiceName string

@description('Resource ID of the central Log Analytics workspace for all diagnostics.')
param logAnalyticsWorkspaceId string

@description('Resource ID of the Application Insights instance connected to APIM.')
param appInsightsId string

@description('Application Insights instrumentation key.')
@secure()
param appInsightsInstrumentationKey string

@description('Diagnostic log retention in days (0 = workspace default).')
param retentionDays int = 90

@description('APIM diagnostic sampling percentage.')
param apimSamplingPercentage int = 100

// ── Module: App Gateway XFF Rewrite ─────────────────────────────────────────

module appGwXffRewrite 'modules/appgateway-xff-rewrite.bicep' = {
  name: 'deploy-appgw-xff-rewrite'
  params: {
    appGatewayName: appGatewayName
  }
}

// ── Module: Diagnostic Settings (all tiers) ─────────────────────────────────

module diagnosticSettings 'modules/diagnostic-settings.bicep' = {
  name: 'deploy-diagnostic-settings'
  params: {
    logAnalyticsWorkspaceId: logAnalyticsWorkspaceId
    appGatewayName: appGatewayName
    apimName: apimName
    appServiceName: appServiceName
    retentionDays: retentionDays
  }
}

// ── Module: APIM XFF Diagnostics ────────────────────────────────────────────

module apimXffDiag 'modules/apim-xff-diagnostics.bicep' = {
  name: 'deploy-apim-xff-diagnostics'
  params: {
    apimName: apimName
    appInsightsId: appInsightsId
    appInsightsInstrumentationKey: appInsightsInstrumentationKey
    samplingPercentage: apimSamplingPercentage
  }
}

// ── Outputs ─────────────────────────────────────────────────────────────────

output appGwRewriteRuleSetId string = appGwXffRewrite.outputs.rewriteRuleSetId
output appGwDiagId string = diagnosticSettings.outputs.appGwDiagId
output apimDiagId string = diagnosticSettings.outputs.apimDiagId
output appServiceDiagId string = diagnosticSettings.outputs.appServiceDiagId
output apimLoggerId string = apimXffDiag.outputs.loggerId
