# X-Forwarded-For (XFF) — Overview & Fundamentals

## What is X-Forwarded-For?

`X-Forwarded-For` (XFF) is a de facto standard HTTP header used to identify the originating IP address of a client connecting through proxies, load balancers, or CDNs. When a request passes through multiple intermediaries, each proxy appends the previous hop's IP to the header, creating a chain:

```
X-Forwarded-For: <client-ip>, <proxy1-ip>, <proxy2-ip>
```

The leftmost IP is typically the original client; each subsequent IP is the address of the proxy that forwarded the request.

**RFC reference:** The `Forwarded` header (RFC 7239) is the standardized replacement, but `X-Forwarded-For` remains the most widely supported header across CDNs, load balancers, and reverse proxies in practice.

## Why XFF Matters

| Use Case | Description |
|----------|-------------|
| **Security logging** | Identify the real source IP for incident response and forensics |
| **Rate limiting** | Throttle by true client IP, not proxy IP |
| **Geo-routing** | Route or restrict based on original client geography |
| **Access control** | IP allow/deny lists must evaluate the real client, not the proxy |
| **Compliance** | Audit trails require accurate source attribution |
| **Fraud detection** | Correlate suspicious activity across services using client IP |

## XFF Header Family

Azure services use several related headers in addition to XFF:

| Header | Set By | Purpose |
|--------|--------|---------|
| `X-Forwarded-For` | All reverse proxies | Chain of client + proxy IPs |
| `X-Forwarded-Proto` | Front Door, App Gateway | Original protocol (http/https) |
| `X-Forwarded-Host` | Front Door, App Gateway | Original `Host` header value |
| `X-Forwarded-Port` | App Gateway | Original destination port |
| `X-Azure-ClientIP` | Azure Front Door | TCP-level client IP as seen by Front Door |
| `X-Azure-SocketIP` | Azure Front Door | Socket-level peer IP |
| `X-Real-Client-IP` | Custom (via APIM policy) | First hop extracted from XFF chain |

## XFF Threat Model

XFF is **client-controlled** on the first hop — any client can send a forged `X-Forwarded-For` header. This has critical security implications:

### Attack Vectors

1. **IP spoofing** — Attacker sends `X-Forwarded-For: 10.0.0.1` to impersonate an internal IP
2. **WAF bypass** — Crafted XFF can bypass IP-based WAF rules if the WAF evaluates XFF instead of socket IP
3. **Rate-limit evasion** — Rotating forged XFF values defeats IP-based throttling
4. **Log poisoning** — Injecting special characters or long strings into XFF to corrupt log parsers

### Mitigation Principles

- **Never trust XFF from untrusted sources** — Only trust XFF from known, authenticated proxies
- **Use socket-level IP where possible** — `SocketAddr` (Front Door WAF) or `context.Request.IpAddress` (APIM) represent the TCP peer
- **Configure `KnownProxies`/`KnownNetworks`** — In application middleware, only strip proxy IPs that belong to your infrastructure
- **Sanitize before backend** — Use App Gateway rewrite rules or APIM policies to normalize/strip invalid XFF values

## How Azure Services Handle XFF

```
┌──────────┐    ┌─────────────┐    ┌─────────────────┐    ┌──────┐    ┌─────────────┐
│  Client   │───▶│ Azure Front │───▶│ Application     │───▶│ APIM │───▶│ App Service │
│           │    │ Door        │    │ Gateway (v2)    │    │      │    │             │
│ XFF: ∅    │    │ Sets XFF    │    │ Appends to XFF  │    │ Pass │    │ Reads XFF   │
│           │    │ + ClientIP  │    │ + Rewrites      │    │ thru │    │ via middleware│
└──────────┘    └─────────────┘    └─────────────────┘    └──────┘    └─────────────┘
```

| Service | XFF Behavior | Key Detail |
|---------|-------------|------------|
| **Azure Front Door** | Sets/appends XFF, sets `X-Azure-ClientIP` | Most trustworthy source of client IP |
| **Application Gateway** | Appends `client_ip:port` to XFF | Use rewrite rules to strip port |
| **API Management** | Passes through XFF (no modification) | Use policies to extract/log |
| **App Service** | Reads XFF via middleware | Requires `ForwardedHeadersMiddleware` in .NET |
| **Azure Firewall** | Does not set or modify XFF | Network-level (L3/L4), not HTTP-aware by default |
| **Load Balancer** | Does not set or modify XFF | Layer-4 only, no HTTP header manipulation |
| **Traffic Manager** | DNS-level routing only | No HTTP traffic, no XFF involvement |

## Microsoft Learn References

- [RFC 7239 — Forwarded HTTP Extension](https://datatracker.ietf.org/doc/html/rfc7239)
- [MDN Web Docs — X-Forwarded-For](https://developer.mozilla.org/en-US/docs/Web/HTTP/Headers/X-Forwarded-For)
- [Azure Front Door HTTP headers protocol support](https://learn.microsoft.com/en-us/azure/frontdoor/front-door-http-headers-protocol)
- [Configure ASP.NET Core to work with proxy servers and load balancers](https://learn.microsoft.com/en-us/aspnet/core/host-and-deploy/proxy-load-balancer)
- [Application Gateway rewrite HTTP headers](https://learn.microsoft.com/en-us/azure/application-gateway/rewrite-http-headers-url)

## GitHub References

- [Azure/azure-policy](https://github.com/Azure/azure-policy) — Official Azure Policy samples
- [Azure/azure-quickstart-templates](https://github.com/Azure/azure-quickstart-templates) — ARM/Bicep quickstarts including networking
- [Azure/api-management-policy-snippets](https://github.com/Azure/api-management-policy-snippets) — APIM policy examples
- [microsoft/Application-Insights-Workbooks](https://github.com/microsoft/Application-Insights-Workbooks) — Azure Monitor workbook templates
