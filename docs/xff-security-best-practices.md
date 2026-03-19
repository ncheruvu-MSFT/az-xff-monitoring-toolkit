# XFF Monitoring — Security Best Practices

This document covers security considerations for X-Forwarded-For (XFF) headers in Azure architectures, including spoofing risks, trust boundaries, header sanitization, and defense-in-depth strategies.

## XFF Spoofing Risks

`X-Forwarded-For` is a **client-controlled header** on the first hop. Any HTTP client can send:

```
GET /api/data HTTP/1.1
Host: api.example.com
X-Forwarded-For: 10.0.0.1, 192.168.1.1
```

If your application or proxy trusts this header without validation, attackers can:

1. **Bypass IP allow-lists** by impersonating trusted IPs
2. **Evade rate limiting** by rotating forged XFF values
3. **Bypass geo-restrictions** by faking IPs from allowed regions
4. **Poison logs** by injecting misleading source addresses
5. **Exploit SSRF-like behavior** if internal systems use XFF for routing decisions

## Trust Boundaries

### The Cardinal Rule

> **Only trust XFF entries appended by proxies you control and authenticate.**

### Trust Chain in Azure

```
Client IP (untrusted) → Front Door (trusted) → App Gateway (trusted) → APIM (trusted)
     ↑                        ↑                       ↑                     ↑
  Can be forged          Appends real IP          Appends AFD IP        Pass-through
```

The **leftmost IP** in XFF is only trustworthy if:
1. The first trusted proxy in our chain (Front Door/App Gateway) **stripped or ignored** any pre-existing XFF from the client, OR
2. We count backward from the **rightmost** IP and only trust entries added by our known proxies

### Recommended Approach: Count from the Right

Instead of trusting XFF[0] (leftmost), count backward from the rightmost entry:

```
XFF: <attacker-injected>, <real-client>, <front-door-ip>, <appgw-ip>
                                  ↑
                         Count back from right:
                         Known proxies = 2 (AFD + AppGW)
                         Real client = XFF[length - known_proxies - 1]
```

This is exactly how `ForwardedHeadersMiddleware` works when `KnownNetworks` / `KnownProxies` and `ForwardLimit` are correctly configured.

## Service-Specific Security Configuration

### Azure Front Door

| Setting | Recommended Value | Why |
|---------|-------------------|-----|
| WAF match variable for IP rules | `SocketAddr` | Cannot be spoofed (TCP peer) |
| NOT recommended for IP rules | `RemoteAddr` | Respects XFF — spoofable |
| Backend access lock-down | NSG with `AzureFrontDoor.Backend` service tag | Prevents direct backend access |
| Front Door ID validation | Check `X-Azure-FDID` header | Ensures traffic came from YOUR Front Door |

**Critical:** The difference between `SocketAddr` and `RemoteAddr` in Front Door WAF has caused real-world bypass vulnerabilities. Always use `SocketAddr` for security-critical IP decisions.

### Application Gateway

| Setting | Recommended Value | Why |
|---------|-------------------|-----|
| XFF normalization | Use `{var_add_x_forwarded_for_proxy}` rewrite | Strips port, normalizes format |
| WAF mode | Prevention (after testing in Detection) | Active blocking |
| Backend health probes | HTTPS with custom probe | Prevents probe spoofing |
| NSG on App Gateway subnet | Allow only Front Door IPs (if AFD fronts it) | Layered access control |

### APIM

| Setting | Recommended Value | Why |
|---------|-------------------|-----|
| IP filtering | Use `context.Request.IpAddress` for TCP peer, XFF for client | Know which is which |
| Rate limiting | Use extracted XFF client IP (first untrusted hop) | Accurate throttling |
| Header sanitization | Strip XFF from outbound responses | Don't leak internal architecture |
| Subscription keys | Required on all APIs | Defense in depth |

### App Service (Application Code)

| Setting | Recommended Value | Why |
|---------|-------------------|-----|
| `KnownNetworks` | Your proxy subnet CIDRs only | Only trust your proxies |
| `KnownProxies` | Specific proxy IPs (if static) | More restrictive than CIDRs |
| `ForwardLimit` | Set to number of known proxies (or `null` for unlimited known) | Prevents excessive trust |
| `ForwardedHeaders` | `XForwardedFor \| XForwardedProto` | Only enable what you need |

**ASP.NET Core example:**

```csharp
builder.Services.Configure<ForwardedHeadersOptions>(options =>
{
    options.ForwardedHeaders =
        ForwardedHeaders.XForwardedFor |
        ForwardedHeaders.XForwardedProto;

    // ONLY trust your infrastructure subnets
    options.KnownNetworks.Add(new IPNetwork(IPAddress.Parse("10.0.0.0"), 8));

    // Set to the exact number of proxies in your chain
    // null = trust all known proxies (use with KnownNetworks)
    options.ForwardLimit = null;

    // Clear the default loopback entries
    options.KnownNetworks.Clear();
    options.KnownProxies.Clear();

    // Re-add only your proxy networks
    options.KnownNetworks.Add(new IPNetwork(IPAddress.Parse("10.0.0.0"), 8));
});
```

## Header Sanitization

### Strip XFF from Responses

Never return XFF headers in HTTP responses — they leak internal architecture information.

**APIM outbound policy:**

