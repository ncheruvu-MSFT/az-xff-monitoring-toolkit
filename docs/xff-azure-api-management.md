# XFF Monitoring — Azure API Management (APIM)

Azure API Management sits between ingress (Front Door / Application Gateway) and backend services. APIM **passes through** the `X-Forwarded-For` header from upstream proxies — it does not set or modify XFF by default. XFF logging requires explicit configuration via diagnostics and policies.

## How APIM Handles XFF

### Default Behavior

| Aspect | Behavior |
|--------|----------|
| **Inbound XFF** | Passed through to backend unchanged |
| **`context.Request.IpAddress`** | Returns the immediate TCP peer IP (e.g., App Gateway IP, not the end user) |
| **Outbound XFF** | Included in response unless explicitly stripped |
| **Header logging** | Not logged by default — must be configured in diagnostics |

### Important Distinction

```
context.Request.IpAddress = 10.0.1.5          ← App Gateway IP (TCP peer)
X-Forwarded-For header = 203.0.113.50, 10.0.1.5  ← Client IP chain
```

For the real client IP, you must read the `X-Forwarded-For` header, not `context.Request.IpAddress`.

## Configuring XFF Header Logging

### Option 1: Application Insights Integration

This is the recommended approach for capturing XFF in APIM telemetry.

**Portal steps:**

1. Navigate to **APIM instance → Application Insights**
2. Link your Application Insights instance
3. Under **APIs → (your API) → Settings → Diagnostics**:
   - Select `applicationinsights` logger
   - Under **Additional settings → Headers to log**:
     - Frontend request: `X-Forwarded-For`, `X-Forwarded-Proto`, `X-Forwarded-Host`, `X-Azure-ClientIP`
     - Backend request: `X-Forwarded-For`, `X-Forwarded-Proto`, `X-Forwarded-Host`
   - Set sampling percentage

**Bicep (from this repo):**

The [apim-xff-diagnostics.bicep](../infra/modules/apim-xff-diagnostics.bicep) module configures the AI logger and diagnostic settings:

```bicep
resource apimDiagnostics 'Microsoft.ApiManagement/service/diagnostics@2023-05-01-preview' = {
  name: 'applicationinsights'
  parent: apim
  properties: {
    alwaysLog: 'allErrors'
    loggerId: aiLogger.id
    sampling: {
      percentage: 100
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
      }
    }
    backend: {
      request: {
        headers: [
          'X-Forwarded-For'
          'X-Forwarded-Proto'
          'X-Forwarded-Host'
        ]
      }
    }
    httpCorrelationProtocol: 'W3C'
    logClientIp: true
    verbosity: 'information'
  }
}
```

### Option 2: Log Analytics via Diagnostic Settings

Send `GatewayLogs` directly to Log Analytics. This captures caller IP but requires the `ApiManagementGatewayLogs` table.

**Azure CLI:**

```bash
az monitor diagnostic-settings create \
  --name "xff-diag-apim" \
  --resource "/subscriptions/<sub-id>/resourceGroups/<rg>/providers/Microsoft.ApiManagement/service/<apim-name>" \
  --workspace "/subscriptions/<sub-id>/resourceGroups/<rg>/providers/Microsoft.OperationalInsights/workspaces/<workspace-name>" \
  --logs '[{"categoryGroup":"allLogs","enabled":true}]' \
  --metrics '[{"category":"AllMetrics","enabled":true}]'
```

## APIM Policies for XFF

### Global Policy — XFF Propagation & Logging

The [xff-global-policy.xml](../samples/apim-policy/xff-global-policy.xml) provides a complete global policy:

```xml
<policies>
    <inbound>
        <base />
        <!-- Forward XFF to backend (skip = don't overwrite existing) -->
        <set-header name="X-Forwarded-For" exists-action="skip">
            <value>@(context.Request.IpAddress)</value>
        </set-header>

        <!-- Extract first hop as X-Real-Client-IP (port-stripped) -->
        <set-header name="X-Real-Client-IP" exists-action="override">
            <value>@{
                var xff = context.Request.Headers.GetValueOrDefault("X-Forwarded-For", "");
                if (!string.IsNullOrEmpty(xff))
                {
                    var firstIp = xff.Split(',')[0].Trim();
                    var colonIdx = firstIp.LastIndexOf(':');
                    if (colonIdx > 0 && !firstIp.Contains('['))
                        firstIp = firstIp.Substring(0, colonIdx);
                    return firstIp;
                }
                return context.Request.IpAddress;
            }</value>
        </set-header>

        <!-- Trace for diagnostics -->
        <trace source="xff-policy" severity="information">
            <message>@($"XFF={context.Request.Headers.GetValueOrDefault("X-Forwarded-For", "(none)")}")</message>
        </trace>
    </inbound>

    <outbound>
        <base />
        <!-- Strip internal headers from response -->
        <set-header name="X-Forwarded-For" exists-action="delete" />
        <set-header name="X-Real-Client-IP" exists-action="delete" />
    </outbound>
</policies>
```

