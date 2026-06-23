from __future__ import annotations

from fastapi.testclient import TestClient
from sqlalchemy import select

from app.main import app
from app.models import AppAccessToken, AppSession, ConnectionStatus, GoogleAccount, User
from app.services.app_auth import create_app_auth_code, device_id_digest
from app.services.oauth import create_authorization_url


DEVICE_ID = "test-device-id-000000000000"


def _user(session, email: str = "person@example.com") -> User:
    user = User(email=email)
    session.add(user)
    session.commit()
    return user


def test_start_url_requires_device_and_persists_bound_state(session) -> None:
    client = TestClient(app)

    response = client.get("/auth/google/start-url", params={"device_id": DEVICE_ID})

    assert response.status_code == 200
    assert "accounts.google.com" in response.json()["authorization_url"]
    url = create_authorization_url(session, device_id=DEVICE_ID)
    assert "redirect_uri=http%3A%2F%2Flocalhost%3A8000%2Fauth%2Fgoogle%2Fcallback" in url


def test_exchange_refresh_me_and_logout_flow(session) -> None:
    user = _user(session)
    session.add(
        GoogleAccount(
            user_id=user.id,
            health_user_id="health-id",
            legacy_user_id="legacy-id",
            status=ConnectionStatus.connected,
            granted_scopes=[],
        )
    )
    session.commit()
    code = create_app_auth_code(
        session,
        user_id=user.id,
        device_id_hash=device_id_digest(DEVICE_ID),
    )
    client = TestClient(app)

    exchange = client.post("/auth/exchange", json={"code": code, "device_id": DEVICE_ID})

    assert exchange.status_code == 200
    token_payload = exchange.json()
    assert token_payload["token_type"] == "bearer"
    assert token_payload["expires_in"] == 900

    replay = client.post("/auth/exchange", json={"code": code, "device_id": DEVICE_ID})
    assert replay.status_code == 401

    me = client.get("/auth/me", headers={"Authorization": f"Bearer {token_payload['access_token']}"})
    assert me.status_code == 200
    assert me.json()["user"]["id"] == user.id
    assert me.json()["user"]["first_name"] is None
    assert me.json()["profile"]["onboarding_completed_at"] is None
    assert me.json()["google_health"]["status"] == "connected"

    updated_me = client.patch(
        "/auth/me",
        headers={"Authorization": f"Bearer {token_payload['access_token']}"},
        json={"first_name": " Aryan ", "last_name": "Test"},
    )
    assert updated_me.status_code == 200
    assert updated_me.json()["user"]["first_name"] == "Aryan"
    assert updated_me.json()["user"]["last_name"] == "Test"

    refresh = client.post(
        "/auth/refresh",
        json={"refresh_token": token_payload["refresh_token"], "device_id": DEVICE_ID},
    )
    assert refresh.status_code == 200
    rotated = refresh.json()
    assert rotated["refresh_token"] != token_payload["refresh_token"]

    reused = client.post(
        "/auth/refresh",
        json={"refresh_token": token_payload["refresh_token"], "device_id": DEVICE_ID},
    )
    assert reused.status_code == 401
    app_session = session.scalar(select(AppSession).where(AppSession.user_id == user.id))
    assert app_session.revoked_at is not None

    old_access = session.scalar(
        select(AppAccessToken).where(AppAccessToken.session_id == app_session.id)
    )
    assert old_access.revoked_at is not None

    logout = client.post(
        "/auth/logout",
        json={"refresh_token": rotated["refresh_token"], "device_id": DEVICE_ID},
    )
    assert logout.status_code == 204


def test_protected_routes_require_bearer_token() -> None:
    client = TestClient(app)

    response = client.get("/dashboard/today")

    assert response.status_code == 401


def test_connections_are_scoped_to_current_user(session, auth_headers) -> None:
    user = _user(session, "one@example.com")
    other = _user(session, "two@example.com")
    session.add_all(
        [
            GoogleAccount(
                user_id=user.id,
                health_user_id="health-one",
                legacy_user_id="legacy-one",
                status=ConnectionStatus.connected,
                granted_scopes=[],
            ),
            GoogleAccount(
                user_id=other.id,
                health_user_id="health-two",
                legacy_user_id="legacy-two",
                status=ConnectionStatus.connected,
                granted_scopes=[],
            ),
        ]
    )
    session.commit()

    response = TestClient(app).get("/connections/google-health", headers=auth_headers(user))

    assert response.status_code == 200
    payload = response.json()
    assert len(payload) == 1
    assert payload[0]["health_user_id_present"] is True
    assert "user_id" not in payload[0]
