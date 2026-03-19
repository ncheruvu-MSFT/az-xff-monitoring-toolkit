using 'main.bicep'

// ── Fill in your resource names and IDs ─────────────────────────────────────

param appGatewayName = '<your-appgw-name>'
param apimName = '<your-apim-name>'
param appServiceName = '<your-app-service-name>'
param logAnalyticsWorkspaceId = '/subscriptions/<sub-id>/resourceGroups/<rg>/providers/Microsoft.OperationalInsights/workspaces/<ws-name>'
param appInsightsId = '/subscriptions/<sub-id>/resourceGroups/<rg>/providers/Microsoft.Insights/components/<ai-name>'
param appInsightsInstrumentationKey = '<your-instrumentation-key>'
param retentionDays = 90
param apimSamplingPercentage = 100
