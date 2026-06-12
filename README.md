# XFF (X-Forwarded-For) Monitoring & Compliance

End-to-end infrastructure, queries, policies, and code samples to **standardize, monitor, and report on X-Forwarded-For (XFF)** across Azure Application Gateway, API Management (APIM), and App Service.

## Architecture

```
┌──────────┐     ┌─────────────────┐     ┌──────┐     ┌─────────────┐
│  Client   │────▶│ Application     │────▶│ APIM │────▶│ App Service │
│           │     │ Gateway (v2)    │     │      │     │             │
└──────────┘     │ + XFF Rewrite   │     │      │     │ + Forwarded │
                 │ + WAF           │     │      │     │   Headers   │
                 └────────┬────────┘     └──┬───┘     └──────┬──────┘
                          │                 │                 │
                          ▼                 ▼                 ▼
                 ┌─────────────────────────────────────────────────┐
                 │          Log Analytics Workspace                │
                 │  AGWAccessLogs │ ApiMgmtGatewayLogs │ AppSvc   │
                 └────────────────────────┬────────────────────────┘
                                          │
                                          ▼
                              ┌───────────────────────┐
                              │ Azure Monitor Workbook │
                              │  (XFF Compliance)      │
                              └───────────────────────┘
```

## Repository Structure

```
xff-monitoring/
├── infra/                          # Bicep IaC
│   ├── main.bicep                  # Orchestrator
│   ├── main.bicepparam             # Parameter file (fill in your values)
│   └── modules/
│       ├── appgateway-xff-rewrite.bicep   # App Gateway XFF normalization rewrite
│       ├── apim-xff-diagnostics.bicep     # APIM diagnostics with XFF header logging
│       └── diagnostic-settings.bicep      # Diagnostic Settings for all 3 tiers
├── queries/
│   └── xff-kql-queries.kql         # 13 KQL queries for monitoring & alerting
├── policies/
│   ├── audit-appgw-xff-rewrite.json       # Audit: App Gateway has rewrite rule
│   ├── deploy-appgw-diagnostics.json      # DINE: Auto-deploy diagnostics on App GW
│   ├── audit-apim-diagnostics.json        # Audit: APIM has diagnostic settings
│   └── xff-policy-initiative.json         # Initiative bundling all policies
├── workbook/
│   └── xff-compliance-workbook.json       # Azure Monitor Workbook template
├── samples/
│   ├── dotnet/
│   │   └── Program.cs              # ASP.NET Core ForwardedHeaders + TelemetryInitializer
│   ├── python/
│   │   └── xff_middleware.py        # Flask ProxyFix + FastAPI middleware + OpenTelemetry
│   └── apim-policy/
│       └── xff-global-policy.xml    # APIM global policy for XFF propagation
└── README.md                        # This file
```

---

## 1. Infrastructure Deployment (Bicep)

### Prerequisites

- Azure CLI ≥ 2.50
- Existing Application Gateway v2, APIM instance, and App Service
- A Log Analytics workspace and Application Insights instance

### Deploy

```bash
# Edit parameters
code xff-monitoring/infra/main.bicepparam

# Deploy
az deployment group create \
  --resource-group <rg-name> \
  --template-file xff-monitoring/infra/main.bicep \
  --parameters xff-monitoring/infra/main.bicepparam
```

### What gets deployed

| Module | Resource | Purpose |
|--------|----------|---------|
| `appgateway-xff-rewrite.bicep` | Rewrite Rule Set | Normalizes XFF using `{var_add_x_forwarded_for_proxy}` (strips `:port`) |
| `diagnostic-settings.bicep` | Diagnostic Settings × 3 | Sends all logs + metrics to central Log Analytics workspace |
| `apim-xff-diagnostics.bicep` | APIM Logger + Diagnostics | Captures `X-Forwarded-For`, `X-Forwarded-Proto`, `X-Forwarded-Host`, `X-Azure-ClientIP` headers in App Insights |

> **After deploying the rewrite rule set**, you must associate it with the desired routing rule(s) on your App Gateway (via Portal or CLI).

---

## 2. KQL Queries

See [`queries/xff-kql-queries.kql`](queries/xff-kql-queries.kql) for 13 ready-to-use queries:

