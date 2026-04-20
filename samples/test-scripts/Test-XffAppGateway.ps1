# ============================================================================
# XFF Test Script (PowerShell) — Proxy → App Gateway → APIM → App Service
# ============================================================================
# Windows-friendly version for testing the XFF flow.
#
# Usage:
#   .\Test-XffAppGateway.ps1 -ProxyIp "20.x.x.x" -AppGwIp "20.y.y.y" -AppFqdn "app-xff-test-xxx.azurewebsites.net"
#   .\Test-XffAppGateway.ps1 -ProxyIp "20.x.x.x" -AppGwIp "20.y.y.y" -AppFqdn "app-xff-test-xxx.azurewebsites.net" -ApimUrl "https://apim-xxx.azure-api.net/xff/"
# ============================================================================

param(
    [Parameter(Mandatory)][string]$ProxyIp,
    [Parameter(Mandatory)][string]$AppGwIp,
    [Parameter(Mandatory)][string]$AppFqdn,
    [string]$ApimUrl
)

$TestMarker = "xff-test-$(Get-Date -Format 'yyyyMMdd-HHmmss')"
$Timestamp  = (Get-Date).ToUniversalTime().ToString("o")

Write-Host "============================================================" -ForegroundColor Cyan
Write-Host "  XFF End-to-End Test - Proxy -> App Gateway -> APIM -> App Service"  -ForegroundColor Cyan
Write-Host "============================================================" -ForegroundColor Cyan
Write-Host ""
Write-Host "  Proxy (VIP) IP : $ProxyIp"
Write-Host "  App Gateway IP : $AppGwIp"
Write-Host "  App Service    : $AppFqdn"
if ($ApimUrl) { Write-Host "  APIM URL       : $ApimUrl" }
Write-Host "  Test marker    : $TestMarker"
Write-Host "  Timestamp      : $Timestamp"
Write-Host ""

# ── Test 1: Direct to App Gateway ───────────────────────────────────────────

Write-Host "-- Test 1: Direct to Application Gateway --" -ForegroundColor Yellow
Write-Host "   Expected: AGWAccessLogs.ClientIp = YOUR public IP"

try {
    $response = Invoke-WebRequest -Uri "http://$AppGwIp/" `
        -Headers @{
            "Host"          = $AppFqdn
            "X-Test-Marker" = "$TestMarker-direct-appgw"
        } `
        -UseBasicParsing -TimeoutSec 15 -ErrorAction Stop
    Write-Host "   HTTP Status: $($response.StatusCode)" -ForegroundColor Green
} catch {
    Write-Host "   HTTP Status: $($_.Exception.Response.StatusCode.value__) - $($_.Exception.Message)" -ForegroundColor Red
}
Write-Host ""

# ── Test 2: Through Proxy (VIP) → App Gateway ──────────────────────────────

Write-Host "-- Test 2: Through Proxy (VIP) -> App Gateway --" -ForegroundColor Yellow
Write-Host "   Expected: AGWAccessLogs.ClientIp = Proxy VIP ($ProxyIp)"
Write-Host "   Expected: XFF = YOUR real IP (set by Nginx proxy)"

try {
    $response = Invoke-WebRequest -Uri "http://$ProxyIp/" `
        -Headers @{
            "Host"          = $AppFqdn
            "X-Test-Marker" = "$TestMarker-via-proxy"
        } `
        -UseBasicParsing -TimeoutSec 15 -ErrorAction Stop
    Write-Host "   HTTP Status: $($response.StatusCode)" -ForegroundColor Green
} catch {
    Write-Host "   HTTP Status: $($_.Exception.Response.StatusCode.value__) - $($_.Exception.Message)" -ForegroundColor Red
}
Write-Host ""

# ── Test 3: Forged XFF through Proxy (security test) ───────────────────────

Write-Host "-- Test 3: Forged XFF through Proxy (security test) --" -ForegroundColor Yellow
Write-Host '   Sending: X-Forwarded-For: 1.2.3.4 (forged)'
Write-Host "   Expected: Proxy appends real IP -> XFF: 1.2.3.4, <your-real-ip>"

