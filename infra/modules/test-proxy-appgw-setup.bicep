// ============================================================================
// Test Infrastructure – Proxy (ACI/Nginx) → App Gateway → App Service
// ============================================================================
// Deploys a minimal environment to test the XFF flow when a proxy/VIP sits
// in front of Application Gateway. Uses Azure Container Instances (ACI) for
// the Nginx proxy — no VM quota required.
//
// Components:
//   1. VNet with subnets (appgw, backend integration)
//   2. ACI container running Nginx as the Proxy (VIP) with public IP
//   3. Application Gateway v2 with XFF rewrite rule
//   4. App Service (Linux, .NET 8) with VNet integration
//   5. Log Analytics workspace + diagnostic settings
//
// Usage:
//   az deployment group create \
//     --resource-group rg-xff-test \
//     --template-file infra/modules/test-proxy-appgw-setup.bicep \
//     --name xff-test-deploy
// ============================================================================

targetScope = 'resourceGroup'

@description('Azure region for all resources.')
param location string = resourceGroup().location

@description('Unique suffix for globally unique resource names.')
param uniqueSuffix string = uniqueString(resourceGroup().id)

@description('App Service plan SKU.')
param appServiceSkuName string = 'F1'

// ── VNet & Subnets ─────────────────────────────────────────────────────────

resource vnet 'Microsoft.Network/virtualNetworks@2023-11-01' = {
  name: 'vnet-xff-test-${uniqueSuffix}'
  location: location
  properties: {
    addressSpace: {
      addressPrefixes: ['10.1.0.0/16']
    }
    subnets: [
      {
        name: 'snet-appgw'
        properties: {
          addressPrefix: '10.1.2.0/24'
        }
      }
    ]
  }
}

// ── Log Analytics Workspace ─────────────────────────────────────────────────

resource logAnalytics 'Microsoft.OperationalInsights/workspaces@2023-09-01' = {
  name: 'log-xff-test-${uniqueSuffix}'
  location: location
  properties: {
    sku: { name: 'PerGB2018' }
    retentionInDays: 30
  }
}

// ── Application Insights ────────────────────────────────────────────────────

resource appInsights 'Microsoft.Insights/components@2020-02-02' = {
  name: 'ai-xff-test-${uniqueSuffix}'
  location: location
  kind: 'web'
  properties: {
    Application_Type: 'web'
    WorkspaceResourceId: logAnalytics.id
  }
}

// ── App Service ─────────────────────────────────────────────────────────────

resource appServicePlan 'Microsoft.Web/serverfarms@2023-12-01' = {
  name: 'plan-xff-test-${uniqueSuffix}'
  location: location
  kind: 'linux'
  sku: { name: appServiceSkuName }
  properties: {
    reserved: true
  }
}

resource appService 'Microsoft.Web/sites@2023-12-01' = {
  name: 'app-xff-test-${uniqueSuffix}'
  location: location
  properties: {
    serverFarmId: appServicePlan.id
    siteConfig: {
      linuxFxVersion: 'DOTNETCORE|8.0'
      alwaysOn: false
      appSettings: [
        {
          name: 'APPLICATIONINSIGHTS_CONNECTION_STRING'
          value: appInsights.properties.ConnectionString
        }
        {
          name: 'ASPNETCORE_FORWARDEDHEADERS_ENABLED'
          value: 'true'
        }
      ]
    }
    httpsOnly: true
  }
}

