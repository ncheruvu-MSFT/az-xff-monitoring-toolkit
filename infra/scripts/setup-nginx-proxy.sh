#!/bin/bash
# ============================================================================
# Nginx Reverse Proxy Setup for XFF Testing
# ============================================================================
# This script is executed by the Azure VM CustomScript extension.
# It installs Nginx and configures it as a reverse proxy that:
#   1. Forwards traffic to the Application Gateway
#   2. Correctly sets X-Forwarded-For with the original client IP
#
# Post-deployment: Update APPGW_BACKEND_IP with the actual App Gateway
# private or public IP using the update-nginx-backend.sh script.
# ============================================================================

set -euo pipefail

export DEBIAN_FRONTEND=noninteractive

echo "=== Installing Nginx ==="
apt-get update -y
apt-get install -y nginx curl jq

echo "=== Configuring Nginx as XFF-aware reverse proxy ==="

# Backup the default config
cp /etc/nginx/sites-available/default /etc/nginx/sites-available/default.bak

# Create the reverse proxy configuration
# APPGW_BACKEND placeholder is replaced post-deployment
cat > /etc/nginx/sites-available/xff-proxy <<'NGINX_CONF'
# ============================================================================
# Nginx Reverse Proxy – XFF Forwarding to Application Gateway
# ============================================================================
# This configuration demonstrates the CORRECT setup for preserving
# the original client IP when a proxy sits in front of App Gateway.
#
# Traffic flow: Client → This Nginx Proxy (VIP) → Application Gateway → Backend
# ============================================================================

# Logging format that includes XFF for troubleshooting
log_format xff_log '$remote_addr - $remote_user [$time_local] '
                   '"$request" $status $body_bytes_sent '
                   '"$http_referer" "$http_user_agent" '
                   'XFF="$proxy_add_x_forwarded_for" '
                   'X-Real-IP="$remote_addr"';

server {
    listen 80 default_server;
    listen [::]:80 default_server;
    server_name _;

    access_log /var/log/nginx/xff-proxy-access.log xff_log;
    error_log  /var/log/nginx/xff-proxy-error.log warn;

    location / {
        # ── CRITICAL: Forward to Application Gateway ──────────────────
        # Replace APPGW_BACKEND with the App Gateway's private or public IP
        proxy_pass http://APPGW_BACKEND:80;

        # ── CRITICAL: Set X-Forwarded-For ─────────────────────────────
        # $proxy_add_x_forwarded_for = existing XFF + $remote_addr
        # This ensures the real client IP is preserved in the XFF chain.
        proxy_set_header X-Forwarded-For    $proxy_add_x_forwarded_for;

        # ── Additional forwarded headers ──────────────────────────────
        proxy_set_header X-Real-IP          $remote_addr;
        proxy_set_header X-Forwarded-Proto  $scheme;
        proxy_set_header X-Forwarded-Host   $host;
        proxy_set_header X-Forwarded-Port   $server_port;
        proxy_set_header Host               $host;

        # ── Proxy timeouts ────────────────────────────────────────────
        proxy_connect_timeout 10s;
        proxy_send_timeout    30s;
        proxy_read_timeout    30s;

        # ── Buffer settings ───────────────────────────────────────────
        proxy_buffering on;
        proxy_buffer_size 4k;
        proxy_buffers 8 4k;
    }

    # Health check endpoint (for testing connectivity)
    location /nginx-health {
        return 200 '{"status":"ok","role":"xff-proxy","server_addr":"$server_addr"}';
        add_header Content-Type application/json;
    }
}
NGINX_CONF

# Enable the proxy site, disable default
ln -sf /etc/nginx/sites-available/xff-proxy /etc/nginx/sites-enabled/xff-proxy
rm -f /etc/nginx/sites-enabled/default

# Test config and restart
nginx -t
systemctl restart nginx
systemctl enable nginx

echo "=== Nginx proxy installed ==="
echo "NOTE: Update APPGW_BACKEND in /etc/nginx/sites-available/xff-proxy"
echo "      with the actual Application Gateway IP, then run:"
echo "      sudo nginx -t && sudo systemctl reload nginx"
