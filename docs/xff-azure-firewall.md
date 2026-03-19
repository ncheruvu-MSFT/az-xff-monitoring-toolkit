# XFF Monitoring — Azure Firewall 

Azure Firewall is a managed, cloud-based network security service. It operates primarily at **Layer 3/4** (network/transport) with optional **Layer 7** (application) rule support. Its relationship with `X-Forwarded-For` is limited but important to understand in multi-tier architectures.

## How Azure Firewall Handles XFF

### Default Behavior

| Aspect | Behavior |
|--------|----------|
| **Sets XFF** | No |
| **Modifies XFF** | No |
| **Inspects XFF** | Not directly — application rules inspect SNI/FQDN, not XFF |
| **SNAT behavior** | Applies SNAT for outbound/east-west traffic (changes source IP) |

### Key Consideration: SNAT Impact on Source IP

Azure Firewall applies **SNAT** (Source Network Address Translation) to traffic flowing through it. This means:

- **Outbound traffic:** Source IP is replaced with firewall's public IP or private IP
- **East-west traffic (between VNets/subnets):** Source IP may be replaced with firewall's IP
- **Inbound traffic via DNAT:** Destination is translated, but source IP is preserved

If Azure Firewall sits between a client and an Application Gateway:

```
Client → Azure Firewall (DNAT) → App Gateway → APIM → App Service
         Source IP preserved ↑     Appends to XFF ↑
```

In **DNAT scenarios**, the original client source IP is preserved in the TCP packet, and Application Gateway then adds it to XFF. However, in **non-DNAT scenarios** (e.g., spoke-to-spoke routing through firewall), SNAT may replace the source IP.

### SNAT Behavior Summary

| Traffic Flow | SNAT Applied | Source IP Seen by Backend |
|-------------|-------------|--------------------------|
| Internet → DNAT rule → Backend | No SNAT on source | Original client IP |
| Spoke VNet → Firewall → Spoke VNet | SNAT (default) | Firewall private IP |
| Spoke → Firewall → Internet | SNAT | Firewall public IP |
| Spoke → Firewall → On-premises | SNAT (configurable) | Firewall private IP |

> **Impact on XFF:** If traffic passes through Azure Firewall with SNAT before reaching a Layer-7 proxy (App Gateway), the proxy will see the firewall's IP as the client IP and XFF will contain the firewall IP, not the real client IP.

## Configuring Firewall Logging

### Diagnostic Settings

Azure Firewall produces network-level and application-level logs:

```bash
az monitor diagnostic-settings create \
  --name "xff-diag-azfw" \
  --resource "/subscriptions/<sub-id>/resourceGroups/<rg>/providers/Microsoft.Network/azureFirewalls/<fw-name>" \
  --workspace "<workspace-resource-id>" \
  --logs '[{"categoryGroup":"allLogs","enabled":true}]' \
  --metrics '[{"category":"AllMetrics","enabled":true}]'
```

### Log Categories

| Category | Content | XFF Relevant? |
|----------|---------|---------------|
| `AZFWNetworkRule` | Network rule hits (L3/L4) | No (no HTTP headers) |
| `AZFWApplicationRule` | Application rule hits (L7 FQDN) | Partial (logs FQDN, not headers) |
| `AZFWNatRule` | DNAT rule hits | No (but source IP is logged) |
| `AZFWThreatIntel` | Threat intelligence matches | Source IP logged |
| `AZFWIdpsSignature` | IDPS signature matches | Source IP logged |

### Structured Logs (Resource-Specific Tables)

Azure Firewall supports resource-specific log tables for better query performance:

| Table | Description |
|-------|-------------|
| `AZFWNetworkRule` | Network rule log entries |
| `AZFWApplicationRule` | Application rule log entries |
| `AZFWNatRule` | NAT rule log entries |
| `AZFWThreatIntel` | Threat intelligence log entries |
| `AZFWIdpsSignature` | IDPS signature matches |
| `AZFWDnsQuery` | DNS proxy query logs |
| `AZFWFlowTrace` | Flow trace (network connection tracking) |

## KQL Queries

### DNAT Rule Hits (Source IP Tracking)

```kql
AZFWNatRule
| where TimeGenerated > ago(24h)
| project
    TimeGenerated,
    SourceIp,
    SourcePort,
    DestinationIp,
    DestinationPort,
    TranslatedIp,
    TranslatedPort,
    Protocol
| order by TimeGenerated desc
```

### Application Rule Hits

