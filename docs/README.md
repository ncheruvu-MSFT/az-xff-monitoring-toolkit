# XFF Monitoring Documentation

Detailed guides for configuring, monitoring, and governing **X-Forwarded-For (XFF)** headers across Azure services.

## Documents

| Document | Description |
|----------|-------------|
| [XFF Overview](xff-overview.md) | What XFF is, why it matters, threat model, and header trust chain |
| [Azure Front Door](xff-azure-front-door.md) | XFF behavior, diagnostic logging, WAF integration, and KQL queries |
| [Azure Application Gateway](xff-azure-application-gateway.md) | XFF rewrite rules, port normalization, diagnostics, and Bicep IaC |
| [Azure API Management](xff-azure-api-management.md) | XFF pass-through, policy-based extraction, App Insights logging |
| [Azure App Service](xff-azure-app-service.md) | ForwardedHeaders middleware (.NET & Python), App Insights telemetry |
| [Azure Load Balancer & Traffic Manager](xff-azure-load-balancer-traffic-manager.md) | Layer-4 vs Layer-7, XFF limitations, and workarounds |
| [Azure Firewall](xff-azure-firewall.md) | Network-level logging, IDPS, and XFF behavior |
| [Third-Party / On-Prem Proxies](xff-third-party-proxies.md) | Nginx, HAProxy, Cloudflare, and hybrid XFF chains |
| [Multi-Tier Architecture Patterns](xff-multi-tier-patterns.md) | End-to-end XFF flow for Front Door → App GW → APIM → App Service |
| [Governance & Azure Policy](xff-governance-azure-policy.md) | Policy definitions, initiatives, compliance, and remediation |
| [Centralized Policy Configuration](xff-centralized-policy-configuration.md) | Enterprise-wide Azure Policy setup so all teams follow the same XFF standard |
| [KQL Query Reference](xff-kql-query-reference.md) | All KQL queries with explanations for monitoring and alerting |
| [Security Best Practices](xff-security-best-practices.md) | XFF spoofing, trust boundaries, header sanitization |

## Quick Links

- [xff-monitoring main README](../README.md)
- [Bicep infrastructure modules](../infra/)
- [Azure Policy definitions](../policies/)
- [KQL queries](../queries/xff-kql-queries.kql)
- [Code samples](../samples/)
- [Azure Monitor Workbook](../workbook/)