### Rate Limiting by Real Client IP

Use XFF-extracted client IP for rate limiting instead of the TCP peer IP:

```xml
<inbound>
    <set-variable name="clientIp" value="@{
        var xff = context.Request.Headers.GetValueOrDefault("X-Forwarded-For", "");
        if (!string.IsNullOrEmpty(xff))
            return xff.Split(',')[0].Trim();
        return context.Request.IpAddress;
    }" />
    <rate-limit-by-key
        calls="100"
        renewal-period="60"
        counter-key="@((string)context.Variables["clientIp"])" />
</inbound>
```

### IP Filtering by XFF

```xml
<inbound>
    <set-variable name="clientIp" value="@{
        var xff = context.Request.Headers.GetValueOrDefault("X-Forwarded-For", "");
        if (!string.IsNullOrEmpty(xff))
            return xff.Split(',')[0].Trim();
        return context.Request.IpAddress;
    }" />
    <choose>
        <when condition="@(!new [] {"203.0.113.0/24","198.51.100.0/24"}.Any(range => /* CIDR check */))">
            <return-response>
                <set-status code="403" reason="Forbidden" />
            </return-response>
        </when>
    </choose>
</inbound>
```

## KQL Queries

### XFF via Application Insights

```kql
requests
| where timestamp > ago(24h)
| extend xff = tostring(customDimensions["Request-Header-x-forwarded-for"])
| where isnotempty(xff)
| project
    timestamp,
    name,
    url,
    resultCode,
    xff,
    client_IP,
    duration
| order by timestamp desc
```

### XFF Presence Rate (Compliance Metric)

```kql
requests
| where timestamp > ago(24h)
| extend xff = tostring(customDimensions["Request-Header-x-forwarded-for"])
| summarize
    TotalRequests = count(),
    WithXFF = countif(isnotempty(xff)),
    WithoutXFF = countif(isempty(xff))
| extend XffPresencePct = round(100.0 * WithXFF / TotalRequests, 2)
```

### XFF via AzureDiagnostics (Alternative)

```kql
ApiManagementGatewayLogs
| where TimeGenerated > ago(24h)
| where isnotempty(RequestHeaders)
| extend headers = parse_json(RequestHeaders)
| extend xff = tostring(headers["X-Forwarded-For"])
| where isnotempty(xff)
| project
    TimeGenerated,
    OperationId,
    ApiId,
    Url,
    ResponseCode,
    xff,
    CallerIpAddress
| order by TimeGenerated desc
```

## Azure Policy

### Audit Missing Diagnostics

The [audit-apim-diagnostics.json](../policies/audit-apim-diagnostics.json) policy flags APIM instances without diagnostic settings:

```bash
az policy definition create \
  --name "audit-apim-diagnostics" \
  --display-name "Audit APIM instances missing diagnostic settings" \
  --rules policies/audit-apim-diagnostics.json \
  --mode All
```

## Microsoft Learn References

- [How to use API Management diagnostic settings with Azure Monitor](https://learn.microsoft.com/en-us/azure/api-management/api-management-howto-use-azure-monitor)
- [APIM policy reference — set-header](https://learn.microsoft.com/en-us/azure/api-management/set-header-policy)
- [Monitor APIs with Azure Application Insights](https://learn.microsoft.com/en-us/azure/api-management/api-management-howto-app-insights)
- [APIM advanced request throttling](https://learn.microsoft.com/en-us/azure/api-management/api-management-sample-flexible-throttling)
- [API Management diagnostics logging reference](https://learn.microsoft.com/en-us/azure/api-management/diagnostic-logs-reference)
- [APIM policy expressions](https://learn.microsoft.com/en-us/azure/api-management/api-management-policy-expressions)
- [APIM trace policy](https://learn.microsoft.com/en-us/azure/api-management/trace-policy)
- [API Management access restriction policies](https://learn.microsoft.com/en-us/azure/api-management/api-management-access-restriction-policies)

## GitHub References

- [Azure/api-management-policy-snippets](https://github.com/Azure/api-management-policy-snippets) — Official APIM policy examples
- [Azure/azure-api-management-devops-resource-kit](https://github.com/Azure/azure-api-management-devops-resource-kit) — DevOps tooling for APIM
- [Azure/api-management-samples](https://github.com/Azure/api-management-samples) — Sample configurations and templates
- [Azure/azure-quickstart-templates — APIM](https://github.com/Azure/azure-quickstart-templates/tree/master/quickstarts/microsoft.apimanagement) — Bicep/ARM templates
