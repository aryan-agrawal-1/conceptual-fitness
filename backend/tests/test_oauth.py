from __future__ import annotations

from urllib.parse import parse_qs, urlparse

import pytest
from sqlalchemy import select

from app.core.security import decrypt_secret, encrypt_secret, utcnow
from app.models import ConnectionStatus, HealthConnection, OAuthState, SignInIdentity, User
from app.services.oauth import (
    CONNECT_HEALTH,
    GoogleAccountInUseError,
    HealthAccountInUseError,
    OAuthConfigurationError,
    complete_google_oauth,
    create_authorization_url,
)
from tests.oauth_fakes import FakeGoogleClient, state_from

DEVICE_ID = "test-device-id-000000000000"
HEALTH_SCOPE = "https://www.googleapis.com/auth/googlehealth.sleep.readonly"


def sign_in_url(session, device_key, **kwargs) -> str:
    return create_authorization_url(
        session, device_id=DEVICE_ID, device_public_key=device_key.public_key, **kwargs
    )


def connect_url(session, user_id: str) -> str:
    return create_authorization_url(session, device_id=DEVICE_ID, purpose=CONNECT_HEALTH, user_id=user_id)


async def sign_in(session, device_key, client: FakeGoogleClient):
    return await complete_google_oauth(
        session, code="auth-code", state=state_from(sign_in_url(session, device_key)), client=client
    )


async def connect(session, user_id: str, client: FakeGoogleClient):
    return await complete_google_oauth(
        session, code="auth-code", state=state_from(connect_url(session, user_id)), client=client
    )


def signed_in_user(session, subject: str = "existing-sub") -> User:
    user = User(email="owner@example.com")
    session.add(user)
    session.flush()
    session.add(SignInIdentity(user_id=user.id, provider="google", subject=subject))
    session.commit()
    return user


def test_sign_in_url_requests_identity_scopes_only(session, device_key) -> None:
    query = parse_qs(urlparse(sign_in_url(session, device_key)).query)

    assert query["client_id"] == ["test-client-id.apps.googleusercontent.com"]
    assert query["redirect_uri"] == ["http://localhost:8000/auth/google/callback"]
    assert query["scope"] == ["openid email profile"]
    assert query["prompt"] == ["select_account"]
    assert "access_type" not in query
    state = session.scalar(select(OAuthState))
    assert state.purpose == "sign_in"
    assert state.consumed_at is None
    assert state.device_id_hash is not None


def test_connect_url_requests_health_scopes_offline(session) -> None:
    user = signed_in_user(session)
    query = parse_qs(urlparse(connect_url(session, user.id)).query)

    assert HEALTH_SCOPE in query["scope"][0].split()
    assert query["access_type"] == ["offline"]
    assert query["prompt"] == ["consent"]
    state = session.scalar(select(OAuthState))
    assert state.purpose == CONNECT_HEALTH
    assert state.user_id == user.id


def test_connect_url_requires_a_user(session) -> None:
    with pytest.raises(OAuthConfigurationError):
        create_authorization_url(session, device_id=DEVICE_ID, purpose=CONNECT_HEALTH)


@pytest.mark.asyncio
async def test_sign_in_creates_user_and_identity_without_health_connection(session, device_key) -> None:
    completion = await sign_in(session, device_key, FakeGoogleClient())

    identity = session.scalar(select(SignInIdentity))
    assert identity.user_id == completion.user_id
    assert identity.provider == "google"
    assert identity.subject == "google-sub"
    assert identity.email == "person@example.com"
    assert identity.last_signed_in_at is not None
    assert session.get(User, completion.user_id).email == "person@example.com"
    assert session.scalars(select(HealthConnection)).all() == []
    assert session.scalar(select(OAuthState)).consumed_at is not None


@pytest.mark.asyncio
async def test_repeat_sign_in_returns_the_same_user(session, device_key) -> None:
    first = await sign_in(session, device_key, FakeGoogleClient())
    second = await sign_in(session, device_key, FakeGoogleClient(email="new@example.com"))

    assert second.user_id == first.user_id
    assert len(session.scalars(select(User)).all()) == 1
    assert session.get(User, first.user_id).email == "new@example.com"


@pytest.mark.asyncio
async def test_sign_in_ignores_unverified_email(session, device_key) -> None:
    completion = await sign_in(session, device_key, FakeGoogleClient(email_verified="false"))

    assert session.get(User, completion.user_id).email is None
    assert session.scalar(select(SignInIdentity)).email is None


@pytest.mark.asyncio
@pytest.mark.parametrize(
    "client",
    [FakeGoogleClient(id_token=None), FakeGoogleClient(audience="someone-else.apps.googleusercontent.com")],
)
async def test_sign_in_rejects_missing_or_foreign_identity_tokens(session, device_key, client) -> None:
    with pytest.raises(OAuthConfigurationError):
        await sign_in(session, device_key, client)
    assert session.scalars(select(User)).all() == []


@pytest.mark.asyncio
async def test_enrollment_rejects_a_different_google_account(session, device_key) -> None:
    owner = signed_in_user(session, subject="owner-sub")
    signed_in_user(session, subject="other-sub")
    url = sign_in_url(session, device_key, purpose="enroll_device", user_id=owner.id)

    with pytest.raises(OAuthConfigurationError, match="does not match"):
        await complete_google_oauth(
            session, code="auth-code", state=state_from(url), client=FakeGoogleClient(subject="other-sub")
        )


