from __future__ import annotations

from datetime import timedelta
from io import BytesIO
import json
from urllib.parse import parse_qs, urlparse
from zipfile import ZipFile

import pytest
from fastapi.testclient import TestClient
from sqlalchemy import select

from app.core.security import token_digest, utcnow
from app.main import app
from app.models import (
    ConnectionStatus,
    DailyContext,
    DailyScore,
    GoogleAccount,
    OAuthState,
    RawHealthRecord,
    ScoreStatus,
    SensitiveActionGrant,
    User,
    UserProfile,
)
from app.services.sensitive_actions import (
    SensitiveActionError,
    consume_sensitive_action_grant,
    create_sensitive_action_grant,
)
from app.services.app_auth import device_id_digest
from app.services.oauth import OAuthConfigurationError, complete_google_health_oauth, create_authorization_url


DEVICE_ID = "test-device-id-000000000000"


def user(session, email: str) -> User:
    item = User(email=email)
    session.add(item)
    session.commit()
    return item


def grant(session, account_user: User, purpose: str = "export") -> str:
    return create_sensitive_action_grant(
        session,
        user_id=account_user.id,
        device_id_hash=device_id_digest(DEVICE_ID),
        purpose=purpose,
    )


def test_sensitive_action_grant_is_user_purpose_expiry_and_replay_bound(session) -> None:
    owner = user(session, "owner@example.com")
    other = user(session, "other@example.com")

    wrong_purpose = grant(session, owner, "delete_account")
    with pytest.raises(SensitiveActionError):
        consume_sensitive_action_grant(
            session, token=wrong_purpose, purpose="export", user_id=owner.id
        )

    wrong_user = grant(session, owner)
    with pytest.raises(SensitiveActionError):
        consume_sensitive_action_grant(
            session, token=wrong_user, purpose="export", user_id=other.id
        )

    wrong_device = grant(session, owner)
    with pytest.raises(SensitiveActionError):
        consume_sensitive_action_grant(
            session,
            token=wrong_device,
            purpose="export",
            user_id=owner.id,
            device_id="different-device-id-00000000",
        )

    expired = grant(session, owner)
    expired_row = session.scalar(
        select(SensitiveActionGrant).where(
            SensitiveActionGrant.token_hash == token_digest(expired)
        )
    )
    expired_row.expires_at = utcnow() - timedelta(seconds=1)
    session.commit()
    with pytest.raises(SensitiveActionError):
        consume_sensitive_action_grant(session, token=expired, purpose="export", user_id=owner.id)

    one_time = grant(session, owner)
    consume_sensitive_action_grant(session, token=one_time, purpose="export", user_id=owner.id)
    with pytest.raises(SensitiveActionError):
        consume_sensitive_action_grant(session, token=one_time, purpose="export", user_id=owner.id)


def test_sensitive_start_requires_session_and_requests_fresh_authentication(
    session, auth_headers
) -> None:
    owner = user(session, "owner@example.com")
    client = TestClient(app)

    unauthorized = client.get(
        "/auth/google/sensitive-start-url",
        params={"device_id": DEVICE_ID, "purpose": "export"},
    )
    assert unauthorized.status_code == 401

    response = client.get(
        "/auth/google/sensitive-start-url",
        params={"device_id": DEVICE_ID, "purpose": "export"},
        headers=auth_headers(owner),
    )
    assert response.status_code == 200
    query = parse_qs(urlparse(response.json()["authorization_url"]).query)
    assert query["prompt"] == ["select_account"]
    assert query["max_age"] == ["0"]
    assert "auth_time" in query["claims"][0]
    assert query["scope"] == [
        "openid email profile https://www.googleapis.com/auth/googlehealth.profile.readonly"
    ]
    assert "access_type" not in query
    assert "include_granted_scopes" not in query
    state = session.scalar(select(OAuthState))
    assert state.user_id == owner.id
    assert state.sensitive_action == "export"


