using System.Web;
using Microsoft.ApplicationInsights.Channel;
using Microsoft.ApplicationInsights.DataContracts;
using Microsoft.ApplicationInsights.Extensibility;

namespace XffDemo.Net47
{
    /// <summary>
    /// Adds XFF + resolved client IP to every RequestTelemetry as customDimensions
    /// so KQL queries against the `requests` / `AppRequests` table can filter on them.
    /// </summary>
    public class XffTelemetryInitializer : ITelemetryInitializer
    {
        public void Initialize(ITelemetry telemetry)
        {
            var request = telemetry as RequestTelemetry;
            if (request == null) return;

            var ctx = HttpContext.Current;
            if (ctx == null) return;

            var entry = ctx.Items[XffHttpModule.ContextKey] as XffEntry
                        ?? XffCapture.FromRequest(ctx);
            if (entry == null) return;

            AddIfPresent(request, "X-Forwarded-For", entry.XForwardedFor);
            AddIfPresent(request, "X-Forwarded-Proto", entry.XForwardedProto);
            AddIfPresent(request, "X-Forwarded-Host", entry.XForwardedHost);
            AddIfPresent(request, "X-Real-Client-IP", entry.XRealClientIp);
            AddIfPresent(request, "X-Azure-ClientIP", entry.XAzureClientIp);
            AddIfPresent(request, "X-Azure-SocketIP", entry.XAzureSocketIp);
            AddIfPresent(request, "ResolvedClientIp", entry.ResolvedClientIp);
            AddIfPresent(request, "RemoteAddr", entry.RemoteAddr);

            // Surface the resolved client IP on the standard Location.Ip field too
            // so the App Insights UI shows it where users expect.
            if (!string.IsNullOrEmpty(entry.ResolvedClientIp) &&
                (string.IsNullOrEmpty(request.Context.Location.Ip) ||
                 request.Context.Location.Ip == "0.0.0.0"))
            {
                request.Context.Location.Ip = entry.ResolvedClientIp;
            }
        }

        private static void AddIfPresent(RequestTelemetry req, string key, string value)
        {
            if (string.IsNullOrEmpty(value)) return;
            if (!req.Properties.ContainsKey(key))
            {
                req.Properties[key] = value;
            }
        }
    }
}
