from __future__ import annotations

from fastapi.testclient import TestClient

from app.main import app


def test_healthz() -> None:
    client = TestClient(app)
    response = client.get("/healthz")
    assert response.status_code == 200
    assert response.json() == {"status": "ok"}


def test_oauth_diagnostics_does_not_return_secrets() -> None:
    client = TestClient(app)
    response = client.get("/auth/google-health/diagnostics")
    assert response.status_code == 200
    payload = response.json()
    assert payload["configured"] is True
    assert payload["client_id_present"] is True
    assert payload["client_secret_present"] is True
    assert "test-client-secret" not in response.text