| # | Query | Purpose |
|---|-------|---------|
| 1 | App Gateway traffic overview | Validate traffic & front-end IPs |
| 2 | Traffic volume by listener | Time series for anomaly detection |
| 3 | WAF blocked requests | Security review |
| 4 | APIM XFF via App Insights | Confirm XFF captured in diagnostics |
| 5 | APIM XFF presence rate | Compliance metric (should be ~100%) |
| 6 | APIM XFF via AzureDiagnostics | Alternative if not using App Insights |
| 7 | App Service XFF via App Insights | Verify ForwardedHeaders middleware works |
| 8 | App Service native HTTP logs | Correlation (no XFF column natively) |
| 9 | Non-normalized XFF (`:port`) | Detect missing/mis-scoped rewrite rules |
| 10 | Cross-tier correlation | End-to-end request tracing |
| 11 | Resource Graph compliance | Audit rewrite rule presence |
| 12 | Top client IPs | Abuse detection |
| 13 | XFF absence alert | Scheduled alert when XFF drops below 95% |

---

## 3. Azure Policy

### Individual Policies

| Policy File | Type | Description |
|-------------|------|-------------|
| `audit-appgw-xff-rewrite.json` | **Audit** | Flags App Gateways missing the `xff-normalization-ruleset` |
| `deploy-appgw-diagnostics.json` | **DeployIfNotExists** | Auto-deploys diagnostic settings (all logs + metrics) to your central workspace |
| `audit-apim-diagnostics.json` | **AuditIfNotExists** | Flags APIM instances without any diagnostic settings |

### Policy Initiative

[`xff-policy-initiative.json`](policies/xff-policy-initiative.json) bundles all three policies. Replace the `<policy-definition-id-*>` placeholders with actual definition IDs after creating each policy.

### Deploy a Policy

```bash
# Create definition
az policy definition create \
  --name "audit-appgw-xff-rewrite" \
  --display-name "Audit App Gateways missing XFF rewrite rule" \
  --rules policies/audit-appgw-xff-rewrite.json \
  --mode All

# Assign
az policy assignment create \
  --name "audit-appgw-xff" \
  --policy "audit-appgw-xff-rewrite" \
  --scope "/subscriptions/<sub-id>"
```

---

## 4. Azure Monitor Workbook

Import [`workbook/xff-compliance-workbook.json`](workbook/xff-compliance-workbook.json) into Azure Monitor Workbooks:

1. Go to **Azure Monitor → Workbooks → + New**
2. Click **Advanced Editor** (code icon `</>`)
3. Paste the JSON content
4. Select your Log Analytics workspace and App Insights as data sources
5. **Save**

### Dashboard Sections

- **App Gateway Traffic** – request volume, top client IPs, status code distribution
- **APIM XFF Compliance** – presence rate tile, presence over time
- **XFF Normalization** – malformed (`:port`) detection chart
- **App Service XFF Coverage** – via Application Insights
- **WAF Blocks** – firewall rule group breakdown
- **Governance** – Resource Graph query for rewrite rule audit

---

## 5. Application Code Samples

### ASP.NET Core (`samples/dotnet/Program.cs`)

- Configures `ForwardedHeadersMiddleware` with `KnownNetworks` for your proxy subnets
- Includes `XffTelemetryInitializer` that writes `X-Forwarded-For` and `ResolvedClientIp` to App Insights `customDimensions`
- Middleware runs **before** auth/routing

### Python (`samples/python/xff_middleware.py`)

- **Flask**: `ProxyFix` middleware with configurable hop count
- **FastAPI**: Custom middleware example
- **Azure Monitor OpenTelemetry**: Span attribute injection for XFF

### APIM Policy (`samples/apim-policy/xff-global-policy.xml`)

- Forwards XFF to backend (preserves App Gateway value)
- Extracts `X-Real-Client-IP` (first hop, port-stripped)
- Traces XFF in APIM diagnostics
- Strips internal headers from outbound responses

---

## 6. XFF Header Capture — Service-by-Service Configuration Guide

This section explains **how each Azure ingress service handles X-Forwarded-For** and what you need to configure to capture and log it. No code implementation — only configuration guidance and official documentation references.

---

### 6.1 Azure Front Door

