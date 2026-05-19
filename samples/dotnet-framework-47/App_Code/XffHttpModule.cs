using System;
using System.Web;

namespace XffDemo.Net47
{
    /// <summary>
    /// Captures XFF headers on every incoming request and stashes a snapshot
    /// into HttpContext.Items so the telemetry initializer can pick it up.
    /// Also pushes the entry into the in-memory ring buffer for the Reports page.
    /// </summary>
    public class XffHttpModule : IHttpModule
    {
        public const string ContextKey = "XffDemo.Entry";

        public void Init(HttpApplication context)
        {
            context.BeginRequest += OnBeginRequest;
        }

        private void OnBeginRequest(object sender, EventArgs e)
        {
            var app = (HttpApplication)sender;
            var ctx = app.Context;
            try
            {
                var entry = XffCapture.FromRequest(ctx);
                if (entry == null) return;

                ctx.Items[ContextKey] = entry;

                // Skip the Reports page itself to avoid polluting the buffer.
                var path = ctx.Request.Path ?? string.Empty;
                if (path.IndexOf("Reports.aspx", StringComparison.OrdinalIgnoreCase) < 0)
                {
                    XffCapture.Add(entry);
                }
            }
            catch (Exception ex)
            {
                System.Diagnostics.Trace.TraceWarning("XffHttpModule failed: " + ex.Message);
            }
        }

        public void Dispose() { }
    }
}
