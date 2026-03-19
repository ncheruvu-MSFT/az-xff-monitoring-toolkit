# XFF Monitoring — Azure App Service

Azure App Service is typically the innermost backend in an Azure multi-tier architecture. It **receives** the `X-Forwarded-For` header from upstream proxies but does not set or modify it. Your application code must explicitly read and process XFF using middleware.

## How App Service Handles XFF

### Default Behavior

| Aspect | Behavior |
|--------|----------|
| **Inbound XFF** | Available in the request headers — App Service platform does not strip it |
| **`REMOTE_ADDR`** | Set to the immediate TCP peer IP (e.g., App Gateway or APIM IP) |
| **Native HTTP logs** | `AppServiceHTTPLogs.CIp` = TCP peer IP, **not** the XFF client IP |
| **Application Insights** | XFF not captured by default — requires middleware or telemetry initializer |

> **Key limitation:** `AppServiceHTTPLogs` does **not** include an XFF column. You must log XFF through application-level telemetry (Application Insights, OpenTelemetry) to capture it.

## .NET — ForwardedHeaders Middleware

ASP.NET Core provides built-in `ForwardedHeadersMiddleware` to resolve the real client IP from XFF.

### Configuration (from this repo's sample)

See [samples/dotnet/Program.cs](../samples/dotnet/Program.cs):

```csharp
builder.Services.Configure<ForwardedHeadersOptions>(options =>
{
    options.ForwardedHeaders =
        ForwardedHeaders.XForwardedFor |
        ForwardedHeaders.XForwardedProto |
        ForwardedHeaders.XForwardedHost;

    // Only trust known proxy subnets
    options.KnownNetworks.Add(new IPNetwork(IPAddress.Parse("10.0.0.0"), 8));
    options.KnownNetworks.Add(new IPNetwork(IPAddress.Parse("172.16.0.0"), 12));

    // Clear forward limit for multi-proxy chains (AppGW → APIM → App Service)
    options.ForwardLimit = null;
});

var app = builder.Build();

// MUST be called before auth, routing, etc.
app.UseForwardedHeaders();
```

### Application Insights Telemetry Initializer

To capture XFF in App Insights `customDimensions`:

```csharp
public class XffTelemetryInitializer : ITelemetryInitializer
{
    private readonly IHttpContextAccessor _httpContextAccessor;

    public XffTelemetryInitializer(IHttpContextAccessor httpContextAccessor)
    {
        _httpContextAccessor = httpContextAccessor;
    }

    public void Initialize(ITelemetry telemetry)
    {
        if (telemetry is RequestTelemetry requestTelemetry)
        {
            var context = _httpContextAccessor.HttpContext;
            if (context == null) return;

            var xff = context.Items["X-Forwarded-For"]?.ToString()
                ?? context.Request.Headers["X-Forwarded-For"].FirstOrDefault();

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

### Critical Order of Middleware

```csharp
app.UseForwardedHeaders();   // ← FIRST
// ... other middleware
app.UseAuthentication();
app.UseAuthorization();
app.MapControllers();
```

`UseForwardedHeaders()` must be called **before** authentication and authorization to ensure the resolved client IP is used for IP-based access decisions.

## Python — Flask and FastAPI

### Flask with ProxyFix

See [samples/python/xff_middleware.py](../samples/python/xff_middleware.py):

```python
from flask import Flask, request
from werkzeug.middleware.proxy_fix import ProxyFix

app = Flask(__name__)

# Trust 2 proxies (App Gateway → APIM → App Service)
# x_for=2 means the client IP is 2 hops back in XFF
app.wsgi_app = ProxyFix(app.wsgi_app, x_for=2, x_proto=1, x_host=1)

@app.before_request
def log_xff():
    xff = request.headers.get("X-Forwarded-For", "")
    app.logger.info(f"RemoteAddr: {request.remote_addr} | XFF: {xff}")
```

### FastAPI Middleware

```python
from fastapi import FastAPI, Request
import logging

app = FastAPI()
logger = logging.getLogger("uvicorn")

@app.middleware("http")
async def xff_middleware(request: Request, call_next):
    xff = request.headers.get("X-Forwarded-For", "")
    client_ip = request.client.host
    logger.info(f"ClientIP: {client_ip} | XFF: {xff}")
    response = await call_next(request)
    return response
```

### Azure Monitor OpenTelemetry (Python)

```python
from azure.monitor.opentelemetry import configure_azure_monitor
from opentelemetry import trace

configure_azure_monitor(
    connection_string="InstrumentationKey=<key>;IngestionEndpoint=..."
)

# In your middleware / request handler:
span = trace.get_current_span()
span.set_attribute("http.xff", xff_value)
span.set_attribute("http.client_ip", resolved_client_ip)
```

## Java — Spring Boot

### Configure ForwardedHeaderFilter

```java
import org.springframework.context.annotation.Bean;
import org.springframework.context.annotation.Configuration;
import org.springframework.web.filter.ForwardedHeaderFilter;

