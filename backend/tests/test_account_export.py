from __future__ import annotations

from datetime import timedelta
from io import BytesIO
import json
from urllib.parse import parse_qs, urlparse
from uuid import uuid4
from zipfile import ZipFile

import pytest
from fastapi.testclient import TestClient
from sqlalchemy import select

from app.core.security import generate_app_token, token_digest, utcnow
from app.main import app
from app.models import (
    AppSession,
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
)
from app.services.app_auth import device_id_digest
from app.services.oauth import complete_google_health_oauth, create_authorization_url


DEVICE_ID = f"test-device-{uuid4()}"


def user(session, email: str) -> User:
    item = User(email=email)
    session.add(item)
    session.commit()
    return item


def grant(
    session,
    account_user: User,
    purpose: str = "export",
    session_id: str | None = None,
) -> str:
    token = generate_app_token()
    session.add(
        SensitiveActionGrant(
        user_id=account_user.id,
        device_id_hash=device_id_digest(DEVICE_ID),
        purpose=purpose,
            session_id=session_id,
            token_hash=token_digest(token),
            expires_at=utcnow() + timedelta(minutes=5),
            verified_at=utcnow(),
        )
    )
    session.commit()
    return token


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
    session, auth_headers, device_key
) -> None:
    owner = user(session, "owner@example.com")
    client = TestClient(app)

    unauthorized = client.get(
        "/auth/google/sensitive-start-url",
        params={
            "device_id": DEVICE_ID,
            "purpose": "enroll_device",
            "device_public_key": device_key.public_key,
        },
    )
    assert unauthorized.status_code == 401

    response = client.get(
        "/auth/google/sensitive-start-url",
        params={
            "device_id": DEVICE_ID,
            "purpose": "enroll_device",
            "device_public_key": device_key.public_key,
        },
        headers=auth_headers(owner),
    )
    assert response.status_code == 200
    query = parse_qs(urlparse(response.json()["authorization_url"]).query)
    assert query["prompt"] == ["select_account"]
    assert query["scope"] == [
        "openid email profile https://www.googleapis.com/auth/googlehealth.profile.readonly"
    ]
    assert "access_type" not in query
    assert "include_granted_scopes" not in query
    assert "max_age" not in query
    assert "claims" not in query
    state = session.scalar(select(OAuthState))
    assert state.user_id == owner.id
    assert state.sensitive_action == "enroll_device"
    assert state.device_public_key == device_key.public_key
    assert state.source_session_id is not None


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

    headers = auth_headers(owner)
    app_session = session.scalar(select(AppSession).where(AppSession.user_id == owner.id))
    response = TestClient(app).post(
        "/account/export",
        headers=headers,
        json={
            "categories": [
                "health_and_workouts",
                "journal",
                "derived_insights",
                "personalization",
            ],
            "sensitive_action_grant": grant(session, owner, session_id=app_session.id),
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
    headers = auth_headers(owner)
    app_session = session.scalar(select(AppSession).where(AppSession.user_id == owner.id))

    wrong_purpose = client.post(
        "/account/export",
        headers=headers,
        json={
            "categories": ["journal"],
            "sensitive_action_grant": grant(
                session,
                owner,
                "delete_account",
                session_id=app_session.id,
            ),
            "device_id": DEVICE_ID,
        },
    )
    assert wrong_purpose.status_code == 403

    legacy_unbound = client.post(
        "/account/export",
        headers=headers,
        json={
            "categories": ["journal"],
            "sensitive_action_grant": grant(session, owner),
            "device_id": DEVICE_ID,
        },
    )
    assert legacy_unbound.status_code == 403

    empty = client.post(
        "/account/export",
        headers=headers,
        json={
            "categories": [],
            "sensitive_action_grant": grant(session, owner, session_id=app_session.id),
            "device_id": DEVICE_ID,
        },
    )
    assert empty.status_code == 422


class SensitiveOAuthClient:
    def __init__(self, health_user_id: str = "health-id") -> None:
        self.health_user_id = health_user_id

    async def exchange_code_for_tokens(self, code: str) -> dict[str, object]:
        return {"access_token": "access-token", "expires_in": 3600}

    async def get_identity(self, access_token: str) -> dict[str, str]:
        return {"healthUserId": self.health_user_id, "legacyUserId": "legacy-id"}

    async def get_userinfo(self, access_token: str) -> dict[str, object]:
        return {"sub": "google-sub", "email": "owner@example.com", "email_verified": True}


@pytest.mark.asyncio
async def test_enrollment_oauth_needs_same_google_account_but_not_auth_time(
    session,
    device_key,
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
        sensitive_action="enroll_device",
        device_public_key=device_key.public_key,
        source_session_id="legacy-session-id",
    )
    state = parse_qs(urlparse(url).query)["state"][0]

    completion = await complete_google_health_oauth(
        session,
        code="auth-code",
        state=state,
        client=SensitiveOAuthClient(),
    )

    assert completion.account.user_id == owner.id
    assert completion.device_public_key == device_key.public_key
    assert completion.source_session_id == "legacy-session-id"