```xml
<outbound>
    <set-header name="X-Forwarded-For" exists-action="delete" />
    <set-header name="X-Real-Client-IP" exists-action="delete" />
    <set-header name="X-Azure-ClientIP" exists-action="delete" />
    <set-header name="X-Azure-SocketIP" exists-action="delete" />
</outbound>
```

**App Gateway response rewrite:**

```bicep
{
  name: 'Strip-Internal-Headers'
  ruleSequence: 200
  actionSet: {
    responseHeaderConfigurations: [
      { headerName: 'X-Forwarded-For', headerValue: '' }
      { headerName: 'X-Powered-By', headerValue: '' }
      { headerName: 'Server', headerValue: '' }
    ]
  }
}
```

### Validate XFF Format

Before processing XFF, validate its format to prevent injection attacks:

```csharp
// Validate XFF contains only valid IP addresses
static bool IsValidXff(string xff)
{
    if (string.IsNullOrEmpty(xff)) return false;

    var parts = xff.Split(',');
    foreach (var part in parts)
    {
        var trimmed = part.Trim();
        // Strip port if present
        var colonIdx = trimmed.LastIndexOf(':');
        if (colonIdx > 0 && !trimmed.Contains('['))
            trimmed = trimmed.Substring(0, colonIdx);

        if (!IPAddress.TryParse(trimmed, out _))
            return false;
    }
    return true;
}
```

## Log Integrity

### Protect XFF in Logs

| Control | Implementation |
|---------|---------------|
| Log Analytics workspace access | RBAC with `Log Analytics Reader` / `Contributor` |
| Immutable logs | Enable immutability on the storage account used for log archival |
| Log retention | Set minimum 90-day retention (or per compliance requirements) |
| Alert on XFF absence | Scheduled alert when XFF presence drops below 95% |
| Alert on format change | Detect sudden `:port` spikes (missing rewrite rule) |

### XFF Absence Alert Rule

```kql
requests
| where timestamp > ago(1h)
| extend xff = tostring(customDimensions["Request-Header-x-forwarded-for"])
| summarize
    TotalRequests = count(),
    WithXFF = countif(isnotempty(xff))
| extend XffPct = round(100.0 * WithXFF / TotalRequests, 2)
| where XffPct < 95
```

## Defense in Depth Checklist

- [ ] **Network layer:** NSGs restrict backend access to only known proxy IPs/service tags
- [ ] **Front Door:** WAF rules use `SocketAddr` for IP matching
- [ ] **App Gateway:** XFF normalization rewrite rule deployed and associated
- [ ] **App Gateway:** WAF v2 in Prevention mode
- [ ] **APIM:** XFF stripped from outbound responses
- [ ] **APIM:** Rate limiting uses extracted client IP from XFF
- [ ] **App Service:** `ForwardedHeadersMiddleware` configured with `KnownNetworks`
- [ ] **App Service:** `ForwardLimit` set to expected proxy count
- [ ] **Logging:** XFF captured in Application Insights on all tiers
- [ ] **Monitoring:** Alerts configured for XFF absence and format anomalies
- [ ] **Policy:** Azure Policy enforces diagnostic settings on all proxy resources
- [ ] **Backend lock-down:** Front Door ID validated via `X-Azure-FDID` header

## Common Vulnerabilities and How to Avoid Them

| Vulnerability | Root Cause | Fix |
|--------------|-----------|-----|
| WAF bypass via XFF spoofing | Using `RemoteAddr` instead of `SocketAddr` | Switch to `SocketAddr` match |
| Rate limit bypass | Trusting client-supplied XFF for throttling | Extract from known proxy count |
| Internal IP exposure | XFF returned in responses | Strip XFF in outbound policies |
| Wrong client IP in logs | Missing `ForwardedHeadersMiddleware` | Configuring middleware with correct proxy list |
| Excessive trust boundary | `ForwardLimit = null` without `KnownNetworks` | Always pair with explicit `KnownNetworks` |

## Microsoft Learn References

- [Configure ASP.NET Core to work with proxy servers](https://learn.microsoft.com/en-us/aspnet/core/host-and-deploy/proxy-load-balancer)
- [Azure Front Door WAF custom rules](https://learn.microsoft.com/en-us/azure/web-application-firewall/afds/waf-front-door-custom-rules)
- [Lock down backend to Front Door only](https://learn.microsoft.com/en-us/azure/frontdoor/front-door-faq#how-do-i-lock-down-the-access-to-my-backend-to-only-azure-front-door-)
- [APIM access restriction policies](https://learn.microsoft.com/en-us/azure/api-management/api-management-access-restriction-policies)
- [Azure network security best practices](https://learn.microsoft.com/en-us/azure/security/fundamentals/network-best-practices)
- [Azure security baseline for Application Gateway](https://learn.microsoft.com/en-us/security/benchmark/azure/baselines/application-gateway-security-baseline)

## GitHub References

- [Azure/Azure-Network-Security](https://github.com/Azure/Azure-Network-Security) — Network security samples and guidance
- [Azure/azure-policy](https://github.com/Azure/azure-policy) — Security-related policy definitions
- [OWASP/CheatSheetSeries — HTTP Headers](https://github.com/OWASP/CheatSheetSeries) — OWASP guidance on header security
