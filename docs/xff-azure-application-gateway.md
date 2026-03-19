# XFF Monitoring — Azure Application Gateway

Azure Application Gateway (v2) is a Layer-7 load balancer that sits between the edge (Front Door or direct client) and backend services (APIM, App Service, VMs). It **automatically appends** the client's IP to the `X-Forwarded-For` header, but requires configuration to normalize the value and capture it in logs.

## How Application Gateway Handles XFF

### Default Behavior

App Gateway v2 appends the connecting client's IP **with port** to the XFF header:

```
# Client connects directly to App Gateway
X-Forwarded-For: 203.0.113.50:54321

# Client connects via Front Door → App Gateway
X-Forwarded-For: 203.0.113.50, 10.0.1.5:54321
```

The `:port` suffix is non-standard and can break downstream parsers. This is the most common XFF issue with App Gateway.

### Headers Set by App Gateway

| Header | Value | Notes |
|--------|-------|-------|
| `X-Forwarded-For` | `<existing-xff>, <client-ip>:<port>` | Port included by default |
| `X-Forwarded-Proto` | `http` or `https` | Protocol seen by App Gateway |
| `X-Forwarded-Port` | `80` or `443` | Front-end port |

## XFF Normalization with Rewrite Rules

Use a **rewrite rule** with the `{var_add_x_forwarded_for_proxy}` server variable to strip the port from XFF.

### Portal Configuration

1. Navigate to **Application Gateway → Rewrites**
2. Click **+ Rewrite set**
3. Name: `xff-normalization-ruleset`
4. Associate with routing rule(s)
5. Add rule:
   - **Header type:** Request header
   - **Header name:** `X-Forwarded-For`
   - **Header value:** `{var_add_x_forwarded_for_proxy}`

### Bicep (from this repo)

The [appgateway-xff-rewrite.bicep](../infra/modules/appgateway-xff-rewrite.bicep) module automates this:

```bicep
resource rewriteRuleSet 'Microsoft.Network/applicationGateways/rewriteRuleSets@2023-11-01' = {
  name: 'xff-normalization-ruleset'
  parent: appGateway
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
```

> **Important:** After deploying the rewrite rule set, you must **associate it with routing rules** on your App Gateway. The Bicep module creates the rule set but does not auto-associate it.

### Key Server Variables

| Variable | Description |
|----------|-------------|
| `{var_add_x_forwarded_for_proxy}` | XFF chain with port stripped from the last entry |
| `{var_client_ip}` | Direct client IP (without port) |
| `{var_client_port}` | Direct client port |
| `{var_request_uri}` | Full original request URI |

## Configuring Diagnostic Logging

### Step 1: Enable Diagnostic Settings

Send App Gateway logs to a Log Analytics workspace.

**Azure CLI:**

```bash
az monitor diagnostic-settings create \
  --name "xff-diag-appgw" \
  --resource "/subscriptions/<sub-id>/resourceGroups/<rg>/providers/Microsoft.Network/applicationGateways/<appgw-name>" \
  --workspace "/subscriptions/<sub-id>/resourceGroups/<rg>/providers/Microsoft.OperationalInsights/workspaces/<workspace-name>" \
  --logs '[{"categoryGroup":"allLogs","enabled":true}]' \
  --metrics '[{"category":"AllMetrics","enabled":true}]'
```

**Bicep (from this repo):**

The [diagnostic-settings.bicep](../infra/modules/diagnostic-settings.bicep) module deploys diagnostics for App Gateway, APIM, and App Service in one template.

### Step 2: Verify Data Flow

After enabling diagnostics, verify data arrives in the `AGWAccessLogs` table (resource-specific) or `AzureDiagnostics` table (legacy):

```kql
AGWAccessLogs
| where TimeGenerated > ago(1h)
| take 10
```

### Log Tables

| Table | Mode | Key Columns |
|-------|------|-------------|
| `AGWAccessLogs` | Resource-specific (recommended) | `ClientIp`, `Host`, `RequestUri`, `HttpStatusCode`, `UserAgent` |
| `AGWFirewallLogs` | Resource-specific | `ClientIp`, `RequestUri`, `RuleId`, `Action` |
| `AGWPerformanceLogs` | Resource-specific | Latency, connections, throughput |
| `AzureDiagnostics` | Legacy (Azure Diagnostics) | All fields flattened with `_s`/`_d` suffixes |

## KQL Queries

### Traffic Overview

