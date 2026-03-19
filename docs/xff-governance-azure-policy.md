# XFF Monitoring — Governance & Azure Policy

This document covers how to enforce XFF header logging and normalization at scale using Azure Policy, policy initiatives, compliance monitoring, and remediation workflows.

## Strategy Overview

| Service | Policy Type | What It Enforces |
|---------|------------|------------------|
| **Azure Front Door** | AuditIfNotExists | Diagnostic settings sending `FrontDoorAccessLog` to Log Analytics |
| **Azure Front Door** | DeployIfNotExists | Auto-deploy diagnostic settings on new Front Door profiles |
| **Application Gateway** | Audit | XFF normalization rewrite rule set exists |
| **Application Gateway** | DeployIfNotExists | Auto-deploy diagnostic settings (access + firewall logs) |
| **APIM** | AuditIfNotExists | Diagnostic settings are configured |
| **APIM** | AuditIfNotExists | Application Insights is linked |
| **App Service** | AuditIfNotExists | Diagnostic settings for HTTP logs are enabled |
| **Azure Firewall** | AuditIfNotExists | Diagnostic settings (structured logs) are enabled |

## Built-in Policies (No Custom Definitions Needed)

Azure provides built-in policies that cover most diagnostic logging requirements. Use these before writing custom policies:

| Built-in Policy | Applies To | Category |
|-----------------|------------|----------|
| *Resource logs in Azure Front Door should be enabled* | Front Door | Monitoring |
| *Azure Application Gateway should have Resource logs enabled* | App Gateway | Network |
| *Resource logs in API Management should be enabled* | APIM | API Management |
| *Diagnostic logs in App Service should be enabled* | App Service | Monitoring |
| *Azure Firewall should have diagnostic settings configured* | Azure Firewall | Network |

> **Tip:** Search for `"diagnostic"` or `"resource logs"` in the Azure Policy portal under **Definitions** to find the latest built-in policies.

### Assigning Built-in Policies

```bash
# Find the built-in policy definition ID
az policy definition list \
  --query "[?contains(displayName, 'Application Gateway') && contains(displayName, 'log')].{name:name, displayName:displayName}" \
  --output table

# Assign at subscription scope
az policy assignment create \
  --name "require-appgw-resource-logs" \
  --display-name "Require Resource Logs on Application Gateway" \
  --policy "<policy-definition-name>" \
  --scope "/subscriptions/<sub-id>"
```

## Custom Policies (from This Repo)

### 1. Audit App Gateway XFF Rewrite Rule

**File:** [audit-appgw-xff-rewrite.json](../policies/audit-appgw-xff-rewrite.json)

Flags Application Gateways that do not have the XFF normalization rewrite rule set (`xff-normalization-ruleset`).

