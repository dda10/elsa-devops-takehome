import hashlib
import os
import random
import time

from fastapi import FastAPI, Request
from fastapi.responses import Response
from prometheus_client import CONTENT_TYPE_LATEST, Counter, Histogram, generate_latest

# Simulated CPU work per /api/quote request. Real hashing (not sleep) so that
# load tests and HPA see genuine CPU usage.
SIMULATED_CPU_MS = float(os.getenv("SIMULATED_CPU_MS", "100"))

QUOTES = [
    {"text": "The secret of getting ahead is getting started.", "author": "Mark Twain"},
    {"text": "It always seems impossible until it is done.", "author": "Nelson Mandela"},
    {"text": "Believe you can and you're halfway there.", "author": "Theodore Roosevelt"},
    {"text": "Small steps every day add up to big results.", "author": "Anonymous"},
]

KNOWN_PATHS = {"/healthz", "/readyz", "/metrics", "/api/quote"}

REQUESTS = Counter("quote_api_http_requests_total", "HTTP requests", ["method", "path", "status"])
# Buckets centred on the ~100ms CPU cost; the defaults jump 0.1 -> 0.25s, too coarse for p95.
LATENCY = Histogram(
    "quote_api_http_request_duration_seconds",
    "HTTP request latency",
    ["path"],
    buckets=(0.025, 0.05, 0.1, 0.125, 0.15, 0.2, 0.25, 0.3, 0.4, 0.5, 0.75, 1.0, 2.0, 5.0),
)

app = FastAPI(title="quote-api")
shutting_down = False


def burn_cpu(ms: float) -> None:
    # Budget is this thread's CPU time, not wall-clock time: under CFS throttling or GIL
    # contention the request takes longer instead of silently doing less work.
    deadline = time.thread_time() + ms / 1000
    digest = b"quote-api"
    while time.thread_time() < deadline:
        digest = hashlib.sha256(digest).digest()


@app.middleware("http")
async def instrument(request: Request, call_next):
    start = time.perf_counter()
    response = await call_next(request)
    # Label only known paths so arbitrary client URLs cannot explode metric cardinality.
    path = request.url.path if request.url.path in KNOWN_PATHS else "other"
    REQUESTS.labels(request.method, path, str(response.status_code)).inc()
    LATENCY.labels(path).observe(time.perf_counter() - start)
    return response


@app.on_event("shutdown")
def mark_shutting_down() -> None:
    global shutting_down
    shutting_down = True


@app.get("/healthz")
def healthz() -> dict:
    return {"status": "alive"}


@app.get("/readyz")
def readyz() -> Response:
    # Fail readiness once shutdown starts so the Service stops routing new traffic.
    if shutting_down:
        return Response(status_code=503, content='{"status": "shutting-down"}', media_type="application/json")
    return {"status": "ready"}


@app.get("/metrics")
def metrics() -> Response:
    return Response(content=generate_latest(), media_type=CONTENT_TYPE_LATEST)


@app.get("/api/quote")
def quote() -> dict:
    # Plain (non-async) def: FastAPI runs it in a worker thread, so the CPU burn
    # does not block the event loop serving health and metrics probes.
    burn_cpu(SIMULATED_CPU_MS)
    return random.choice(QUOTES)
