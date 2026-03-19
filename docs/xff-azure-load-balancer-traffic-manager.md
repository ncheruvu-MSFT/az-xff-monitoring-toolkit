# XFF Monitoring — Azure Load Balancer & Traffic Manager

Azure Load Balancer and Azure Traffic Manager operate at different network layers and have fundamentally different relationships with the `X-Forwarded-For` header compared to Layer-7 services like Front Door and Application Gateway.

## Azure Load Balancer

### Overview

Azure Load Balancer is a **Layer-4 (TCP/UDP)** load balancer. It operates at the transport layer and does **not inspect, set, or modify HTTP headers** — including `X-Forwarded-For`.

### XFF Behavior

| Aspect | Behavior |
|--------|----------|
| **Sets XFF** | No — Layer-4 only, no HTTP awareness |
| **Modifies XFF** | No |
| **Preserves source IP** | Depends on configuration (see below) |

### Source IP Preservation

**Standard Load Balancer (default):**

- Uses **SNAT** (Source Network Address Translation) for outbound traffic
- For inbound traffic to backend instances, the **original client IP is preserved** as the source IP in the TCP packet
- Backend applications see the real client IP in `REMOTE_ADDR` / `req.socket.remoteAddress`

**Key scenarios:**

| Scenario | Source IP Seen by Backend |
|----------|-------------------------|
| Public LB → VM | Original client IP |
| Public LB → VMSS | Original client IP |
| Internal LB → VM/VMSS | Original client IP within VNet |
| LB + NVA (Network Virtual Appliance) | NVA IP (SNAT) |

### When XFF is Relevant

If you place a Load Balancer in front of an HTTP-aware service (e.g., Nginx on VMs), that service must handle XFF. The LB itself does not:

```
Client → Azure LB (L4) → Nginx (VM) → App
                           ↑
                     Nginx sets XFF
                     from REMOTE_ADDR
```

In this case, configure Nginx to set XFF:

```nginx
# /etc/nginx/nginx.conf
proxy_set_header X-Forwarded-For $proxy_add_x_forwarded_for;
proxy_set_header X-Real-IP $remote_addr;
proxy_set_header X-Forwarded-Proto $scheme;
```

### Diagnostic Logging

Load Balancer metrics and logs focus on connections and health probes, not HTTP headers:

```bash
az monitor diagnostic-settings create \
  --name "lb-diagnostics" \
  --resource "/subscriptions/<sub-id>/resourceGroups/<rg>/providers/Microsoft.Network/loadBalancers/<lb-name>" \
  --workspace "<workspace-resource-id>" \
  --logs '[{"categoryGroup":"allLogs","enabled":true}]' \
  --metrics '[{"category":"AllMetrics","enabled":true}]'
```

**Available log categories:**

| Category | Content |
|----------|---------|
| `LoadBalancerAlertEvent` | Alert events |
| `LoadBalancerProbeHealthStatus` | Health probe status per backend |

**Available metrics (more useful):**

| Metric | Description |
|--------|-------------|
| `SYN Count` | TCP SYN packets (connection attempts) |
| `Byte Count` | Total bytes transferred |
| `Packet Count` | Total packets |
| `SNAT Connection Count` | SNAT port usage |
| `Health Probe Status` | Backend pool health |

## Azure Traffic Manager

### Overview

Azure Traffic Manager is a **DNS-based** traffic routing service. It operates at the **DNS layer** and does **not** proxy HTTP traffic — it simply resolves DNS queries to direct clients to the optimal endpoint.

### XFF Behavior

| Aspect | Behavior |
|--------|----------|
| **Sets XFF** | No — DNS-only, no HTTP traffic passes through Traffic Manager |
| **Modifies XFF** | No |
| **Sees HTTP requests** | No — Traffic Manager is not in the HTTP data path |

### How It Works

```
1. Client → DNS query: app.trafficmanager.net
2. Traffic Manager → DNS response: backend-eastus.azurewebsites.net
3. Client → Direct HTTPS connection to backend-eastus.azurewebsites.net
```

Traffic Manager is **never in the HTTP request path**. Therefore:
- XFF is not relevant to Traffic Manager configuration
- The backend service receives the client's real IP directly (unless another proxy is involved)
- No diagnostic logs contain HTTP header information

