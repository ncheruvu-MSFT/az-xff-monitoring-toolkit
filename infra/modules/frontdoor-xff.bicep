// ============================================================================
// Azure Front Door (Standard) — XFF edge in front of the App Service origin
// ============================================================================
// Deploys a Front Door Standard profile that sits in front of the existing
// App Service. Front Door is the outermost edge and the first Azure service
// to see the client's real IP. It appends the client IP to X-Forwarded-For
// and sets X-Azure-ClientIP / X-Azure-SocketIP on every request to the origin.
//
// Access logs (FrontDoorAccessLog) are sent to the central Log Analytics
// workspace so XFF / client-IP telemetry can be queried alongside the other
// tiers (App Gateway, APIM, App Service).
//
// References:
//   https://learn.microsoft.com/en-us/azure/frontdoor/front-door-http-headers-protocol
//   https://learn.microsoft.com/en-us/azure/frontdoor/standard-premium/how-to-logs
// ============================================================================

// ── Parameters ──────────────────────────────────────────────────────────────

@description('Name of the Front Door (Standard) profile.')
param frontDoorProfileName string = 'afd-xff-test'

@description('Name of the Front Door endpoint (becomes <name>-<hash>.azurefd.net).')
param endpointName string = 'ep-xff-test'

@description('Hostname of the origin App Service (e.g. app-xxx.azurewebsites.net).')
param originHostName string

@description('Resource ID of the central Log Analytics workspace.')
param logAnalyticsWorkspaceId string

// ── Front Door profile ──────────────────────────────────────────────────────

resource profile 'Microsoft.Cdn/profiles@2024-02-01' = {
  name: frontDoorProfileName
  location: 'global'
  sku: {
    name: 'Standard_AzureFrontDoor'
  }
}

// ── Endpoint ────────────────────────────────────────────────────────────────

resource endpoint 'Microsoft.Cdn/profiles/afdEndpoints@2024-02-01' = {
  parent: profile
  name: endpointName
  location: 'global'
  properties: {
    enabledState: 'Enabled'
  }
}

// ── Origin group + health probe ─────────────────────────────────────────────

resource originGroup 'Microsoft.Cdn/profiles/originGroups@2024-02-01' = {
  parent: profile
  name: 'og-appservice'
  properties: {
    loadBalancingSettings: {
      sampleSize: 4
      successfulSamplesRequired: 3
      additionalLatencyInMilliseconds: 50
    }
    healthProbeSettings: {
      probePath: '/'
      probeRequestType: 'HEAD'
      probeProtocol: 'Https'
      probeIntervalInSeconds: 100
    }
  }
}

resource origin 'Microsoft.Cdn/profiles/originGroups/origins@2024-02-01' = {
  parent: originGroup
  name: 'origin-appservice'
  properties: {
    hostName: originHostName
    originHostHeader: originHostName
    httpPort: 80
    httpsPort: 443
    priority: 1
    weight: 1000
    enabledState: 'Enabled'
    enforceCertificateNameCheck: true
  }
}

// ── Route (default domain → origin group) ───────────────────────────────────

resource route 'Microsoft.Cdn/profiles/afdEndpoints/routes@2024-02-01' = {
  parent: endpoint
  name: 'route-default'
  dependsOn: [
    origin
  ]
  properties: {
    originGroup: {
      id: originGroup.id
    }
    supportedProtocols: [
      'Http'
      'Https'
    ]
    patternsToMatch: [
      '/*'
    ]
    forwardingProtocol: 'HttpsOnly'
    linkToDefaultDomain: 'Enabled'
    httpsRedirect: 'Enabled'
    enabledState: 'Enabled'
  }
}

// ── Diagnostic settings → Log Analytics ─────────────────────────────────────

resource frontDoorDiag 'Microsoft.Insights/diagnosticSettings@2021-05-01-preview' = {
  name: 'xff-diag-frontdoor'
  scope: profile
  properties: {
    workspaceId: logAnalyticsWorkspaceId
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

// ── Outputs ─────────────────────────────────────────────────────────────────

output frontDoorProfileId string = profile.id
output frontDoorEndpointHostName string = endpoint.properties.hostName
output frontDoorDiagId string = frontDoorDiag.id
