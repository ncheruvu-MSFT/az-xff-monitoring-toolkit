# XFF Monitoring — Multi-Tier Architecture Patterns

This document describes end-to-end XFF header flow through common Azure multi-tier architectures, with configuration requirements and KQL queries for each pattern.

## Pattern 1: Front Door → Application Gateway → App Service

The most common Azure web application architecture for global HTTP ingress.

```
┌──────────┐    ┌─────────────┐    ┌─────────────────┐    ┌─────────────┐
│  Client   │───▶│ Azure Front │───▶│ Application     │───▶│ App Service │
│ 203.0.x.x│    │ Door        │    │ Gateway (v2)    │    │             │
└──────────┘    └─────────────┘    └─────────────────┘    └─────────────┘
```

### XFF Flow

| Hop | Service | XFF After This Hop | Notes |
|-----|---------|-------------------|-------|
| 0 | Client | `(none)` | Client may send forged XFF |
| 1 | Front Door | `203.0.113.50` | AFD appends real client IP |
| 2 | App Gateway | `203.0.113.50, 13.107.x.x` | Appends AFD edge IP (with port unless rewrite rule) |
| 3 | App Service | `203.0.113.50, 13.107.x.x` | Receives full chain via middleware |

### Configuration Checklist

- [ ] **Front Door:** Enable diagnostic settings → Log Analytics
- [ ] **App Gateway:** Deploy XFF normalization rewrite rule (strip port)
- [ ] **App Gateway:** Associate rewrite rule set with routing rule(s)
- [ ] **App Gateway:** Enable diagnostic settings → Log Analytics
- [ ] **App Service:** Configure `ForwardedHeadersMiddleware` with `KnownNetworks`
- [ ] **App Service:** Set `ForwardLimit = null` for multi-hop chains
- [ ] **App Service:** Register `XffTelemetryInitializer` for App Insights

### Backend Lock-Down

Restrict App Gateway to accept traffic only from Front Door:
- Use NSGs to allow only Front Door service tag `AzureFrontDoor.Backend`
- Validate `X-Azure-FDID` header matches your Front Door instance ID

```bicep
// NSG rule to allow only Front Door traffic
{
  name: 'Allow-FrontDoor-Only'
  properties: {
    priority: 100
    direction: 'Inbound'
    access: 'Allow'
    protocol: 'Tcp'
    sourceAddressPrefix: 'AzureFrontDoor.Backend'
    destinationPortRange: '443'
  }
}
```

---

## Pattern 2: Front Door → APIM → App Service

For API-first architectures where APIM provides API gateway functionality without a separate Application Gateway.

```
┌──────────┐    ┌─────────────┐    ┌──────┐    ┌─────────────┐
│  Client   │───▶│ Azure Front │───▶│ APIM │───▶│ App Service │
│ 203.0.x.x│    │ Door        │    │      │    │             │
└──────────┘    └─────────────┘    └──────┘    └─────────────┘
```

### XFF Flow

| Hop | Service | XFF After This Hop |
|-----|---------|-------------------|
| 0 | Client | `(none)` |
| 1 | Front Door | `203.0.113.50` |
| 2 | APIM | `203.0.113.50` (pass-through) |
| 3 | App Service | `203.0.113.50` |

### Configuration Checklist

- [ ] **Front Door:** Enable diagnostic settings
- [ ] **APIM:** Configure Application Insights with XFF header logging
- [ ] **APIM:** Deploy global XFF policy (propagation + `X-Real-Client-IP`)
- [ ] **APIM:** Enable diagnostic settings → Log Analytics
- [ ] **App Service:** Configure `ForwardedHeadersMiddleware` (trust 1 proxy hop)
- [ ] **App Service:** Register telemetry initializer for XFF

---

## Pattern 3: Front Door → App Gateway → APIM → App Service

The full four-tier architecture providing global CDN, WAF, API gateway, and compute.