try {
    $response = Invoke-WebRequest -Uri "http://$ProxyIp/" `
        -Headers @{
            "Host"              = $AppFqdn
            "X-Forwarded-For"   = "1.2.3.4"
            "X-Test-Marker"     = "$TestMarker-forged-xff"
        } `
        -UseBasicParsing -TimeoutSec 15 -ErrorAction Stop
    Write-Host "   HTTP Status: $($response.StatusCode)" -ForegroundColor Green
} catch {
    Write-Host "   HTTP Status: $($_.Exception.Response.StatusCode.value__) - $($_.Exception.Message)" -ForegroundColor Red
}
Write-Host ""

# ── Test 4: Direct to App Service (baseline) ───────────────────────────────

Write-Host "-- Test 4: Direct to App Service (HTTPS) --" -ForegroundColor Yellow
Write-Host "   Expected: AppServiceHTTPLogs.CIp = YOUR public IP"

try {
    $response = Invoke-WebRequest -Uri "https://$AppFqdn/" `
        -Headers @{
            "X-Test-Marker" = "$TestMarker-direct-appsvc"
        } `
        -UseBasicParsing -TimeoutSec 15 -ErrorAction Stop
    Write-Host "   HTTP Status: $($response.StatusCode)" -ForegroundColor Green
} catch {
    Write-Host "   HTTP Status: $($_.Exception.Response.StatusCode.value__) - $($_.Exception.Message)" -ForegroundColor Red
}
Write-Host ""

# ── Test 5: Proxy health check ─────────────────────────────────────────────

Write-Host "-- Test 5: Proxy Nginx health check --" -ForegroundColor Yellow
try {
    $health = Invoke-RestMethod -Uri "http://$ProxyIp/nginx-health" -TimeoutSec 10
    Write-Host "   Response: $($health | ConvertTo-Json -Compress)" -ForegroundColor Green
} catch {
    Write-Host "   FAILED: $($_.Exception.Message)" -ForegroundColor Red
}
Write-Host ""

# ── Test 6: Direct to APIM (no XFF) ───────────────────────────────────────

if ($ApimUrl) {
    # Warm up APIM Consumption SKU (cold start can take 20-30s)
    Write-Host "-- APIM warm-up (Consumption SKU cold start) --" -ForegroundColor DarkGray
    try { $null = Invoke-WebRequest -Uri $ApimUrl -UseBasicParsing -TimeoutSec 45 -ErrorAction SilentlyContinue } catch {}
    Write-Host "   Done." -ForegroundColor DarkGray
    Write-Host ""

    Write-Host "-- Test 6: Direct to APIM (no XFF header) --" -ForegroundColor Yellow
    Write-Host "   Expected: ApiManagementGatewayLogs.CallerIpAddress = YOUR public IP"
    Write-Host "   Expected: No X-Forwarded-For header present"

    try {
        $response = Invoke-WebRequest -Uri $ApimUrl `
            -Headers @{
                "X-Test-Marker" = "$TestMarker-direct-apim"
            } `
            -UseBasicParsing -TimeoutSec 45 -ErrorAction Stop
        Write-Host "   HTTP Status: $($response.StatusCode)" -ForegroundColor Green
    } catch {
        Write-Host "   HTTP Status: $($_.Exception.Response.StatusCode.value__) - $($_.Exception.Message)" -ForegroundColor Red
    }
    Write-Host ""

    # ── Test 7: APIM with XFF header (simulating upstream proxy) ───────────

    Write-Host "-- Test 7: APIM with XFF header (simulating proxy upstream) --" -ForegroundColor Yellow
    Write-Host "   Sending: X-Forwarded-For: 198.51.100.42 (simulated real client)"
    Write-Host "   Expected: APIM logs CallerIpAddress = YOUR IP, XFF header = 198.51.100.42"

    try {
        $response = Invoke-WebRequest -Uri $ApimUrl `
            -Headers @{
                "X-Forwarded-For" = "198.51.100.42"
                "X-Test-Marker"   = "$TestMarker-apim-with-xff"
            } `
            -UseBasicParsing -TimeoutSec 45 -ErrorAction Stop
        Write-Host "   HTTP Status: $($response.StatusCode)" -ForegroundColor Green
    } catch {
        Write-Host "   HTTP Status: $($_.Exception.Response.StatusCode.value__) - $($_.Exception.Message)" -ForegroundColor Red
    }
    Write-Host ""

    # ── Test 8: APIM with multi-hop XFF (chained proxy simulation) ─────────

    Write-Host "-- Test 8: APIM with multi-hop XFF (chained proxy simulation) --" -ForegroundColor Yellow
    Write-Host "   Sending: X-Forwarded-For: 203.0.113.10, 10.0.0.5"
    Write-Host "   Expected: APIM sees CallerIpAddress = YOUR IP, XFF chain = 203.0.113.10, 10.0.0.5"

    try {
        $response = Invoke-WebRequest -Uri $ApimUrl `
            -Headers @{
                "X-Forwarded-For" = "203.0.113.10, 10.0.0.5"
                "X-Test-Marker"   = "$TestMarker-apim-multihop"
            } `
            -UseBasicParsing -TimeoutSec 45 -ErrorAction Stop
        Write-Host "   HTTP Status: $($response.StatusCode)" -ForegroundColor Green
    } catch {
        Write-Host "   HTTP Status: $($_.Exception.Response.StatusCode.value__) - $($_.Exception.Message)" -ForegroundColor Red
    }
    Write-Host ""

    # ── Test 9: APIM with forged XFF (security test) ──────────────────────

    Write-Host "-- Test 9: APIM with forged XFF (security test) --" -ForegroundColor Yellow
    Write-Host "   Sending: X-Forwarded-For: 1.2.3.4 (forged)"
    Write-Host "   Expected: APIM policy should resolve real client via CallerIpAddress"

    try {
        $response = Invoke-WebRequest -Uri $ApimUrl `
            -Headers @{
                "X-Forwarded-For" = "1.2.3.4"
                "X-Test-Marker"   = "$TestMarker-apim-forged-xff"
            } `
            -UseBasicParsing -TimeoutSec 45 -ErrorAction Stop
        Write-Host "   HTTP Status: $($response.StatusCode)" -ForegroundColor Green
    } catch {
        Write-Host "   HTTP Status: $($_.Exception.Response.StatusCode.value__) - $($_.Exception.Message)" -ForegroundColor Red
    }
    Write-Host ""
} else {
    Write-Host "-- Tests 6-9: APIM tests SKIPPED (no -ApimUrl provided) --" -ForegroundColor DarkGray
    Write-Host ""
}

