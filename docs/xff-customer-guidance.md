# X-Forwarded-For (XFF) Header Monitoring — Customer Guidance

## Background

In a typical Azure multi-tier architecture — **Proxy (VIP) → Application Gateway → APIM → App Service** — the real client IP is lost at each tier because each service only logs the **TCP peer IP** (the immediate upstream connection), not the original client.

```
┌──────────┐     ┌──────────────┐     ┌─────────────────┐     ┌──────────┐     ┌─────────────┐
│  Client   │────▶│  Proxy (VIP) │────▶│  App Gateway    │────▶│   APIM   │────▶│ App Service  │
│ 203.0.x.x│     │  e.g. Nginx  │     │  (v2 / Basic)   │     │          │     │             │
└──────────┘     └──────────────┘     └─────────────────┘     └──────────┘     └─────────────┘
```

**What happens today (the problem):**

| Tier | Log Table | Field | What It Shows | What You Expected |
|------|-----------|-------|---------------|-------------------|
| App Gateway | `AzureDiagnostics` / `AGWAccessLogs` | `clientIP_s` / `ClientIp` | **Proxy VIP IP** | Real client IP |
| APIM | `ApiManagementGatewayLogs` | `CallerIpAddress` | **App GW or Proxy IP** | Real client IP |
| App Service | `AppServiceHTTPLogs` | `CIp` | **APIM / App Gateway IP** | Real client IP |

