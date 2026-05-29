using System;
using System.Collections.Concurrent;
using System.Collections.Generic;
using System.IO;
using System.Net;
using System.Net.Http;
using System.Text;
using System.Threading;
using System.Threading.Tasks;
using System.Web.Script.Serialization;

namespace XffDemo.Net47
{
    /// <summary>
    /// SDK-free shipper for XffEntry → Azure Monitor Logs Ingestion API.
    /// Auth: App Service system-assigned managed identity via IDENTITY_ENDPOINT/IDENTITY_HEADER.
    /// Config (app settings / env vars):
    ///   XFF_DCE_URI            e.g. https://dce-xff-xxxx.eastus-1.ingest.monitor.azure.com
    ///   XFF_DCR_IMMUTABLE_ID   e.g. dcr-abc123...
    ///   XFF_DCR_STREAM         e.g. Custom-XffEvents_CL  (default)
    /// If any of DCE/DCR are missing, the shipper is disabled and Enqueue is a no-op.
    /// All failures fall back to Trace.TraceWarning so they surface via AppServiceConsoleLogs.
    /// </summary>
    public static class XffLogIngestion
    {
        private const string DefaultStream = "Custom-XffEvents_CL";
        private const string TokenResource = "https://monitor.azure.com";
        private const string TokenApiVersion = "2019-08-01";
        private const string IngestApiVersion = "2023-01-01";
        private const int MaxQueue = 5000;
        private const int MaxBatch = 100;
        private static readonly TimeSpan FlushInterval = TimeSpan.FromSeconds(5);
        private static readonly TimeSpan TokenSkew = TimeSpan.FromMinutes(5);

        private static readonly object _initLock = new object();
        private static bool _initialized;
        private static bool _enabled;
        private static string _dceUri;
        private static string _dcrId;
        private static string _stream;
        private static string _identityEndpoint;
        private static string _identityHeader;
        private static BlockingCollection<XffEntry> _queue;
        private static HttpClient _http;
        private static Thread _worker;
        private static readonly JavaScriptSerializer _json = new JavaScriptSerializer { MaxJsonLength = 4 * 1024 * 1024 };

        private static string _cachedToken;
        private static DateTime _tokenExpiresUtc;

        public static bool Enabled
        {
            get { EnsureInit(); return _enabled; }
        }

        public static void Enqueue(XffEntry entry)
        {
            if (entry == null) return;
            EnsureInit();
            if (!_enabled) return;
            if (!_queue.TryAdd(entry))
            {
                // Queue full — drop oldest by draining one, then retry once.
                XffEntry dropped;
                _queue.TryTake(out dropped);
                _queue.TryAdd(entry);
            }
        }

        private static void EnsureInit()
        {
            if (_initialized) return;
            lock (_initLock)
            {
                if (_initialized) return;
                try
                {
                    _dceUri = ReadSetting("XFF_DCE_URI");
                    _dcrId = ReadSetting("XFF_DCR_IMMUTABLE_ID");
                    _stream = ReadSetting("XFF_DCR_STREAM");
                    if (string.IsNullOrWhiteSpace(_stream)) _stream = DefaultStream;
                    _identityEndpoint = Environment.GetEnvironmentVariable("IDENTITY_ENDPOINT");
                    _identityHeader = Environment.GetEnvironmentVariable("IDENTITY_HEADER");

                    if (string.IsNullOrWhiteSpace(_dceUri) || string.IsNullOrWhiteSpace(_dcrId))
                    {
                        System.Diagnostics.Trace.TraceInformation(
                            "XffLogIngestion disabled: XFF_DCE_URI or XFF_DCR_IMMUTABLE_ID not configured.");
                        _enabled = false;
                        return;
                    }
                    if (string.IsNullOrWhiteSpace(_identityEndpoint) || string.IsNullOrWhiteSpace(_identityHeader))
                    {
                        System.Diagnostics.Trace.TraceInformation(
                            "XffLogIngestion disabled: IDENTITY_ENDPOINT/IDENTITY_HEADER missing (not running in App Service with system-assigned MI).");
                        _enabled = false;
                        return;
                    }

                    ServicePointManager.SecurityProtocol |= SecurityProtocolType.Tls12;

                    _queue = new BlockingCollection<XffEntry>(MaxQueue);
                    _http = new HttpClient { Timeout = TimeSpan.FromSeconds(30) };

                    _worker = new Thread(WorkerLoop)
                    {
                        IsBackground = true,
                        Name = "XffLogIngestion"
                    };
                    _worker.Start();

                    _enabled = true;
                    System.Diagnostics.Trace.TraceInformation(
                        "XffLogIngestion enabled: DCE=" + _dceUri + " DCR=" + _dcrId + " stream=" + _stream);
                }
                catch (Exception ex)
                {
                    System.Diagnostics.Trace.TraceError("XffLogIngestion init failed: " + ex);
                    _enabled = false;
                }
                finally
                {
                    _initialized = true;
                }
            }
        }

        private static string ReadSetting(string name)
        {
            var v = System.Configuration.ConfigurationManager.AppSettings[name];
            if (!string.IsNullOrWhiteSpace(v)) return v;
            return Environment.GetEnvironmentVariable(name);
        }

