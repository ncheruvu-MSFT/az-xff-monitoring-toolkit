// ============================================================================
// Application Gateway – XFF Normalization Rewrite Rule
// ============================================================================
// Deploys a rewrite rule set on App Gateway v2 that normalizes X-Forwarded-For
// by using the server variable `add_x_forwarded_for_proxy` (strips :port).
//
// Reference:
//   https://learn.microsoft.com/en-us/azure/application-gateway/rewrite-http-headers-url
// ============================================================================

@description('Name of the existing Application Gateway (v2).')
param appGatewayName string

@description('Name of the rewrite rule set to create / update.')
param rewriteRuleSetName string = 'xff-normalization-ruleset'

@description('Name of the individual rewrite rule.')
param rewriteRuleName string = 'Normalize-XFF'

@description('Sequence number for the rewrite rule (lower = higher priority).')
param ruleSequence int = 100

// Reference the existing Application Gateway
resource appGateway 'Microsoft.Network/applicationGateways@2023-11-01' existing = {
  name: appGatewayName
}

// Deploy or update the rewrite rule set with XFF normalization
resource rewriteRuleSet 'Microsoft.Network/applicationGateways/rewriteRuleSets@2023-11-01' = {
  name: rewriteRuleSetName
  parent: appGateway
  properties: {
    rewriteRules: [
      {
        name: rewriteRuleName
        ruleSequence: ruleSequence
        conditions: []                       // Apply to all requests
        actionSet: {
          requestHeaderConfigurations: [
            {
              // Normalize XFF: use the server variable that strips :port
              headerName: 'X-Forwarded-For'
              headerValue: '{var_add_x_forwarded_for_proxy}'
            }
          ]
          responseHeaderConfigurations: []
          urlConfiguration: null
        }
      }
    ]
  }
}

output rewriteRuleSetId string = rewriteRuleSet.id
output rewriteRuleSetName string = rewriteRuleSet.name
