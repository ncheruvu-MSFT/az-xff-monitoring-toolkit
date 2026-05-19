using System;
using System.Text;
using System.Web;
using System.Web.UI;

namespace XffDemo.Net47
{
    public partial class DefaultPage : Page
    {
        protected void Page_Load(object sender, EventArgs e)
        {
            var entry = HttpContext.Current.Items[XffHttpModule.ContextKey] as XffEntry
                        ?? XffCapture.FromRequest(HttpContext.Current);

            var sb = new StringBuilder();
            sb.Append("<table>");
            Row(sb, "Timestamp (UTC)", entry.TimestampUtc.ToString("o"));
            Row(sb, "Method", entry.Method);
            Row(sb, "Path", entry.Path);
            Row(sb, "Host", entry.Host);
            Row(sb, "Remote Address (TCP peer)", entry.RemoteAddr);
            Row(sb, "X-Forwarded-For", entry.XForwardedFor);
            Row(sb, "X-Forwarded-Proto", entry.XForwardedProto);
            Row(sb, "X-Forwarded-Host", entry.XForwardedHost);
            Row(sb, "X-Real-Client-IP", entry.XRealClientIp);
            Row(sb, "X-Azure-ClientIP", entry.XAzureClientIp);
            Row(sb, "X-Azure-SocketIP", entry.XAzureSocketIp);
            Row(sb, "<b>Resolved Client IP</b>", "<b>" + Encode(entry.ResolvedClientIp) + "</b>", encode: false);
            sb.Append("</table>");
            LitEntry.Text = sb.ToString();

            var hb = new StringBuilder("<table><tr><th>Header</th><th>Value</th></tr>");
            foreach (string h in Request.Headers)
            {
                hb.Append("<tr><td>").Append(Encode(h)).Append("</td><td>").Append(Encode(Request.Headers[h])).Append("</td></tr>");
            }
            hb.Append("</table>");
            LitHeaders.Text = hb.ToString();
        }

        private static void Row(StringBuilder sb, string label, string value, bool encode = true)
        {
            sb.Append("<tr><td>").Append(label).Append("</td><td>")
              .Append(encode ? Encode(value) : (value ?? string.Empty))
              .Append("</td></tr>");
        }

        private static string Encode(string s)
        {
            return string.IsNullOrEmpty(s) ? "<em>(none)</em>" : HttpUtility.HtmlEncode(s);
        }
    }
}