```
┌──────────┐   ┌─────────┐   ┌─────────────┐   ┌──────┐   ┌─────────────┐
│  Client   │──▶│  Front  │──▶│ App Gateway │──▶│ APIM │──▶│ App Service │
│ 203.0.x.x│   │  Door   │   │ (v2 + WAF)  │   │      │   │             │
└──────────┘   └─────────┘   └─────────────┘   └──────┘   └─────────────┘
```

### XFF Flow

| Hop | Service | XFF After This Hop |
|-----|---------|-------------------|
| 0 | Client | `(none)` |
| 1 | Front Door | `203.0.113.50` |
| 2 | App Gateway | `203.0.113.50, 13.107.x.x` |
| 3 | APIM | `203.0.113.50, 13.107.x.x` (pass-through) |
| 4 | App Service | `203.0.113.50, 13.107.x.x` |

### Configuration Checklist

- [ ] All items from Pattern 1
- [ ] **APIM:** XFF header logging + global policy
- [ ] **App Service:** `ForwardLimit = null` (3+ hops)
- [ ] **App Service:** `KnownNetworks` includes App Gateway and APIM subnets

---

## Pattern 4: Azure Firewall → App Gateway → App Service (Zero Trust)

High-security pattern with network-level filtering before Layer-7 processing.

```
┌──────────┐   ┌─────────────┐   ┌─────────────┐   ┌─────────────┐
│  Client   │──▶│ Azure       │──▶│ Application │──▶│ App Service │
│ 203.0.x.x│   │ Firewall    │   │ Gateway     │   │             │
│           │   │ (DNAT)      │   │ (WAF v2)    │   │             │
└──────────┘   └─────────────┘   └─────────────┘   └─────────────┘
```

### XFF Flow

| Hop | Service | XFF After This Hop | IP in TCP Packet |
|-----|---------|-------------------|------------------|
| 0 | Client | `(none)` | `203.0.113.50` |
| 1 | Azure Firewall | `(none)` (no HTTP awareness) | `203.0.113.50` (DNAT preserves source) |
| 2 | App Gateway | `203.0.113.50` | `10.0.1.5` (App GW subnet) |
| 3 | App Service | `203.0.113.50` | `10.0.2.5` (backend subnet) |

### Configuration Checklist

- [ ] **Azure Firewall:** DNAT rule to forward traffic to App Gateway
- [ ] **Azure Firewall:** Enable structured diagnostic logs
- [ ] **App Gateway:** XFF normalization rewrite rule
- [ ] **App Gateway:** Enable WAF and diagnostic settings
- [ ] **App Service:** `ForwardedHeadersMiddleware` (trust 1 proxy hop)

---

## Pattern 5: Cloudflare → Azure Front Door → App Gateway → App Service

Hybrid CDN pattern with external CDN in front of Azure.

```
┌──────────┐   ┌────────────┐   ┌───────────┐   ┌─────────────┐   ┌─────────┐
│  Client   │──▶│ Cloudflare │──▶│ Azure     │──▶│ App Gateway │──▶│ App Svc │
│ 203.0.x.x│   │            │   │ Front Door│   │             │   │         │
└──────────┘   └────────────┘   └───────────┘   └─────────────┘   └─────────┘
```

### XFF Flow

| Hop | XFF After This Hop | Additional Headers |
|-----|--------------------|-------------------|
| Cloudflare | `203.0.113.50` | `CF-Connecting-IP: 203.0.113.50` |
| Front Door | `203.0.113.50, 198.41.x.x` | `X-Azure-ClientIP: 198.41.x.x` (CF edge) |
| App Gateway | `203.0.113.50, 198.41.x.x, 13.107.x.x` | |
| App Service | `203.0.113.50, 198.41.x.x, 13.107.x.x` | |

> **Warning:** `X-Azure-ClientIP` in this pattern contains the Cloudflare edge IP, not the end user IP. Use `CF-Connecting-IP` or XFF[0] for the real client.

---

## Pattern 6: AKS with NGINX Ingress