> **Important — Alias Limitation:** This policy can only verify that a rewrite rule set with the **name** `xff-normalization-ruleset` exists. Azure Policy **cannot** inspect the inner configuration of rewrite rules (e.g., `headerName`, `headerValue`, or `{var_add_x_forwarded_for_proxy}`) because the Application Gateway resource provider does not expose aliases for nested `requestHeaderConfigurations` properties. See the [centralized policy configuration guide](xff-centralized-policy-configuration.md#42-azure-application-gateway) for a layered enforcement strategy that combines Azure Policy, Resource Graph validation, CI/CD checks, and shared Bicep modules to achieve full coverage.

```bash
az policy definition create \
  --name "audit-appgw-xff-rewrite" \
  --display-name "Audit App Gateways missing XFF rewrite rule" \
  --rules @xff-monitoring/policies/audit-appgw-xff-rewrite.json \
  --mode All

az policy assignment create \
  --name "audit-appgw-xff" \
  --policy "audit-appgw-xff-rewrite" \
  --scope "/subscriptions/<sub-id>"
```

### 2. Auto-Deploy App Gateway Diagnostics (DINE)

**File:** [deploy-appgw-diagnostics.json](../policies/deploy-appgw-diagnostics.json)

Automatically deploys diagnostic settings on any App Gateway that doesn't have them.

```bash
az policy definition create \
  --name "deploy-appgw-diagnostics" \
  --display-name "Deploy diagnostic settings on Application Gateway" \
  --rules @xff-monitoring/policies/deploy-appgw-diagnostics.json \
  --mode All \
  --params '{"logAnalyticsWorkspaceId":{"type":"String"}}'

az policy assignment create \
  --name "deploy-appgw-diag" \
  --policy "deploy-appgw-diagnostics" \
  --scope "/subscriptions/<sub-id>" \
  --params '{"logAnalyticsWorkspaceId":{"value":"<workspace-resource-id>"}}' \
  --mi-system-assigned \
  --location "<region>"
```

> **Note:** DINE policies require a managed identity with appropriate RBAC roles. The role definition IDs are specified in the policy's `roleDefinitionIds`.

### 3. Audit APIM Diagnostics

**File:** [audit-apim-diagnostics.json](../policies/audit-apim-diagnostics.json)

Flags APIM instances that don't have diagnostic settings configured.

```bash
az policy definition create \
  --name "audit-apim-diagnostics" \
  --display-name "Audit APIM instances missing diagnostic settings" \
  --rules @xff-monitoring/policies/audit-apim-diagnostics.json \
  --mode All
```

## Policy Initiative (Bundle)

**File:** [xff-policy-initiative.json](../policies/xff-policy-initiative.json)

Bundles all XFF-related policies into a single initiative for centralized assignment.

### Deploying the Initiative

```bash
# 1. Create each policy definition first (see above)

# 2. Update the initiative JSON with actual policy definition IDs
#    Replace <policy-definition-id-*> placeholders

# 3. Create the initiative
az policy set-definition create \
  --name "xff-compliance-initiative" \
  --display-name "XFF Compliance Initiative" \
  --definitions @xff-monitoring/policies/xff-policy-initiative.json \
  --params '{"logAnalyticsWorkspaceId":{"type":"String","metadata":{"displayName":"Log Analytics Workspace ID"}}}'

# 4. Assign at management group level for full coverage
az policy assignment create \
  --name "xff-compliance" \
  --policy-set-definition "xff-compliance-initiative" \
  --scope "/providers/Microsoft.Management/managementGroups/<mg-name>" \
  --params '{"logAnalyticsWorkspaceId":{"value":"<workspace-resource-id>"}}' \
  --mi-system-assigned \
  --location "<region>"
```

## Compliance Monitoring

### Azure Resource Graph — Compliance Status

```kql
policyresources
| where type == "microsoft.policyinsights/policystates"
| where properties.policySetDefinitionName == "xff-compliance-initiative"
| extend
    complianceState = tostring(properties.complianceState),
    resourceId = tostring(properties.resourceId),
    policyName = tostring(properties.policyDefinitionName)
| summarize
    Compliant = countif(complianceState == "Compliant"),
    NonCompliant = countif(complianceState == "NonCompliant")
    by policyName
```

### Resource Graph — App Gateways Without Rewrite Rules

```kql
resources
| where type == "microsoft.network/applicationgateways"
| extend rewriteSets = properties.rewriteRuleSets
| extend hasXffRewrite = isnotempty(rewriteSets)
| project name, resourceGroup, subscriptionId, hasXffRewrite
| where hasXffRewrite == false
```

### Resource Graph — Resources Without Diagnostic Settings

```kql
resources
| where type in (
    "microsoft.network/applicationgateways",
    "microsoft.apimanagement/service",
    "microsoft.web/sites",
    "microsoft.cdn/profiles",
    "microsoft.network/azurefirewalls"
)
| join kind=leftouter (
    diagnosticsettings
    | where isnotempty(properties.workspaceId)
    | distinct resourceId = tolower(id)
) on $left.id == $right.resourceId
| where isempty(resourceId1)
| project type, name, resourceGroup, subscriptionId
| order by type asc
```

## Remediation

### Trigger Remediation for DINE Policies

When a DINE policy finds non-compliant resources, trigger remediation to apply the missing configuration:

```bash
# List non-compliant resources
az policy state list \
  --policy-assignment "deploy-appgw-diag" \
  --filter "complianceState eq 'NonCompliant'" \
  --query "[].{resourceId:resourceId}" \
  --output table

# Create remediation task
az policy remediation create \
  --name "remediate-appgw-diag-$(date +%Y%m%d)" \
  --policy-assignment "deploy-appgw-diag" \
  --resource-group "<rg-name>"
```

### Monitor Remediation Progress

```bash
az policy remediation show \
  --name "remediate-appgw-diag-20260319" \
  --resource-group "<rg-name>" \
  --query "{status:provisioningState, succeeded:deploymentStatus.totalDeployments, failed:deploymentStatus.failedDeployments}"
```

## Management Group Organization

For enterprise-scale XFF governance, assign the initiative at the management group level:

```
Root Management Group
├── Platform (Landing Zone)
│   ├── Connectivity (Hub VNets, Firewall, DNS)
│   │   └── XFF Initiative assigned here → covers firewalls, App Gateways
│   └── Management (Log Analytics, Automation)
├── Workloads
│   ├── Production
│   │   └── XFF Initiative assigned here → covers APIM, App Services
│   └── Non-Production
│       └── XFF Initiative (Audit-only mode)
```

## Microsoft Learn References

- [What is Azure Policy?](https://learn.microsoft.com/en-us/azure/governance/policy/overview)
- [Tutorial: Create custom policy definitions](https://learn.microsoft.com/en-us/azure/governance/policy/tutorials/create-custom-policy-definition)
- [Deploy diagnostic settings at scale with Azure Policy](https://learn.microsoft.com/en-us/azure/azure-monitor/essentials/diagnostic-settings-policy)
- [Policy initiative definition structure](https://learn.microsoft.com/en-us/azure/governance/policy/concepts/initiative-definition-structure)
- [Remediate non-compliant resources](https://learn.microsoft.com/en-us/azure/governance/policy/how-to/remediate-resources)
- [Organize resources with management groups](https://learn.microsoft.com/en-us/azure/governance/management-groups/overview)
- [Azure Policy built-in definitions — Networking](https://learn.microsoft.com/en-us/azure/governance/policy/samples/built-in-policies#network)
- [Azure Policy built-in definitions — API Management](https://learn.microsoft.com/en-us/azure/governance/policy/samples/built-in-policies#api-management)
- [Azure Policy built-in definitions — Monitoring](https://learn.microsoft.com/en-us/azure/governance/policy/samples/built-in-policies#monitoring)

## GitHub References

- [Azure/azure-policy](https://github.com/Azure/azure-policy) — Official Azure Policy samples and built-in definitions
- [Azure/Community-Policy](https://github.com/Azure/Community-Policy) — Community-contributed policy definitions
- [Azure/enterprise-scale](https://github.com/Azure/Enterprise-Scale) — Enterprise-scale landing zone with policy assignments