@pytest.mark.asyncio
async def test_connect_creates_health_connection_for_signed_in_user(session) -> None:
    user = signed_in_user(session)

    completion = await connect(session, user.id, FakeGoogleClient())

    connection = session.get(HealthConnection, completion.connection_id)
    assert completion.user_id == user.id
    assert completion.purpose == CONNECT_HEALTH
    assert connection.user_id == user.id
    assert connection.provider == "google_health"
    assert connection.status == ConnectionStatus.connected
    assert connection.external_user_id == "google-health-id"
    assert connection.external_legacy_user_id == "fitbit-legacy-id"
    assert connection.granted_scopes == ["scope-a", "scope-b"]
    assert decrypt_secret(connection.encrypted_refresh_token) == "refresh-token"
    assert session.get(User, user.id).email == "owner@example.com"


@pytest.mark.asyncio
async def test_connect_does_not_create_a_sign_in_identity(session) -> None:
    user = signed_in_user(session)

    await connect(session, user.id, FakeGoogleClient(subject="health-account-sub"))

    assert [identity.subject for identity in session.scalars(select(SignInIdentity))] == ["existing-sub"]


@pytest.mark.asyncio
async def test_reconnecting_the_same_health_account_reuses_the_connection(session) -> None:
    user = signed_in_user(session)
    first = await connect(session, user.id, FakeGoogleClient())
    connection = session.get(HealthConnection, first.connection_id)
    connection.status = ConnectionStatus.disconnected
    session.commit()

    second = await connect(session, user.id, FakeGoogleClient(refresh_token="second-token"))

    assert second.connection_id == first.connection_id
    assert len(session.scalars(select(HealthConnection)).all()) == 1
    session.refresh(connection)
    assert connection.status == ConnectionStatus.connected
    assert decrypt_secret(connection.encrypted_refresh_token) == "second-token"


@pytest.mark.asyncio
async def test_connecting_another_device_replaces_the_active_one(session) -> None:
    user = signed_in_user(session)
    first = await connect(session, user.id, FakeGoogleClient())
    client = FakeGoogleClient(health_user_id="second-health-id", legacy_user_id="second-legacy-id")

    second = await connect(session, user.id, client)

    previous = session.get(HealthConnection, first.connection_id)
    current = session.get(HealthConnection, second.connection_id)
    assert previous.status == ConnectionStatus.disconnected
    assert previous.encrypted_refresh_token is None
    assert current.status == ConnectionStatus.connected
    assert client.revoked == ["refresh-token"]


@pytest.mark.asyncio
async def test_health_account_owned_by_another_user_is_rejected(session) -> None:
    owner = signed_in_user(session, subject="owner-sub")
    session.add(
        HealthConnection(
            user_id=owner.id,
            external_user_id="google-health-id",
            status=ConnectionStatus.disconnected,
            encrypted_refresh_token=encrypt_secret("owner-token"),
        )
    )
    session.commit()
    other = signed_in_user(session, subject="other-sub")

    with pytest.raises(HealthAccountInUseError):
        await connect(session, other.id, FakeGoogleClient())

    assert session.scalars(
        select(HealthConnection).where(HealthConnection.user_id == other.id)
    ).all() == []


@pytest.mark.asyncio
async def test_connect_without_refresh_token_fails_for_a_new_connection(session) -> None:
    user = signed_in_user(session)

    with pytest.raises(OAuthConfigurationError, match="refresh token"):
        await connect(session, user.id, FakeGoogleClient(refresh_token=None))


@pytest.mark.asyncio
async def test_connect_is_refused_for_accounts_pending_deletion(session) -> None:
    user = signed_in_user(session)
    user.deletion_scheduled_for = utcnow()
    session.commit()

    with pytest.raises(OAuthConfigurationError, match="Pending-deletion"):
        await connect(session, user.id, FakeGoogleClient())


def apple_signed_in_user(session) -> User:
    user = User()
    session.add(user)
    session.flush()
    session.add(SignInIdentity(user_id=user.id, provider="apple", subject="apple-sub"))
    session.commit()
    return user


@pytest.mark.asyncio
async def test_connect_records_which_google_account_was_used(session) -> None:
    user = apple_signed_in_user(session)

    await connect(session, user.id, FakeGoogleClient(subject="fitbit-google-sub"))

    assert session.scalar(select(HealthConnection)).account_subject == "fitbit-google-sub"


@pytest.mark.asyncio
async def test_google_sign_in_is_refused_for_another_accounts_data_source(session, device_key) -> None:
    owner = apple_signed_in_user(session)
    await connect(session, owner.id, FakeGoogleClient(subject="fitbit-google-sub"))

    with pytest.raises(GoogleAccountInUseError):
        await sign_in(session, device_key, FakeGoogleClient(subject="fitbit-google-sub"))

    assert session.scalars(select(User)).all() == [owner]
    assert session.scalars(select(SignInIdentity).where(SignInIdentity.provider == "google")).all() == []


@pytest.mark.asyncio
async def test_connect_is_refused_when_the_google_account_signs_in_to_another_account(session) -> None:
    signed_in_user(session, subject="google-sub")
    user = apple_signed_in_user(session)

    with pytest.raises(GoogleAccountInUseError):
        await connect(session, user.id, FakeGoogleClient(subject="google-sub"))

    assert session.scalars(select(HealthConnection)).all() == []


@pytest.mark.asyncio
async def test_connect_with_your_own_google_sign_in_account_is_allowed(session) -> None:
    user = signed_in_user(session, subject="google-sub")

    await connect(session, user.id, FakeGoogleClient(subject="google-sub"))

    assert session.scalar(select(HealthConnection)).user_id == user.id