Container-native pattern with Kubernetes ingress handling XFF.

```
┌──────────┐   ┌─────────────┐   ┌─────────────────┐   ┌──────────────┐
│  Client   │──▶│ Azure LB    │──▶│ NGINX Ingress   │──▶│ Pod/Container│
│ 203.0.x.x│   │ (L4)        │   │ Controller      │   │              │
└──────────┘   └─────────────┘   └─────────────────┘   └──────────────┘
```

### XFF Flow

| Hop | XFF After This Hop |
|-----|--------------------|
| Azure LB | `(none)` — L4, preserves source IP in TCP |
| NGINX Ingress | `203.0.113.50` — sets XFF from `$remote_addr` |
| Pod | `203.0.113.50` |

### Configuration

```yaml
# NGINX Ingress ConfigMap
apiVersion: v1
kind: ConfigMap
metadata:
  name: nginx-configuration
  namespace: ingress-nginx
data:
  use-forwarded-headers: "true"
  compute-full-forwarded-for: "true"
```

---

## Cross-Tier Correlation KQL Query

Correlate requests across all tiers using timestamps and XFF:

```kql
let appGwRequests = AGWAccessLogs
| where TimeGenerated > ago(1h)
| project
    TimeGenerated,
    Tier = "AppGateway",
    ClientIp,
    Host,
    RequestUri,
    HttpStatusCode,
    TransactionId;

let apimRequests = ApiManagementGatewayLogs
| where TimeGenerated > ago(1h)
| extend headers = parse_json(RequestHeaders)
| extend xff = tostring(headers["X-Forwarded-For"])
| project
    TimeGenerated,
    Tier = "APIM",
    ClientIp = CallerIpAddress,
    Host = Url,
    RequestUri = Url,
    HttpStatusCode = ResponseCode,
    TransactionId = CorrelationId;

union appGwRequests, apimRequests
| order by TimeGenerated desc
```

## Decision Matrix

| Requirement | Recommended Pattern |
|-------------|-------------------|
| Global CDN + WAF | Pattern 1 (Front Door → App GW → App Svc) |
| API gateway with CDN | Pattern 2 (Front Door → APIM → App Svc) |
| Full enterprise stack | Pattern 3 (AFD → App GW → APIM → App Svc) |
| High-security / zero-trust | Pattern 4 (Firewall → App GW → App Svc) |
| External CDN + Azure | Pattern 5 (Cloudflare → AFD → App GW) |
| Container workloads | Pattern 6 (AKS → NGINX Ingress → Pods) |

## Microsoft Learn References

- [Protect APIs with Application Gateway and APIM](https://learn.microsoft.com/en-us/azure/architecture/reference-architectures/apis/protect-apis)
- [Zero-trust network for web applications](https://learn.microsoft.com/en-us/azure/architecture/example-scenario/gateway/application-gateway-before-azure-firewall)
- [Firewall and Application Gateway for virtual networks](https://learn.microsoft.com/en-us/azure/architecture/example-scenario/gateway/firewall-application-gateway)
- [Hub-spoke network topology in Azure](https://learn.microsoft.com/en-us/azure/architecture/networking/architecture/hub-spoke)
- [End-to-end TLS with Azure Front Door](https://learn.microsoft.com/en-us/azure/frontdoor/end-to-end-tls)
- [AKS networking concepts](https://learn.microsoft.com/en-us/azure/aks/concepts-network)
- [Application Gateway Ingress Controller](https://learn.microsoft.com/en-us/azure/application-gateway/ingress-controller-overview)

## GitHub References

- [Azure/azure-quickstart-templates](https://github.com/Azure/azure-quickstart-templates) — Multi-tier architecture templates
- [mspnp/reference-architectures](https://github.com/mspnp/reference-architectures) — Microsoft Patterns & Practices reference architectures
- [Azure/application-gateway-kubernetes-ingress](https://github.com/Azure/application-gateway-kubernetes-ingress) — AGIC for AKS
