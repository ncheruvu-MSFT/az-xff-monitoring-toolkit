# Centralized Azure Policy Configuration for XFF Compliance

This guide explains how to configure Azure Policy **centrally** so that all teams across your organization follow the same XFF monitoring, diagnostic logging, and header normalization standards — without requiring each team to configure resources individually.

---

## 1. Why Centralize with Azure Policy

Azure Policy enables platform teams to enforce organizational standards **declaratively** at the management group, subscription, or resource group scope. Policies evaluate resources in real time during creation and updates, and can also audit or remediate existing resources.

For XFF monitoring, centralized policy ensures:

- Every Application Gateway normalizes XFF headers with the required rewrite rule
- Every ingress resource (Front Door, App Gateway, APIM, App Service, Firewall) sends diagnostic logs to the central Log Analytics workspace
- Teams cannot deploy non-compliant resources in **Deny** mode, or are alerted in **Audit** mode
- New resources are automatically configured via **DeployIfNotExists** (DINE) policies

**Microsoft Learn:**
- [What is Azure Policy?](https://learn.microsoft.com/en-us/azure/governance/policy/overview)
- [Azure Policy definition structure](https://learn.microsoft.com/en-us/azure/governance/policy/concepts/definition-structure)
- [Understand Azure Policy effects](https://learn.microsoft.com/en-us/azure/governance/policy/concepts/effects)

---

## 2. Management Group Hierarchy — Where to Assign

Azure Policy assignments **inherit downward** through the management group hierarchy. Assigning at a high scope ensures uniform coverage without per-subscription effort.

### Recommended Hierarchy (Azure Landing Zone Model)

```
Tenant Root Group
└── Organization Root
    ├── Platform
    │   ├── Connectivity          ← Assign XFF policies here (Firewall, App Gateway, Front Door)
    │   ├── Identity
    │   └── Management            ← Central Log Analytics workspace lives here
    ├── Landing Zones
    │   ├── Production            ← Assign XFF policies here (APIM, App Service)
    │   └── Non-Production        ← Assign in Audit-only mode
    ├── Sandbox                   ← Exempt or Audit-only
    └── Decommissioned            ← Exempt
```

### Scoping Rules

| Scope Level | Use When |
|-------------|----------|
| **Management group** | Enforce across all subscriptions belonging to the group. Best for org-wide standards. |
| **Subscription** | Enforce within a single subscription. Use for subscription-specific overrides. |
| **Resource group** | Enforce within a single resource group. Use for team-level exceptions. |

### Exemptions

If a resource or subscription has a legitimate reason to not comply, use **policy exemptions** instead of removing the assignment:

- **Waiver** — Permanently exempt (documented risk acceptance)
- **Mitigated** — Temporarily exempt (alternative control is in place)

**Microsoft Learn:**
- [Organize resources with management groups](https://learn.microsoft.com/en-us/azure/governance/management-groups/overview)
- [Azure Policy assignment structure](https://learn.microsoft.com/en-us/azure/governance/policy/concepts/assignment-structure)
- [Azure Policy exemption structure](https://learn.microsoft.com/en-us/azure/governance/policy/concepts/exemption-structure)
- [Azure landing zone — policy-driven governance](https://learn.microsoft.com/en-us/azure/cloud-adoption-framework/ready/landing-zone/design-principles#policy-driven-governance)
- [Enterprise-scale management group and subscription organization](https://learn.microsoft.com/en-us/azure/cloud-adoption-framework/ready/landing-zone/design-area/resource-org-management-groups)

---

## 3. Policy Effects — Choosing the Right Enforcement Level

Azure Policy supports multiple effects. Choose the right one based on your rollout phase:

| Effect | Behavior | When to Use |
|--------|----------|-------------|
| **Audit** | Logs non-compliance but allows the deployment | Initial rollout, visibility-only phase |
| **Deny** | Blocks non-compliant resource creation/update | After teams have adopted the standard |
| **AuditIfNotExists** | Checks for existence of a related resource (e.g., diagnostic settings) | Auditing dependent configurations |
| **DeployIfNotExists** | Automatically creates/configures the missing related resource | Auto-remediation of diagnostic settings |
| **Modify** | Adds, updates, or removes properties on a resource during create/update | Tagging, adding managed identity |
| **Disabled** | Policy exists but is not evaluated | Temporarily pausing enforcement |

### Recommended Rollout Phases

| Phase | Timeline | Effect | Purpose |
|-------|----------|--------|---------|
| **1. Discovery** | Week 1–2 | Audit / AuditIfNotExists | Assess current compliance posture |
| **2. Auto-remediation** | Week 3–4 | DeployIfNotExists | Fix existing resources automatically |
| **3. Prevention** | Week 5+ | Deny | Block non-compliant new deployments |

**Microsoft Learn:**
- [Understand Azure Policy effects](https://learn.microsoft.com/en-us/azure/governance/policy/concepts/effects)
- [Azure Policy evaluation order](https://learn.microsoft.com/en-us/azure/governance/policy/concepts/effects#order-of-evaluation)
- [DeployIfNotExists policy effect](https://learn.microsoft.com/en-us/azure/governance/policy/concepts/effects#deployifnotexists)

---

## 4. Service-by-Service Policy Requirements

### 4.1 Azure Front Door

| Standard | Policy Effect | What to Enforce |
|----------|--------------|-----------------|
| Diagnostic logs enabled | AuditIfNotExists | `FrontDoorAccessLog` and `FrontDoorWebApplicationFirewallLog` sent to central Log Analytics workspace |
| Auto-deploy diagnostics | DeployIfNotExists | Automatically configure diagnostic settings on new Front Door profiles |
| WAF enabled | Audit | Front Door profiles should have WAF policy associated |

**Built-in policies available:**
- *Azure Front Door should have resource logs enabled* — Audits diagnostic log configuration
- *Azure Front Door Standard or Premium (Plus WAF) should have resource logs enabled* — For Standard/Premium SKUs
- *Azure Web Application Firewall should be enabled for Azure Front Door entry-points* — WAF association

**Microsoft Learn:**
- [Azure Front Door diagnostic logs](https://learn.microsoft.com/en-us/azure/frontdoor/front-door-diagnostics)
- [Azure Policy built-in definitions for CDN](https://learn.microsoft.com/en-us/azure/governance/policy/samples/built-in-policies#cdn)
- [Enable WAF on Front Door](https://learn.microsoft.com/en-us/azure/web-application-firewall/afds/waf-front-door-create-portal)

---

### 4.2 Azure Application Gateway

| Standard | Policy Effect | What to Enforce |
|----------|--------------|-----------------|
| XFF rewrite rule set exists (by name) | Audit / Deny | `xff-normalization-ruleset` rewrite rule set must be present |
| Diagnostic logs enabled | DeployIfNotExists | All logs + metrics sent to central Log Analytics workspace |
| WAF enabled | Audit | App Gateway v2 should have WAF policy associated |

**Built-in policies available:**
- *Azure Application Gateway should have resource logs enabled* — Audits diagnostic settings
- *Web Application Firewall (WAF) should be enabled for Application Gateway* — WAF association
- *Web Application Firewall (WAF) should use the specified mode for Application Gateway* — Prevention vs Detection mode

> **Note:** There is no built-in policy for the XFF rewrite rule. Use the custom policy definition from this repo ([audit-appgw-xff-rewrite.json](../policies/audit-appgw-xff-rewrite.json)) to enforce it.

#### Azure Policy Limitation — Rewrite Rule Content Cannot Be Enforced

The Bicep configuration teams should deploy is:

```bicep
resource rewriteRuleSet 'Microsoft.Network/applicationGateways/rewriteRuleSets@2023-11-01' = {
  name: 'xff-normalization-ruleset'
  parent: appGateway
  properties: {
    rewriteRules: [
      {
        name: 'Normalize-XFF'
        ruleSequence: 100
        conditions: []
        actionSet: {
          requestHeaderConfigurations: [
            {
              headerName: 'X-Forwarded-For'
              headerValue: '{var_add_x_forwarded_for_proxy}'
            }
          ]
          responseHeaderConfigurations: []
        }
      }
    ]
  }
}
```

**What Azure Policy CAN enforce:**
- That a rewrite rule set with the **name** `xff-normalization-ruleset` **exists** on the Application Gateway (via the `Microsoft.Network/applicationGateways/rewriteRuleSets[*].name` alias)

**What Azure Policy CANNOT enforce:**
- That the rewrite rule set contains a rule named `Normalize-XFF`
- That `headerName` is set to `X-Forwarded-For`
- That `headerValue` is set to `{var_add_x_forwarded_for_proxy}`
- That the rewrite rule set is **associated with a routing rule**

**Why:** Azure Policy relies on [resource provider aliases](https://learn.microsoft.com/en-us/azure/governance/policy/concepts/definition-structure#aliases) to evaluate resource properties. The Application Gateway resource provider exposes aliases for top-level properties like `rewriteRuleSets[*].name` but does **not** expose aliases for nested properties inside rewrite rules such as `requestHeaderConfigurations[*].headerName` or `headerValue`. Without an alias, Azure Policy cannot read or evaluate those fields.

You can verify available aliases with:

```bash
az provider show \
  --namespace Microsoft.Network \
  --resource-type applicationGateways \
  --expand "resourceTypes/aliases" \
  --query "resourceTypes[0].aliases[?contains(name, 'rewriteRule')].name" \
  --output table
```

**Microsoft Learn:**
- [Understanding aliases in Azure Policy](https://learn.microsoft.com/en-us/azure/governance/policy/concepts/definition-structure#aliases)
- [List available aliases (Azure CLI)](https://learn.microsoft.com/en-us/azure/governance/policy/concepts/definition-structure#aliases)
- [Azure Policy definition structure — field property](https://learn.microsoft.com/en-us/azure/governance/policy/concepts/definition-structure-policy-rule#fields)

#### Recommended Enforcement Strategies

Since Azure Policy alone cannot enforce the full rewrite rule configuration, use a **layered approach**:

| Layer | Strategy | What It Covers | MS Learn Reference |
|-------|----------|---------------|-------------------|
| **1. Azure Policy (Audit/Deny)** | Check that a rewrite rule set named `xff-normalization-ruleset` exists | Rule set presence | [Custom policy definitions](https://learn.microsoft.com/en-us/azure/governance/policy/tutorials/create-custom-policy-definition) |
| **2. Azure Resource Graph** | Periodically query App Gateway properties to verify rule content (`headerName`, `headerValue`) | Deep property validation | [Resource Graph queries](https://learn.microsoft.com/en-us/azure/governance/resource-graph/concepts/query-language) |
| **3. CI/CD Pipeline Validation** | In deployment pipelines, validate the Bicep/ARM template contains the correct rewrite rule before deployment | Pre-deployment check | [Azure Policy as code](https://learn.microsoft.com/en-us/azure/governance/policy/concepts/policy-as-code) |
| **4. Shared Bicep Module** | Publish the `appgateway-xff-rewrite.bicep` module to a Bicep module registry so all teams use the same tested module | Standardized IaC | [Bicep module registry](https://learn.microsoft.com/en-us/azure/azure-resource-manager/bicep/private-module-registry) |
| **5. Azure Monitor Alert** | Use a KQL query to detect non-normalized XFF values (containing `:port`) and alert when the rewrite is missing or misconfigured | Runtime detection | [Create log alert rules](https://learn.microsoft.com/en-us/azure/azure-monitor/alerts/alerts-create-log-alert-rule) |

**Strategy 1 — Azure Policy (already in this repo):**

The custom [audit-appgw-xff-rewrite.json](../policies/audit-appgw-xff-rewrite.json) checks for the rule set name. This is the baseline — if the name is wrong, the configuration is definitely missing.

**Strategy 2 — Azure Resource Graph deep validation:**

Resource Graph can query the full `properties` bag, including nested rewrite rule content:

```kql
resources
| where type == "microsoft.network/applicationgateways"
| mv-expand ruleSet = properties.rewriteRuleSets
| where ruleSet.name == "xff-normalization-ruleset"
| mv-expand rule = ruleSet.properties.rewriteRules
| mv-expand headerConfig = rule.properties.actionSet.requestHeaderConfigurations
| extend
    ruleName = tostring(rule.name),
    headerName = tostring(headerConfig.headerName),
    headerValue = tostring(headerConfig.headerValue)
| project
    name,
    resourceGroup,
    subscriptionId,
    ruleName,
    headerName,
    headerValue,
    isCorrect = (headerName == "X-Forwarded-For" and headerValue == "{var_add_x_forwarded_for_proxy}")
| where isCorrect == false or isempty(headerName)
```

Run this query on a schedule (e.g., daily via Azure Automation or Logic App) to detect drift.

**Microsoft Learn:**
- [Azure Resource Graph overview](https://learn.microsoft.com/en-us/azure/governance/resource-graph/overview)
- [Starter Resource Graph queries](https://learn.microsoft.com/en-us/azure/governance/resource-graph/samples/starter)
- [Azure Automation runbooks](https://learn.microsoft.com/en-us/azure/automation/automation-runbook-types)

**Strategy 3 — CI/CD pipeline check:**

Add a step in your deployment pipeline that validates the ARM/Bicep output contains the expected properties before deploying:

- Use `az bicep build` to compile Bicep to ARM JSON
- Parse the JSON to confirm `rewriteRuleSets` contains the correct `headerName` and `headerValue`
- Fail the pipeline if the expected configuration is missing

**Microsoft Learn:**
- [Azure Policy as code workflows](https://learn.microsoft.com/en-us/azure/governance/policy/concepts/policy-as-code)
- [Integrate Azure Policy with Azure DevOps](https://learn.microsoft.com/en-us/azure/governance/policy/tutorials/policy-devops-pipelines)

**Strategy 4 — Shared Bicep module registry:**

Publish the `appgateway-xff-rewrite.bicep` module to an Azure Container Registry-based Bicep module registry so all teams consume the same validated module:

```bicep
// Teams reference the shared module
module xffRewrite 'br:myregistry.azurecr.io/bicep/modules/appgw-xff-rewrite:v1.0' = {
  name: 'deploy-xff-rewrite'
  params: {
    appGatewayName: appGateway.name
  }
}
```

This ensures the `headerName`, `headerValue`, and `{var_add_x_forwarded_for_proxy}` configuration is always correct — the module is the single source of truth.

**Microsoft Learn:**
- [Create a private Bicep module registry](https://learn.microsoft.com/en-us/azure/azure-resource-manager/bicep/private-module-registry)
- [Publish Bicep modules to a registry](https://learn.microsoft.com/en-us/azure/azure-resource-manager/bicep/bicep-cli#publish)
- [Share Bicep modules within your organization](https://learn.microsoft.com/en-us/azure/azure-resource-manager/bicep/private-module-registry#configure-module-registry-access)

**Strategy 5 — Runtime detection via Azure Monitor:**

Even with all pre-deployment checks, configuration can drift. Use a KQL alert to detect when XFF values still contain `:port` (meaning the rewrite rule is missing or misconfigured):

```kql
requests
| where timestamp > ago(1h)
| extend xff = tostring(customDimensions["Request-Header-x-forwarded-for"])
| where isnotempty(xff) and xff matches regex @"\d+\.\d+\.\d+\.\d+:\d+"
| summarize MalformedCount = count()
| where MalformedCount > 0
```

**Microsoft Learn:**
- [Create log alert rules in Azure Monitor](https://learn.microsoft.com/en-us/azure/azure-monitor/alerts/alerts-create-log-alert-rule)
- [Azure Monitor alerts overview](https://learn.microsoft.com/en-us/azure/azure-monitor/alerts/alerts-overview)

**Microsoft Learn:**
- [Application Gateway diagnostics and logging](https://learn.microsoft.com/en-us/azure/application-gateway/application-gateway-diagnostics)
- [Azure Policy built-in definitions for networking](https://learn.microsoft.com/en-us/azure/governance/policy/samples/built-in-policies#network)
- [Rewrite HTTP headers with Application Gateway](https://learn.microsoft.com/en-us/azure/application-gateway/rewrite-http-headers-url)

---

### 4.3 Azure API Management

| Standard | Policy Effect | What to Enforce |
|----------|--------------|-----------------|
| Diagnostic logs enabled | AuditIfNotExists | Gateway logs sent to Log Analytics |
| Application Insights linked | AuditIfNotExists | APIM must have Application Insights integration |
| API-level header logging | Manual / Audit | `X-Forwarded-For` listed in headers-to-log for each API diagnostic setting |

**Built-in policies available:**
- *API Management services should use a virtual network* — Ensures APIM is VNet-integrated
- *API Management should have resource logs enabled* — Audits diagnostic settings
- *API Management minimum API version should be set to 2019-12-01 or higher* — Security baseline

> **Note:** There is no built-in policy to enforce that **specific headers** (like XFF) are in the APIM diagnostics headers-to-log list. Enforce this via the custom APIM diagnostic Bicep module from this repo, or via organizational documentation as a configuration standard.

**Microsoft Learn:**
- [API Management diagnostic settings](https://learn.microsoft.com/en-us/azure/api-management/api-management-howto-use-azure-monitor)
- [Monitor APIs with Azure Application Insights](https://learn.microsoft.com/en-us/azure/api-management/api-management-howto-app-insights)
- [Azure Policy built-in definitions for API Management](https://learn.microsoft.com/en-us/azure/governance/policy/samples/built-in-policies#api-management)
- [API Management diagnostics logging reference](https://learn.microsoft.com/en-us/azure/api-management/diagnostic-logs-reference)

---

### 4.4 Azure App Service

| Standard | Policy Effect | What to Enforce |
|----------|--------------|-----------------|
| Diagnostic logs enabled | AuditIfNotExists | `AppServiceHTTPLogs`, `AppServiceAppLogs` sent to Log Analytics |
| Auto-deploy diagnostics | DeployIfNotExists | Automatically configure diagnostic settings on new App Services |
| HTTPS only | Deny | App Service accessible only via HTTPS |

**Built-in policies available:**
- *App Service apps should have resource logs enabled* — Audits diagnostic settings
- *App Service apps should only be accessible over HTTPS* — Transport security
- *App Service apps should use the latest TLS version* — TLS enforcement
- *App Service app slots should have resource logs enabled* — Covers deployment slots

> **Note:** Azure Policy cannot enforce that application code includes `ForwardedHeadersMiddleware` or a telemetry initializer. Those are application-level concerns that should be standardized via shared NuGet/pip packages, code templates, or CI/CD pipeline checks.

**Microsoft Learn:**
- [Enable diagnostic logging for App Service](https://learn.microsoft.com/en-us/azure/app-service/troubleshoot-diagnostic-logs)
- [Azure Policy built-in definitions for App Service](https://learn.microsoft.com/en-us/azure/governance/policy/samples/built-in-policies#app-service)
- [Monitor App Service with Azure Monitor](https://learn.microsoft.com/en-us/azure/app-service/monitor-app-service)

---

### 4.5 Azure Firewall

| Standard | Policy Effect | What to Enforce |
|----------|--------------|-----------------|
| Diagnostic logs enabled | AuditIfNotExists | Structured logs (`AZFWNetworkRule`, `AZFWApplicationRule`, etc.) sent to Log Analytics |
| Auto-deploy diagnostics | DeployIfNotExists | Automatically configure diagnostic settings on new Firewalls |

**Built-in policies available:**
- *Azure Firewall should have diagnostic settings configured* — Audits or auto-deploys diagnostic settings
- *Azure Firewall policy should enable TLS inspection* — Premium SKU TLS inspection

**Microsoft Learn:**
- [Azure Firewall logs and metrics](https://learn.microsoft.com/en-us/azure/firewall/firewall-diagnostics)
- [Azure Firewall structured logs](https://learn.microsoft.com/en-us/azure/firewall/firewall-structured-logs)
- [Azure Policy built-in definitions for networking](https://learn.microsoft.com/en-us/azure/governance/policy/samples/built-in-policies#network)

---

### 4.6 Azure Load Balancer

| Standard | Policy Effect | What to Enforce |
|----------|--------------|-----------------|
| Diagnostic logs enabled | AuditIfNotExists | Flow logs and metrics sent to Log Analytics |

**Built-in policies available:**
- *Flow logs should be configured for every network security group* — NSG flow log enforcement (related)

> **Note:** Load Balancer is Layer 4 and does not interact with XFF. Diagnostic policies apply to health probe and connection metrics only.

**Microsoft Learn:**
- [Monitor Load Balancer](https://learn.microsoft.com/en-us/azure/load-balancer/monitor-load-balancer)
- [Azure Policy built-in definitions for networking](https://learn.microsoft.com/en-us/azure/governance/policy/samples/built-in-policies#network)

---

## 5. Building the Centralized Initiative

A **policy initiative** (also called a policy set definition) bundles multiple policy definitions into one assignable unit. This is the recommended approach for centralized governance.

### Initiative Design

```
XFF Compliance Initiative
├── [Built-in]   Front Door diagnostic logs audit
├── [Built-in]   App Gateway diagnostic logs audit
├── [Built-in]   APIM diagnostic logs audit
├── [Built-in]   App Service diagnostic logs audit
├── [Built-in]   Azure Firewall diagnostic logs audit
├── [Built-in]   WAF enabled on Front Door
├── [Built-in]   WAF enabled on App Gateway
├── [Custom]     App Gateway XFF rewrite rule audit
├── [Custom]     App Gateway auto-deploy diagnostics (DINE)
└── [Custom]     APIM diagnostics audit (with workspace check)
```

### Steps to Create

1. **Inventory built-in policies** — Search the Azure Policy portal for existing built-in polices that match your requirements. Prefer built-in over custom.
2. **Create custom definitions** — Only create custom policy definitions for requirements that no built-in covers (e.g., XFF rewrite rule audit).
3. **Create the initiative** — Bundle all policies with parameterized values (e.g., Log Analytics workspace ID).
4. **Test at subscription scope** — Assign in Audit mode to a test subscription first.
5. **Gradual rollout** — Move to management group scope after validating compliance results.

### Initiative Parameters

Centralize common parameters so all bundled policies share the same values:

| Parameter | Type | Description |
|-----------|------|-------------|
| `logAnalyticsWorkspaceId` | String | Resource ID of the central Log Analytics workspace |
| `effect` | String | Default policy effect (Audit, Deny, etc.) |
| `requiredRewriteRuleSetName` | String | Name of the XFF rewrite rule set to enforce on App Gateways |

**Microsoft Learn:**
- [Policy initiative definition structure](https://learn.microsoft.com/en-us/azure/governance/policy/concepts/initiative-definition-structure)
- [Create and assign an initiative definition](https://learn.microsoft.com/en-us/azure/governance/policy/tutorials/create-and-manage#create-and-assign-an-initiative-definition)
- [Group policy definitions with initiatives](https://learn.microsoft.com/en-us/azure/governance/policy/overview#initiative-definition)

---

## 6. Assigning with Managed Identity (DINE Policies)

DeployIfNotExists and Modify policies require a **managed identity** to perform remediation deployments. When you assign the initiative, Azure Policy creates a system-assigned managed identity and grants it the roles specified in each policy's `roleDefinitionIds`.

### Required RBAC Roles

| Policy Action | Required Role(s) |
|---------------|------------------|
| Deploy diagnostic settings on App Gateway | **Monitoring Contributor** + **Log Analytics Contributor** |
| Deploy diagnostic settings on Front Door | **Monitoring Contributor** + **Log Analytics Contributor** |
| Deploy diagnostic settings on APIM | **Monitoring Contributor** + **Log Analytics Contributor** |
| Deploy diagnostic settings on App Service | **Monitoring Contributor** + **Log Analytics Contributor** |

### Assignment Location

The managed identity must be created in a region. Choose the same region as your central Log Analytics workspace.

### Cross-Subscription Access

If the initiative is assigned at a management group but the Log Analytics workspace is in a different subscription, the managed identity needs **Monitoring Contributor** role scoped to the subscription containing the target workspace.

**Microsoft Learn:**
- [Remediate non-compliant resources with Azure Policy](https://learn.microsoft.com/en-us/azure/governance/policy/how-to/remediate-resources)
- [Configure the managed identity for policy assignments](https://learn.microsoft.com/en-us/azure/governance/policy/how-to/remediate-resources#configure-the-managed-identity)
- [Azure built-in roles — Monitoring Contributor](https://learn.microsoft.com/en-us/azure/role-based-access-control/built-in-roles/monitor#monitoring-contributor)
- [Azure built-in roles — Log Analytics Contributor](https://learn.microsoft.com/en-us/azure/role-based-access-control/built-in-roles/analytics#log-analytics-contributor)

---

## 7. Compliance Monitoring & Dashboards

After assigning the initiative, monitor compliance through multiple channels.

### Azure Portal — Policy Compliance Blade

1. Navigate to **Azure Policy → Compliance**
2. Filter by the **XFF Compliance Initiative** assignment
3. Drill into each policy definition to see per-resource compliance status
4. Export compliance data to CSV for reporting

**Microsoft Learn:**
- [Get compliance data of Azure resources](https://learn.microsoft.com/en-us/azure/governance/policy/how-to/get-compliance-data)
- [Determine causes of non-compliance](https://learn.microsoft.com/en-us/azure/governance/policy/how-to/determine-non-compliance)

### Azure Resource Graph — Programmatic Compliance Queries

Use the `policyresources` table in Azure Resource Graph to query compliance across all subscriptions:

```kql
policyresources
| where type == "microsoft.policyinsights/policystates"
| where properties.policySetDefinitionName == "xff-compliance-initiative"
| extend
    complianceState = tostring(properties.complianceState),
    resourceType = tostring(properties.resourceType),
    resourceId = tostring(properties.resourceId),
    policyName = tostring(properties.policyDefinitionName)
| summarize
    Compliant = countif(complianceState == "Compliant"),
    NonCompliant = countif(complianceState == "NonCompliant")
    by policyName, resourceType
```

**Microsoft Learn:**
- [Query Azure Policy compliance data with Resource Graph](https://learn.microsoft.com/en-us/azure/governance/policy/how-to/get-compliance-data#azure-resource-graph)
- [Azure Resource Graph query language](https://learn.microsoft.com/en-us/azure/governance/resource-graph/concepts/query-language)

### Azure Monitor Workbook — Visual Dashboard

The XFF Compliance Workbook (included in this repo at [workbook/xff-compliance-workbook.json](../workbook/xff-compliance-workbook.json)) provides visual dashboards. For policy-specific compliance visualization, create a companion workbook that queries the `policyresources` table using Azure Resource Graph data source.

**Microsoft Learn:**
- [Create interactive reports with Azure Monitor Workbooks](https://learn.microsoft.com/en-us/azure/azure-monitor/visualize/workbooks-overview)

---

## 8. Remediation Workflow

### Automatic Remediation (DINE Policies)

DINE policies evaluate resources continuously. New resources are remediated at creation time. Existing non-compliant resources require a **remediation task**:

1. **Identify non-compliant resources** via the Policy Compliance blade or Resource Graph
2. **Create a remediation task** from the portal or CLI
3. **Monitor progress** — each remediation task tracks successful and failed deployments
4. **Investigate failures** — check the deployment activity log for the managed identity

### Remediation via Azure Portal

1. Go to **Azure Policy → Compliance**
2. Select the non-compliant policy
3. Click **Create Remediation Task**
4. Choose scope (management group, subscription, or resource group)
5. The managed identity deploys the missing configuration

### Remediation at Scale

For enterprise-wide remediation of existing resources:

- Schedule remediation tasks via **Azure Automation** or **Logic Apps**
- Use the **Azure Policy Remediation REST API** for pipeline-driven remediation
- Monitor via **Azure Monitor alerts** on policy compliance state changes

**Microsoft Learn:**
- [Remediate non-compliant resources](https://learn.microsoft.com/en-us/azure/governance/policy/how-to/remediate-resources)
- [Create remediation task structure](https://learn.microsoft.com/en-us/azure/governance/policy/how-to/remediate-resources#create-a-remediation-task)
- [Policy compliance event triggers (Azure Event Grid)](https://learn.microsoft.com/en-us/azure/governance/policy/concepts/event-overview)

---

## 9. Multi-Team Governance Model

### RACI Matrix

| Activity | Platform Team | Application Team | Security Team |
|----------|:------------:|:----------------:|:-------------:|
| Define XFF policy standards | **R/A** | C | C |
| Create/maintain custom policy definitions | **R** | I | C |
| Assign initiative at management group | **R/A** | I | C |
| Remediate non-compliant infrastructure | **R** | I | I |
| Configure application-level XFF middleware | I | **R/A** | C |
| Monitor compliance dashboard | C | I | **R** |
| Review exemption requests | C | **R** | **A** |
| Incident response using XFF logs | C | C | **R/A** |

*R = Responsible, A = Accountable, C = Consulted, I = Informed*

### Team Responsibilities

**Platform / Infrastructure Team:**
- Maintains the centralized policy initiative definitions
- Assigns policies at the management group level
- Manages the central Log Analytics workspace
- Runs remediation tasks for existing resources

**Application / Development Teams:**
- Ensure application code includes XFF middleware (`ForwardedHeadersMiddleware`, `ProxyFix`, etc.)
- Configure `KnownNetworks` / `KnownProxies` for their deployment topology
- Register telemetry initializers to capture XFF in Application Insights
- Request policy exemptions when needed (with justification)

**Security / Compliance Team:**
- Reviews compliance dashboards and Resource Graph reports
- Approves or denies exemption requests
- Defines the required XFF rewrite rule naming convention
- Audits WAF rules to ensure `SocketAddr` is used (not `RemoteAddr`)

### Enforcing Application-Level Standards (Beyond Azure Policy)

Azure Policy cannot enforce application **code** standards (middleware configuration, telemetry initializers). Use these complementary approaches:

| Approach | Description |
|----------|-------------|
| **Shared libraries / NuGet/pip packages** | Publish a team-maintained package that includes pre-configured XFF middleware and telemetry initializer |
| **Application templates (scaffolding)** | Provide project templates that include XFF middleware by default |
| **CI/CD pipeline checks** | Add pipeline steps that scan `Program.cs` / `startup.py` for `UseForwardedHeaders` or `ProxyFix` |
| **Architecture Decision Records (ADRs)** | Document the XFF configuration standard as an ADR in the team wiki |
| **Pull request checklists** | Include "XFF middleware configured" as a review checklist item |

**Microsoft Learn:**
- [Cloud Adoption Framework — governance disciplines](https://learn.microsoft.com/en-us/azure/cloud-adoption-framework/govern/)
- [Azure landing zone design principles](https://learn.microsoft.com/en-us/azure/cloud-adoption-framework/ready/landing-zone/design-principles)

---

## 10. Handling Exceptions & Policy Exemptions

Not all resources can comply with every policy. Azure Policy provides a formal exemption mechanism.

### When to Use Exemptions

| Scenario | Exemption Category | Example |
|----------|-------------------|---------|
| Legacy App Gateway v1 (no rewrite rules) | Waiver | App Gateway v1 doesn't support rewrite rules; scheduled for v2 migration |
| Dev/test environment | Mitigated | Reduced logging in non-production is accepted risk |
| Third-party managed APIM | Waiver | Vendor manages APIM instance; no control over diagnostics |

### Creating an Exemption

Exemptions are created at the policy assignment level via the portal or CLI and support expiration dates.

**Microsoft Learn:**
- [Azure Policy exemption structure](https://learn.microsoft.com/en-us/azure/governance/policy/concepts/exemption-structure)
- [Create a policy exemption](https://learn.microsoft.com/en-us/azure/governance/policy/how-to/exemption-structure)

---

## 11. Keeping Policies Up to Date

### Version Control

Store all custom policy definitions in source control (this repo's `policies/` directory) and deploy via CI/CD:

- Review policy changes through pull requests
- Use Azure DevOps or GitHub Actions to deploy policy definitions
- Tag policy definition versions for rollback

### Staying Current with Built-in Policies

Azure regularly adds and updates built-in policy definitions. Review periodically:

1. Check the [Azure Policy built-in definitions](https://learn.microsoft.com/en-us/azure/governance/policy/samples/built-in-policies) page
2. Search for new policies in the portal under **Policy → Definitions**
3. Replace custom definitions with built-in equivalents when available

**Microsoft Learn:**
- [Azure Policy as code workflows](https://learn.microsoft.com/en-us/azure/governance/policy/concepts/policy-as-code)
- [Export Azure Policy resources](https://learn.microsoft.com/en-us/azure/governance/policy/how-to/export-resources)
- [Manage Azure Policy with GitHub](https://learn.microsoft.com/en-us/azure/governance/policy/tutorials/policy-as-code-github)

---

## Summary — Centralized Configuration Checklist

| # | Action | Scope | MS Learn Reference |
|---|--------|-------|--------------------|
| 1 | Design management group hierarchy | Org-wide | [Management groups](https://learn.microsoft.com/en-us/azure/governance/management-groups/overview) |
| 2 | Inventory built-in policies for each service | Platform team | [Built-in policy samples](https://learn.microsoft.com/en-us/azure/governance/policy/samples/built-in-policies) |
| 3 | Create custom policy for App Gateway XFF rewrite rule audit | Platform team | [Create custom policy](https://learn.microsoft.com/en-us/azure/governance/policy/tutorials/create-custom-policy-definition) |
| 4 | Create custom DINE policy for auto-deploying diagnostics | Platform team | [DeployIfNotExists effect](https://learn.microsoft.com/en-us/azure/governance/policy/concepts/effects#deployifnotexists) |
| 5 | Bundle into XFF Compliance Initiative | Platform team | [Initiative structure](https://learn.microsoft.com/en-us/azure/governance/policy/concepts/initiative-definition-structure) |
| 6 | Assign initiative to management groups (Audit mode) | Platform team | [Assignment structure](https://learn.microsoft.com/en-us/azure/governance/policy/concepts/assignment-structure) |
| 7 | Run remediation tasks for existing resources | Platform team | [Remediate resources](https://learn.microsoft.com/en-us/azure/governance/policy/how-to/remediate-resources) |
| 8 | Review compliance in portal / Resource Graph | Security team | [Get compliance data](https://learn.microsoft.com/en-us/azure/governance/policy/how-to/get-compliance-data) |
| 9 | Transition to Deny mode after compliance > 95% | Platform team | [Policy effects](https://learn.microsoft.com/en-us/azure/governance/policy/concepts/effects) |
| 10 | Publish shared app-level libraries for XFF middleware | App teams | [ASP.NET Core proxy config](https://learn.microsoft.com/en-us/aspnet/core/host-and-deploy/proxy-load-balancer) |
| 11 | Set up policy-as-code CI/CD | Platform team | [Policy as code](https://learn.microsoft.com/en-us/azure/governance/policy/concepts/policy-as-code) |
| 12 | Schedule periodic policy review and built-in refresh | Platform team | [Export policy resources](https://learn.microsoft.com/en-us/azure/governance/policy/how-to/export-resources) |

---

## Microsoft Learn References (Consolidated)

### Azure Policy Core

- [What is Azure Policy?](https://learn.microsoft.com/en-us/azure/governance/policy/overview)
- [Azure Policy definition structure](https://learn.microsoft.com/en-us/azure/governance/policy/concepts/definition-structure)
- [Understand Azure Policy effects](https://learn.microsoft.com/en-us/azure/governance/policy/concepts/effects)
- [Policy initiative definition structure](https://learn.microsoft.com/en-us/azure/governance/policy/concepts/initiative-definition-structure)
- [Azure Policy assignment structure](https://learn.microsoft.com/en-us/azure/governance/policy/concepts/assignment-structure)
- [Azure Policy exemption structure](https://learn.microsoft.com/en-us/azure/governance/policy/concepts/exemption-structure)

### Creating & Managing Policies

- [Tutorial: Create custom policy definitions](https://learn.microsoft.com/en-us/azure/governance/policy/tutorials/create-custom-policy-definition)
- [Tutorial: Create and manage policies to enforce compliance](https://learn.microsoft.com/en-us/azure/governance/policy/tutorials/create-and-manage)
- [Azure Policy as code workflows](https://learn.microsoft.com/en-us/azure/governance/policy/concepts/policy-as-code)
- [Manage Azure Policy with GitHub](https://learn.microsoft.com/en-us/azure/governance/policy/tutorials/policy-as-code-github)
- [Export Azure Policy resources](https://learn.microsoft.com/en-us/azure/governance/policy/how-to/export-resources)

### Compliance & Remediation

- [Get compliance data of Azure resources](https://learn.microsoft.com/en-us/azure/governance/policy/how-to/get-compliance-data)
- [Determine causes of non-compliance](https://learn.microsoft.com/en-us/azure/governance/policy/how-to/determine-non-compliance)
- [Remediate non-compliant resources](https://learn.microsoft.com/en-us/azure/governance/policy/how-to/remediate-resources)
- [Policy compliance events with Azure Event Grid](https://learn.microsoft.com/en-us/azure/governance/policy/concepts/event-overview)

### Built-in Policy Catalogs

- [Built-in policies — Networking](https://learn.microsoft.com/en-us/azure/governance/policy/samples/built-in-policies#network)
- [Built-in policies — API Management](https://learn.microsoft.com/en-us/azure/governance/policy/samples/built-in-policies#api-management)
- [Built-in policies — App Service](https://learn.microsoft.com/en-us/azure/governance/policy/samples/built-in-policies#app-service)
- [Built-in policies — Monitoring](https://learn.microsoft.com/en-us/azure/governance/policy/samples/built-in-policies#monitoring)
- [Built-in policies — CDN (Front Door)](https://learn.microsoft.com/en-us/azure/governance/policy/samples/built-in-policies#cdn)

### Diagnostic Settings at Scale

- [Deploy diagnostic settings at scale with Azure Policy](https://learn.microsoft.com/en-us/azure/azure-monitor/essentials/diagnostic-settings-policy)
- [Azure Monitor diagnostic settings overview](https://learn.microsoft.com/en-us/azure/azure-monitor/essentials/diagnostic-settings)

### Governance & Organization

- [Organize resources with management groups](https://learn.microsoft.com/en-us/azure/governance/management-groups/overview)
- [Azure landing zone design principles](https://learn.microsoft.com/en-us/azure/cloud-adoption-framework/ready/landing-zone/design-principles)
- [Cloud Adoption Framework — governance disciplines](https://learn.microsoft.com/en-us/azure/cloud-adoption-framework/govern/)
- [Enterprise-scale management group organization](https://learn.microsoft.com/en-us/azure/cloud-adoption-framework/ready/landing-zone/design-area/resource-org-management-groups)

### RBAC for Policy Managed Identities

- [Monitoring Contributor role](https://learn.microsoft.com/en-us/azure/role-based-access-control/built-in-roles/monitor#monitoring-contributor)
- [Log Analytics Contributor role](https://learn.microsoft.com/en-us/azure/role-based-access-control/built-in-roles/analytics#log-analytics-contributor)
