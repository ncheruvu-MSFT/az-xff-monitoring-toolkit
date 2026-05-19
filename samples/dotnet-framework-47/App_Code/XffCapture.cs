using System;
using System.Collections.Concurrent;
using System.Collections.Generic;
using System.Linq;
using System.Web;

namespace XffDemo.Net47
{
    /// <summary>
    /// Per-request snapshot of XFF-related headers and resolved IPs.
    /// </summary>
    public class XffEntry
    {
        public DateTime TimestampUtc { get; set; }
        public string Path { get; set; }
        public string Method { get; set; }
        public string RemoteAddr { get; set; }          // TCP peer (what App Service sees)
        public string XForwardedFor { get; set; }       // raw XFF chain
        public string XForwardedProto { get; set; }
        public string XForwardedHost { get; set; }
        public string XRealClientIp { get; set; }       // optional, set by APIM policy
        public string XAzureClientIp { get; set; }      // App Service front-end
        public string XAzureSocketIp { get; set; }      // App Service front-end
        public string ResolvedClientIp { get; set; }    // first non-trusted hop from XFF
        public string UserAgent { get; set; }
        public string Host { get; set; }
    }

    /// <summary>
    /// In-memory rolling buffer of recent requests, used by Reports.aspx.
    /// Not durable — App Insights is the long-term store.
    /// </summary>
    public static class XffCapture
    {
        private const int MaxEntries = 500;
        private static readonly ConcurrentQueue<XffEntry> _entries = new ConcurrentQueue<XffEntry>();
        private static long _totalRequests;

        public static long TotalRequests
        {
            get { return System.Threading.Interlocked.Read(ref _totalRequests); }
        }

        public static void Add(XffEntry entry)
        {
            if (entry == null) return;
            _entries.Enqueue(entry);
            System.Threading.Interlocked.Increment(ref _totalRequests);

            // Trim
            while (_entries.Count > MaxEntries)
            {
                XffEntry dropped;
                _entries.TryDequeue(out dropped);
            }
        }

        public static IList<XffEntry> Snapshot()
        {
            return _entries.ToArray().Reverse().ToList();
        }

        public static void Clear()
        {
            XffEntry dropped;
            while (_entries.TryDequeue(out dropped)) { }
            System.Threading.Interlocked.Exchange(ref _totalRequests, 0);
        }

        /// <summary>
        /// Builds an XffEntry from the current HttpRequest.
        /// </summary>
        public static XffEntry FromRequest(HttpContext ctx)
        {
            if (ctx == null || ctx.Request == null) return null;
            var req = ctx.Request;

            string xff = req.Headers["X-Forwarded-For"];
            string resolved = ResolveClientIp(xff, req.UserHostAddress);

            return new XffEntry
            {
                TimestampUtc = DateTime.UtcNow,
                Path = req.Path,
                Method = req.HttpMethod,
                RemoteAddr = req.UserHostAddress,
                XForwardedFor = xff,
                XForwardedProto = req.Headers["X-Forwarded-Proto"],
                XForwardedHost = req.Headers["X-Forwarded-Host"],
                XRealClientIp = req.Headers["X-Real-Client-IP"],
                XAzureClientIp = req.Headers["X-Azure-ClientIP"],
                XAzureSocketIp = req.Headers["X-Azure-SocketIP"],
                ResolvedClientIp = resolved,
                UserAgent = req.UserAgent,
                Host = req.Headers["Host"]
            };
        }

        /// <summary>
        /// Returns the left-most non-empty IP in the XFF chain, falling back to UserHostAddress.
        /// Strips port suffixes (e.g. "1.2.3.4:5678" -> "1.2.3.4").
        /// </summary>
        public static string ResolveClientIp(string xff, string fallback)
        {
            if (!string.IsNullOrWhiteSpace(xff))
            {
                var first = xff.Split(',')[0].Trim();
                int colon = first.LastIndexOf(':');
                // Strip port only for IPv4 (single colon). Leave IPv6 alone.
                if (colon > 0 && first.IndexOf(':') == colon)
                {
                    first = first.Substring(0, colon);
                }
                if (!string.IsNullOrEmpty(first)) return first;
            }
            return fallback;
        }
    }
}
