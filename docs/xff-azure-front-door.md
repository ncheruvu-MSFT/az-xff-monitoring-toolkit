# XFF Monitoring — Azure Front Door

Azure Front Door is typically the outermost edge in an Azure multi-tier architecture. It is the **first Azure service to see the client's real IP** and is therefore the most authoritative source of XFF in the request chain.

## How Front Door Handles XFF

Front Door **automatically appends** the client's IP to the `X-Forwarded-For` header on every request forwarded to the backend origin. If the client sends a pre-existing `X-Forwarded-For` header, Front Door appends the TCP peer IP to the existing chain.

### Headers Set by Front Door

| Header | Value | Trust Level |
|--------|-------|-------------|
| `X-Forwarded-For` | `<existing-xff>, <client-tcp-ip>` | Medium — client can prepend forged IPs |
| `X-Azure-ClientIP` | TCP-level client IP as seen by Front Door | **High** — set by Azure infrastructure |
| `X-Azure-SocketIP` | Socket-level peer IP | **High** — set by Azure infrastructure |
| `X-Forwarded-Host` | Original `Host` header from client | Informational |
| `X-Forwarded-Proto` | Original protocol (`http` or `https`) | Informational |
| `X-Azure-Ref` | Unique request reference for support | Diagnostic |
| `X-Azure-RequestChain` | Request hop tracking | Diagnostic |

> **Key insight:** `X-Azure-ClientIP` is set by Azure Front Door infrastructure at the TCP level and cannot be spoofed by the client. For IP-based security decisions, prefer `X-Azure-ClientIP` over `X-Forwarded-For`.

## Configuring Diagnostic Logging

### Step 1: Enable Diagnostic Settings

Send Front Door access logs to a Log Analytics workspace for XFF analysis.

**Azure CLI:**

```bash
az monitor diagnostic-settings create \
  --name "xff-diag-frontdoor" \
  --resource "/subscriptions/<sub-id>/resourceGroups/<rg>/providers/Microsoft.Cdn/profiles/<afd-name>" \
  --workspace "/subscriptions/<sub-id>/resourceGroups/<rg>/providers/Microsoft.OperationalInsights/workspaces/<workspace-name>" \
  --logs '[{"categoryGroup":"allLogs","enabled":true}]' \
  --metrics '[{"category":"AllMetrics","enabled":true}]'
```

**Bicep:**

```bicep
resource frontDoorDiag 'Microsoft.Insights/diagnosticSettings@2021-05-01-preview' = {
  name: 'xff-diag-frontdoor'
  scope: frontDoorProfile
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
```

### Step 2: Enable WAF Logs (if WAF is configured)

Front Door WAF logs capture per-rule match details including client IP. Enable by including `FrontDoorWebApplicationFirewallLog` in diagnostic settings.

### Step 3: Use Built-in Analytics (Standard/Premium)

Front Door Standard/Premium SKUs include a built-in analytics dashboard:
- Navigate to **Front Door profile → Analytics** in the Azure portal
- View traffic by client IP, geography, status code, and latency

## KQL Queries for Front Door

### Access Log Overview

```kql
AzureDiagnostics
| where ResourceProvider == "MICROSOFT.CDN"
    and Category == "FrontDoorAccessLog"
| where TimeGenerated > ago(24h)
| project
    TimeGenerated,
    clientIp_s,
    socketIp_s,
    httpMethod_s,
    requestUri_s,
    httpStatusCode_d,
    hostName_s,
    timeTaken_d,
    userAgent_s
| order by TimeGenerated desc
```

### XFF Chain Analysis

```kql
AzureDiagnostics
| where ResourceProvider == "MICROSOFT.CDN"
    and Category == "FrontDoorAccessLog"
| where TimeGenerated > ago(24h)
| extend xffChain = column_ifexists("xForwardedFor_s", "")
| where isnotempty(xffChain)
| extend clientFromXff = tostring(split(xffChain, ",")[0])
| project TimeGenerated, clientIp_s, socketIp_s, xffChain, clientFromXff, requestUri_s
| order by TimeGenerated desc
```