Azure Front Door **automatically appends** the client's IP to the `X-Forwarded-For` header on every request forwarded to the backend. It also sets `X-Azure-ClientIP` (the socket-level client IP as seen by Front Door) and `X-Azure-SocketIP`.

**How to configure XFF logging:**

1. **Enable Diagnostic Settings** — Send `FrontDoorAccessLog` and `FrontDoorHealthProbeLog` to a Log Analytics workspace. The access log includes `clientIp`, `socketIp`, and the full `X-Forwarded-For` chain.
2. **WAF Logs** — Enable `FrontDoorWebApplicationFirewallLog` to capture per-rule match details including client IP.
3. **Front Door Standard/Premium** — Use the built-in analytics dashboard under **Front Door → Analytics** for IP-level traffic insights.

**Key behavior:**
- Front Door uses `X-Forwarded-For`, `X-Forwarded-Host`, and `X-Forwarded-Proto` headers.
- The `X-Azure-ClientIP` header is set by Front Door and represents the TCP-level client IP — this is more trustworthy than XFF in multi-proxy chains.
- For WAF IP restrictions, always match on `SocketAddr` (TCP peer IP), **not** `RemoteAddr` (which respects XFF and is spoofable).

**KQL query — capture client IPs from Front Door access logs:**

Run this in the Log Analytics **Logs** blade after Diagnostic Settings are enabled. It summarizes the client IPs Front Door captured (`clientIp_s`) along with the socket-level peer IP (`socketIp_s`) and HTTP status:

```kql
AzureDiagnostics
| where ResourceProvider == "MICROSOFT.CDN" and Category == "FrontDoorAccessLog"
| where TimeGenerated > ago(1h)
| summarize Requests = count(), FirstSeen = min(TimeGenerated), LastSeen = max(TimeGenerated)
    by clientIp_s, socketIp_s, httpStatusCode_s
| order by Requests desc
```

> **CLI quoting note (Windows):** The Azure CLI strips embedded double quotes from `--analytics-query`. When running this via `az monitor log-analytics query`, replace the inner `"..."` string literals with `'...'` (KQL accepts single quotes). In the portal Logs blade, use it as-is.

Additional Front Door validation queries (per-request detail, X-Forwarded-For chain analysis, top client IPs, and WAF blocked requests) are available in [`queries/xff-frontdoor-validation.kql`](queries/xff-frontdoor-validation.kql).

