# XFF Monitoring — Third-Party & On-Premises Proxies

In hybrid and multi-cloud architectures, traffic often passes through non-Azure proxies before reaching Azure services. Understanding how these proxies handle `X-Forwarded-For` is critical for maintaining an accurate XFF chain.

## Nginx

Nginx is commonly used as a reverse proxy on VMs behind Azure Load Balancer, or as a sidecar/ingress in Kubernetes.

### XFF Configuration

```nginx
# /etc/nginx/conf.d/proxy.conf
server {
    listen 80;
    server_name api.example.com;

    location / {
        proxy_pass http://backend:8080;

        # Set XFF — appends client IP to existing XFF chain
        proxy_set_header X-Forwarded-For $proxy_add_x_forwarded_for;
        proxy_set_header X-Real-IP $remote_addr;
        proxy_set_header X-Forwarded-Proto $scheme;
        proxy_set_header X-Forwarded-Host $host;
        proxy_set_header Host $host;
    }
}
```

### Key Variables

| Variable | Value |
|----------|-------|
| `$proxy_add_x_forwarded_for` | Existing XFF + `, $remote_addr` (appends) |
| `$remote_addr` | TCP peer IP |
| `$realip_remote_addr` | Original remote addr before `realip` module processing |

### Extracting Real Client IP (behind Azure Load Balancer)

If Nginx is behind an Azure Load Balancer, `$remote_addr` is already the real client IP (LB preserves source IP). No additional `set_real_ip_from` is needed.

If Nginx is behind an Application Gateway or Front Door:

```nginx
# Trust Azure Front Door and App Gateway IP ranges
set_real_ip_from 10.0.0.0/8;
set_real_ip_from 172.16.0.0/12;
real_ip_header X-Forwarded-For;
real_ip_recursive on;
```

### Access Log Format with XFF

```nginx
log_format xff_log '$remote_addr - $remote_user [$time_local] '
                   '"$request" $status $body_bytes_sent '
                   '"$http_x_forwarded_for" "$http_x_real_ip"';

access_log /var/log/nginx/access.log xff_log;
```

## HAProxy

### XFF Configuration

```haproxy
# /etc/haproxy/haproxy.cfg
defaults
    option forwardfor    # Automatically adds X-Forwarded-For

frontend http_front
    bind *:80
    default_backend http_back

    # Custom header for first client IP
    http-request set-header X-Real-Client-IP %[req.hdr(X-Forwarded-For),word(1,,)]

backend http_back
    server backend1 10.0.1.10:8080 check
```

### Key Options

| Option | Behavior |
|--------|----------|
| `option forwardfor` | Appends client IP to XFF (default) |
| `option forwardfor except 10.0.0.0/8` | Don't add XFF for internal sources |
| `option forwardfor if-none` | Only set XFF if not already present |

### Log Format with XFF

```haproxy
log-format "%ci:%cp [%tr] %ft %b/%s %TR/%Tw/%Tc/%Tr/%Ta %ST %B %CC %CS %tsc %ac/%fc/%bc/%sc/%rc %sq/%bq %hr %hs %{+Q}r %[capture.req.hdr(0)]"

# Capture XFF header
frontend http_front
    capture request header X-Forwarded-For len 200
```

## Cloudflare

Cloudflare is a common CDN/WAF that sits in front of Azure services.

### Headers Set by Cloudflare

| Header | Value | Notes |
|--------|-------|-------|
| `X-Forwarded-For` | Client IP chain | Appended by Cloudflare |
| `CF-Connecting-IP` | Real client IP | **Most reliable** — set by Cloudflare |
| `CF-IPCountry` | Client country code | Geo information |
| `True-Client-IP` | Real client IP (Enterprise only) | Alias for CF-Connecting-IP |
| `CF-RAY` | Unique request ID | Diagnostic |

### Trusting Cloudflare IPs in Azure

When Cloudflare fronts your Azure services, configure your proxies to trust Cloudflare IP ranges:

- Cloudflare publishes their IP ranges at: `https://www.cloudflare.com/ips/`
- Configure App Gateway or Nginx `set_real_ip_from` with these ranges
- Use `CF-Connecting-IP` as the most reliable source of client IP

### Pattern: Cloudflare → Azure Front Door → App Gateway

```
Client → Cloudflare → Azure Front Door → App Gateway → App Service
  XFF:     ∅         + client_ip       + CF_ip       + AFD_ip
```

