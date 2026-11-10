from __future__ import annotations

from dataclasses import replace
from datetime import timedelta
from uuid import uuid4

import jwt
import pytest
from cryptography.hazmat.primitives.asymmetric import rsa
from fastapi.testclient import TestClient
from sqlalchemy import select

from app.apple.client import APPLE_ISSUER, APPLE_REVOKE_URL, APPLE_TOKEN_URL, AppleAuthError
from app.core.security import decrypt_secret, encrypt_secret, utcnow
from app.main import app
from app.models import AppSession, ConnectionStatus, HealthConnection, OAuthState, SignInIdentity, User
from app.services import apple_sign_in
from app.services.account_deletion import DELETION_GRACE_PERIOD, purge_due_accounts
from app.services.app_auth import create_app_auth_code, device_id_digest
from app.services.apple_sign_in import (
    complete_apple_sign_in,
    create_apple_nonce,
    handle_apple_notification,
)
from app.services.device_keys import auth_code_transcript
from app.services.oauth import (
    OAuthConfigurationError,
    OAuthStateError,
    complete_google_oauth,
    create_authorization_url,
)
from tests.apple_fakes import FakeAppleClient
from tests.oauth_fakes import FakeGoogleClient, state_from

DEVICE_ID = f"test-device-{uuid4()}"


async def apple_sign_in_with(session, apple: FakeAppleClient, *, purpose="sign_in", user_id=None, device_key=None, **names):
    nonce = create_apple_nonce(
        session,
        device_id=DEVICE_ID,
        purpose=purpose,
        user_id=user_id,
        device_public_key=device_key.public_key if device_key else None,
    )
    return await complete_apple_sign_in(
        session,
        nonce=nonce,
        identity_token=apple.identity_token(nonce),
        authorization_code="apple-code",
        device_id=DEVICE_ID,
        client=apple,
        **names,
    )


def apple_user(session, subject: str = "apple-sub", **user_fields) -> User:
    user = User(**user_fields)
    session.add(user)
    session.flush()
    session.add(
        SignInIdentity(
            user_id=user.id,
            provider="apple",
            subject=subject,
            encrypted_refresh_token=encrypt_secret("stored-apple-token"),
        )
    )
    session.commit()
    return user


def signed_in_client(session, user: User) -> TestClient:
    code = create_app_auth_code(session, user_id=user.id, device_id_hash=device_id_digest(DEVICE_ID))
    client = TestClient(app)
    tokens = client.post("/auth/exchange", json={"code": code, "device_id": DEVICE_ID}).json()
    client.headers["Authorization"] = f"Bearer {tokens['access_token']}"
    return client


@pytest.mark.asyncio
async def test_first_sign_in_creates_an_account_with_relay_email_name_and_stored_token(session) -> None:
    apple = FakeAppleClient()

    completion = await apple_sign_in_with(session, apple, first_name=" Sam ", last_name="Lee")

    user = session.get(User, completion.user_id)
    identity = session.scalar(select(SignInIdentity))
    assert (user.first_name, user.last_name) == ("Sam", "Lee")
    assert user.email == "relay123@privaterelay.appleid.com"
    assert (identity.provider, identity.subject) == ("apple", "apple-sub")
    assert decrypt_secret(identity.encrypted_refresh_token) == "apple-refresh-token"
    assert session.scalars(select(HealthConnection)).all() == []


@pytest.mark.asyncio
async def test_code_exchange_uses_a_short_lived_es256_client_secret(session) -> None:
    apple = FakeAppleClient()

    await apple_sign_in_with(session, apple)

    url, data = apple.requests[0]
    assert url == APPLE_TOKEN_URL
    assert data["client_id"] == "com.example.conceptualfitness"
    assert data["grant_type"] == "authorization_code"
    header = jwt.get_unverified_header(data["client_secret"])
    claims = jwt.decode(data["client_secret"], options={"verify_signature": False})
    assert header == {"alg": "ES256", "kid": "KEYID12345", "typ": "JWT"}
    assert claims["iss"] == "TEAMID1234"
    assert claims["sub"] == "com.example.conceptualfitness"
    assert claims["aud"] == APPLE_ISSUER
    assert claims["exp"] - claims["iat"] <= 300


