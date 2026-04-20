#!/bin/bash
# ============================================================================
# Update Nginx Proxy Backend to Point to Application Gateway
# ============================================================================
# Run this on the proxy VM (via SSH) after deployment to set the actual
# Application Gateway IP in the Nginx config.
#
# Usage:
#   ssh azureuser@<proxy-public-ip>
#   sudo bash update-nginx-backend.sh <appgw-private-or-public-ip>
# ============================================================================

set -euo pipefail

APPGW_IP="${1:?Usage: $0 <app-gateway-ip>}"
NGINX_CONF="/etc/nginx/sites-available/xff-proxy"

if [ ! -f "$NGINX_CONF" ]; then
    echo "ERROR: Nginx config not found at $NGINX_CONF"
    echo "       Run setup-nginx-proxy.sh first."
    exit 1
fi

echo "Updating Nginx backend to point to App Gateway: $APPGW_IP"

sed -i "s|APPGW_BACKEND|$APPGW_IP|g" "$NGINX_CONF"

echo "Testing Nginx config..."
nginx -t

echo "Reloading Nginx..."
systemctl reload nginx

echo ""
echo "Done. Nginx is now forwarding traffic to $APPGW_IP"
echo "Verify with: curl -v http://localhost/nginx-health"
echo ""
echo "XFF flow: Client -> this proxy ($HOSTNAME) -> App Gateway ($APPGW_IP) -> Backend"