In this chain:
- XFF will contain: `client_ip, cloudflare_ip, frontdoor_ip`
- `CF-Connecting-IP` = real client IP
- `X-Azure-ClientIP` = Cloudflare edge IP (not the end user)

## AWS ALB / CloudFront (Multi-Cloud)

If migrating from AWS or running hybrid:

### AWS ALB XFF Behavior

- ALB appends client IP to XFF: `X-Forwarded-For: client_ip, alb_ip`
- ALB also sets `X-Forwarded-Proto` and `X-Forwarded-Port`

### AWS CloudFront XFF Behavior

- CloudFront appends to existing XFF
- `CloudFront-Viewer-Address` header contains original client `ip:port`

### Hybrid Pattern: CloudFront → Azure Front Door

```
Client → CloudFront → Azure Front Door → App Gateway → Backend
  XFF:     ∅         + client_ip       + CF_ip        + AFD_ip
```

## On-Premises F5 / NetScaler

### F5 BIG-IP

```tcl
# iRule to set XFF
when HTTP_REQUEST {
    HTTP::header insert X-Forwarded-For [IP::client_addr]
}
```

### Citrix NetScaler (ADC)

```
# Rewrite action to insert XFF
add rewrite action act_insert_xff insert_http_header X-Forwarded-For CLIENT.IP.SRC
add rewrite policy pol_insert_xff true act_insert_xff
bind lb vserver vs_web -policyName pol_insert_xff -priority 100
```

## Kubernetes Ingress Controllers

### NGINX Ingress Controller (AKS)

The NGINX Ingress Controller in AKS handles XFF through ConfigMap or annotation settings:

```yaml
# ConfigMap
apiVersion: v1
kind: ConfigMap
metadata:
  name: nginx-configuration
  namespace: ingress-nginx
data:
  use-forwarded-headers: "true"
  compute-full-forwarded-for: "true"
  forwarded-for-header: "X-Forwarded-For"
```

Per-ingress annotation:

```yaml
apiVersion: networking.k8s.io/v1
kind: Ingress
metadata:
  annotations:
    nginx.ingress.kubernetes.io/configuration-snippet: |
      proxy_set_header X-Forwarded-For $proxy_add_x_forwarded_for;
```

### Traefik (Default AKS ingress)

```yaml
# Traefik static configuration
entryPoints:
  web:
    address: ":80"
    forwardedHeaders:
      trustedIPs:
        - "10.0.0.0/8"
        - "172.16.0.0/12"
```

## XFF Chain Verification

When multiple proxies are involved, verify the XFF chain is correct:

### Expected Chain

```
Client (203.0.113.50)
  → Cloudflare (198.41.x.x)
    → Azure Front Door (13.107.x.x)
      → App Gateway (10.0.1.5)
        → APIM (10.0.2.5)
          → App Service

XFF at App Service: 203.0.113.50, 198.41.x.x, 13.107.x.x, 10.0.1.5
```

### Verification KQL Query

```kql
requests
| where timestamp > ago(1h)
| extend xff = tostring(customDimensions["X-Forwarded-For"])
| where isnotempty(xff)
| extend hopCount = array_length(split(xff, ","))
| summarize count() by hopCount
| order by hopCount asc
```

Unexpected hop counts indicate a misconfigured proxy in the chain.

## Microsoft Learn References

- [Configure ASP.NET Core to work with proxy servers and load balancers](https://learn.microsoft.com/en-us/aspnet/core/host-and-deploy/proxy-load-balancer)
- [AKS NGINX Ingress Controller](https://learn.microsoft.com/en-us/azure/aks/app-routing)
- [AKS networking concepts](https://learn.microsoft.com/en-us/azure/aks/concepts-network)
- [Hub-spoke network topology](https://learn.microsoft.com/en-us/azure/architecture/networking/architecture/hub-spoke)

## GitHub References

- [kubernetes/ingress-nginx](https://github.com/kubernetes/ingress-nginx) — NGINX Ingress Controller (XFF config docs)
- [traefik/traefik](https://github.com/traefik/traefik) — Traefik proxy (forwarded headers config)
- [Azure/application-gateway-kubernetes-ingress](https://github.com/Azure/application-gateway-kubernetes-ingress) — AGIC for AKS
- [Azure/AKS](https://github.com/Azure/AKS) — AKS roadmap and known issues