# ── KQL Queries for Validation ──────────────────────────────────────────────

Write-Host "============================================================" -ForegroundColor Cyan
Write-Host "  Tests complete. Wait 5-10 min for logs to appear."        -ForegroundColor Cyan
Write-Host ""
Write-Host "  Use these KQL queries in Log Analytics:" -ForegroundColor White
Write-Host ""
Write-Host "  1. App Gateway access logs:" -ForegroundColor Yellow
Write-Host @"
     AGWAccessLogs
     | where TimeGenerated > ago(30m)
     | where UserAgent has "PowerShell" or UserAgent has "curl"
     | project TimeGenerated, ClientIp, Host, RequestUri, HttpStatusCode, UserAgent
     | order by TimeGenerated desc
"@
Write-Host ""
Write-Host "  2. App Service HTTP logs:" -ForegroundColor Yellow
Write-Host @"
     AppServiceHTTPLogs
     | where TimeGenerated > ago(30m)
     | project TimeGenerated, CIp, CsHost, CsUriStem, ScStatus, UserAgent
     | order by TimeGenerated desc
"@
Write-Host ""
Write-Host "  3. Application Insights (with XFF middleware):" -ForegroundColor Yellow
Write-Host @"
     requests
     | where timestamp > ago(30m)
     | extend xff = tostring(customDimensions["X-Forwarded-For"])
     | extend resolvedIp = tostring(customDimensions["ResolvedClientIp"])
     | extend realClientIp = tostring(customDimensions["X-Real-Client-IP"])
     | project timestamp, xff, resolvedIp, realClientIp, client_IP, name, resultCode
     | order by timestamp desc
"@
Write-Host ""
Write-Host "  4. APIM Gateway Logs (CallerIpAddress + XFF extraction):" -ForegroundColor Yellow
Write-Host @"
     ApiManagementGatewayLogs
     | where TimeGenerated > ago(30m)
     | extend headers = parse_json(RequestHeaders)
     | extend xff = tostring(headers["X-Forwarded-For"])
     | extend OriginalClientIp = trim(' ', tostring(split(xff, ',')[0]))
     | project TimeGenerated, CallerIpAddress, XffHeader = xff, OriginalClientIp, Method = RequestMethod, Url, ResponseCode
     | order by TimeGenerated desc
"@
Write-Host ""
Write-Host "  Test marker: $TestMarker" -ForegroundColor Green
Write-Host "============================================================" -ForegroundColor Cyan