@pytest.mark.asyncio
async def test_later_sign_ins_keep_the_saved_name_and_reach_the_same_account(session) -> None:
    first = await apple_sign_in_with(session, FakeAppleClient(), first_name="Sam", last_name="Lee")
    second = await apple_sign_in_with(session, FakeAppleClient(refresh_token="newer-token"))
    third = await apple_sign_in_with(session, FakeAppleClient(), first_name="Other", last_name="Name")

    user = session.get(User, first.user_id)
    assert first.user_id == second.user_id == third.user_id
    assert (user.first_name, user.last_name) == ("Sam", "Lee")
    assert len(session.scalars(select(User)).all()) == 1


@pytest.mark.asyncio
async def test_hidden_email_and_missing_name_still_create_an_account(session) -> None:
    completion = await apple_sign_in_with(session, FakeAppleClient(email=None))

    user = session.get(User, completion.user_id)
    assert user.email is None
    assert user.first_name is None


@pytest.mark.asyncio
@pytest.mark.parametrize(
    "overrides",
    [
        {"nonce": "not-the-nonce"},
        {"nonce": None},
        {"aud": "com.someone.else"},
        {"iss": "https://example.com"},
        {"exp": 1},
    ],
)
async def test_identity_tokens_with_wrong_claims_are_rejected(session, overrides) -> None:
    apple = FakeAppleClient()
    nonce = create_apple_nonce(session, device_id=DEVICE_ID)

    with pytest.raises((AppleAuthError, OAuthConfigurationError)):
        await complete_apple_sign_in(
            session,
            nonce=nonce,
            identity_token=apple.identity_token(nonce, **overrides),
            authorization_code="apple-code",
            device_id=DEVICE_ID,
            client=apple,
        )
    assert session.scalars(select(User)).all() == []
    assert apple.requests == []


@pytest.mark.asyncio
@pytest.mark.parametrize("key_id", ["test-apple-key", "unknown-key"])
async def test_identity_tokens_not_signed_by_apple_are_rejected(session, key_id) -> None:
    apple = FakeAppleClient()
    nonce = create_apple_nonce(session, device_id=DEVICE_ID)
    forged = apple.token(
        {"sub": "apple-sub", "nonce": apple_sign_in.hashed_nonce(nonce)},
        key=rsa.generate_private_key(public_exponent=65537, key_size=2048),
        key_id=key_id,
    )

    with pytest.raises(AppleAuthError):
        await complete_apple_sign_in(
            session,
            nonce=nonce,
            identity_token=forged,
            authorization_code="apple-code",
            device_id=DEVICE_ID,
            client=apple,
        )


@pytest.mark.asyncio
async def test_a_nonce_works_once_and_only_for_its_device(session) -> None:
    apple = FakeAppleClient()
    nonce = create_apple_nonce(session, device_id=DEVICE_ID)
    other_nonce = create_apple_nonce(session, device_id=DEVICE_ID)

    with pytest.raises(OAuthStateError):
        await complete_apple_sign_in(
            session,
            nonce=other_nonce,
            identity_token=apple.identity_token(other_nonce),
            authorization_code="apple-code",
            device_id="another-device-000000",
            client=apple,
        )
    await complete_apple_sign_in(
        session,
        nonce=nonce,
        identity_token=apple.identity_token(nonce),
        authorization_code="apple-code",
        device_id=DEVICE_ID,
        client=apple,
    )
    with pytest.raises(OAuthStateError):
        await complete_apple_sign_in(
            session,
            nonce=nonce,
            identity_token=apple.identity_token(nonce),
            authorization_code="apple-code",
            device_id=DEVICE_ID,
            client=apple,
        )


@pytest.mark.asyncio
async def test_google_state_cannot_be_used_as_an_apple_nonce(session) -> None:
    apple = FakeAppleClient()
    google_state = state_from(create_authorization_url(session, device_id=DEVICE_ID))

    with pytest.raises(OAuthStateError):
        await complete_apple_sign_in(
            session,
            nonce=google_state,
            identity_token=apple.identity_token(google_state),
            authorization_code="apple-code",
            device_id=DEVICE_ID,
            client=apple,
        )