```kql
AZFWApplicationRule
| where TimeGenerated > ago(24h)
| project
    TimeGenerated,
    SourceIp,
    SourcePort,
    Fqdn,
    TargetUrl,
    Protocol,
    Action,
    Policy,
    RuleCollectionGroup,
    RuleCollection,
    Rule
| order by TimeGenerated desc
```

### Threat Intelligence Matches

```kql
AZFWThreatIntel
| where TimeGenerated > ago(24h)
| project
    TimeGenerated,
    SourceIp,
    DestinationIp,
    DestinationPort,
    ThreatDescription,
    Protocol,
    Action
| order by TimeGenerated desc
```

### IDPS Signature Matches

```kql
AZFWIdpsSignature
| where TimeGenerated > ago(24h)
| project
    TimeGenerated,
    SourceIp,
    DestinationIp,
    DestinationPort,
    SignatureId,
    Description,
    Severity,
    Action
| order by TimeGenerated desc
```

### Correlate Firewall Source IPs with App Gateway XFF

```kql
let fwDnat = AZFWNatRule
| where TimeGenerated > ago(1h)
| project FwTime = TimeGenerated, ClientIp = SourceIp, TranslatedIp;

let appGwAccess = AGWAccessLogs
| where TimeGenerated > ago(1h)
| project GwTime = TimeGenerated, ClientIp, Host, RequestUri, HttpStatusCode;

fwDnat
| join kind=inner appGwAccess on ClientIp
| project FwTime, GwTime, ClientIp, TranslatedIp, Host, RequestUri, HttpStatusCode
| order by FwTime desc
```

## Architectural Patterns

### Pattern 1: Firewall Before App Gateway (Recommended for Inbound)

```
Internet → Azure Firewall (DNAT) → Application Gateway → Backend
           Preserves source IP        Sets XFF
```

- DNAT preserves client source IP
- App Gateway correctly sets XFF with real client IP

### Pattern 2: Firewall After App Gateway (Hub-Spoke)

```
Internet → Application Gateway → Azure Firewall → Backend
           Sets XFF                May SNAT
```

- App Gateway sets XFF correctly
- Firewall may SNAT, but XFF is already in the HTTP header
- Backend reads XFF from HTTP, not TCP source

### Pattern 3: Zero-Trust (Firewall + App Gateway Combined)

```
Internet → Azure Firewall (DNAT) → Application Gateway (WAF) → APIM → App Service
```

- Firewall handles L3/L4 filtering and threat intel
- App Gateway handles L7 + WAF + XFF normalization
- This is the Microsoft-recommended architecture for high-security workloads

## Azure Policy for Firewall Diagnostics

```json
{
  "if": {
    "field": "type",
    "equals": "Microsoft.Network/azureFirewalls"
  },
  "then": {
    "effect": "AuditIfNotExists",
    "details": {
      "type": "Microsoft.Insights/diagnosticSettings",
      "existenceCondition": {
        "field": "Microsoft.Insights/diagnosticSettings/logs.enabled",
        "equals": "true"
      }
    }
  }
}
```

## Microsoft Learn References

- [Azure Firewall overview](https://learn.microsoft.com/en-us/azure/firewall/overview)
- [Azure Firewall logs and metrics](https://learn.microsoft.com/en-us/azure/firewall/firewall-diagnostics)
- [Azure Firewall structured logs](https://learn.microsoft.com/en-us/azure/firewall/firewall-structured-logs)
- [Azure Firewall DNAT rules](https://learn.microsoft.com/en-us/azure/firewall/tutorial-firewall-dnat)
- [Azure Firewall SNAT private IP ranges](https://learn.microsoft.com/en-us/azure/firewall/snat-private-range)
- [Azure Firewall IDPS](https://learn.microsoft.com/en-us/azure/firewall/premium-features#idps)
- [Zero-trust network for web applications](https://learn.microsoft.com/en-us/azure/architecture/example-scenario/gateway/application-gateway-before-azure-firewall)
- [Firewall and Application Gateway for virtual networks](https://learn.microsoft.com/en-us/azure/architecture/example-scenario/gateway/firewall-application-gateway)

## GitHub References

- [Azure/azure-quickstart-templates — Azure Firewall](https://github.com/Azure/azure-quickstart-templates/tree/master/quickstarts/microsoft.network/azurefirewall-create-with-zones-sandbox) — Bicep/ARM templates
- [Azure/azure-policy](https://github.com/Azure/azure-policy) — Policy definitions for firewall diagnostics
- [Azure/Azure-Network-Security](https://github.com/Azure/Azure-Network-Security) — Network security samples including firewall configurations
