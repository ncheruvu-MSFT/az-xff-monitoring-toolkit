# XFF Monitoring — KQL Query Reference

Complete reference of KQL queries for monitoring, alerting, and auditing X-Forwarded-For (XFF) across Azure services. All queries are designed for Log Analytics or Application Insights workspaces.

> See also: [xff-kql-queries.kql](../queries/xff-kql-queries.kql) for the original query file in this repo.

---

## Application Gateway Queries

### 1. Traffic Overview

Validate traffic and front-end IPs flowing through App Gateway.

```kql
AGWAccessLogs
| where TimeGenerated > ago(24h)
| project
    TimeGenerated,
    ResourceId,
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

### 2. Traffic Volume by Listener (Anomaly Detection)

Time series for spotting traffic anomalies or confirming routing.

```kql
AGWAccessLogs
| where TimeGenerated > ago(24h)
| summarize
    RequestCount = count(),
    AvgLatencyMs = avg(TimeTaken)
    by bin(TimeGenerated, 5m), ListenerName, Host
| order by TimeGenerated asc
```

### 3. WAF Blocked Requests

Security review of firewall blocks.

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

### 4. Top Client IPs (Abuse Detection)

Identify potential DDoS or brute-force sources.

```kql
AGWAccessLogs
| where TimeGenerated > ago(24h)
| summarize RequestCount = count() by ClientIp
| top 20 by RequestCount desc
```

### 5. Status Code Distribution

```kql
AGWAccessLogs
| where TimeGenerated > ago(24h)
| summarize RequestCount = count() by HttpStatusCode
| order by RequestCount desc
```

---

## APIM Queries

### 6. XFF Captured via Application Insights

Confirm XFF is being captured through APIM diagnostics.

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

### 7. XFF Presence Rate (Compliance Metric)

Shows what percentage of requests have XFF — should be ~100% if a reverse proxy fronts APIM.

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

### 8. XFF via AzureDiagnostics (Alternative)

Use when APIM logs go to Log Analytics directly instead of App Insights.

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

### 9. XFF Presence Over Time

Track XFF compliance trends.

```kql
requests
| where timestamp > ago(7d)
| extend xff = tostring(customDimensions["Request-Header-x-forwarded-for"])
| summarize
    WithXFF = countif(isnotempty(xff)),
    WithoutXFF = countif(isempty(xff))
    by bin(timestamp, 1h)
| extend XffPct = round(100.0 * WithXFF / (WithXFF + WithoutXFF), 2)
| render timechart
```

---

## App Service Queries

### 10. XFF in Application Insights Custom Dimensions

Verify `ForwardedHeadersMiddleware` and telemetry initializer are working.

```kql
requests
| where timestamp > ago(24h)
| where cloud_RoleName contains "<your-app-service-name>"
| extend xff = tostring(customDimensions["X-Forwarded-For"])
| project
    timestamp,
    name,
    url,
    resultCode,
    xff,
    client_IP
| order by timestamp desc
```

### 11. Native HTTP Logs (No XFF Column)

`AppServiceHTTPLogs` does not include XFF natively, but useful for correlation.

```kql
AppServiceHTTPLogs
| where TimeGenerated > ago(24h)
| project
    TimeGenerated,
    CIp,
    CsHost,
    CsUriStem,
    ScStatus,
    TimeTaken,
    UserAgent
| order by TimeGenerated desc
```

---

## XFF Normalization Queries

### 12. Detect Non-Normalized XFF (Contains `:port`)

Spikes indicate the App Gateway rewrite rule is missing or not associated with routing rules.

```kql
requests
| where timestamp > ago(24h)
| extend xff = tostring(customDimensions["Request-Header-x-forwarded-for"])
| where isnotempty(xff) and xff has ":"
| summarize MalformedCount = count() by bin(timestamp, 1h)
| order by timestamp asc
```

### 13. Malformed XFF Details

```kql
requests
| where timestamp > ago(24h)
| extend xff = tostring(customDimensions["Request-Header-x-forwarded-for"])
| where isnotempty(xff) and xff has ":"
| project timestamp, name, url, xff, client_IP
| order by timestamp desc
| take 100
```

---

## Cross-Tier Correlation Queries

### 14. End-to-End Request Flow

Correlate App Gateway and APIM requests using timestamps and correlation IDs.

```kql
let appGwRequests = AGWAccessLogs
| where TimeGenerated > ago(1h)
| project
    TimeGenerated,
    Tier = "AppGateway",
    ClientIp,
    Host,
    RequestUri,
    HttpStatusCode,
    TransactionId;

let apimRequests = ApiManagementGatewayLogs
| where TimeGenerated > ago(1h)
| extend headers = parse_json(RequestHeaders)
| extend xff = tostring(headers["X-Forwarded-For"])
| project
    TimeGenerated,
    Tier = "APIM",
    ClientIp = CallerIpAddress,
    Host = Url,
    RequestUri = Url,
    HttpStatusCode = ResponseCode,
    TransactionId = CorrelationId;