```kql
AGWAccessLogs
| where TimeGenerated > ago(24h)
| project
    TimeGenerated,
    ClientIp,
    Host,
    RequestUri,
    HttpStatusCode,
    ListenerName,
    RuleName,
    ServerRouted,
    UserAgent
| order by TimeGenerated desc
```

### Traffic Volume by Listener (Anomaly Detection)

```kql
AGWAccessLogs
| where TimeGenerated > ago(24h)
| summarize
    RequestCount = count(),
    AvgLatencyMs = avg(TimeTaken)
    by bin(TimeGenerated, 5m), ListenerName, Host
| order by TimeGenerated asc
```

### WAF Blocked Requests

```kql
AGWFirewallLogs
| where TimeGenerated > ago(24h)
| where Action == "Blocked"
| project
    TimeGenerated,
    ClientIp,
    RequestUri,
    RuleId,
    RuleGroup,
    Message,
    Action
| order by TimeGenerated desc
```

### Top Client IPs (Abuse Detection)

```kql
AGWAccessLogs
| where TimeGenerated > ago(24h)
| summarize RequestCount = count() by ClientIp
| top 20 by RequestCount desc
```

### Detect Non-Normalized XFF (Missing Rewrite Rule)

If you see spikes in this query, the rewrite rule is missing or not associated with the correct routing rule:

```kql
requests
| where timestamp > ago(24h)
| extend xff = tostring(customDimensions["Request-Header-x-forwarded-for"])
| where isnotempty(xff) and xff has ":"
| summarize MalformedCount = count() by bin(timestamp, 1h)
| order by timestamp asc
```

## Azure Resource Graph — Audit Rewrite Rules

Audit which App Gateways have the XFF normalization rewrite rule set configured:

```kql
resources
| where type == "microsoft.network/applicationgateways"
| extend rewriteSets = properties.rewriteRuleSets
| extend hasRewrite = isnotempty(rewriteSets)
| project name, resourceGroup, subscriptionId, hasRewrite, rewriteSets
| order by hasRewrite asc
```

## Azure Policy

### Audit Missing XFF Rewrite Rule

The [audit-appgw-xff-rewrite.json](../policies/audit-appgw-xff-rewrite.json) policy flags App Gateways missing the `xff-normalization-ruleset`:

```bash
az policy definition create \
  --name "audit-appgw-xff-rewrite" \
  --display-name "Audit App Gateways missing XFF rewrite rule" \
  --rules policies/audit-appgw-xff-rewrite.json \
  --mode All
```

### Auto-Deploy Diagnostics (DINE)

The [deploy-appgw-diagnostics.json](../policies/deploy-appgw-diagnostics.json) policy automatically deploys diagnostic settings on new App Gateways:

```bash
az policy definition create \
  --name "deploy-appgw-diagnostics" \
  --display-name "Deploy diagnostic settings on App Gateway" \
  --rules policies/deploy-appgw-diagnostics.json \
  --mode All
```

## Microsoft Learn References

- [Application Gateway HTTP headers and rewrite](https://learn.microsoft.com/en-us/azure/application-gateway/rewrite-http-headers-url)
- [Application Gateway server variables](https://learn.microsoft.com/en-us/azure/application-gateway/rewrite-http-headers-url#server-variables)
- [Tutorial: Rewrite HTTP headers with Application Gateway](https://learn.microsoft.com/en-us/azure/application-gateway/rewrite-http-headers-portal)
- [Application Gateway diagnostics and logging](https://learn.microsoft.com/en-us/azure/application-gateway/application-gateway-diagnostics)
- [Monitor Application Gateway](https://learn.microsoft.com/en-us/azure/application-gateway/monitor-application-gateway)
- [AGWAccessLogs table reference](https://learn.microsoft.com/en-us/azure/azure-monitor/reference/tables/agwaccesslogs)
- [Configure WAF on Application Gateway](https://learn.microsoft.com/en-us/azure/web-application-firewall/ag/application-gateway-web-application-firewall-portal)
- [Application Gateway v2 overview](https://learn.microsoft.com/en-us/azure/application-gateway/overview-v2)

## GitHub References

- [Azure/azure-quickstart-templates — Application Gateway](https://github.com/Azure/azure-quickstart-templates/tree/master/quickstarts/microsoft.network) — ARM/Bicep templates
- [Azure/azure-policy](https://github.com/Azure/azure-policy) — Policy definitions for networking resources
- [Azure/application-gateway-kubernetes-ingress](https://github.com/Azure/application-gateway-kubernetes-ingress) — AGIC for AKS with App Gateway