resource appServiceDiag 'Microsoft.Insights/diagnosticSettings@2021-05-01-preview' = {
  name: 'xff-diag-appsvc'
  scope: appService
  properties: {
    workspaceId: logAnalytics.id
    logs: [
      {
        category: 'AppServiceHTTPLogs'
        enabled: true
      }
      {
        category: 'AppServiceConsoleLogs'
        enabled: true
      }
      {
        category: 'AppServiceAppLogs'
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

// ── Application Gateway v2 ─────────────────────────────────────────────────

resource appGwPip 'Microsoft.Network/publicIPAddresses@2023-11-01' = {
  name: 'pip-appgw-${uniqueSuffix}'
  location: location
  sku: { name: 'Standard' }
  properties: {
    publicIPAllocationMethod: 'Static'
    dnsSettings: {
      domainNameLabel: 'appgw-xff-${uniqueSuffix}'
    }
  }
}

var appGwName = 'appgw-xff-test-${uniqueSuffix}'

resource appGateway 'Microsoft.Network/applicationGateways@2023-11-01' = {
  name: appGwName
  location: location
  properties: {
    sku: {
      name: 'Basic'
      tier: 'Basic'
      capacity: 1
    }
    gatewayIPConfigurations: [
      {
        name: 'appGwIpConfig'
        properties: {
          subnet: { id: vnet.properties.subnets[0].id }
        }
      }
    ]
    frontendIPConfigurations: [
      {
        name: 'appGwFrontendIp'
        properties: {
          publicIPAddress: { id: appGwPip.id }
        }
      }
    ]
    frontendPorts: [
      {
        name: 'port-80'
        properties: { port: 80 }
      }
    ]
    backendAddressPools: [
      {
        name: 'backend-pool'
        properties: {
          backendAddresses: [
            { fqdn: appService.properties.defaultHostName }
          ]
        }
      }
    ]
    backendHttpSettingsCollection: [
      {
        name: 'http-settings'
        properties: {
          port: 443
          protocol: 'Https'
          cookieBasedAffinity: 'Disabled'
          pickHostNameFromBackendAddress: true
          requestTimeout: 30
        }
      }
    ]
    httpListeners: [
      {
        name: 'http-listener'
        properties: {
          frontendIPConfiguration: {
            id: resourceId('Microsoft.Network/applicationGateways/frontendIPConfigurations', appGwName, 'appGwFrontendIp')
          }
          frontendPort: {
            id: resourceId('Microsoft.Network/applicationGateways/frontendPorts', appGwName, 'port-80')
          }
          protocol: 'Http'
        }
      }
    ]
    rewriteRuleSets: [
      {
        name: 'xff-normalization-ruleset'
        properties: {
          rewriteRules: [
            {
              name: 'Normalize-XFF'
              ruleSequence: 100
              conditions: []
              actionSet: {
                requestHeaderConfigurations: [
                  {
                    headerName: 'X-Forwarded-For'
                    headerValue: '{var_add_x_forwarded_for_proxy}'
                  }
                ]
                responseHeaderConfigurations: []
              }
            }
          ]
        }
      }
    ]
    requestRoutingRules: [
      {
        name: 'routing-rule'
        properties: {
          priority: 100
          ruleType: 'Basic'
          httpListener: {
            id: resourceId('Microsoft.Network/applicationGateways/httpListeners', appGwName, 'http-listener')
          }
          backendAddressPool: {
            id: resourceId('Microsoft.Network/applicationGateways/backendAddressPools', appGwName, 'backend-pool')
          }
          backendHttpSettings: {
            id: resourceId('Microsoft.Network/applicationGateways/backendHttpSettingsCollection', appGwName, 'http-settings')
          }
          rewriteRuleSet: {
            id: resourceId('Microsoft.Network/applicationGateways/rewriteRuleSets', appGwName, 'xff-normalization-ruleset')
          }
        }
      }
    ]
  }
}

resource appGwDiag 'Microsoft.Insights/diagnosticSettings@2021-05-01-preview' = {
  name: 'xff-diag-appgw'
  scope: appGateway
  properties: {
    workspaceId: logAnalytics.id
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

// ── Nginx Proxy via Azure Container Instances (ACI) ─────────────────────────
// ACI with public IP simulates the Proxy (VIP) in front of App Gateway.
// No VM quota required. Nginx config forwards to App Gateway public IP
// and correctly sets X-Forwarded-For.

// Build the nginx config with the resolved App GW DNS name
var appGwFqdn = appGwPip.properties.dnsSettings.fqdn
var nginxConfigTemplate = '''server {
    listen 80 default_server;
    server_name _;

    access_log /dev/stdout;
    error_log  /dev/stderr warn;

    resolver 168.63.129.16 valid=30s;
    set $backend "BACKEND_PLACEHOLDER";

    location / {
        proxy_pass http://$backend:80;
        proxy_set_header X-Forwarded-For    $proxy_add_x_forwarded_for;
        proxy_set_header X-Real-IP          $remote_addr;
        proxy_set_header X-Forwarded-Proto  $scheme;
        proxy_set_header X-Forwarded-Host   $host;
        proxy_set_header Host               $host;
        proxy_connect_timeout 10s;
        proxy_send_timeout    30s;
        proxy_read_timeout    30s;
    }

    location /nginx-health {
        return 200 '{"status":"ok","role":"xff-proxy"}';
        add_header Content-Type application/json;
    }
}'''

var nginxConfigResolved = replace(nginxConfigTemplate, 'BACKEND_PLACEHOLDER', appGwFqdn)

resource nginxProxy 'Microsoft.ContainerInstance/containerGroups@2023-05-01' = {
  name: 'aci-proxy-${uniqueSuffix}'
  location: location
  properties: {
    osType: 'Linux'
    restartPolicy: 'Always'
    ipAddress: {
      type: 'Public'
      ports: [
        { port: 80, protocol: 'TCP' }
      ]
    }
    containers: [
      {
        name: 'nginx-proxy'
        properties: {
          image: 'nginx:alpine'
          ports: [
            { port: 80, protocol: 'TCP' }
          ]
          resources: {
            requests: {
              cpu: 1
              memoryInGB: json('1.5')
            }
          }
          volumeMounts: [
            {
              name: 'nginx-conf'
              mountPath: '/etc/nginx/conf.d'
              readOnly: true
            }
          ]
        }
      }
    ]
    volumes: [
      {
        name: 'nginx-conf'
        secret: {
          'default.conf': base64(nginxConfigResolved)
        }
      }
    ]
  }
  dependsOn: [appGateway]
}

// ── Outputs ─────────────────────────────────────────────────────────────────

output proxyPublicIp string = nginxProxy.properties.ipAddress.ip
output appGatewayPublicIp string = appGwPip.properties.ipAddress
output appGatewayFqdn string = appGwFqdn
output appServiceDefaultHostName string = appService.properties.defaultHostName
output appServiceName string = appService.name
output logAnalyticsWorkspaceName string = logAnalytics.name
output logAnalyticsWorkspaceId string = logAnalytics.id
output appInsightsName string = appInsights.name
output vnetName string = vnet.name
output appGatewayName string = appGateway.name
output testCommand string = 'Run: .\\Test-XffAppGateway.ps1 -ProxyIp "${nginxProxy.properties.ipAddress.ip}" -AppGwIp "${appGwPip.properties.ipAddress}" -AppFqdn "${appService.properties.defaultHostName}"'
