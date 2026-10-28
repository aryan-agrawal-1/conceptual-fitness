from __future__ import annotations

from fastapi.testclient import TestClient

from app.main import app
from app.models import User


def test_catalogue_endpoint_is_authenticated_versioned_and_retryable(session, auth_headers, caplog):
    client = TestClient(app)
    assert client.get("/journal/catalogue").status_code == 401
    user = User(email="journal@example.com")
    session.add(user)
    session.commit()
    headers = auth_headers(user)

    first = client.get("/journal/catalogue", headers=headers)
    assert first.status_code == 200
    assert first.json() == client.get("/journal/catalogue?version=1", headers=headers).json()
    assert len(first.json()["behaviours"]) == 27
    assert first.json()["version"] == first.json()["schema_version"] == 1
    assert first.json()["observation_schema"]["discriminator"]["propertyName"] == "kind"
    assert client.get("/journal/catalogue?version=2", headers=headers).status_code == 404
    assert client.get("/journal/catalogue?version=0", headers=headers).status_code == 422
    assert client.get("/journal/catalogue?version=no", headers=headers).status_code == 422
    assert client.get("/journal/catalogue", headers=headers).json() == first.json()
    assert "reason=unsupported_version" in caplog.text
    assert user.email not in caplog.text