### WAF Blocked Requests

```kql
AzureDiagnostics
| where ResourceProvider == "MICROSOFT.CDN"
    and Category == "FrontDoorWebApplicationFirewallLog"
| where TimeGenerated > ago(24h)
| where action_s == "Block"
| project
    TimeGenerated,
    clientIP_s,
    requestUri_s,
    ruleName_s,
    policy_s,
    action_s,
    details_msg_s
| order by TimeGenerated desc
```

### Top Client IPs

```kql
AzureDiagnostics
| where ResourceProvider == "MICROSOFT.CDN"
    and Category == "FrontDoorAccessLog"
| where TimeGenerated > ago(24h)
| summarize RequestCount = count() by clientIp_s
| top 20 by RequestCount desc
```

## WAF IP Restriction — Critical Security Note

When configuring WAF IP match conditions on Front Door:

- **Use `SocketAddr`** (TCP peer IP) for IP restrictions — this is the real TCP connection source and **cannot be spoofed**
- **Do NOT use `RemoteAddr`** for security-critical rules — `RemoteAddr` respects `X-Forwarded-For` and can be spoofed by clients

```
# WAF Custom Rule — correct approach
Match variable: SocketAddr
Operator: IPMatch
Values: <allowed-ip-ranges>
Action: Allow (with default deny)
```

This distinction is critical. Using `RemoteAddr` instead of `SocketAddr` has led to documented bypass vulnerabilities in real-world deployments.

## Azure Policy for Front Door Diagnostics

Ensure all Front Door profiles have diagnostic settings enabled using the built-in policy:

| Policy | ID | Type |
|--------|----|------|
| *Diagnostic logs in Azure Front Door should be enabled* | `cef7eea0-dd51-4067-b8d5-46f5a0111b84` | Built-in |

Custom policy for XFF-specific auditing:

```json
{
  "if": {
    "field": "type",
    "equals": "Microsoft.Cdn/profiles"
  },
  "then": {
    "effect": "AuditIfNotExists",
    "details": {
      "type": "Microsoft.Insights/diagnosticSettings",
      "existenceCondition": {
        "field": "Microsoft.Insights/diagnosticSettings/logs.enabled",
        "equals": "true"
      }
    }
  }
}
```

## Microsoft Learn References

- [Azure Front Door HTTP headers protocol support](https://learn.microsoft.com/en-us/azure/frontdoor/front-door-http-headers-protocol)
- [Azure Front Door diagnostic logs](https://learn.microsoft.com/en-us/azure/frontdoor/front-door-diagnostics)
- [Monitor metrics and logs in Azure Front Door](https://learn.microsoft.com/en-us/azure/frontdoor/front-door-diagnostics)
- [Azure Front Door WAF custom rules](https://learn.microsoft.com/en-us/azure/web-application-firewall/afds/waf-front-door-custom-rules)
- [Configure WAF on Azure Front Door](https://learn.microsoft.com/en-us/azure/web-application-firewall/afds/waf-front-door-create-portal)
- [Azure Front Door rules engine actions](https://learn.microsoft.com/en-us/azure/frontdoor/front-door-rules-engine-actions)
- [Lock down backend access to Azure Front Door only](https://learn.microsoft.com/en-us/azure/frontdoor/front-door-faq#how-do-i-lock-down-the-access-to-my-backend-to-only-azure-front-door-)
- [End-to-end TLS with Azure Front Door](https://learn.microsoft.com/en-us/azure/frontdoor/end-to-end-tls)

## GitHub References

- [Azure/azure-quickstart-templates — Front Door](https://github.com/Azure/azure-quickstart-templates/tree/master/quickstarts/microsoft.cdn) — Bicep/ARM templates for Front Door deployment
- [Azure/azure-policy](https://github.com/Azure/azure-policy) — Built-in and community policy definitions
- [microsoft/Application-Insights-Workbooks](https://github.com/microsoft/Application-Insights-Workbooks) — Workbook templates for Front Door monitoring
