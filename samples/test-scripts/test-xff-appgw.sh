#!/bin/bash
# ============================================================================
# XFF End-to-End Test Script
# ============================================================================
# Tests the full XFF flow: Client → Proxy (VIP) → App Gateway → APIM → App Service
#
# Prerequisites:
#   - Proxy VM deployed with Nginx configured (setup-nginx-proxy.sh)
#   - Application Gateway with XFF rewrite rule
#   - App Service with ForwardedHeaders middleware deployed
#   - Diagnostic settings enabled on all tiers
#   - (Optional) APIM with xff-global-policy.xml and diagnostic settings
#
# Usage:
#   ./test-xff-appgw.sh <proxy-public-ip> <appgw-public-ip> <app-service-fqdn> [apim-url]
#
# Examples:
#   ./test-xff-appgw.sh 4.174.181.251 4.205.85.213 app-xff-test-xxx.azurewebsites.net
#   ./test-xff-appgw.sh 4.174.181.251 4.205.85.213 app-xff-test-xxx.azurewebsites.net https://apim-xxx.azure-api.net/xff/
# ============================================================================

set -euo pipefail

# ── Arguments ────────────────────────────────────────────────────────────────

PROXY_IP="${1:?Usage: $0 <proxy-public-ip> <appgw-public-ip> <app-service-fqdn> [apim-url]}"
APPGW_IP="${2:?Usage: $0 <proxy-public-ip> <appgw-public-ip> <app-service-fqdn> [apim-url]}"
APP_FQDN="${3:?Usage: $0 <proxy-public-ip> <appgw-public-ip> <app-service-fqdn> [apim-url]}"
APIM_URL="${4:-}"

TIMESTAMP=$(date -u +"%Y-%m-%dT%H:%M:%SZ")
TEST_MARKER="xff-test-$(date +%s)"

echo "============================================================"
echo "  XFF End-to-End Test — Proxy → App Gateway → APIM → App Service"
echo "============================================================"
echo ""
echo "  Proxy (VIP) IP : $PROXY_IP"
echo "  App Gateway IP : $APPGW_IP"
echo "  App Service    : $APP_FQDN"
if [ -n "$APIM_URL" ]; then
    echo "  APIM URL       : $APIM_URL"
fi
echo "  Test marker    : $TEST_MARKER"
echo "  Timestamp      : $TIMESTAMP"
echo ""

# ── Test 1: Direct to App Gateway (baseline) ────────────────────────────────

echo "── Test 1: Direct request to Application Gateway ──────────"
echo "   Expected: AGWAccessLogs.ClientIp = YOUR public IP"
echo ""

HTTP_CODE=$(curl -s -o /dev/null -w "%{http_code}" \
    -H "Host: $APP_FQDN" \
    -H "X-Test-Marker: ${TEST_MARKER}-direct-appgw" \
    "http://${APPGW_IP}/" 2>/dev/null || echo "FAILED")

echo "   HTTP Status: $HTTP_CODE"
echo ""

# ── Test 2: Through Proxy (VIP) → App Gateway ──────────────────────────────

echo "── Test 2: Request through Proxy (VIP) → App Gateway ──────"
echo "   Expected: AGWAccessLogs.ClientIp = Proxy VIP IP"
echo "   Expected: XFF header = YOUR public IP (set by proxy)"
echo ""

HTTP_CODE=$(curl -s -o /dev/null -w "%{http_code}" \
    -H "Host: $APP_FQDN" \
    -H "X-Test-Marker: ${TEST_MARKER}-via-proxy" \
    "http://${PROXY_IP}/" 2>/dev/null || echo "FAILED")

echo "   HTTP Status: $HTTP_CODE"
echo ""

# ── Test 3: Proxy with verbose headers ──────────────────────────────────────

echo "── Test 3: Verbose request through Proxy (show headers) ───"

RESPONSE=$(curl -s -D - \
    -H "Host: $APP_FQDN" \
    -H "X-Test-Marker: ${TEST_MARKER}-verbose" \
    "http://${PROXY_IP}/" 2>/dev/null | head -30 || echo "FAILED")

echo "$RESPONSE"
echo ""

# ── Test 4: Proxy with pre-existing (forged) XFF ───────────────────────────

echo "── Test 4: Forged XFF through Proxy (security test) ───────"
echo "   Sending: X-Forwarded-For: 1.2.3.4 (forged)"
echo "   Expected: Proxy appends real IP → XFF: 1.2.3.4, <your-real-ip>"
echo ""

HTTP_CODE=$(curl -s -o /dev/null -w "%{http_code}" \
    -H "Host: $APP_FQDN" \
    -H "X-Forwarded-For: 1.2.3.4" \
    -H "X-Test-Marker: ${TEST_MARKER}-forged-xff" \
    "http://${PROXY_IP}/" 2>/dev/null || echo "FAILED")

echo "   HTTP Status: $HTTP_CODE"
echo ""

# ── Test 5: Direct to App Service (baseline for CIp) ───────────────────────

echo "── Test 5: Direct to App Service (HTTPS) ──────────────────"
echo "   Expected: AppServiceHTTPLogs.CIp = YOUR public IP"
echo ""

HTTP_CODE=$(curl -s -o /dev/null -w "%{http_code}" \
    -H "X-Test-Marker: ${TEST_MARKER}-direct-appsvc" \
    "https://${APP_FQDN}/" 2>/dev/null || echo "FAILED")

