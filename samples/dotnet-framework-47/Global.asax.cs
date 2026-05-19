using System;
using System.Web;

namespace XffDemo.Net47
{
    public class Global : HttpApplication
    {
        protected void Application_Start(object sender, EventArgs e)
        {
            // Application Insights is wired up via ApplicationInsightsModule
            // declared in Web.config + ApplicationInsights.config.
            // XFF capture happens in XffHttpModule (registered in Web.config).
        }

        protected void Application_Error(object sender, EventArgs e)
        {
            var ex = Server.GetLastError();
            if (ex != null)
            {
                System.Diagnostics.Trace.TraceError("Unhandled error: " + ex);
            }
        }
    }
}