union appGwRequests, apimRequests
| order by TimeGenerated desc
```

### 15. XFF Hop Count Distribution

Verify the expected number of proxy hops in the XFF chain.

```kql
requests
| where timestamp > ago(24h)
| extend xff = tostring(customDimensions["Request-Header-x-forwarded-for"])
| where isnotempty(xff)
| extend hopCount = array_length(split(xff, ","))
| summarize count() by hopCount
| order by hopCount asc
```

---

## Front Door Queries

### 16. Front Door Access Log

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
    timeTaken_d
| order by TimeGenerated desc
```

### 17. Front Door WAF Blocks

```kql
AzureDiagnostics
| where ResourceProvider == "MICROSOFT.CDN"
    and Category == "FrontDoorWebApplicationFirewallLog"
| where TimeGenerated > ago(24h)
| where action_s == "Block"
| summarize BlockCount = count() by clientIP_s, ruleName_s
| order by BlockCount desc
```

---

## Azure Firewall Queries

### 18. DNAT Rule Hits (Source IP Tracking)

```kql
AZFWNatRule
| where TimeGenerated > ago(24h)
| project
    TimeGenerated,
    SourceIp,
    DestinationIp,
    TranslatedIp,
    TranslatedPort,
    Protocol
| order by TimeGenerated desc
```

### 19. Firewall + App Gateway Correlation

```kql
let fwDnat = AZFWNatRule
| where TimeGenerated > ago(1h)
| project FwTime = TimeGenerated, ClientIp = SourceIp, TranslatedIp;

let appGwAccess = AGWAccessLogs
| where TimeGenerated > ago(1h)
| project GwTime = TimeGenerated, ClientIp, Host, RequestUri, HttpStatusCode;

fwDnat
| join kind=inner appGwAccess on ClientIp
| project FwTime, GwTime, ClientIp, TranslatedIp, Host, RequestUri, HttpStatusCode
| order by FwTime desc
```

---

## Alerting Queries

### 20. XFF Absence Alert

Trigger when XFF presence drops below 95% in a 1-hour window. Use as a **scheduled alert rule** in Azure Monitor.

```kql
requests
| where timestamp > ago(1h)
| extend xff = tostring(customDimensions["Request-Header-x-forwarded-for"])
| summarize
    TotalRequests = count(),
    WithXFF = countif(isnotempty(xff))
| extend XffPct = round(100.0 * WithXFF / TotalRequests, 2)
| where XffPct < 95
```

### 21. Sudden XFF Format Change Alert

Detect when the malformed (`:port`) XFF ratio spikes.

```kql
requests
| where timestamp > ago(1h)
| extend xff = tostring(customDimensions["Request-Header-x-forwarded-for"])
| where isnotempty(xff)
| summarize
    Total = count(),
    WithPort = countif(xff has ":")
| extend PortPct = round(100.0 * WithPort / Total, 2)
| where PortPct > 5
```

### 22. Unusual Hop Count Alert

Detect requests with unexpected proxy hop counts (potential spoofing).

```kql
requests
| where timestamp > ago(1h)
| extend xff = tostring(customDimensions["Request-Header-x-forwarded-for"])
| where isnotempty(xff)
| extend hopCount = array_length(split(xff, ","))
| where hopCount > 5 or hopCount < 1
| summarize AnomalousCount = count()
| where AnomalousCount > 10
```

---

## Resource Graph Queries

### 23. App Gateways With/Without Rewrite Rule Sets

Run in **Azure Resource Graph Explorer** (not Log Analytics).

```kql
resources
| where type == "microsoft.network/applicationgateways"
| extend rewriteSets = properties.rewriteRuleSets
| extend hasRewrite = isnotempty(rewriteSets)
| project name, resourceGroup, subscriptionId, hasRewrite, rewriteSets
| order by hasRewrite asc
```

### 24. Resources Without Diagnostic Settings

```kql
resources
| where type in (
    "microsoft.network/applicationgateways",
    "microsoft.apimanagement/service",
    "microsoft.web/sites",
    "microsoft.cdn/profiles"
)
| join kind=leftouter (
    diagnosticsettings
    | distinct resourceId = tolower(id)
) on $left.id == $right.resourceId
| where isempty(resourceId1)
| project type, name, resourceGroup, subscriptionId
```

## Microsoft Learn References

- [AGWAccessLogs table reference](https://learn.microsoft.com/en-us/azure/azure-monitor/reference/tables/agwaccesslogs)
- [APIM Azure Monitor integration](https://learn.microsoft.com/en-us/azure/api-management/api-management-howto-use-azure-monitor)
- [Application Insights — requests table](https://learn.microsoft.com/en-us/azure/azure-monitor/reference/tables/requests)
- [KQL quick reference](https://learn.microsoft.com/en-us/kusto/query/kql-quick-reference)
- [Create log alert rules in Azure Monitor](https://learn.microsoft.com/en-us/azure/azure-monitor/alerts/alerts-create-log-alert-rule)
- [Azure Resource Graph query language](https://learn.microsoft.com/en-us/azure/governance/resource-graph/concepts/query-language)
