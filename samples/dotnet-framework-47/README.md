# XFF Demo — .NET Framework 4.7.2 (ASP.NET Web Forms)

> Targets `v4.7.2` (the lowest available targeting pack on most modern build agents; runtime is fully compatible with 4.7). Retarget to `v4.7` in the csproj if you have the 4.7 dev pack installed.

A minimal ASP.NET application that runs on **Azure App Service (Windows)** and:

1. **Captures** `X-Forwarded-For` and related headers on every request via an `IHttpModule`.
2. **Reports** them via an in-app dashboard (`Reports.aspx`) with CSV/JSON export.
3. **Forwards** them to **Application Insights** as `customDimensions` via a custom `ITelemetryInitializer`, so the KQL queries in [`queries/xff-custom-dimensions.kql`](../../queries/xff-custom-dimensions.kql) work out of the box.

> Companion to the ASP.NET Core sample in [samples/dotnet](../dotnet). Use this one when your target is a classic Windows App Service running .NET Framework 4.x.

## Files

| File | Purpose |
|---|---|
| [Global.asax](Global.asax) / [Global.asax.cs](Global.asax.cs) | App entry point |
| [App_Code/XffCapture.cs](App_Code/XffCapture.cs) | In-memory ring buffer (max 500 entries) + `XffEntry` model + IP resolver |
| [App_Code/XffHttpModule.cs](App_Code/XffHttpModule.cs) | Per-request hook that stashes headers into `HttpContext.Items` and the buffer |
| [App_Code/XffTelemetryInitializer.cs](App_Code/XffTelemetryInitializer.cs) | Adds XFF fields to `RequestTelemetry.Properties` (App Insights `customDimensions`) |
| [Default.aspx](Default.aspx) / [.cs](Default.aspx.cs) | Echo page showing current request's headers and resolved IP |
| [Reports.aspx](Reports.aspx) / [.cs](Reports.aspx.cs) | Dashboard: totals, top IPs, recent requests, CSV/JSON export, clear-buffer button |
| [Web.config](Web.config) | Registers `XffHttpModule` + AI module |
| [ApplicationInsights.config](ApplicationInsights.config) | Wires the `XffTelemetryInitializer` and the built-in `ClientIpHeaderTelemetryInitializer` (so `client_IP` in AI = first IP in XFF) |
| [deploy.ps1](deploy.ps1) | Restore → build → zip → `az webapp deploy` |
| [Test-XffCapture.ps1](Test-XffCapture.ps1) | Local test suite: sends 8 varied XFF requests then asserts the Reports JSON/CSV/HTML — 11 assertions including left-most-IP resolution, IPv4 port stripping, X-Real-Client-IP capture, multi-hop chains |

## What gets captured

Per request, the module records:

- `RemoteAddr` — TCP peer (what App Service sees; usually the App GW / AFD IP)
- `X-Forwarded-For` — full chain
- `X-Forwarded-Proto`, `X-Forwarded-Host`
- `X-Real-Client-IP` — set by APIM policy ([apim-policy/xff-global-policy.xml](../apim-policy/xff-global-policy.xml))
- `X-Azure-ClientIP`, `X-Azure-SocketIP` — front-end-added headers on App Service
- `ResolvedClientIp` — left-most IP in XFF (the real client)

These appear in App Insights as `customDimensions["X-Forwarded-For"]`, `customDimensions["ResolvedClientIp"]`, etc.

The built-in `ClientIpHeaderTelemetryInitializer` is configured with `UseFirstIp=true`, so the standard `client_IP` column in `requests` / `AppRequests` shows the real client (not `0.0.0.0`).

## Prerequisites

- **Windows App Service** plan (any tier). Linux App Service requires the .NET Core sample.
- Visual Studio Build Tools 2019/2022 with the **Web development** workload (provides MSBuild + `Microsoft.WebApplication.targets`), or full Visual Studio.
- Azure CLI (`az login` first).
- An Application Insights resource (optional but recommended).

## Local build & run

```powershell
# From this folder
nuget restore .\XffDemo.Net47.csproj -PackagesDirectory .\packages
msbuild .\XffDemo.Net47.csproj /p:Configuration=Debug
# Open in IIS Express via Visual Studio, or:
# %ProgramFiles%\IIS Express\iisexpress.exe /path:"$PWD" /port:8080
```

