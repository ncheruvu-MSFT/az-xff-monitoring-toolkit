#!/usr/bin/env pwsh
# Creates XFF Monitoring saved searches in Log Analytics workspace
# Usage: .\scripts\create-saved-searches.ps1

$wsBase = "https://management.azure.com/subscriptions/64e1939f-6460-4656-ad75-dcc277b155f1/resourceGroups/rg-xff-test-eastus/providers/Microsoft.OperationalInsights/workspaces/log-xff-test-cg4l2wl4myrww/savedSearches"
$apiVer = "api-version=2020-08-01"

$queries = @(
    @{
        id = "xff-appgw-clientip"
        displayName = "XFF: App Gateway - ClientIP Breakdown"
        query = @'
AzureDiagnostics
| where TimeGenerated > ago(24h)
| where ResourceType == "APPLICATIONGATEWAYS"
| summarize RequestCount = count() by clientIP_s
| order by RequestCount desc
| extend Note = "clientIP_s = TCP peer IP (proxy VIP), NOT real client"
'@
    },
    @{
        id = "xff-apim-xff-extraction"
        displayName = "XFF: APIM - Extract Real Client IP from XFF"
        query = @'
ApiManagementGatewayLogs
| where TimeGenerated > ago(24h)
| where isnotempty(RequestHeaders)
| extend headers = parse_json(RequestHeaders)
| extend xff = tostring(headers["X-Forwarded-For"])
| where isnotempty(xff)
| extend OriginalClientIp = trim(' ', tostring(split(xff, ',')[0]))
| project TimeGenerated, CallerIpAddress, XffHeader = xff, OriginalClientIp, Method, Url, ResponseCode
| order by TimeGenerated desc
'@
    },
    @{
        id = "xff-appsvc-cip"
        displayName = "XFF: App Service - CIp Breakdown"
        query = @'
AppServiceHTTPLogs
| where TimeGenerated > ago(24h)
| summarize RequestCount = count() by CIp
| order by RequestCount desc
| extend Note = "CIp = TCP peer IP (App GW / APIM IP), NOT real client"
'@
    },
    @{
        id = "xff-real-client-ip"
        displayName = "XFF: Real Client IP from App Insights"
        query = @'
AppRequests
| where TimeGenerated > ago(24h)
| extend xff = tostring(Properties["X-Forwarded-For"])
| extend resolvedClientIp = tostring(Properties["ResolvedClientIp"])
| where isnotempty(xff)
| project
    TimeGenerated,
    RealClientIp = trim(' ', tostring(split(xff, ",")[0])),
    FullXffChain = xff,
    ResolvedByMiddleware = resolvedClientIp,
    AppServiceCIp = ClientIP,
    Url,
    ResultCode
| order by TimeGenerated desc
'@
    },
    @{
        id = "xff-coverage-pct"
        displayName = "XFF: Coverage % - Requests with Real Client IP"
        query = @'
AppRequests
| where TimeGenerated > ago(24h)
| extend xff = tostring(Properties["X-Forwarded-For"])
| summarize
    TotalRequests = count(),
    WithXFF = countif(isnotempty(xff)),
    WithoutXFF = countif(isempty(xff))
| extend XffCoveragePct = round(100.0 * WithXFF / TotalRequests, 1)
'@
    },
    @{
        id = "xff-coverage-trend"
        displayName = "XFF: Coverage Trend by Hour (7 days)"
        query = @'
AppRequests
| where TimeGenerated > ago(7d)
| extend xff = tostring(Properties["X-Forwarded-For"])
| summarize
    Total = count(),
    WithXFF = countif(isnotempty(xff))
    by bin(TimeGenerated, 1h)
| extend CoveragePct = round(100.0 * WithXFF / Total, 1)
| project TimeGenerated, Total, WithXFF, CoveragePct
| render timechart
'@
    }
)

$success = 0
$failed = 0
foreach ($q in $queries) {
    $body = @{
        properties = @{
            category    = "XFF Monitoring"
            displayName = $q.displayName
            query       = $q.query
            version     = 2
        }
    } | ConvertTo-Json -Depth 5

    $tmpFile = "$env:TEMP\xff-saved-search.json"
    $body | Out-File $tmpFile -Encoding utf8

    $uri = "$wsBase/$($q.id)?$apiVer"
    try {
        $result = az rest --method PUT --uri $uri --body "@$tmpFile" 2>&1
        $parsed = $result | ConvertFrom-Json
        Write-Host "OK: $($parsed.properties.displayName)" -ForegroundColor Green
        $success++
    }
    catch {
        Write-Host "FAIL: $($q.displayName) - $_" -ForegroundColor Red
        $failed++
    }
}

Write-Host "`nDone: $success succeeded, $failed failed" -ForegroundColor Cyan