        private static void WorkerLoop()
        {
            var batch = new List<XffEntry>(MaxBatch);
            while (!_queue.IsAddingCompleted)
            {
                batch.Clear();
                try
                {
                    XffEntry first;
                    if (!_queue.TryTake(out first, FlushInterval)) continue;
                    batch.Add(first);
                    XffEntry next;
                    while (batch.Count < MaxBatch && _queue.TryTake(out next))
                    {
                        batch.Add(next);
                    }
                    SendBatch(batch).GetAwaiter().GetResult();
                }
                catch (Exception ex)
                {
                    System.Diagnostics.Trace.TraceWarning("XffLogIngestion worker error: " + ex.Message);
                    // Backoff a little on repeated failures.
                    Thread.Sleep(2000);
                }
            }
        }

        private static async Task SendBatch(List<XffEntry> batch)
        {
            if (batch.Count == 0) return;

            var token = await GetTokenAsync().ConfigureAwait(false);
            if (string.IsNullOrEmpty(token)) return;

            var payload = new List<Dictionary<string, object>>(batch.Count);
            foreach (var e in batch)
            {
                payload.Add(new Dictionary<string, object>
                {
                    { "TimeGenerated", e.TimestampUtc.ToString("o") },
                    { "Path", e.Path ?? string.Empty },
                    { "Method", e.Method ?? string.Empty },
                    { "RemoteAddr", e.RemoteAddr ?? string.Empty },
                    { "XForwardedFor", e.XForwardedFor ?? string.Empty },
                    { "XForwardedProto", e.XForwardedProto ?? string.Empty },
                    { "XForwardedHost", e.XForwardedHost ?? string.Empty },
                    { "XRealClientIp", e.XRealClientIp ?? string.Empty },
                    { "XAzureClientIp", e.XAzureClientIp ?? string.Empty },
                    { "XAzureSocketIp", e.XAzureSocketIp ?? string.Empty },
                    { "ResolvedClientIp", e.ResolvedClientIp ?? string.Empty },
                    { "UserAgent", e.UserAgent ?? string.Empty },
                    { "HostHeader", e.Host ?? string.Empty },
                    { "ComputerName", Environment.MachineName ?? string.Empty }
                });
            }

            var url = string.Format("{0}/dataCollectionRules/{1}/streams/{2}?api-version={3}",
                _dceUri.TrimEnd('/'), _dcrId, _stream, IngestApiVersion);

            using (var req = new HttpRequestMessage(HttpMethod.Post, url))
            {
                req.Headers.Authorization = new System.Net.Http.Headers.AuthenticationHeaderValue("Bearer", token);
                req.Content = new StringContent(_json.Serialize(payload), Encoding.UTF8, "application/json");
                using (var resp = await _http.SendAsync(req).ConfigureAwait(false))
                {
                    if (!resp.IsSuccessStatusCode)
                    {
                        string body = string.Empty;
                        try { body = await resp.Content.ReadAsStringAsync().ConfigureAwait(false); } catch { }
                        System.Diagnostics.Trace.TraceWarning(string.Format(
                            "XffLogIngestion POST {0} → {1}: {2}",
                            url, (int)resp.StatusCode, Truncate(body, 500)));
                        // 401 → invalidate cached token so we re-fetch next round.
                        if (resp.StatusCode == HttpStatusCode.Unauthorized)
                        {
                            _cachedToken = null;
                            _tokenExpiresUtc = DateTime.MinValue;
                        }
                    }
                }
            }
        }

        private static async Task<string> GetTokenAsync()
        {
            if (!string.IsNullOrEmpty(_cachedToken) && DateTime.UtcNow + TokenSkew < _tokenExpiresUtc)
            {
                return _cachedToken;
            }

            var url = string.Format("{0}?resource={1}&api-version={2}",
                _identityEndpoint, Uri.EscapeDataString(TokenResource), TokenApiVersion);

            using (var req = new HttpRequestMessage(HttpMethod.Get, url))
            {
                req.Headers.Add("X-IDENTITY-HEADER", _identityHeader);
                using (var resp = await _http.SendAsync(req).ConfigureAwait(false))
                {
                    var body = await resp.Content.ReadAsStringAsync().ConfigureAwait(false);
                    if (!resp.IsSuccessStatusCode)
                    {
                        System.Diagnostics.Trace.TraceWarning(string.Format(
                            "XffLogIngestion token fetch → {0}: {1}",
                            (int)resp.StatusCode, Truncate(body, 500)));
                        return null;
                    }
                    var parsed = (IDictionary<string, object>)_json.DeserializeObject(body);
                    var access = parsed != null && parsed.ContainsKey("access_token") ? parsed["access_token"] as string : null;
                    var expiresOn = parsed != null && parsed.ContainsKey("expires_on") ? Convert.ToString(parsed["expires_on"]) : null;
                    if (string.IsNullOrEmpty(access)) return null;

                    long epoch;
                    if (long.TryParse(expiresOn, out epoch))
                    {
                        _tokenExpiresUtc = new DateTime(1970, 1, 1, 0, 0, 0, DateTimeKind.Utc).AddSeconds(epoch);
                    }
                    else
                    {
                        _tokenExpiresUtc = DateTime.UtcNow.AddMinutes(10);
                    }
                    _cachedToken = access;
                    return _cachedToken;
                }
            }
        }

        private static string Truncate(string s, int max)
        {
            if (string.IsNullOrEmpty(s)) return string.Empty;
            return s.Length <= max ? s : s.Substring(0, max) + "…";
        }
    }
}
