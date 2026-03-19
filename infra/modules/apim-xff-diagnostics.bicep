// ============================================================================
// APIM – XFF Header Logging via Diagnostics + Policy
// ============================================================================
// 1. Configures APIM Diagnostics (Application Insights) to capture
//    X-Forwarded-For in frontend/backend request headers.
// 2. Deploys a global policy snippet that ensures XFF propagation.
//
// Reference:
//   https://learn.microsoft.com/en-us/azure/api-management/api-management-howto-use-azure-monitor
//   https://iliaselmatani.codes/posts/apimlog/
// ============================================================================

@description('Name of the existing APIM instance.')
param apimName string

@description('Resource ID of the Application Insights instance connected to APIM.')
param appInsightsId string

@description('Application Insights instrumentation key.')
param appInsightsInstrumentationKey string

@description('Sampling percentage for diagnostics (0-100).')
param samplingPercentage int = 100

// ── Existing APIM ──────────────────────────────────────────────────────────

resource apim 'Microsoft.ApiManagement/service@2023-05-01-preview' existing = {
  name: apimName
}

// ── Logger (Application Insights) ──────────────────────────────────────────

resource aiLogger 'Microsoft.ApiManagement/service/loggers@2023-05-01-preview' = {
  name: 'xff-appinsights-logger'
  parent: apim
  properties: {
    loggerType: 'applicationInsights'
    resourceId: appInsightsId
    credentials: {
      instrumentationKey: appInsightsInstrumentationKey
    }
    isBuffered: true
  }
}

// ── Diagnostics – capture XFF in request headers ───────────────────────────

resource apimDiagnostics 'Microsoft.ApiManagement/service/diagnostics@2023-05-01-preview' = {
  name: 'applicationinsights'
  parent: apim
  properties: {
    alwaysLog: 'allErrors'
    loggerId: aiLogger.id
    sampling: {
      percentage: samplingPercentage
      samplingType: 'fixed'
    }
    frontend: {
      request: {
        headers: [
          'X-Forwarded-For'
          'X-Forwarded-Proto'
          'X-Forwarded-Host'
          'X-Azure-ClientIP'
        ]
        body: {
          bytes: 0
        }
      }
      response: {
        headers: []
        body: {
          bytes: 0
        }
      }
    }
    backend: {
      request: {
        headers: [
          'X-Forwarded-For'
          'X-Forwarded-Proto'
          'X-Forwarded-Host'
        ]
        body: {
          bytes: 0
        }
      }
      response: {
        headers: []
        body: {
          bytes: 0
        }
      }
    }
    httpCorrelationProtocol: 'W3C'
    logClientIp: true
    verbosity: 'information'
  }
}

output loggerId string = aiLogger.id
output diagnosticsId string = apimDiagnostics.id