> **Evidence from our test environment:** Out of 1,685 requests logged in `AppServiceHTTPLogs`, **95% showed `4.205.85.213`** (the App Gateway IP) as the client — not the real end-user IP. Similarly, `AzureDiagnostics` showed `4.172.218.37` (the proxy's egress IP) for all proxied traffic.

This is **by design** — these fields capture the TCP socket peer, not the XFF header value. Below are the alternative approaches to capture the real client IP at each tier.

---

## Question 1: How to Store the X-Forwarded-For Value at the App Gateway Level?

### The Limitation

The `AGWAccessLogs.ClientIp` (resource-specific mode) or `AzureDiagnostics.clientIP_s` (legacy mode) always records the **TCP peer IP** — the IP of the device directly connected to App Gateway. When a proxy sits in front, this will be the proxy IP, not the real client.

**There is no native column in AGWAccessLogs that captures the full XFF header.**

### The Solution: App Gateway Rewrite Rule + Application Insights

#### Step 1 — Deploy an XFF Normalization Rewrite Rule

Configure App Gateway to normalize the `X-Forwarded-For` header using the built-in `{var_add_x_forwarded_for_proxy}` server variable. This ensures downstream services receive a clean XFF chain (without the non-standard `:port` suffix).

**Portal steps:**
1. Navigate to **Application Gateway → Rewrites**
2. Click **+ Rewrite set** → Name: `xff-normalization-ruleset`
3. Associate with your routing rule(s)
4. Add rule:
   - **Header type:** Request header
   - **Header name:** `X-Forwarded-For`
   - **Header value:** `{var_add_x_forwarded_for_proxy}`

**Bicep (Infrastructure as Code):**

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

> **Important:** The rewrite rule set must be **associated with routing rule(s)** on the App Gateway to take effect.

#### Step 2 — Capture XFF via Application Insights at the Backend

Since App Gateway access logs do not include an XFF column, the recommended approach is to capture the XFF header in **Application Insights** on the backend application using a telemetry initializer. With a **workspace-based** Application Insights resource, this data flows into the Log Analytics workspace as the `AppRequests` table, where `customDimensions` maps to the `Properties` column.

**KQL to query the captured XFF value (run in Log Analytics workspace):**

```kql
// Run this in your Log Analytics workspace
AppRequests
| where TimeGenerated > ago(24h)
| extend xff = tostring(Properties["X-Forwarded-For"])
| extend resolvedClientIp = tostring(Properties["ResolvedClientIp"])
| project TimeGenerated, xff, resolvedClientIp, Url, ResultCode, ClientIP
| order by TimeGenerated desc
```

> **Schema Note — App Insights vs. Log Analytics:**
> | App Insights (direct query) | Log Analytics (workspace) |
> |---|---|
> | `requests` | `AppRequests` |
> | `customDimensions` | `Properties` |
> | `timestamp` | `TimeGenerated` |
> | `client_IP` | `ClientIP` |
> | `url` | `Url` |
> | `resultCode` | `ResultCode` |
> | `name` | `Name` |
>
> All KQL in this document uses **Log Analytics workspace** syntax so clients can copy-paste directly.

#### Key Server Variables

| Variable | Description |
|----------|-------------|
| `{var_add_x_forwarded_for_proxy}` | Full XFF chain with port stripped from last entry |
| `{var_client_ip}` | Direct client IP (TCP peer, no port) |
| `{var_client_port}` | Direct client port |

### Summary for App Gateway

| What | Where | How |
|------|-------|-----|
| TCP peer IP (proxy IP) | `AGWAccessLogs.ClientIp` | Available natively — no change needed |
| Real client IP from XFF | `AppRequests.Properties["X-Forwarded-For"]` in Log Analytics | Requires backend middleware + telemetry initializer |
| Normalized XFF on the wire | App Gateway rewrite rule | `{var_add_x_forwarded_for_proxy}` server variable |

---

## Question 2: How to Store the X-Forwarded-For Value at the APIM Level?

### The Limitation

`ApiManagementGatewayLogs.CallerIpAddress` always records the **TCP peer IP** — the IP of the device directly connected to APIM. When App Gateway sits in front, this will be the App Gateway IP. There is no native "original client IP" field in API Management Gateway Logs.

### The Solution: APIM Diagnostics + Policy for XFF Forwarding

#### Step 1 — Enable APIM Diagnostic Entity with Header Logging

Configure the APIM `azuremonitor` diagnostic entity to log `X-Forwarded-For` in `RequestHeaders`. This populates the `RequestHeaders` column in `ApiManagementGatewayLogs`.

**Azure CLI / REST API:**

```bash
# 1. Create the Azure Monitor logger (if not already present)
az rest --method PUT \
  --uri "https://management.azure.com{apim-resource-id}/loggers/azuremonitor?api-version=2022-08-01" \
  --body '{"properties":{"loggerType":"azureMonitor","isBuffered":true}}'

# 2. Create the diagnostics entity with header logging
az rest --method PUT \
  --uri "https://management.azure.com{apim-resource-id}/diagnostics/azuremonitor?api-version=2022-08-01" \
  --body '{
    "properties": {
      "loggerId": "/loggers/azuremonitor",
      "alwaysLog": "allErrors",
      "logClientIp": true,
      "verbosity": "information",
      "sampling": { "samplingType": "fixed", "percentage": 100 },
      "frontend": {
        "request": {
          "headers": ["X-Forwarded-For", "X-Real-Client-IP", "Host"],
          "body": { "bytes": 0 }
        }
      }
    }
  }'
```

> **Important:** Two separate configurations are needed: (1) Azure Monitor **diagnostic settings** (under `Microsoft.Insights/diagnosticSettings`) route `GatewayLogs` to Log Analytics, and (2) the APIM **diagnostics entity** (under `Microsoft.ApiManagement/service/diagnostics`) controls *what* gets logged, including request headers.

#### Step 2 — Configure APIM Policy to Forward XFF to Backend

Use an APIM global or API-level policy to preserve and forward the `X-Forwarded-For` header to the backend, and optionally set an `X-Real-Client-IP` header with the first IP from the XFF chain:

```xml
<policies>
  <inbound>
    <base />
    <!-- Preserve and forward XFF to backend -->
    <set-header name="X-Forwarded-For" exists-action="skip">
      <value>@(context.Request.Headers.GetValueOrDefault("X-Forwarded-For", context.Request.IpAddress))</value>
    </set-header>
    <!-- Extract real client IP (first IP in XFF chain) -->
    <set-header name="X-Real-Client-IP" exists-action="override">
      <value>@{
        var xff = context.Request.Headers.GetValueOrDefault("X-Forwarded-For", "");
        var firstIp = xff.Split(',')[0].Trim();
        return string.IsNullOrEmpty(firstIp) ? context.Request.IpAddress : firstIp;
      }</value>
    </set-header>
  </inbound>
</policies>
```

> See the full policy sample: [`samples/apim-policy/xff-global-policy.xml`](../samples/apim-policy/xff-global-policy.xml)

#### Step 3 — Query Real Client IP via GatewayLogs

```kql
// Extract real client IP from XFF header in APIM logs
ApiManagementGatewayLogs
| where TimeGenerated > ago(24h)
| where isnotempty(RequestHeaders)
| extend headers = parse_json(RequestHeaders)
| extend xff = tostring(headers["X-Forwarded-For"])
| extend OriginalClientIp = trim(' ', tostring(split(xff, ',')[0]))
| project TimeGenerated, CallerIpAddress, XffHeader = xff, OriginalClientIp, Method, Url, ResponseCode
| order by TimeGenerated desc
```

**Compare with native logs (shows the problem):**

```kql
// CallerIpAddress is always the App Gateway or Proxy IP
ApiManagementGatewayLogs
| where TimeGenerated > ago(24h)
| summarize RequestCount = count() by CallerIpAddress
| order by RequestCount desc
// Result: CallerIpAddress = App GW IP, not real client
```

### Summary for APIM

| What | Where | How |
|------|-------|-----|
| TCP peer IP (App GW IP) | `ApiManagementGatewayLogs.CallerIpAddress` | Available natively — no change needed |
| Real client IP from XFF | `ApiManagementGatewayLogs.RequestHeaders` | Requires APIM diagnostics entity with header logging |
| XFF forwarded to backend | APIM policy | `set-header` policy to forward XFF + set `X-Real-Client-IP` |

---

## Question 3: How to Store the X-Forwarded-For Value at the App Service Level?

### The Limitation

`AppServiceHTTPLogs.CIp` always shows the **TCP peer IP** — in this architecture, that is the Application Gateway's IP. There is no native XFF column in `AppServiceHTTPLogs`.

### The Solution: Application-Level Middleware + Application Insights

#### Step 1 — Configure ForwardedHeaders Middleware

This resolves `HttpContext.Connection.RemoteIpAddress` to the real client IP from the XFF header.

**.NET (ASP.NET Core):**

```csharp
builder.Services.Configure<ForwardedHeadersOptions>(options =>
{
    options.ForwardedHeaders =
        ForwardedHeaders.XForwardedFor |
        ForwardedHeaders.XForwardedProto |
        ForwardedHeaders.XForwardedHost;

    // Trust your Application Gateway / APIM / proxy subnets
    options.KnownNetworks.Add(new IPNetwork(IPAddress.Parse("10.0.0.0"), 8));
    options.KnownNetworks.Add(new IPNetwork(IPAddress.Parse("172.16.0.0"), 12));

    // Clear limit for multi-proxy chains (Proxy → AppGW → APIM → App Service)
    options.ForwardLimit = null;
});

var app = builder.Build();
app.UseForwardedHeaders();   // MUST be FIRST — before auth, routing, etc.
```

**Python (Flask):**

```python
from werkzeug.middleware.proxy_fix import ProxyFix

# Trust 3 proxies (Proxy VIP → App Gateway → APIM → App Service)
app.wsgi_app = ProxyFix(app.wsgi_app, x_for=3, x_proto=1, x_host=1)
```

**Java (Spring Boot):**

```properties
server.forward-headers-strategy=FRAMEWORK
```

#### Step 2 — Register an XFF Telemetry Initializer (Application Insights)

This captures the XFF header in Application Insights `customDimensions` so it appears in KQL queries.

**.NET:**

```csharp
public class XffTelemetryInitializer : ITelemetryInitializer
{
    private readonly IHttpContextAccessor _httpContextAccessor;

    public XffTelemetryInitializer(IHttpContextAccessor httpContextAccessor)
        => _httpContextAccessor = httpContextAccessor;

    public void Initialize(ITelemetry telemetry)
    {
        if (telemetry is RequestTelemetry requestTelemetry)
        {
            var context = _httpContextAccessor.HttpContext;
            if (context == null) return;

            var xff = context.Request.Headers["X-Forwarded-For"].FirstOrDefault();
            if (!string.IsNullOrEmpty(xff))
            {
                requestTelemetry.Properties["X-Forwarded-For"] = xff;
                requestTelemetry.Properties["ResolvedClientIp"] =
                    context.Connection.RemoteIpAddress?.ToString() ?? "";
            }
        }
    }
}

// Register in Program.cs:
builder.Services.AddApplicationInsightsTelemetry();
builder.Services.AddSingleton<ITelemetryInitializer, XffTelemetryInitializer>();
builder.Services.AddHttpContextAccessor();
```

#### Step 3 — Query Real Client IP in KQL

Once the middleware and telemetry initializer are deployed, query the `AppRequests` table in your Log Analytics workspace:

```kql
// Real client IP from Application Insights (run in Log Analytics workspace)
AppRequests
| where TimeGenerated > ago(24h)
| extend xff = tostring(Properties["X-Forwarded-For"])
| extend resolvedClientIp = tostring(Properties["ResolvedClientIp"])
| project
    TimeGenerated,
    RealClientIp = trim(' ', tostring(split(xff, ",")[0])),   // First IP in XFF chain = original client
    FullXffChain = xff,
    ResolvedByMiddleware = resolvedClientIp,
    AppServiceCIp = ClientIP,           // This is still the App GW IP
    Url,
    ResultCode
| order by TimeGenerated desc
```

**Compare with native logs (shows the problem):**

```kql
// AppServiceHTTPLogs — CIp is always the App Gateway IP
AppServiceHTTPLogs
| where TimeGenerated > ago(24h)
| summarize RequestCount = count() by CIp
| order by RequestCount desc
// Result: 95%+ of CIp values = App Gateway IP
```

### Summary for App Service

| What | Where | How |
|------|-------|-----|
| TCP peer IP (App GW IP) | `AppServiceHTTPLogs.CIp` | Available natively — this won't change |
| Real client IP from XFF | `AppRequests.Properties["X-Forwarded-For"]` in Log Analytics | Requires ForwardedHeaders middleware + telemetry initializer |
| Full XFF chain | `AppRequests.Properties["X-Forwarded-For"]` in Log Analytics | Same middleware captures the full chain |

---

## Question 4: Log Retention — How Long Can We Store Logs and What Does It Cost?

### Diagnostic Logs Retention

Azure Log Analytics supports flexible retention:

| Retention Type | Duration | Cost |
|---------------|----------|------|
| **Interactive retention** (hot, queryable) | 30 days (default) — up to **730 days** (2 years) | Included in first 31 days; after that **$0.10/GB/month** |
| **Long-term retention** (archive, cold) | Up to **12 years** total | **$0.02/GB/month** (archived data) |
| **Basic Logs** plan (reduced query) | 8 days interactive + up to 365 days archive | **$0.65/GB ingestion** (vs. $2.76 Analytics) |

### How to Configure Retention

**Per-table retention (recommended):**

```bash
# Set AppServiceHTTPLogs to 90-day interactive retention
az monitor log-analytics workspace table update \
  --resource-group <rg> \
  --workspace-name <workspace> \
  --name AppServiceHTTPLogs \
  --retention-time 90 \
  --total-retention-time 365

# Set AzureDiagnostics (App GW logs) to 90-day interactive + 1 year total
az monitor log-analytics workspace table update \
  --resource-group <rg> \
  --workspace-name <workspace> \
  --name AzureDiagnostics \
  --retention-time 90 \
  --total-retention-time 365
```

**Workspace-level default:**

```bash
az monitor log-analytics workspace update \
  --resource-group <rg> \
  --name <workspace> \
  --retention-time 90
```

### Cost Breakdown

| Cost Component | Price | Notes |
|---------------|-------|-------|
| **Data ingestion** | **$2.76/GB** (Pay-As-You-Go, Analytics plan) | First 5 GB/day free per billing account |
| **Data ingestion (Basic Logs)** | **$0.65/GB** | Lower cost, limited query capability |
| **Interactive retention beyond 31 days** | **$0.10/GB/month** | Per GB stored past 31 days |
| **Archive retention** | **$0.02/GB/month** | Long-term, search-only |
| **Commitment tiers** | 100 GB/day: ~$1.96/GB | 200+ GB/day: even lower |

### Estimated Monthly Cost by Data Volume

| Daily Ingestion | Retention | Monthly Cost (approx.) |
|----------------|-----------|----------------------|
| 1 GB/day | 30 days (default) | ~$83/month |
| 1 GB/day | 90 days | ~$83 + ~$6 retention = ~$89/month |
| 1 GB/day | 365 days | ~$83 + ~$15 (90d interactive) + ~$5 (275d archive) = ~$103/month |
| 5 GB/day | 30 days | Free (5 GB/day allowance) |
| 5 GB/day | 90 days | Free ingestion + ~$30 retention = ~$30/month |
| 10 GB/day | 90 days | ~$138 ingestion + ~$60 retention = ~$198/month |

> **Tip:** Use the [Azure Pricing Calculator](https://azure.microsoft.com/pricing/calculator/) for precise estimates based on your actual data volume. Check current ingestion with the KQL query below.

### Check Your Current Data Volume

```kql
// How much data is being ingested daily, by table?
Usage
| where TimeGenerated > ago(30d)
| where IsBillable == true
| summarize
    DailyGB = round(sum(Quantity) / 1024.0, 3)
    by DataType, bin(TimeGenerated, 1d)
| summarize
    AvgDailyGB = round(avg(DailyGB), 3),
    MaxDailyGB = round(max(DailyGB), 3)
    by DataType
| order by AvgDailyGB desc
```

### Recommendations

| Scenario | Recommended Retention | Estimated Extra Cost |
|----------|----------------------|---------------------|
| **Standard operations** | 90 days interactive | ~$0.10/GB/month for days 32–90 |
| **Security & compliance** | 90 days interactive + 1 year archive | + $0.02/GB/month for archive |
| **Long-term audit** | 90 days interactive + 7 years archive | + $0.02/GB/month for archive |
| **Cost-sensitive** | 30 days (default) + export to Storage | Storage: ~$0.018/GB/month (Hot) |

**Alternative: Export to Azure Storage for cheapest long-term retention:**

```bash
# Export logs to a Storage Account (much cheaper for long-term)
az monitor log-analytics workspace data-export create \
  --resource-group <rg> \
  --workspace-name <workspace> \
  --name "export-to-storage" \
  --destination <storage-account-resource-id> \
  --table-names AppServiceHTTPLogs AzureDiagnostics
```

---

## Architecture Diagram — Where Monitoring Captures Data

```
                  ┌──────────────────────────────────────────────────────────────┐
                  │                   Log Analytics Workspace                     │
                  │                                                              │
                  │  ┌──────────────────┐ ┌──────────────────┐ ┌──────────────┐  │
                  │  │ AzureDiagnostics  │ │ ApiManagement    │ │ AppService   │  │
                  │  │ (AGW Access Logs) │ │ GatewayLogs      │ │ HTTPLogs     │  │
                  │  │                   │ │                  │ │              │  │
                  │  │ clientIP_s =      │ │ CallerIpAddress= │ │ CIp =        │  │
                  │  │  Proxy VIP IP ⚠️  │ │  AppGW IP ⚠️     │ │  APIM IP ⚠️  │  │
                  │  └──────────────────┘ └──────────────────┘ └──────────────┘  │
                  │                                                              │
                  │  ┌──────────────────────────────────────────────────────────┐│
                  │  │ AppRequests (from workspace-based App Insights)          ││
                  │  │ Properties["X-Forwarded-For"] = Real Client IP ✅        ││
                  │  └──────────────────────────────────────────────────────────┘│
                  └──────────────────────────────────────────────────────────────┘
                       ▲              ▲                ▲               ▲
           Diagnostic  │  Diagnostic  │   Diagnostic   │  App Insights │
           Settings    │  Settings    │   Settings     │  SDK/Agent    │
                       │              │                │               │
┌──────────┐ ┌───────┐│ ┌──────────┐ │ ┌────────────┐ │ ┌───────────┐ │
│  Client   │▶│ Proxy │┼▶│ App      │─┼▶│    APIM    │─┼▶│ App       │─┘
│ 203.0.x.x│ │ (VIP) ││ │ Gateway  │ │ │            │ │ │ Service   │
└──────────┘ └───────┘│ └──────────┘ │ └────────────┘ │ └───────────┘
                      │              │                │
       XFF header:    │              │                │
       (none)────▶ 203.0.x.x ──▶ 203.0.x.x,<proxy> ──▶ 203.0.x.x,<proxy>,<appgw>
```

**⚠️ = TCP peer IP (not real client)** — this is the default behavior.
**✅ = Real client IP** — requires middleware + telemetry initializer.

---

## Client-Ready KQL — All Tiers, Single Log Analytics Query

Copy-paste this query into your **Log Analytics workspace** to see what IP each tier logs and where the real client IP is:

```kql
// ═══════════════════════════════════════════════════════════════
// ALL-TIER IP TRACE — Run in Log Analytics Workspace
// ═══════════════════════════════════════════════════════════════
// Shows what IP each tier logs, proving the XFF problem
// and where the real client IP is (with the ✅ mark)
let timeFilter = ago(24h);
// ── Tier 1: App Gateway — clientIP_s = proxy VIP (TCP peer) ──
let appgw = AzureDiagnostics
| where TimeGenerated > timeFilter
| where ResourceType == "APPLICATIONGATEWAYS"
| summarize RequestCount = count() by IP = clientIP_s
| extend Tier = "1. App Gateway", Field = "clientIP_s",
         IPType = "TCP Peer (Proxy VIP)", IsRealClient = "❌ No";
// ── Tier 2: APIM — CallerIpAddress = App GW IP (TCP peer) ──
let apim_native = ApiManagementGatewayLogs
| where TimeGenerated > timeFilter
| summarize RequestCount = count() by IP = CallerIpAddress
| extend Tier = "2. APIM", Field = "CallerIpAddress",
         IPType = "TCP Peer (App GW IP)", IsRealClient = "❌ No";
// ── Tier 2b: APIM — XFF from RequestHeaders = real client ──
let apim_xff = ApiManagementGatewayLogs
| where TimeGenerated > timeFilter
| where isnotempty(RequestHeaders)
| extend headers = parse_json(RequestHeaders)
| extend xff = tostring(headers["X-Forwarded-For"])
| where isnotempty(xff)
| extend OriginalClientIp = trim(' ', tostring(split(xff, ',')[0]))
| summarize RequestCount = count() by IP = OriginalClientIp
| extend Tier = "2b. APIM (XFF)", Field = "RequestHeaders[X-Forwarded-For]",
         IPType = "First IP in XFF chain", IsRealClient = "✅ Yes";
// ── Tier 3: App Service — CIp = APIM/AppGW IP (TCP peer) ──
let appsvc = AppServiceHTTPLogs
| where TimeGenerated > timeFilter
| summarize RequestCount = count() by IP = CIp
| extend Tier = "3. App Service", Field = "CIp",
         IPType = "TCP Peer (APIM/AppGW IP)", IsRealClient = "❌ No";
// ── Tier 4: App Insights — Properties["X-Forwarded-For"] = real client ──
let appinsights = AppRequests
| where TimeGenerated > timeFilter
| extend xff = tostring(Properties["X-Forwarded-For"])
| where isnotempty(xff)
| extend OriginalClientIp = trim(' ', tostring(split(xff, ',')[0]))
| summarize RequestCount = count() by IP = OriginalClientIp
| extend Tier = "4. App Insights (XFF)", Field = "Properties[X-Forwarded-For]",
         IPType = "First IP in XFF chain", IsRealClient = "✅ Yes";
// ── Union all tiers ──
union appgw, apim_native, apim_xff, appsvc, appinsights
| project Tier, Field, IP, RequestCount, IPType, IsRealClient
| order by Tier asc, RequestCount desc
```

**Additional client queries (run in Log Analytics):**

```kql
// XFF Coverage — what % of requests have the real client IP captured?
AppRequests
| where TimeGenerated > ago(24h)
| extend xff = tostring(Properties["X-Forwarded-For"])
| summarize
    TotalRequests = count(),
    WithXFF = countif(isnotempty(xff)),
    WithoutXFF = countif(isempty(xff))
| extend XffCoveragePct = round(100.0 * WithXFF / TotalRequests, 1)
```

```kql
// XFF Coverage trend by hour — detect if capture drops
AppRequests
| where TimeGenerated > ago(7d)
| extend xff = tostring(Properties["X-Forwarded-For"])
| summarize
    Total = count(),
    WithXFF = countif(isnotempty(xff))
    by bin(TimeGenerated, 1h)
| extend CoveragePct = round(100.0 * WithXFF / Total, 1)
| project TimeGenerated, Total, WithXFF, CoveragePct
| render timechart
```

---

## Quick Reference — Implementation Checklist

### At the Proxy Layer
- [ ] Configure the proxy to set `X-Forwarded-For: <real-client-ip>` on outbound requests

### At the App Gateway Layer
- [ ] Deploy XFF normalization rewrite rule (`{var_add_x_forwarded_for_proxy}`)
- [ ] Associate rewrite rule set with all routing rules
- [ ] Enable diagnostic settings → Log Analytics workspace

### At the APIM Layer
- [ ] Create Azure Monitor logger (`azuremonitor` logger type)
- [ ] Create APIM diagnostics entity with `X-Forwarded-For` in `frontend.request.headers`
- [ ] Deploy XFF forwarding policy (preserve XFF + set `X-Real-Client-IP`)
- [ ] Enable Azure Monitor diagnostic settings → Log Analytics (Dedicated mode for `ApiManagementGatewayLogs`)

### At the App Service Layer
- [ ] Deploy ForwardedHeaders middleware (must be **first** middleware)
- [ ] Configure `KnownNetworks` to trust App Gateway / APIM / proxy subnets
- [ ] Set `ForwardLimit = null` for multi-proxy chains (Proxy → AppGW → APIM → App)
- [ ] Register `XffTelemetryInitializer` for Application Insights
- [ ] Register `IHttpContextAccessor` (required by the telemetry initializer)
- [ ] Enable diagnostic settings → Log Analytics workspace

### Monitoring & Retention
- [ ] Set per-table retention based on compliance needs
- [ ] Configure archive tier for long-term retention requirements
- [ ] Set up data export to Storage Account if >1 year retention needed
- [ ] Deploy Azure Monitor Workbook for ongoing visibility

---

## Related Resources

| Resource | Link |
|----------|------|
| XFF Overview | [xff-overview.md](xff-overview.md) |
| App Gateway XFF Guide | [xff-azure-application-gateway.md](xff-azure-application-gateway.md) |
| App Service XFF Guide | [xff-azure-app-service.md](xff-azure-app-service.md) |
| Multi-Tier Patterns | [xff-multi-tier-patterns.md](xff-multi-tier-patterns.md) |
| KQL Query Reference | [xff-kql-query-reference.md](xff-kql-query-reference.md) |
| APIM XFF Guide | [xff-azure-api-management.md](xff-azure-api-management.md) |
| Security Best Practices | [xff-security-best-practices.md](xff-security-best-practices.md) |
| APIM Global Policy Sample | [samples/apim-policy/xff-global-policy.xml](../samples/apim-policy/xff-global-policy.xml) |
| .NET Sample Code | [samples/dotnet/Program.cs](../samples/dotnet/Program.cs) |
| Python Middleware Sample | [samples/python/xff_middleware.py](../samples/python/xff_middleware.py) |
| Validation KQL Queries | [queries/xff-proxy-appgw-validation.kql](../queries/xff-proxy-appgw-validation.kql) |
| Azure Log Analytics Pricing | [Azure Monitor Pricing](https://azure.microsoft.com/pricing/details/monitor/) |
| ForwardedHeaders Docs | [Microsoft Learn](https://learn.microsoft.com/aspnet/core/host-and-deploy/proxy-load-balancer) |
