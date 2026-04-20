// ============================================================================
// ASP.NET Core – ForwardedHeaders Middleware + XFF Telemetry Initializer
// ============================================================================
// Demonstrates how to:
//   1. Configure ForwardedHeadersMiddleware with known proxies so the app
//      sees the real client IP from X-Forwarded-For.
//   2. Log the XFF value into Application Insights customDimensions so it
//      appears in KQL queries against the `requests` table.
//   3. Handle multi-tier proxy chains including APIM in the path:
//      Client → Proxy (VIP) → App Gateway → APIM → App Service
//
// References:
//   https://learn.microsoft.com/en-us/aspnet/core/host-and-deploy/proxy-load-balancer
//   https://learn.microsoft.com/en-us/azure/api-management/api-management-howto-deploy-multi-region
// ============================================================================

using System.Net;
using Microsoft.ApplicationInsights.Channel;
using Microsoft.ApplicationInsights.DataContracts;
using Microsoft.ApplicationInsights.Extensibility;
using Microsoft.AspNetCore.HttpOverrides;
using Microsoft.AspNetCore.Http;

var builder = WebApplication.CreateBuilder(args);

// ── 1. Configure Forwarded Headers ─────────────────────────────────────────
builder.Services.Configure<ForwardedHeadersOptions>(options =>
{
    options.ForwardedHeaders =
        ForwardedHeaders.XForwardedFor |
        ForwardedHeaders.XForwardedProto |
        ForwardedHeaders.XForwardedHost;

    // IMPORTANT: Only trust known proxy IPs.
    // Add your Application Gateway / AFD / APIM subnet(s) here.
    // Using CIDR notation for internal subnets is recommended.
    options.KnownNetworks.Add(new Microsoft.AspNetCore.HttpOverrides.IPNetwork(IPAddress.Parse("10.0.0.0"), 8));
    options.KnownNetworks.Add(new Microsoft.AspNetCore.HttpOverrides.IPNetwork(IPAddress.Parse("172.16.0.0"), 12));

    // If your App Gateway has a specific VIP:
    // options.KnownProxies.Add(IPAddress.Parse("20.x.x.x"));

    // If APIM is in the chain, add the APIM VIP(s) so the middleware
    // can peel back the correct number of XFF hops:
    // options.KnownProxies.Add(IPAddress.Parse("<apim-public-vip>"));

    // Clear default limits for chained proxies (AppGW → APIM → App Service)
    // With APIM in the chain there are 3+ hops: Proxy → AppGW → APIM → App
    options.ForwardLimit = null;
});

// ── 2. Register Application Insights + XFF telemetry initializer ────────────
builder.Services.AddApplicationInsightsTelemetry();
builder.Services.AddHttpContextAccessor();
builder.Services.AddSingleton<ITelemetryInitializer, XffTelemetryInitializer>();

// Add your other services...
builder.Services.AddControllers();

var app = builder.Build();

// ── 3. Use Forwarded Headers FIRST (before auth, routing, etc.) ─────────────
app.UseForwardedHeaders();

// Optional: log the resolved client IP for debugging
app.Use(async (context, next) =>
{
    var clientIp = context.Connection.RemoteIpAddress?.ToString();
    var xff = context.Request.Headers["X-Forwarded-For"].FirstOrDefault();
    context.Items["X-Forwarded-For"] = xff;  // pass to telemetry initializer

    // Capture X-Real-Client-IP if APIM policy sets it (see xff-global-policy.xml)
    var realClientIp = context.Request.Headers["X-Real-Client-IP"].FirstOrDefault();
    context.Items["X-Real-Client-IP"] = realClientIp;

    app.Logger.LogDebug(
        "Request from {ClientIp}, XFF: {XForwardedFor}, X-Real-Client-IP: {RealClientIp}, Path: {Path}",
        clientIp, xff ?? "(none)", realClientIp ?? "(none)", context.Request.Path);

    await next();
});

app.UseAuthorization();
app.MapControllers();

// Simple health/demo endpoint
app.MapGet("/", (HttpContext ctx) =>
{
    var xff = ctx.Request.Headers["X-Forwarded-For"].FirstOrDefault() ?? "(none)";
    var realClientIp = ctx.Request.Headers["X-Real-Client-IP"].FirstOrDefault() ?? "(none)";
    var remoteIp = ctx.Connection.RemoteIpAddress?.ToString() ?? "(unknown)";
    return Results.Ok(new
    {
        message = "XFF Demo App",
        remoteIpAddress = remoteIp,
        xForwardedFor = xff,
        xRealClientIp = realClientIp
    });
});

app.Run();


// ── Telemetry Initializer ───────────────────────────────────────────────────
// Attaches the X-Forwarded-For header value to every request telemetry item
// so it shows up in App Insights customDimensions["X-Forwarded-For"].

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

            // Prefer the value stashed in HttpContext.Items (post-ForwardedHeaders processing)
            var xff = context.Items["X-Forwarded-For"]?.ToString();

            // Fallback: read header directly
            if (string.IsNullOrEmpty(xff))
            {
                xff = context.Request.Headers["X-Forwarded-For"].FirstOrDefault();
            }

            if (!string.IsNullOrEmpty(xff))
            {
                requestTelemetry.Properties["X-Forwarded-For"] = xff;
            }

            // Capture X-Real-Client-IP set by APIM xff-global-policy.xml
            var realClientIp = context.Items["X-Real-Client-IP"]?.ToString();
            if (string.IsNullOrEmpty(realClientIp))
            {
                realClientIp = context.Request.Headers["X-Real-Client-IP"].FirstOrDefault();
            }
            if (!string.IsNullOrEmpty(realClientIp))
            {
                requestTelemetry.Properties["X-Real-Client-IP"] = realClientIp;
            }

            // Also capture the resolved remote IP (after ForwardedHeaders processing)
            var remoteIp = context.Connection.RemoteIpAddress?.ToString();
            if (!string.IsNullOrEmpty(remoteIp))
            {
                requestTelemetry.Properties["ResolvedClientIp"] = remoteIp;
            }
        }
    }
}