@Configuration
public class WebConfig {
    @Bean
    public ForwardedHeaderFilter forwardedHeaderFilter() {
        return new ForwardedHeaderFilter();
    }
}
```

### Application Properties

```properties
# Trust proxy headers from known networks
server.forward-headers-strategy=FRAMEWORK
server.tomcat.remoteip.internal-proxies=10\\.\\d{1,3}\\.\\d{1,3}\\.\\d{1,3}|172\\.1[6-9]\\.\\d{1,3}\\.\\d{1,3}|172\\.2[0-9]\\.\\d{1,3}\\.\\d{1,3}|172\\.3[0-1]\\.\\d{1,3}\\.\\d{1,3}
```

### Log XFF to Application Insights (Java Agent)

The Azure Monitor Java agent (`applicationinsights-agent-*.jar`) can capture request headers as custom dimensions. Add to `applicationinsights.json`:

```json
{
  "preview": {
    "captureHttpServerHeaders": {
      "requestHeaders": ["X-Forwarded-For", "X-Azure-ClientIP"]
    }
  }
}
```

## Node.js — Express

### Trust Proxy Setting

```javascript
const express = require('express');
const app = express();

// Trust 2 hops of proxies (App Gateway → APIM)
app.set('trust proxy', 2);

app.use((req, res, next) => {
    const clientIp = req.ip;           // Resolved from XFF based on trust proxy
    const xff = req.headers['x-forwarded-for'];
    console.log(`ClientIP: ${clientIp} | XFF: ${xff}`);
    next();
});
```

### Application Insights SDK (Node.js)

```javascript
const appInsights = require('applicationinsights');
appInsights.setup('<connection-string>').start();

appInsights.defaultClient.addTelemetryProcessor((envelope, context) => {
    if (envelope.data.baseType === 'RequestData') {
        const xff = context?.['http.ServerRequest']?.headers?.['x-forwarded-for'];
        if (xff) {
            envelope.data.baseData.properties = envelope.data.baseData.properties || {};
            envelope.data.baseData.properties['X-Forwarded-For'] = xff;
        }
    }
    return true;
});
```

## KQL Queries

### App Service XFF via Application Insights

```kql
requests
| where timestamp > ago(24h)
| where cloud_RoleName contains "<your-app-service-name>"
| extend xff = tostring(customDimensions["X-Forwarded-For"])
| project timestamp, name, url, resultCode, xff, client_IP
| order by timestamp desc
```

### Native HTTP Logs (No XFF Column)

```kql
AppServiceHTTPLogs
| where TimeGenerated > ago(24h)
| project
    TimeGenerated,
    CIp,           // TCP peer IP (proxy IP if behind one)
    CsHost,
    CsUriStem,
    ScStatus,
    TimeTaken,
    UserAgent
| order by TimeGenerated desc
```

## Diagnostic Settings for App Service

**Azure CLI:**

```bash
az monitor diagnostic-settings create \
  --name "xff-diag-appsvc" \
  --resource "/subscriptions/<sub-id>/resourceGroups/<rg>/providers/Microsoft.Web/sites/<app-name>" \
  --workspace "/subscriptions/<sub-id>/resourceGroups/<rg>/providers/Microsoft.OperationalInsights/workspaces/<workspace-name>" \
  --logs '[{"category":"AppServiceHTTPLogs","enabled":true},{"category":"AppServiceConsoleLogs","enabled":true},{"category":"AppServiceAppLogs","enabled":true}]' \
  --metrics '[{"category":"AllMetrics","enabled":true}]'
```

## Microsoft Learn References

- [Configure ASP.NET Core to work with proxy servers and load balancers](https://learn.microsoft.com/en-us/aspnet/core/host-and-deploy/proxy-load-balancer)
- [App Service networking features](https://learn.microsoft.com/en-us/azure/app-service/networking-features)
- [Enable diagnostic logging for App Service](https://learn.microsoft.com/en-us/azure/app-service/troubleshoot-diagnostic-logs)
- [Monitor App Service with Azure Monitor](https://learn.microsoft.com/en-us/azure/app-service/monitor-app-service)
- [Application Insights for ASP.NET Core](https://learn.microsoft.com/en-us/azure/azure-monitor/app/asp-net-core)
- [Flask — ProxyFix middleware](https://flask.palletsprojects.com/en/latest/deploying/proxy_fix/)
- [Azure Monitor OpenTelemetry for Python](https://learn.microsoft.com/en-us/azure/azure-monitor/app/opentelemetry-enable?tabs=python)
- [Azure Monitor Java agent — capture request headers](https://learn.microsoft.com/en-us/azure/azure-monitor/app/java-standalone-config#capture-http-server-headers)
- [Application Insights for Node.js](https://learn.microsoft.com/en-us/azure/azure-monitor/app/nodejs)
- [Spring Boot — ForwardedHeaderFilter](https://docs.spring.io/spring-boot/reference/web/servlet.html#web.servlet.embedded-container.customizing.forwarded-headers)

## GitHub References

- [microsoft/ApplicationInsights-dotnet](https://github.com/microsoft/ApplicationInsights-dotnet) — .NET App Insights SDK
- [microsoft/ApplicationInsights-Java](https://github.com/microsoft/ApplicationInsights-Java) — Java App Insights agent
- [microsoft/ApplicationInsights-node.js](https://github.com/microsoft/ApplicationInsights-node.js) — Node.js App Insights SDK
- [Azure/azure-sdk-for-python — azure-monitor-opentelemetry](https://github.com/Azure/azure-sdk-for-python/tree/main/sdk/monitor/azure-monitor-opentelemetry) — Python OpenTelemetry exporter