### When XFF Becomes Relevant

If Traffic Manager routes to a backend fronted by other proxies:

```
Client → DNS (Traffic Manager) → Front Door → App Gateway → App Service
                                   ↑
                             XFF is set here
```

In this architecture, Traffic Manager is transparent to XFF — it only affects which regional endpoint the client connects to.

### Diagnostic Logging

Traffic Manager logs are about DNS routing decisions, not HTTP:

```bash
az monitor diagnostic-settings create \
  --name "tm-diagnostics" \
  --resource "/subscriptions/<sub-id>/resourceGroups/<rg>/providers/Microsoft.Network/trafficManagerProfiles/<tm-name>" \
  --workspace "<workspace-resource-id>" \
  --logs '[{"categoryGroup":"allLogs","enabled":true}]' \
  --metrics '[{"category":"AllMetrics","enabled":true}]'
```

**Available log categories:**

| Category | Content |
|----------|---------|
| `ProbeHealthStatusEvents` | Endpoint health probe results |

**Useful metrics:**

| Metric | Description |
|--------|-------------|
| `Queries by Endpoint Returned` | DNS responses per endpoint |
| `Probe Agent Current Endpoint State` | Health status per endpoint |

## Comparison: Layer-4 vs Layer-7 for XFF

| Capability | Load Balancer (L4) | Traffic Manager (DNS) | Front Door (L7) | App Gateway (L7) |
|-----------|-------------------|---------------------|-----------------|-----------------|
| Sets XFF | No | No | Yes | Yes |
| Modifies XFF | No | No | Appends | Appends (with port) |
| HTTP awareness | No | No | Full | Full |
| Client IP preservation | Yes (TCP) | N/A (DNS) | Via XFF/headers | Via XFF/headers |
| Logging of XFF | No | No | Yes | Yes |
| WAF capability | No | No | Yes | Yes |

## Architectural Guidance

### When to Use Each Service

| Scenario | Recommended Service |
|----------|-------------------|
| HTTP XFF tracking needed | Front Door or Application Gateway |
| Global DNS routing + XFF | Traffic Manager → Front Door → App Gateway |
| Internal L4 load balancing | Internal Load Balancer (XFF N/A) |
| VM-based backends needing XFF | LB → Nginx/HAProxy (handles XFF) |

### Hybrid Pattern: LB + Reverse Proxy

For VM-based deployments that need XFF:

```
Client → Azure LB (L4) → Nginx/HAProxy (VM) → Application (VM)
                              ↑
                        Sets XFF from
                        client source IP
```

## Microsoft Learn References

- [Azure Load Balancer overview](https://learn.microsoft.com/en-us/azure/load-balancer/load-balancer-overview)
- [Azure Load Balancer SKU comparison](https://learn.microsoft.com/en-us/azure/load-balancer/skus)
- [Monitor Load Balancer](https://learn.microsoft.com/en-us/azure/load-balancer/monitor-load-balancer)
- [Load Balancer health probes](https://learn.microsoft.com/en-us/azure/load-balancer/load-balancer-custom-probe-overview)
- [Azure Traffic Manager overview](https://learn.microsoft.com/en-us/azure/traffic-manager/traffic-manager-overview)
- [Traffic Manager routing methods](https://learn.microsoft.com/en-us/azure/traffic-manager/traffic-manager-routing-methods)
- [Monitor Traffic Manager](https://learn.microsoft.com/en-us/azure/traffic-manager/traffic-manager-monitoring)
- [Traffic Manager endpoint monitoring](https://learn.microsoft.com/en-us/azure/traffic-manager/traffic-manager-monitoring)

## GitHub References

- [Azure/azure-quickstart-templates — Load Balancer](https://github.com/Azure/azure-quickstart-templates/tree/master/quickstarts/microsoft.network) — ARM/Bicep templates for LB
- [Azure/azure-quickstart-templates — Traffic Manager](https://github.com/Azure/azure-quickstart-templates/tree/master/quickstarts/microsoft.network/traffic-manager-external-endpoint) — Traffic Manager quickstarts
