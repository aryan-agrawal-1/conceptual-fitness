from __future__ import annotations

from urllib.parse import parse_qs, urlparse

import pytest
from sqlalchemy import select

from app.core.security import decrypt_secret
from app.models import GoogleAccount, OAuthState
from app.services.oauth import complete_google_health_oauth, create_authorization_url


class FakeGoogleHealthClient:
    async def exchange_code_for_tokens(self, code: str) -> dict[str, object]:
        assert code == "auth-code"
        return {
            "access_token": "access-token",
            "refresh_token": "refresh-token",
            "expires_in": 3600,
            "scope": "scope-a scope-b",
        }

    async def get_identity(self, access_token: str) -> dict[str, str]:
        assert access_token == "access-token"
        return {
            "name": "users/me/identity",
            "legacyUserId": "fitbit-legacy-id",
            "healthUserId": "google-health-id",
        }

    async def get_userinfo(self, access_token: str) -> dict[str, object]:
        assert access_token == "access-token"
        return {"email": "person@example.com", "email_verified": True}


def test_create_authorization_url_persists_state(session) -> None:
    url = create_authorization_url(session, device_id="test-device-id-000000000000")
    parsed = urlparse(url)
    query = parse_qs(parsed.query)

    assert parsed.netloc == "accounts.google.com"
    assert query["client_id"] == ["test-client-id.apps.googleusercontent.com"]
    assert query["redirect_uri"] == ["http://localhost:8000/auth/google/callback"]
    assert query["access_type"] == ["offline"]
    assert query["prompt"] == ["consent"]
    assert "state" in query

    states = session.scalars(select(OAuthState)).all()
    assert len(states) == 1
    assert states[0].consumed_at is None
    assert states[0].device_id_hash is not None


@pytest.mark.asyncio
async def test_complete_oauth_creates_user_and_google_account(session) -> None:
    url = create_authorization_url(session, device_id="test-device-id-000000000000")
    state = parse_qs(urlparse(url).query)["state"][0]

    completion = await complete_google_health_oauth(
        session,
        code="auth-code",
        state=state,
        client=FakeGoogleHealthClient(),
    )
    account = completion.account

    saved = session.get(GoogleAccount, account.id)
    assert saved is not None
    assert saved.user_id is not None
    assert saved.health_user_id == "google-health-id"
    assert saved.legacy_user_id == "fitbit-legacy-id"
    assert saved.granted_scopes == ["scope-a", "scope-b"]
    assert decrypt_secret(saved.encrypted_refresh_token) == "refresh-token"
    assert saved.user.email == "person@example.com"

    oauth_state = session.scalar(select(OAuthState))
    assert oauth_state.consumed_at is not None
