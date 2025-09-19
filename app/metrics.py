from __future__ import annotations

import time
from fastapi import APIRouter, Response
from prometheus_client import CONTENT_TYPE_LATEST, Counter, Histogram, generate_latest

REQUEST_COUNT = Counter(
    "http_requests_total",
    "Total HTTP requests",
    labelnames=("method", "path", "status"),
)

REQUEST_LATENCY = Histogram(
    "http_request_duration_seconds",
    "HTTP request latency in seconds",
    labelnames=("method", "path", "status"),
    buckets=(0.005, 0.01, 0.025, 0.05, 0.1, 0.25, 0.5, 1.0, 2.5, 5.0),
)


class MetricsMiddleware:
    """Collects basic Prometheus metrics for each request."""

    def __init__(self, app):
        self.app = app

    async def __call__(self, scope, receive, send):
        if scope["type"] != "http":
            await self.app(scope, receive, send)
            return

        method = scope.get("method", "").upper()
        path = scope.get("path", "")
        if not path:
            raw_path = scope.get("raw_path")
            if isinstance(raw_path, (bytes, bytearray)):
                path = raw_path.decode("latin-1")
        start_time = time.perf_counter()
        status_code: int | None = None

        async def send_wrapper(message):
            nonlocal status_code
            if message["type"] == "http.response.start":
                status_code = message["status"]
            await send(message)

        try:
            await self.app(scope, receive, send_wrapper)
        finally:
            duration = time.perf_counter() - start_time
            status = str(status_code or 500)
            REQUEST_COUNT.labels(method=method, path=path, status=status).inc()
            REQUEST_LATENCY.labels(method=method, path=path, status=status).observe(duration)


router = APIRouter()


@router.get("/metrics", include_in_schema=False)
async def metrics_endpoint() -> Response:
    """Expose Prometheus metrics."""
    data = generate_latest()
    return Response(content=data, media_type=CONTENT_TYPE_LATEST)
