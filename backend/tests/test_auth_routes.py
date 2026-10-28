from __future__ import annotations

from uuid import uuid4

from fastapi.testclient import TestClient
from sqlalchemy import select

from app.main import app
from app.models import (
    AppAccessToken,
    AppAuthCode,
    AppSession,
    ConnectionStatus,
    GoogleAccount,
    OAuthState,
    User,
)
from app.services.app_auth import create_app_auth_code, device_id_digest
from app.services.device_keys import auth_code_transcript, sensitive_action_transcript
from app.services.oauth import create_authorization_url


DEVICE_ID = f"test-device-{uuid4()}"


def _user(session, email: str = "person@example.com") -> User:
    user = User(email=email)
    session.add(user)
    session.commit()
    return user


def test_start_url_requires_device_and_persists_bound_state(session, device_key) -> None:
    client = TestClient(app)

    response = client.get(
        "/auth/google/start-url",
        params={"device_id": DEVICE_ID, "device_public_key": device_key.public_key},
    )

    assert response.status_code == 200
    assert "accounts.google.com" in response.json()["authorization_url"]
    url = create_authorization_url(
        session,
        device_id=DEVICE_ID,
        device_public_key=device_key.public_key,
    )
    assert "redirect_uri=http%3A%2F%2Flocalhost%3A8000%2Fauth%2Fgoogle%2Fcallback" in url


def test_normal_start_allows_unbound_simulator_session(session) -> None:
    response = TestClient(app).get(
        "/auth/google/start-url",
        params={"device_id": DEVICE_ID},
    )

    assert response.status_code == 200
    state = session.scalar(select(OAuthState))
    assert state.device_public_key is None


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


def test_key_bound_exchange_requires_valid_signature_before_consuming_code(
    session,
    device_key,
) -> None:
    user = _user(session)
    code = create_app_auth_code(
        session,
        user_id=user.id,
        device_id_hash=device_id_digest(DEVICE_ID),
        device_public_key=device_key.public_key,
    )
    client = TestClient(app)

    invalid = client.post(
        "/auth/exchange",
        json={"code": code, "device_id": DEVICE_ID, "signature": device_key.sign(b"wrong")},
    )

    assert invalid.status_code == 401
    stored_code = session.scalar(select(AppAuthCode).where(AppAuthCode.user_id == user.id))
    assert stored_code.consumed_at is None

    valid = client.post(
        "/auth/exchange",
        json={
            "code": code,
            "device_id": DEVICE_ID,
            "signature": device_key.sign(auth_code_transcript(code, DEVICE_ID)),
        },
    )

    assert valid.status_code == 200
    app_session = session.scalar(select(AppSession).where(AppSession.user_id == user.id))
    assert app_session.device_public_key == device_key.public_key


def test_device_challenge_requires_enrollment_and_is_one_use(session, auth_headers, device_key) -> None:
    user = _user(session)
    client = TestClient(app)
    legacy = client.post(
        "/auth/device/challenge",
        headers=auth_headers(user),
        json={"purpose": "export"},
    )
    assert legacy.status_code == 409
    assert legacy.json()["detail"]["code"] == "device_key_enrollment_required"

    code = create_app_auth_code(
        session,
        user_id=user.id,
        device_id_hash=device_id_digest(DEVICE_ID),
        device_public_key=device_key.public_key,
    )
    tokens = client.post(
        "/auth/exchange",
        json={
            "code": code,
            "device_id": DEVICE_ID,
            "signature": device_key.sign(auth_code_transcript(code, DEVICE_ID)),
        },
    ).json()
    headers = {"Authorization": f"Bearer {tokens['access_token']}"}
    challenge_response = client.post(
        "/auth/device/challenge",
        headers=headers,
        json={"purpose": "export"},
    )
    assert challenge_response.status_code == 200
    challenge = challenge_response.json()["challenge"]
    session_id = challenge_response.json()["session_id"]
    signature = device_key.sign(sensitive_action_transcript("export", session_id, challenge))

    authorized = client.post(
        "/auth/device/authorize",
        headers=headers,
        json={"purpose": "export", "challenge": challenge, "signature": signature},
    )
    replay = client.post(
        "/auth/device/authorize",
        headers=headers,
        json={"purpose": "export", "challenge": challenge, "signature": signature},
    )

    assert authorized.status_code == 200
    assert authorized.json()["sensitive_action_grant"] == challenge
    assert replay.status_code == 403


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