Then browse:

- `http://localhost:8080/Default.aspx` — echo
- `http://localhost:8080/Reports.aspx` — dashboard

To exercise XFF locally without a proxy:

```powershell
curl -H "X-Forwarded-For: 203.0.113.7, 10.0.0.4" http://localhost:8080/
```

### Automated test suite

With IIS Express running on port `8088`:

```powershell
& "${env:ProgramFiles}\IIS Express\iisexpress.exe" /path:"$PWD" /port:8088 /clr:v4.0
# (in another shell)
.\Test-XffCapture.ps1
```

Expected output:

```
=== Sending 8 requests ===
  No XFF                    -> HTTP 200
  Single hop                -> HTTP 200
  Multi-hop chain           -> HTTP 200
  With APIM real-client     -> HTTP 200
  Azure front-end           -> HTTP 200
  IPv4 with port            -> HTTP 200
  Repeat known client       -> HTTP 200
  Repeat known client 2     -> HTTP 200

=== Assertions ===
  [PASS] At least 8 entries captured
  [PASS] Single-hop resolves to 203.0.113.7
  [PASS] Multi-hop picks left-most (198.51.100.10)
  [PASS] X-Real-Client-IP captured
  [PASS] X-Azure-ClientIP captured
  [PASS] IPv4 port stripped (203.0.113.99)
  [PASS] Repeat client appears >=3 times
  [PASS] CSV has expected columns
  [PASS] HTML report contains 203.0.113.7
  [PASS] HTML report contains 198.51.100.10
  [PASS] HTML report contains 'Top Resolved'

Passed: 11 / Failed: 0
```

## Deploy to App Service

```powershell
.\deploy.ps1 `
    -ResourceGroup rg-xff-test-eastus `
    -AppName app-xff-test-cg4l2wl4myrww `
    -AppInsightsName ai-xff-test-cg4l2wl4myrww
```

The script:

1. Restores NuGet packages into `./packages`
2. Builds with MSBuild, publishing to `./publish`
3. Zips the publish output
4. Pushes via `az webapp deploy --type zip`
5. Sets `APPLICATIONINSIGHTS_CONNECTION_STRING` on the site
6. **Disables codeless AI** (`ApplicationInsightsAgent_EXTENSION_VERSION=disabled`) so the SDK-installed initializer is the only one running — otherwise you get duplicate telemetry and the codeless layer can overwrite `client_IP` with `0.0.0.0` (see [`/memories/repo/xff-test-environment.md`](../../.) finding).

## Viewing reports

### In-app
- `https://<app>.azurewebsites.net/Reports.aspx` — live dashboard
- `?format=csv` — download recent buffer as CSV
- `?format=json` — JSON

### In Application Insights / Log Analytics
Use the queries in [`queries/xff-custom-dimensions.kql`](../../queries/xff-custom-dimensions.kql). Quick check:

```kusto
requests
| where timestamp > ago(1h)
| extend xff = tostring(customDimensions["X-Forwarded-For"])
| extend resolved = tostring(customDimensions["ResolvedClientIp"])
| project timestamp, name, client_IP, resolved, xff
| order by timestamp desc
```

### In the demo workbook
The workbook [`workbook/xff-proxy-appgw-demo-workbook.json`](../../workbook/xff-proxy-appgw-demo-workbook.json) section *"Solution — XFF from App Insights customDimensions"* renders these fields directly.

## Security notes

- The Reports page is **unauthenticated** by design (demo). Before exposing it publicly, add Easy Auth (App Service Authentication) or move to an admin-only path.
- The XFF header is **client-controllable** unless your edge stripped/replaced it. Only trust the left-most XFF entry when traffic ingressed through a known proxy that overwrites/appends the header. App Gateway with the `{var_add_x_forwarded_for_proxy}` rewrite (see [infra/modules/appgateway-xff-rewrite.bicep](../../infra/modules/appgateway-xff-rewrite.bicep)) does this correctly.
- The in-memory buffer is **per-instance**. Scaled-out sites will have one buffer per worker; use App Insights for cross-instance reporting.