echo "   HTTP Status: $HTTP_CODE"
echo ""

# ── Test 6: Nginx proxy health check ───────────────────────────────────────

echo "── Test 6: Proxy health check ─────────────────────────────"

HEALTH=$(curl -s "http://${PROXY_IP}/nginx-health" 2>/dev/null || echo "FAILED")
echo "   Response: $HEALTH"
echo ""

# ── Test 7: Direct to APIM (no XFF) ──────────────────────────────────────────────

if [ -n "$APIM_URL" ]; then
    # Warm up APIM Consumption SKU (cold start can take 20-30s)
    echo "── APIM warm-up (Consumption SKU cold start) ─────────────"
    curl -s -o /dev/null --max-time 45 "${APIM_URL}" 2>/dev/null || true
    echo "   Done."
    echo ""

    echo "── Test 7: Direct request to APIM (no XFF) ───────────────"
    echo "   Expected: ApiManagementGatewayLogs.CallerIpAddress = YOUR public IP"
    echo ""

    HTTP_CODE=$(curl -s -o /dev/null -w "%{http_code}" --max-time 45 \
        -H "X-Test-Marker: ${TEST_MARKER}-direct-apim" \
        "${APIM_URL}" 2>/dev/null || echo "FAILED")

    echo "   HTTP Status: $HTTP_CODE"
    echo ""

    # ── Test 8: APIM with XFF header (simulating upstream proxy) ──────────

    echo "── Test 8: APIM with XFF header (simulating proxy) ───────"
    echo "   Sending: X-Forwarded-For: 198.51.100.42 (simulated real client)"
    echo "   Expected: APIM logs CallerIpAddress = YOUR IP, XFF = 198.51.100.42"
    echo ""

    HTTP_CODE=$(curl -s -o /dev/null -w "%{http_code}" --max-time 45 \
        -H "X-Forwarded-For: 198.51.100.42" \
        -H "X-Test-Marker: ${TEST_MARKER}-apim-with-xff" \
        "${APIM_URL}" 2>/dev/null || echo "FAILED")

    echo "   HTTP Status: $HTTP_CODE"
    echo ""

    # ── Test 9: APIM with multi-hop XFF ───────────────────────────────────

    echo "── Test 9: APIM with multi-hop XFF (chained proxy) ─────"
    echo "   Sending: X-Forwarded-For: 203.0.113.10, 10.0.0.5"
    echo ""

    HTTP_CODE=$(curl -s -o /dev/null -w "%{http_code}" --max-time 45 \
        -H "X-Forwarded-For: 203.0.113.10, 10.0.0.5" \
        -H "X-Test-Marker: ${TEST_MARKER}-apim-multihop" \
        "${APIM_URL}" 2>/dev/null || echo "FAILED")

    echo "   HTTP Status: $HTTP_CODE"
    echo ""

    # ── Test 10: APIM forged XFF (security test) ───────────────────────

    echo "── Test 10: APIM with forged XFF (security test) ───────"
    echo "   Sending: X-Forwarded-For: 1.2.3.4 (forged)"
    echo "   Expected: APIM policy resolves real client via CallerIpAddress"
    echo ""

    HTTP_CODE=$(curl -s -o /dev/null -w "%{http_code}" --max-time 45 \
        -H "X-Forwarded-For: 1.2.3.4" \
        -H "X-Test-Marker: ${TEST_MARKER}-apim-forged" \
        "${APIM_URL}" 2>/dev/null || echo "FAILED")

    echo "   HTTP Status: $HTTP_CODE"
    echo ""
else
    echo "── Tests 7-10: APIM tests SKIPPED (no apim-url argument) ───"
    echo ""
fi

# ── Summary ──────────────────────────────────────────────────────────────────

echo "============================================================"
echo "  Tests complete. Wait 5-10 minutes for logs to appear."
echo ""
echo "  Use these KQL queries to validate (filter by test marker):"
echo ""
echo "  1. App Gateway logs:"
echo '     AGWAccessLogs'
echo '     | where TimeGenerated > ago(30m)'
echo "     | where UserAgent has \"curl\""
echo '     | project TimeGenerated, ClientIp, Host, RequestUri, HttpStatusCode'
echo ""
echo "  2. App Service HTTP logs:"
echo '     AppServiceHTTPLogs'
echo '     | where TimeGenerated > ago(30m)'
echo '     | project TimeGenerated, CIp, CsHost, CsUriStem, ScStatus'
echo ""
echo "  3. Application Insights (if middleware deployed):"
echo '     requests'
echo '     | where timestamp > ago(30m)'
echo '     | extend xff = tostring(customDimensions["X-Forwarded-For"])'
echo '     | project timestamp, xff, client_IP, name, resultCode'
echo ""
echo "  4. APIM Gateway Logs (CallerIpAddress + XFF extraction):"
echo '     ApiManagementGatewayLogs'
echo '     | where TimeGenerated > ago(30m)'
echo '     | extend headers = parse_json(RequestHeaders)'
echo '     | extend xff = tostring(headers["X-Forwarded-For"])'
echo '     | project TimeGenerated, CallerIpAddress, xff, RequestMethod, Url, ResponseCode'
echo '     | order by TimeGenerated desc'
echo ""
echo "  Test marker for filtering: $TEST_MARKER"
echo "============================================================"
