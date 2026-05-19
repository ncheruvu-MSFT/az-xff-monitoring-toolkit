using System;
using System.Collections.Generic;
using System.Linq;
using System.Text;
using System.Web;
using System.Web.UI;

namespace XffDemo.Net47
{
    public partial class ReportsPage : Page
    {
        protected void Page_Load(object sender, EventArgs e)
        {
            var format = (Request.QueryString["format"] ?? string.Empty).ToLowerInvariant();
            var entries = XffCapture.Snapshot();

            if (format == "csv") { WriteCsv(entries); return; }
            if (format == "json") { WriteJson(entries); return; }

            Render(entries);
        }

        protected void BtnClear_Click(object sender, EventArgs e)
        {
            XffCapture.Clear();
            Response.Redirect("Reports.aspx");
        }

        private void Render(IList<XffEntry> entries)
        {
            LitTotal.Text = XffCapture.TotalRequests.ToString();
            LitBufferSize.Text = entries.Count.ToString();
            LitUnique.Text = entries.Select(x => x.ResolvedClientIp).Where(x => !string.IsNullOrEmpty(x)).Distinct().Count().ToString();
            LitWithXff.Text = entries.Count(x => !string.IsNullOrEmpty(x.XForwardedFor)).ToString();

            // Top IPs
            var top = entries
                .Where(x => !string.IsNullOrEmpty(x.ResolvedClientIp))
                .GroupBy(x => x.ResolvedClientIp)
                .Select(g => new { Ip = g.Key, Count = g.Count(), Last = g.Max(x => x.TimestampUtc) })
                .OrderByDescending(x => x.Count)
                .Take(10)
                .ToList();

            var tb = new StringBuilder("<table><tr><th>Resolved IP</th><th>Requests</th><th>Last Seen (UTC)</th></tr>");
            foreach (var t in top)
            {
                tb.Append("<tr><td>").Append(HttpUtility.HtmlEncode(t.Ip))
                  .Append("</td><td>").Append(t.Count)
                  .Append("</td><td>").Append(t.Last.ToString("u")).Append("</td></tr>");
            }
            if (top.Count == 0) tb.Append("<tr><td colspan='3'><em>No data yet — make a few requests to Default.aspx.</em></td></tr>");
            tb.Append("</table>");
            LitTopIps.Text = tb.ToString();

            // Entries
            var sb = new StringBuilder("<table><tr>")
                .Append("<th>Time (UTC)</th><th>Method</th><th>Path</th>")
                .Append("<th>Remote Addr</th><th>X-Forwarded-For</th><th>X-Real-Client-IP</th>")
                .Append("<th>X-Azure-ClientIP</th><th>Resolved Client IP</th></tr>");
            foreach (var x in entries)
            {
                sb.Append("<tr>")
                  .Append("<td>").Append(x.TimestampUtc.ToString("HH:mm:ss")).Append("</td>")
                  .Append("<td>").Append(HttpUtility.HtmlEncode(x.Method)).Append("</td>")
                  .Append("<td>").Append(HttpUtility.HtmlEncode(x.Path)).Append("</td>")
                  .Append("<td>").Append(HttpUtility.HtmlEncode(x.RemoteAddr)).Append("</td>")
                  .Append("<td>").Append(HttpUtility.HtmlEncode(x.XForwardedFor)).Append("</td>")
                  .Append("<td>").Append(HttpUtility.HtmlEncode(x.XRealClientIp)).Append("</td>")
                  .Append("<td>").Append(HttpUtility.HtmlEncode(x.XAzureClientIp)).Append("</td>")
                  .Append("<td><b>").Append(HttpUtility.HtmlEncode(x.ResolvedClientIp)).Append("</b></td>")
                  .Append("</tr>");
            }
            if (entries.Count == 0) sb.Append("<tr><td colspan='8'><em>Buffer empty.</em></td></tr>");
            sb.Append("</table>");
            LitEntries.Text = sb.ToString();
        }

        private void WriteCsv(IList<XffEntry> entries)
        {
            Response.Clear();
            Response.ContentType = "text/csv";
            Response.AddHeader("Content-Disposition", "attachment; filename=xff-report.csv");
            var w = Response.Output;
            w.WriteLine("TimestampUtc,Method,Path,Host,RemoteAddr,XForwardedFor,XForwardedProto,XForwardedHost,XRealClientIp,XAzureClientIp,XAzureSocketIp,ResolvedClientIp,UserAgent");
            foreach (var x in entries)
            {
                w.WriteLine(string.Join(",",
                    Csv(x.TimestampUtc.ToString("o")),
                    Csv(x.Method), Csv(x.Path), Csv(x.Host), Csv(x.RemoteAddr),
                    Csv(x.XForwardedFor), Csv(x.XForwardedProto), Csv(x.XForwardedHost),
                    Csv(x.XRealClientIp), Csv(x.XAzureClientIp), Csv(x.XAzureSocketIp),
                    Csv(x.ResolvedClientIp), Csv(x.UserAgent)));
            }
            Response.End();
        }

        private void WriteJson(IList<XffEntry> entries)
        {
            Response.Clear();
            Response.ContentType = "application/json";
            var serializer = new System.Web.Script.Serialization.JavaScriptSerializer();
            serializer.MaxJsonLength = int.MaxValue;
            Response.Write(serializer.Serialize(entries));
            Response.End();
        }

        private static string Csv(string s)
        {
            if (string.IsNullOrEmpty(s)) return string.Empty;
            if (s.IndexOfAny(new[] { ',', '"', '\n', '\r' }) >= 0)
                return "\"" + s.Replace("\"", "\"\"") + "\"";
            return s;
        }
    }
}