@pytest.mark.asyncio
async def test_exchanged_tokens_must_belong_to_the_same_apple_account(session) -> None:
    with pytest.raises(OAuthConfigurationError, match="does not match"):
        await apple_sign_in_with(session, FakeAppleClient(exchanged_subject="someone-else"))
    with pytest.raises(OAuthConfigurationError, match="did not return tokens"):
        await apple_sign_in_with(session, FakeAppleClient(refresh_token=None))
    assert session.scalars(select(User)).all() == []


@pytest.mark.asyncio
async def test_accounts_pending_deletion_cannot_sign_in(session) -> None:
    apple_user(session, deletion_scheduled_for=utcnow() + DELETION_GRACE_PERIOD)

    with pytest.raises(OAuthConfigurationError, match="Pending-deletion"):
        await apple_sign_in_with(session, FakeAppleClient())


@pytest.mark.asyncio
async def test_enrollment_rejects_a_different_apple_account(session, device_key) -> None:
    owner = apple_user(session, subject="owner-sub")
    apple_user(session, subject="other-sub")

    with pytest.raises(OAuthConfigurationError, match="does not match"):
        await apple_sign_in_with(
            session,
            FakeAppleClient(subject="other-sub"),
            purpose="enroll_device",
            user_id=owner.id,
            device_key=device_key,
        )


@pytest.mark.asyncio
async def test_google_cannot_reauthenticate_an_apple_account(session, device_key) -> None:
    owner = apple_user(session)
    url = create_authorization_url(
        session,
        device_id=DEVICE_ID,
        purpose="enroll_device",
        user_id=owner.id,
        device_public_key=device_key.public_key,
    )

    with pytest.raises(OAuthConfigurationError, match="requires an existing account"):
        await complete_google_oauth(session, code="code", state=state_from(url), client=FakeGoogleClient())


def test_sign_in_routes_issue_a_device_bound_session(session, device_key, monkeypatch) -> None:
    apple = FakeAppleClient()
    monkeypatch.setattr(apple_sign_in, "AppleClient", lambda: apple)
    client = TestClient(app)

    nonce = client.get(
        "/auth/apple/start", params={"device_id": DEVICE_ID, "device_public_key": device_key.public_key}
    ).json()["nonce"]
    completed = client.post(
        "/auth/apple/complete",
        json={
            "nonce": nonce,
            "identity_token": apple.identity_token(nonce),
            "authorization_code": "apple-code",
            "device_id": DEVICE_ID,
            "first_name": "Sam",
        },
    )
    code = completed.json()["code"]
    tokens = client.post(
        "/auth/exchange",
        json={
            "code": code,
            "device_id": DEVICE_ID,
            "signature": device_key.sign(auth_code_transcript(code, DEVICE_ID)),
        },
    ).json()
    me = client.get("/auth/me", headers={"Authorization": f"Bearer {tokens['access_token']}"}).json()

    assert completed.json()["status"] == "signed_in"
    assert session.scalar(select(OAuthState)).provider == "apple"
    assert me["user"]["sign_in_provider"] == "apple"
    assert me["user"]["first_name"] == "Sam"
    assert me["health_connection"]["status"] == "disconnected"


def test_failed_completion_reports_a_generic_code(session, monkeypatch) -> None:
    apple = FakeAppleClient()
    monkeypatch.setattr(apple_sign_in, "AppleClient", lambda: apple)
    client = TestClient(app)
    nonce = client.get("/auth/apple/start", params={"device_id": DEVICE_ID}).json()["nonce"]

    response = client.post(
        "/auth/apple/complete",
        json={
            "nonce": nonce,
            "identity_token": apple.identity_token("other-nonce"),
            "authorization_code": "apple-code",
            "device_id": DEVICE_ID,
        },
    )

    assert response.status_code == 403
    assert response.json()["detail"] == {"code": "sign_in_failed"}


def test_recovery_returns_a_grant_for_an_account_pending_deletion(session, device_key, monkeypatch) -> None:
    apple_user(session, deletion_scheduled_for=utcnow() + timedelta(days=3))
    apple = FakeAppleClient()
    monkeypatch.setattr(apple_sign_in, "AppleClient", lambda: apple)
    client = TestClient(app)
    nonce = client.get(
        "/auth/apple/start",
        params={
            "device_id": DEVICE_ID,
            "purpose": "recover_deletion",
            "device_public_key": device_key.public_key,
        },
    ).json()["nonce"]

    response = client.post(
        "/auth/apple/complete",
        json={
            "nonce": nonce,
            "identity_token": apple.identity_token(nonce),
            "authorization_code": "apple-code",
            "device_id": DEVICE_ID,
        },
    ).json()

    assert response["status"] == "authorized"
    assert response["purpose"] == "recover_deletion"
    assert response["grant"]