**Microsoft Learn documentation:**
- [Azure Front Door HTTP headers protocol support](https://learn.microsoft.com/en-us/azure/frontdoor/front-door-http-headers-protocol)
- [Azure Front Door diagnostic logs](https://learn.microsoft.com/en-us/azure/frontdoor/front-door-diagnostics)
- [Monitor metrics and logs in Azure Front Door](https://learn.microsoft.com/en-us/azure/frontdoor/front-door-diagnostics)
- [Azure Front Door WAF custom rules — IP match conditions](https://learn.microsoft.com/en-us/azure/web-application-firewall/afds/waf-front-door-custom-rules)
- [Configure Azure Front Door with a Web Application Firewall (WAF)](https://learn.microsoft.com/en-us/azure/web-application-firewall/afds/waf-front-door-create-portal)

---

### 6.2 Azure Application Gateway

Application Gateway v2 **automatically adds** the client's IP to the `X-Forwarded-For` header before forwarding to backends. However, the default format includes the port (e.g., `10.0.0.1:54321`), which can cause issues downstream.

**How to configure XFF logging:**

1. **Enable Diagnostic Settings** — Send `ApplicationGatewayAccessLog`, `ApplicationGatewayFirewallLog`, and `ApplicationGatewayPerformanceLog` to a Log Analytics workspace. The access log includes `clientIP` and `httpMethod`.
2. **Create a Rewrite Rule** — Use the server variable `{var_add_x_forwarded_for_proxy}` (which strips `:port`) to normalize the XFF header before it reaches backends.
3. **WAF v2** — Enable WAF diagnostic logs to capture per-rule matches with client IP detail.

**Key behavior:**
- App Gateway appends `client_ip:port` to XFF by default.
- Use rewrite rules to normalize the header (strip the port).
- The `{var_add_x_forwarded_for_proxy}` server variable automatically handles port removal.
- App Gateway also sets `X-Forwarded-Proto` and `X-Forwarded-Port`.

**Microsoft Learn documentation:**
- [Application Gateway HTTP headers and rewrite](https://learn.microsoft.com/en-us/azure/application-gateway/rewrite-http-headers-url)
- [Application Gateway server variables](https://learn.microsoft.com/en-us/azure/application-gateway/rewrite-http-headers-url#server-variables)
- [Tutorial: Rewrite HTTP headers with Application Gateway](https://learn.microsoft.com/en-us/azure/application-gateway/rewrite-http-headers-portal)
- [Application Gateway diagnostics and logging](https://learn.microsoft.com/en-us/azure/application-gateway/application-gateway-diagnostics)
- [Configure WAF on Application Gateway](https://learn.microsoft.com/en-us/azure/web-application-firewall/ag/application-gateway-web-application-firewall-portal)

---

### 6.3 Azure API Management (APIM)

APIM **passes through** the `X-Forwarded-For` header from upstream proxies (Front Door, Application Gateway) to backends. APIM also supports extracting and logging this header through policies and diagnostic settings.

**How to configure XFF logging:**

1. **Enable Diagnostic Settings** — Send `GatewayLogs` to a Log Analytics workspace. These logs include the caller's IP address.
2. **Connect Application Insights** — Under **APIM → Application Insights**, link your Application Insights instance and enable **sampling** for request telemetry.
3. **Configure Diagnostic API-level settings** — Under **APIM → APIs → (your API) → Settings → Diagnostics**, enable logging of request/response headers including `X-Forwarded-For`, `X-Forwarded-Proto`, `X-Forwarded-Host`, and `X-Azure-ClientIP`.
4. **Global Policy** — Use an inbound policy to extract the first-hop IP from XFF, set it as `X-Real-Client-IP`, and trace it via `<trace>` for diagnostics.

**Key behavior:**
- APIM does not modify or set XFF by default — it passes through what it receives.
- You can log specific headers via the built-in diagnostics or Application Insights integration.
- Use `set-header` and `set-variable` policies to extract and propagate the real client IP.
- APIM's built-in `context.Request.IpAddress` returns the immediate caller's IP (which may be App Gateway, not the end user).

**KQL — retrieving client IPs:**

The query depends on which logging pipeline you configured. The `Xff` value holds the real client IP chain, while `client_IP` / `CallerIpAddress` is only the immediate TCP peer (e.g., the App Gateway or Front Door IP).

*Option A — via Application Insights (recommended).* Requires `X-Forwarded-For` to be added under **Headers to log** in the APIM API-level diagnostic settings; the header then appears in `customDimensions` with the `Request-Header-` prefix:

```kusto
requests
| where timestamp > ago(24h)
| extend Xff = tostring(customDimensions["Request-Header-x-forwarded-for"])
| where isnotempty(Xff)
| project timestamp, name, url, resultCode, Xff, client_IP, duration
| order by timestamp desc
```

To extract only the **real client IP** (the leftmost hop in the chain):

```kusto
requests
| where timestamp > ago(24h)
| extend Xff = tostring(customDimensions["Request-Header-x-forwarded-for"])
| extend ClientIp = trim(" ", tostring(split(Xff, ",")[0]))
| where isnotempty(ClientIp)
| project timestamp, name, ClientIp, Xff, resultCode
| order by timestamp desc
```

*Option B — via `ApiManagementGatewayLogs` (GatewayLogs sent directly to Log Analytics):*

```kusto
ApiManagementGatewayLogs
| where TimeGenerated > ago(24h)
| where isnotempty(RequestHeaders)
| extend headers = parse_json(RequestHeaders)
| extend Xff = tostring(headers["X-Forwarded-For"])
| where isnotempty(Xff)
| project TimeGenerated, OperationId, ApiId, Url, ResponseCode, Xff, CallerIpAddress
| order by TimeGenerated desc
```

**Microsoft Learn documentation:**
- [How to use API Management diagnostic settings](https://learn.microsoft.com/en-us/azure/api-management/api-management-howto-use-azure-monitor)
- [APIM policy reference — set-header](https://learn.microsoft.com/en-us/azure/api-management/set-header-policy)
- [Monitor APIs with Azure Application Insights](https://learn.microsoft.com/en-us/azure/api-management/api-management-howto-app-insights)
- [APIM advanced request throttling — using client IP](https://learn.microsoft.com/en-us/azure/api-management/api-management-sample-flexible-throttling)
- [API Management diagnostics logging settings](https://learn.microsoft.com/en-us/azure/api-management/diagnostic-logs-reference)

---

### 6.4 Azure App Service

Azure App Service is typically the **innermost backend** in a multi-tier architecture. The platform **receives** the `X-Forwarded-For` header from upstream proxies (Front Door, App Gateway, APIM) but **does not set, modify, or natively log it**. Capturing XFF on App Service requires application-level configuration plus the right telemetry pipeline.

**Default platform behavior:**

| Aspect | Behavior |
|--------|----------|
| **Inbound XFF header** | Available in `HttpRequest.Headers["X-Forwarded-For"]` — App Service does **not** strip it |
| **`REMOTE_ADDR` / `HttpContext.Connection.RemoteIpAddress`** | TCP peer IP only (e.g., the upstream App Gateway/APIM IP) — **not** the real end-user IP |
| **`AppServiceHTTPLogs.CIp`** | TCP peer IP only — **no XFF column exists** in the platform diagnostic table |
| **Application Insights `client_IP`** | Anonymized to `0.0.0.0` by default (privacy) — and even when enabled, reflects the TCP peer, not XFF |

> **Key limitation:** Because `AppServiceHTTPLogs` has no XFF column, you **cannot** capture the original client IP through diagnostic settings alone. You must propagate XFF into Application Insights `customDimensions` (or another structured log sink) from the application layer.

**How to configure XFF logging:**

1. **Enable Diagnostic Settings** — Send `AppServiceHTTPLogs`, `AppServiceConsoleLogs`, and `AppServiceAppLogs` to a Log Analytics workspace. Note: this captures the TCP peer IP only; treat it as an audit trail, not as the real client IP.
2. **Link Application Insights** — Under **App Service → Application Insights**, enable the recommended agent or SDK. This is the pipeline that will carry the XFF value end-to-end.
3. **Configure `ForwardedHeadersMiddleware` (ASP.NET Core)** — Enable forwarded-header processing **before** auth/routing, and set `KnownNetworks` / `KnownProxies` to the subnets of your App Gateway / APIM / Front Door fronting tier. This makes `HttpContext.Connection.RemoteIpAddress` resolve to the real client.
4. **Add a Telemetry Initializer** — Write `X-Forwarded-For` (raw) and the resolved client IP into App Insights `customDimensions` so they are queryable from KQL. See the sample [`XffTelemetryInitializer`](samples/dotnet/Program.cs).
5. **Python / Flask / FastAPI** — Use `werkzeug.middleware.proxy_fix.ProxyFix` (Flask) or a custom ASGI middleware (FastAPI) with a configured trusted-hop count, and emit XFF as a span attribute via Azure Monitor OpenTelemetry. See [`samples/python/xff_middleware.py`](samples/python/xff_middleware.py).
6. **Classic ASP.NET (.NET Framework 4.x)** — Read `Request.ServerVariables["HTTP_X_FORWARDED_FOR"]` in a `Global.asax` `BeginRequest` handler and attach it via a custom `ITelemetryInitializer` registered in `ApplicationInsights.config`. See [`samples/dotnet-framework-47/`](samples/dotnet-framework-47/).

**Key behavior:**
- App Service is **passive** with respect to XFF — it neither adds nor strips the header. Whatever the upstream proxy puts on the wire is what your app code sees.
- The first (leftmost) IP in XFF is the original client; subsequent entries are each intermediate proxy in order. Always extract the leftmost untrusted IP after applying your trusted-proxy list.
- `ForwardLimit` should match the number of trusted proxies in the chain (e.g., `3` for Proxy → App Gateway → APIM → App Service). Setting it to `null` lets the middleware honour the full chain — only safe when `KnownNetworks` strictly bounds trust.
- App Insights `client_IP` collection is **opt-in**. Even when enabled, it reflects the peer the App Insights SDK observes (typically App Gateway) — `customDimensions['ResolvedClientIp']` populated from XFF is the source of truth for the real user IP.
- For **Linux App Service**, the same middleware patterns apply; there is no platform-level difference for XFF handling between Windows and Linux plans.

**KQL — querying the XFF you wrote into Application Insights:**

```kusto
requests
| where timestamp > ago(1h)
| extend Xff = tostring(customDimensions["X-Forwarded-For"])
| extend ResolvedClientIp = tostring(customDimensions["ResolvedClientIp"])
| where isnotempty(Xff)
| project timestamp, name, resultCode, Xff, ResolvedClientIp, AppGwClientIp = client_IP
| take 50
```

**Microsoft Learn documentation:**
- [Configure ASP.NET Core to work with proxy servers and load balancers](https://learn.microsoft.com/en-us/aspnet/core/host-and-deploy/proxy-load-balancer)
- [App Service diagnostic logs — enable and view](https://learn.microsoft.com/en-us/azure/app-service/troubleshoot-diagnostic-logs)
- [`AppServiceHTTPLogs` table reference](https://learn.microsoft.com/en-us/azure/azure-monitor/reference/tables/appservicehttplogs)
- [Application Insights for ASP.NET Core](https://learn.microsoft.com/en-us/azure/azure-monitor/app/asp-net-core)
- [Application Insights `ITelemetryInitializer`](https://learn.microsoft.com/en-us/azure/azure-monitor/app/api-filtering-sampling#add-properties-itelemetryinitializer)
- [Capture X-Forwarded-For in App Service (Q&A)](https://learn.microsoft.com/en-us/answers/questions/1053449/can-we-capture-x-forwarded-for-header-in-app-servi)
- [Flask `ProxyFix` middleware](https://werkzeug.palletsprojects.com/en/latest/middleware/proxy_fix/)
- [Azure Monitor OpenTelemetry for Python](https://learn.microsoft.com/en-us/azure/azure-monitor/app/opentelemetry-enable?tabs=python)

> **About App Gateway `AGWAccessLogs.ClientIp`** — Multiple customers ask whether `ClientIp` should contain the full `X-Forwarded-For` chain. **No — this is by design.** The `ClientIp` column always records the **TCP peer IP** (the device directly connected to App Gateway). When a proxy or Front Door sits in front of App Gateway, `ClientIp` is that proxy's IP, not the original client. The full XFF chain is not surfaced as a dedicated column in `AGWAccessLogs`; capture it by (a) using a rewrite rule with the `{var_add_x_forwarded_for_proxy}` server variable to normalize XFF before it reaches the backend, and (b) logging the resolved client IP in your backend's Application Insights `customDimensions` (sections 6.2 and 6.4 above). See [AGWAccessLogs schema](https://learn.microsoft.com/en-us/azure/azure-monitor/reference/tables/agwaccesslogs).

---

## 7. Centralized Azure Policy for XFF Governance

Use Azure Policy at the **management group** or **subscription** scope to enforce XFF header logging and normalization across all three services centrally.

### 7.1 Policy Strategy

| Service | Policy Type | What It Enforces |
|---------|------------|------------------|
| **Azure Front Door** | **AuditIfNotExists** | Front Door profiles must have diagnostic settings sending `FrontDoorAccessLog` to a Log Analytics workspace |
| **Azure Front Door** | **DeployIfNotExists** | Auto-deploy diagnostic settings for Front Door when created |
| **Application Gateway** | **Audit** | App Gateways must have the XFF normalization rewrite rule set |
| **Application Gateway** | **DeployIfNotExists** | Auto-deploy diagnostic settings (access + firewall logs) to the central workspace |
| **APIM** | **AuditIfNotExists** | APIM instances must have diagnostic settings configured |
| **APIM** | **AuditIfNotExists** | APIM instances must have Application Insights linked |

### 7.2 Built-in Azure Policies (No Custom Definitions Needed)

Azure provides several built-in policies that cover diagnostic logging. Use these before writing custom policies:

| Built-in Policy | Applies To | ID |
|-----------------|------------|----|
| *Diagnostic logs in Azure Front Door should be enabled* | Front Door | `cef7eea0-dd51-4067-b8d5-46f5a0111b84` (category-based) |
| *Azure Application Gateway should have Resource logs enabled* | App Gateway | Built-in diagnostic category |
| *API Management services should use a virtual network* | APIM | Network-level control |
| *Diagnostic settings for Application Gateway to Log Analytics* | App Gateway | DeployIfNotExists |

> **Tip**: Search for `"diagnostic"` or `"logs"` in the Azure Policy portal under **Definitions** to find the latest built-in policies for each service.

**Microsoft Learn documentation:**
- [Azure Policy built-in definitions for networking](https://learn.microsoft.com/en-us/azure/governance/policy/samples/built-in-policies#network)
- [Azure Policy built-in definitions for API Management](https://learn.microsoft.com/en-us/azure/governance/policy/samples/built-in-policies#api-management)
- [Azure Policy built-in definitions for monitoring](https://learn.microsoft.com/en-us/azure/governance/policy/samples/built-in-policies#monitoring)
- [Deploy diagnostic settings at scale with Azure Policy](https://learn.microsoft.com/en-us/azure/azure-monitor/essentials/diagnostic-settings-policy)
- [Azure Policy initiative definitions](https://learn.microsoft.com/en-us/azure/governance/policy/concepts/initiative-definition-structure)
- [Remediate non-compliant resources with Azure Policy](https://learn.microsoft.com/en-us/azure/governance/policy/how-to/remediate-resources)

### 7.3 Custom Policy Initiative (XFF-Specific)

For XFF-specific governance beyond built-in diagnostic policies, create a custom **Policy Initiative** that bundles:

1. **Front Door diagnostic audit** — Ensures `FrontDoorAccessLog` is flowing to Log Analytics
2. **App Gateway XFF rewrite audit** — Ensures the `xff-normalization-ruleset` rewrite rule exists
3. **App Gateway diagnostic deployment** — Auto-deploys diagnostic settings on new App Gateways
4. **APIM diagnostic audit** — Ensures diagnostic settings exist on all APIM instances

Assign this initiative at the **management group level** to cover all subscriptions uniformly.

See [`policies/xff-policy-initiative.json`](policies/xff-policy-initiative.json) for the initiative template used in this repo.

---

## 8. Official Microsoft Learn & GitHub References

### Configuration & How-To Guides

| Topic | Link |
|-------|------|
| Configure X-Forwarded-For on App Gateway (rewrite rules) | [Tutorial: Rewrite HTTP headers — Azure portal](https://learn.microsoft.com/en-us/azure/application-gateway/rewrite-http-headers-portal) |
| Front Door HTTP headers and protocol support | [Front Door HTTP headers](https://learn.microsoft.com/en-us/azure/frontdoor/front-door-http-headers-protocol) |
| Front Door rules engine — header manipulation | [Front Door rules engine actions](https://learn.microsoft.com/en-us/azure/frontdoor/front-door-rules-engine-actions) |
| APIM policy for setting/forwarding headers | [APIM set-header policy](https://learn.microsoft.com/en-us/azure/api-management/set-header-policy) |
| Configure APIM diagnostic logging | [APIM diagnostic settings](https://learn.microsoft.com/en-us/azure/api-management/api-management-howto-use-azure-monitor) |
| ForwardedHeaders middleware in ASP.NET Core | [Configure ASP.NET Core to work with proxy servers](https://learn.microsoft.com/en-us/aspnet/core/host-and-deploy/proxy-load-balancer) |
| App Service behind proxies — header forwarding | [App Service networking features](https://learn.microsoft.com/en-us/azure/app-service/networking-features) |

### Architecture & Best Practices

| Topic | Link |
|-------|------|
| End-to-end TLS with Front Door and App Gateway | [End-to-end TLS with Azure Front Door](https://learn.microsoft.com/en-us/azure/frontdoor/end-to-end-tls) |
| Application Gateway + APIM multi-tier design | [Protect APIs with Application Gateway and APIM](https://learn.microsoft.com/en-us/azure/architecture/reference-architectures/apis/protect-apis) |
| Hub-spoke network topology with shared services | [Hub-spoke network topology in Azure](https://learn.microsoft.com/en-us/azure/architecture/networking/architecture/hub-spoke) |
| Zero-trust network for web applications | [Zero-trust network for web applications](https://learn.microsoft.com/en-us/azure/architecture/example-scenario/gateway/application-gateway-before-azure-firewall) |

### Azure Policy & Governance

| Topic | Link |
|-------|------|
| Azure Policy overview | [What is Azure Policy?](https://learn.microsoft.com/en-us/azure/governance/policy/overview) |
| Create custom policy definitions | [Tutorial: Create custom policy definitions](https://learn.microsoft.com/en-us/azure/governance/policy/tutorials/create-custom-policy-definition) |
| Deploy diagnostic settings via policy | [Create diagnostic settings at scale](https://learn.microsoft.com/en-us/azure/azure-monitor/essentials/diagnostic-settings-policy) |
| Policy initiative structure | [Initiative definition structure](https://learn.microsoft.com/en-us/azure/governance/policy/concepts/initiative-definition-structure) |
| Management group organization | [Organize resources with management groups](https://learn.microsoft.com/en-us/azure/governance/management-groups/overview) |

### GitHub Samples & Quickstarts

| Topic | Link |
|-------|------|
| Azure Policy samples (official) | [github.com/Azure/azure-policy](https://github.com/Azure/azure-policy) |
| Azure Policy community definitions | [github.com/Azure/Community-Policy](https://github.com/Azure/Community-Policy) |
| Azure Monitor community workbooks | [github.com/microsoft/Application-Insights-Workbooks](https://github.com/microsoft/Application-Insights-Workbooks) |
| Azure network security samples | [github.com/Azure/azure-quickstart-templates](https://github.com/Azure/azure-quickstart-templates) |
| APIM policy snippets | [github.com/Azure/api-management-policy-snippets](https://github.com/Azure/api-management-policy-snippets) |

---

## 9. Security & Integrity Notes

| Topic | Guidance |
|-------|----------|
| **AFD IP enforcement** | Use `SocketAddr` (real TCP peer) at WAF, not `RemoteAddr` (XFF-respecting, spoofable). [Reference](https://trustedsec.com/blog/azures-front-door-waf-wtf-ip-restriction-bypass) |
| **Trust boundaries** | Only trust XFF from known proxies (App Gateway/AFD/APIM). Configure `KnownProxies`/`KnownNetworks` accordingly. |
| **X-Azure-ClientIP** | If AFD fronts your app, this header is set by AFD and may be easier to reason about than XFF. [Reference](https://learn.microsoft.com/en-us/azure/frontdoor/front-door-http-headers-protocol) |
| **Port stripping** | The App Gateway rewrite rule (`{var_add_x_forwarded_for_proxy}`) strips `:port` from XFF. Monitor for non-normalized values (query #9). |
| **Front Door header trust** | Only trust `X-Azure-ClientIP` and `X-Azure-SocketIP` from Front Door if traffic is restricted to Front Door IPs via App Gateway or NSGs. [Reference](https://learn.microsoft.com/en-us/azure/frontdoor/front-door-faq#how-do-i-lock-down-the-access-to-my-backend-to-only-azure-front-door-) |
| **Multi-proxy XFF chain** | In a Front Door → App Gateway → APIM chain, XFF will contain multiple IPs. Always extract the **first** (leftmost) untrusted IP for the real client. |

---

## References

- [App Gateway – Rewrite HTTP Headers](https://learn.microsoft.com/en-us/azure/application-gateway/rewrite-http-headers-url)
- [App Gateway – Monitoring](https://learn.microsoft.com/en-us/azure/application-gateway/monitor-application-gateway)
- [AGWAccessLogs Table](https://learn.microsoft.com/en-us/azure/azure-monitor/reference/tables/agwaccesslogs)
- [APIM – Azure Monitor Integration](https://learn.microsoft.com/en-us/azure/api-management/api-management-howto-use-azure-monitor)
- [APIM – Logging Headers to App Insights](https://iliaselmatani.codes/posts/apimlog/)
- [App Service – Capture XFF](https://learn.microsoft.com/en-us/answers/questions/1053449/can-we-capture-x-forwarded-for-header-in-app-servi)
- [ASP.NET Core – Proxy Load Balancer](https://learn.microsoft.com/en-us/aspnet/core/host-and-deploy/proxy-load-balancer)
- [AFD HTTP Headers](https://learn.microsoft.com/en-us/azure/frontdoor/front-door-http-headers-protocol)
