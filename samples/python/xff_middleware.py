"""
============================================================================
Python (Flask/FastAPI) – XFF Middleware + Azure Monitor OpenTelemetry
============================================================================
Equivalent of the .NET ForwardedHeadersMiddleware for Python stacks.

For Flask:  Use ProxyFix middleware.
For FastAPI: Use a custom middleware or TrustedHostMiddleware.

This example shows both approaches + logging XFF to Application Insights
via the Azure Monitor OpenTelemetry exporter.

Supports multi-tier chains: Proxy → App Gateway → APIM → App Service
When APIM is in the chain, also captures X-Real-Client-IP set by APIM policy.

References:
  https://flask.palletsprojects.com/en/latest/deploying/proxy_fix/
  https://learn.microsoft.com/en-us/azure/azure-monitor/app/opentelemetry-enable?tabs=python
============================================================================
"""

# ── Option A: Flask + ProxyFix ──────────────────────────────────────────────

from flask import Flask, request
from werkzeug.middleware.proxy_fix import ProxyFix

app = Flask(__name__)

# Trust 2+ proxies (e.g., App Gateway → APIM → App Service).
# x_for=2 means the client IP is 2 hops back in X-Forwarded-For.
# With APIM: Proxy → AppGW → APIM → App Service = 3 hops, use x_for=3.
app.wsgi_app = ProxyFix(app.wsgi_app, x_for=2, x_proto=1, x_host=1)


@app.before_request
def log_xff():
    """Log XFF header and APIM-specific headers for every request."""
    xff = request.headers.get("X-Forwarded-For", "")
    remote_addr = request.remote_addr
    real_client_ip = request.headers.get("X-Real-Client-IP", "")
    app.logger.info(
        f"Request: {request.path} | RemoteAddr: {remote_addr} | XFF: {xff}"
        f" | X-Real-Client-IP: {real_client_ip}"
    )


@app.route("/health")
def health():
    return {"status": "ok", "client_ip": request.remote_addr}


# ── Option B: FastAPI middleware ────────────────────────────────────────────

"""
from fastapi import FastAPI, Request
from starlette.middleware.trustedhost import TrustedHostMiddleware
import logging

app = FastAPI()
logger = logging.getLogger("uvicorn")

@app.middleware("http")
async def xff_middleware(request: Request, call_next):
    xff = request.headers.get("X-Forwarded-For", "")
    client_ip = request.client.host
    logger.info(f"Path: {request.url.path} | ClientIP: {client_ip} | XFF: {xff}")
    response = await call_next(request)
    return response
"""

# ── Azure Monitor OpenTelemetry – capture XFF as span attribute ─────────────

"""
# pip install azure-monitor-opentelemetry
from azure.monitor.opentelemetry import configure_azure_monitor
from opentelemetry import trace

configure_azure_monitor(
    connection_string="InstrumentationKey=<your-key>;IngestionEndpoint=..."
)

# In your middleware / request handler:
span = trace.get_current_span()
span.set_attribute("http.xff", xff_value)
span.set_attribute("http.client_ip", resolved_client_ip)
# Capture X-Real-Client-IP set by APIM xff-global-policy.xml
span.set_attribute("http.real_client_ip", real_client_ip_header)
"""

if __name__ == "__main__":
    app.run(host="0.0.0.0", port=8000)
