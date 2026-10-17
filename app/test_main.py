from fastapi.testclient import TestClient

import main


client = TestClient(main.app)


def test_healthz_is_alive():
    r = client.get("/healthz")
    assert r.status_code == 200
    assert r.json() == {"status": "alive"}


def test_readyz_is_ready():
    r = client.get("/readyz")
    assert r.status_code == 200


def test_quote_returns_a_quote():
    r = client.get("/api/quote")
    assert r.status_code == 200
    body = r.json()
    assert body["text"] and body["author"]


def test_metrics_expose_custom_counter():
    client.get("/api/quote")
    r = client.get("/metrics")
    assert r.status_code == 200
    assert "quote_api_http_requests_total" in r.text


def test_unknown_paths_are_labelled_other():
    client.get("/does-not-exist-123")
    assert 'path="other"' in client.get("/metrics").text
    assert "does-not-exist-123" not in client.get("/metrics").text