def test_enrollment_start_requires_a_signed_in_session(session, device_key) -> None:
    response = TestClient(app).get(
        "/auth/apple/start",
        params={"device_id": DEVICE_ID, "purpose": "enroll_device", "device_public_key": device_key.public_key},
    )

    assert response.status_code == 401


def test_start_reports_missing_apple_configuration(session, monkeypatch) -> None:
    monkeypatch.setattr(apple_sign_in, "missing_apple_keys", lambda settings: ["APPLE_KEY_ID"])

    response = TestClient(app).get("/auth/apple/start", params={"device_id": DEVICE_ID})

    assert response.status_code == 500


@pytest.mark.asyncio
async def test_consent_revoked_signs_out_everywhere_and_forgets_the_token(session) -> None:
    user = apple_user(session)
    client = signed_in_client(session, user)
    apple = FakeAppleClient()

    result = await handle_apple_notification(session, apple.notification("consent-revoked"), client=apple)

    session.expire_all()
    assert result == "consent-revoked"
    assert session.scalar(select(SignInIdentity)).encrypted_refresh_token is None
    assert all(app_session.revoked_at for app_session in session.scalars(select(AppSession)))
    assert client.get("/auth/me").status_code == 401
    assert session.get(User, user.id).deletion_scheduled_for is None


@pytest.mark.asyncio
async def test_apple_account_deletion_schedules_our_deletion(session) -> None:
    user = apple_user(session)
    session.add(HealthConnection(user_id=user.id, status=ConnectionStatus.connected))
    session.commit()
    apple = FakeAppleClient()

    result = await handle_apple_notification(session, apple.notification("account-delete"), client=apple)

    session.expire_all()
    assert result == "account-delete"
    assert session.get(User, user.id).deletion_scheduled_for is not None
    assert session.scalar(select(HealthConnection)).status == ConnectionStatus.disconnected


@pytest.mark.asyncio
async def test_other_and_unknown_notifications_change_nothing(session) -> None:
    apple_user(session)
    apple = FakeAppleClient()

    assert await handle_apple_notification(session, apple.notification("email-disabled"), client=apple) == "ignored"
    assert (
        await handle_apple_notification(session, apple.notification("account-delete", "stranger"), client=apple)
        == "unknown_account"
    )
    assert session.scalar(select(SignInIdentity)).encrypted_refresh_token is not None


def test_notification_route_rejects_unsigned_payloads(session, monkeypatch) -> None:
    apple = FakeAppleClient()
    monkeypatch.setattr(apple_sign_in, "AppleClient", lambda: apple)
    forged = apple.token(
        {"events": '{"type": "account-delete", "sub": "apple-sub"}'},
        key=rsa.generate_private_key(public_exponent=65537, key_size=2048),
    )
    client = TestClient(app)

    assert client.post("/auth/apple/notifications", json={"payload": forged}).status_code == 400
    assert client.post(
        "/auth/apple/notifications", json={"payload": apple.notification("email-enabled")}
    ).status_code == 204


@pytest.mark.asyncio
async def test_purge_revokes_the_apple_token(session) -> None:
    now = utcnow()
    user = apple_user(session, deletion_requested_at=now - DELETION_GRACE_PERIOD, deletion_scheduled_for=now)
    apple = FakeAppleClient()

    result = await purge_due_accounts(session, now=now, google_client=FakeGoogleClient(), apple_client=apple)

    assert result == {"purged": 1, "failed": 0, "revocation_failed": 0}
    assert apple.revoked == ["stored-apple-token"]
    assert apple.requests[0][0] == APPLE_REVOKE_URL
    assert apple.requests[0][1]["token_type_hint"] == "refresh_token"
    assert session.get(User, user.id) is None


@pytest.mark.asyncio
async def test_an_invalid_private_key_fails_as_an_apple_error(session) -> None:
    apple = FakeAppleClient()
    apple.settings = replace(apple.settings, apple_private_key="not-a-key")

    with pytest.raises(AppleAuthError, match="private key"):
        apple.client_secret()