def test_export_is_selectable_scoped_documented_and_secret_free(session, auth_headers) -> None:
    owner = user(session, "owner@example.com")
    other = user(session, "other@example.com")
    account = GoogleAccount(
        user_id=owner.id,
        health_user_id="owner-health-id",
        status=ConnectionStatus.connected,
        granted_scopes=["health.read"],
        encrypted_refresh_token="must-not-export",
        last_error="must-not-export",
    )
    other_account = GoogleAccount(
        user_id=other.id,
        health_user_id="other-health-id",
        status=ConnectionStatus.connected,
        granted_scopes=[],
    )
    session.add_all(
        [
            UserProfile(user_id=owner.id),
            UserProfile(user_id=other.id),
            account,
            other_account,
            DailyContext(
                user_id=owner.id,
                context_date=utcnow().date(),
                context_type="journal_note",
                value={"text": "private owner note"},
            ),
            DailyContext(
                user_id=other.id,
                context_date=utcnow().date(),
                context_type="journal_note",
                value={"text": "other user note"},
            ),
            DailyScore(
                user_id=owner.id,
                score_date=utcnow().date(),
                score_type="readiness",
                algorithm_version="v1",
                value=72,
                value_unit="score",
                status=ScoreStatus.scored,
            ),
        ]
    )
    session.commit()
    session.add(
        RawHealthRecord(
            user_id=owner.id,
            google_account_id=account.id,
            data_type="steps",
            source_record_id="source-1",
            raw_json={"steps": 1234},
            content_hash="hash",
        )
    )
    session.commit()

    response = TestClient(app).post(
        "/account/export",
        headers=auth_headers(owner),
        json={
            "categories": [
                "health_and_workouts",
                "journal",
                "derived_insights",
                "personalization",
            ],
            "sensitive_action_grant": grant(session, owner),
            "device_id": DEVICE_ID,
            "local_insights": [
                {
                    "date": "2026-09-19",
                    "slot": "daytime",
                    "kind": "dailyBrief",
                    "text": "A cached on-device brief.",
                    "generated_at": "2026-09-19T08:00:00Z",
                }
            ],
        },
    )

    assert response.status_code == 200
    assert response.headers["content-type"] == "application/zip"
    with ZipFile(BytesIO(response.content)) as archive:
        assert set(archive.namelist()) == {
            "manifest.json",
            "journal.json",
            "derived_insights.json",
            "personalization.json",
            "health_and_workouts.json",
        }
        manifest = json.loads(archive.read("manifest.json"))
        assert manifest["schema_version"] == "1.0"
        assert manifest["selected_categories"] == [
            "derived_insights",
            "health_and_workouts",
            "journal",
            "personalization",
        ]
        journal = json.loads(archive.read("journal.json"))
        notes = journal["tables"]["daily_contexts"]
        assert [item["value"]["text"] for item in notes] == ["private owner note"]
        insights = json.loads(archive.read("derived_insights.json"))
        assert insights["tables"]["client_daily_insights"][0]["text"] == "A cached on-device brief."
        health = json.loads(archive.read("health_and_workouts.json"))
        assert health["tables"]["raw_health_records"][0]["raw_json"] == {"steps": 1234}
        personalization = archive.read("personalization.json").decode()
        assert "owner-health-id" in personalization
        assert "other-health-id" not in personalization
        assert "must-not-export" not in personalization


def test_export_rejects_wrong_purpose_and_empty_selection(session, auth_headers) -> None:
    owner = user(session, "owner@example.com")
    client = TestClient(app)

    wrong_purpose = client.post(
        "/account/export",
        headers=auth_headers(owner),
        json={
            "categories": ["journal"],
            "sensitive_action_grant": grant(session, owner, "delete_account"),
            "device_id": DEVICE_ID,
        },
    )
    assert wrong_purpose.status_code == 403

    empty = client.post(
        "/account/export",
        headers=auth_headers(owner),
        json={
            "categories": [],
            "sensitive_action_grant": grant(session, owner),
            "device_id": DEVICE_ID,
        },
    )
    assert empty.status_code == 422


class SensitiveOAuthClient:
    def __init__(self, claims: dict[str, object], userinfo_sub: str = "google-sub") -> None:
        self.claims = claims
        self.userinfo_sub = userinfo_sub

    async def exchange_code_for_tokens(self, code: str) -> dict[str, object]:
        return {"access_token": "access-token", "id_token": "id-token", "expires_in": 3600}

    async def verify_id_token(self, id_token: str) -> dict[str, object]:
        return self.claims

    async def get_identity(self, access_token: str) -> dict[str, str]:
        return {"healthUserId": "health-id", "legacyUserId": "legacy-id"}

    async def get_userinfo(self, access_token: str) -> dict[str, object]:
        return {"sub": self.userinfo_sub, "email": "owner@example.com", "email_verified": True}


@pytest.mark.asyncio
@pytest.mark.parametrize("claim_change,userinfo_sub", [
    ({"auth_time": None}, "google-sub"),
    ({"auth_time": int((utcnow() - timedelta(minutes=10)).timestamp())}, "google-sub"),
    ({"auth_time": int((utcnow() + timedelta(minutes=2)).timestamp())}, "google-sub"),
    ({}, "different-sub"),
])
async def test_sensitive_oauth_rejects_missing_stale_or_mismatched_authentication_evidence(
    session,
    claim_change,
    userinfo_sub,
) -> None:
    owner = user(session, "owner@example.com")
    session.add(
        GoogleAccount(
            user_id=owner.id,
            health_user_id="health-id",
            legacy_user_id="legacy-id",
            status=ConnectionStatus.connected,
            granted_scopes=[],
        )
    )
    session.commit()
    url = create_authorization_url(
        session,
        device_id=DEVICE_ID,
        user_id=owner.id,
        sensitive_action="export",
    )
    state = parse_qs(urlparse(url).query)["state"][0]
    now = int(utcnow().timestamp())
    claims = {
        "aud": "test-client-id.apps.googleusercontent.com",
        "iss": "https://accounts.google.com",
        "sub": "google-sub",
        "exp": now + 300,
        "auth_time": now,
        **claim_change,
    }

    with pytest.raises(OAuthConfigurationError):
        await complete_google_health_oauth(
            session,
            code="auth-code",
            state=state,
            client=SensitiveOAuthClient(claims, userinfo_sub),
        )
