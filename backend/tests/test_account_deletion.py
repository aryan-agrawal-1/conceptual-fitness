from __future__ import annotations

from datetime import timedelta

import pytest
from fastapi.testclient import TestClient
from sqlalchemy import create_engine, event, select
from sqlalchemy.orm import Session

from app.core.security import encrypt_secret, utcnow
from app.db.session import Base
from app.main import app
from app.models import (
    AppAccessToken,
    AppSession,
    ConnectionStatus,
    DailySummary,
    GoogleAccount,
    MetricSample,
    RawHealthRecord,
    SensitiveActionGrant,
    User,
    UserProfile,
    Workout,
)
from app.services.account_deletion import (
    DELETION_GRACE_PERIOD,
    purge_due_accounts,
    schedule_account_deletion,
)
from app.services.account_recovery import AccountRecoveryError, recover_account
from app.services.app_auth import create_app_auth_code, device_id_digest, exchange_auth_code
from app.services.sensitive_actions import create_sensitive_action_grant
from app.services.sync import sync_google_account_range


DEVICE_ID = "deletion-test-device-000000"


def test_every_user_foreign_key_cascades_on_permanent_erasure() -> None:
    user_foreign_keys = [
        foreign_key
        for table in Base.metadata.tables.values()
        for foreign_key in table.foreign_keys
        if foreign_key.target_fullname == "users.id"
    ]

    assert user_foreign_keys
    assert all(foreign_key.ondelete == "CASCADE" for foreign_key in user_foreign_keys)


def test_schedule_revokes_access_and_can_recover_during_grace_period(session) -> None:
    now = utcnow()
    user = User()
    session.add(user)
    session.flush()
    account = GoogleAccount(
        user_id=user.id,
        status=ConnectionStatus.connected,
        encrypted_refresh_token=encrypt_secret("provider-token"),
    )
    app_session = AppSession(
        user_id=user.id,
        device_id_hash="device",
        expires_at=now + timedelta(days=30),
    )
    session.add_all([account, app_session])
    session.flush()
    access = AppAccessToken(
        session_id=app_session.id,
        user_id=user.id,
        token_hash="access",
        expires_at=now + timedelta(minutes=15),
    )
    session.add(access)
    session.commit()

    scheduled = schedule_account_deletion(session, user, now=now)

    assert scheduled.deletion_requested_at == now.replace(tzinfo=None)
    assert scheduled.deletion_scheduled_for == (now + DELETION_GRACE_PERIOD).replace(tzinfo=None)
    assert app_session.revoked_at is not None
    session.refresh(access)
    assert access.revoked_at is not None
    assert account.status == ConnectionStatus.disconnected
    assert account.encrypted_refresh_token is not None

    rescheduled = schedule_account_deletion(session, user, now=now + timedelta(days=1))
    assert rescheduled.deletion_requested_at == now.replace(tzinfo=None)
    assert rescheduled.deletion_scheduled_for == (now + DELETION_GRACE_PERIOD).replace(tzinfo=None)

    recovered = recover_account(session, user, now=now + timedelta(days=13))

    assert recovered.deletion_requested_at is None
    assert recovered.deletion_scheduled_for is None
    assert app_session.revoked_at is not None
    session.refresh(account)
    assert account.status == ConnectionStatus.connected


def test_recovery_fails_at_deadline(session) -> None:
    now = utcnow()
    user = User(
        deletion_requested_at=now - DELETION_GRACE_PERIOD,
        deletion_scheduled_for=now,
    )
    session.add(user)
    session.commit()

    with pytest.raises(AccountRecoveryError, match="period has ended"):
        recover_account(session, user, now=now)


def test_deletion_routes_revoke_old_access_and_issue_only_a_fresh_recovery_session(
    session,
) -> None:
    user = User(email="delete@example.com")
    session.add(user)
    session.flush()
    account = GoogleAccount(
        user_id=user.id,
        status=ConnectionStatus.connected,
        encrypted_refresh_token=encrypt_secret("provider-token"),
    )
    session.add(account)
    session.commit()
    app_code = create_app_auth_code(
        session,
        user_id=user.id,
        device_id_hash=device_id_digest(DEVICE_ID),
    )
    old_tokens = exchange_auth_code(session, code=app_code, device_id=DEVICE_ID)
    old_headers = {"Authorization": f"Bearer {old_tokens.access_token}"}
    delete_grant = create_sensitive_action_grant(
        session,
        user_id=user.id,
        device_id_hash=device_id_digest(DEVICE_ID),
        purpose="delete_account",
    )
    client = TestClient(app)

    scheduled = client.post(
        "/account/deletion",
        headers=old_headers,
        json={
            "confirmation": "DELETE",
            "sensitive_action_grant": delete_grant,
            "device_id": DEVICE_ID,
        },
    )

    assert scheduled.status_code == 200
    assert scheduled.json()["status"] == "pending"
    assert scheduled.json()["scheduled_for"] is not None
    assert client.get("/auth/me", headers=old_headers).status_code == 401
    assert client.post(
        "/auth/refresh",
        json={"refresh_token": old_tokens.refresh_token, "device_id": DEVICE_ID},
    ).status_code == 401

    normal_code = create_app_auth_code(
        session,
        user_id=user.id,
        device_id_hash=device_id_digest(DEVICE_ID),
    )
    assert client.post(
        "/auth/exchange",
        json={"code": normal_code, "device_id": DEVICE_ID},
    ).status_code == 401

    recover_grant = create_sensitive_action_grant(
        session,
        user_id=user.id,
        device_id_hash=device_id_digest(DEVICE_ID),
        purpose="recover_deletion",
    )
    recovered = client.post(
        "/account/deletion/recover",
        json={"sensitive_action_grant": recover_grant, "device_id": DEVICE_ID},
    )

    assert recovered.status_code == 200
    assert recovered.json()["status"] == "recovered"
    fresh_headers = {"Authorization": f"Bearer {recovered.json()['access_token']}"}
    assert client.get("/auth/me", headers=fresh_headers).status_code == 200
    assert client.get("/auth/me", headers=old_headers).status_code == 401
    session.refresh(account)
    assert account.status == ConnectionStatus.connected


def test_schedule_requires_exact_confirmation_and_matching_grant_device(session, auth_headers) -> None:
    user = User()
    session.add(user)
    session.commit()
    headers = auth_headers(user, device_id=DEVICE_ID)
    client = TestClient(app)

    invalid_confirmation = client.post(
        "/account/deletion",
        headers=headers,
        json={
            "confirmation": "delete",
            "sensitive_action_grant": "unused",
            "device_id": DEVICE_ID,
        },
    )
    assert invalid_confirmation.status_code == 422

    export_grant = create_sensitive_action_grant(
        session,
        user_id=user.id,
        device_id_hash=device_id_digest(DEVICE_ID),
        purpose="export",
    )
    wrong_purpose = client.post(
        "/account/deletion",
        headers=headers,
        json={
            "confirmation": "DELETE",
            "sensitive_action_grant": export_grant,
            "device_id": DEVICE_ID,
        },
    )
    assert wrong_purpose.status_code == 403

    delete_grant = create_sensitive_action_grant(
        session,
        user_id=user.id,
        device_id_hash=device_id_digest(DEVICE_ID),
        purpose="delete_account",
    )
    wrong_device = client.post(
        "/account/deletion",
        headers=headers,
        json={
            "confirmation": "DELETE",
            "sensitive_action_grant": delete_grant,
            "device_id": "different-device-0000000",
        },
    )
    assert wrong_device.status_code == 403


def test_expired_recovery_grant_is_rejected_without_authentication(session) -> None:
    now = utcnow()
    user = User(deletion_requested_at=now, deletion_scheduled_for=now + DELETION_GRACE_PERIOD)
    session.add(user)
    session.commit()
    token = create_sensitive_action_grant(
        session,
        user_id=user.id,
        device_id_hash=device_id_digest(DEVICE_ID),
        purpose="recover_deletion",
    )
    grant = session.scalar(select(SensitiveActionGrant).where(SensitiveActionGrant.user_id == user.id))
    grant.expires_at = now - timedelta(seconds=1)
    session.add(grant)
    session.commit()

    response = TestClient(app).post(
        "/account/deletion/recover",
        json={"sensitive_action_grant": token, "device_id": DEVICE_ID},
    )

    assert response.status_code == 403


@pytest.mark.asyncio
async def test_purge_waits_until_the_exact_deadline(session) -> None:
    now = utcnow()
    user = User(deletion_requested_at=now, deletion_scheduled_for=now + timedelta(microseconds=1))
    session.add(user)
    session.commit()

    result = await purge_due_accounts(session, now=now, google_client=StubGoogleClient())

    assert result == {"purged": 0, "failed": 0, "revocation_failed": 0}
    assert session.get(User, user.id) is not None


@pytest.mark.asyncio
async def test_in_flight_sync_cannot_reconnect_a_pending_account(session) -> None:
    now = utcnow()
    user = User()
    session.add(user)
    session.flush()
    account = GoogleAccount(
        user_id=user.id,
        status=ConnectionStatus.connected,
        encrypted_refresh_token=encrypt_secret("provider-token"),
    )
    session.add(account)
    session.commit()
    client = DeletingDuringRefreshClient(session, user)

    with pytest.raises(RuntimeError, match="not connected"):
        await sync_google_account_range(
            session,
            account=account,
            start=now.date(),
            end=now.date(),
            data_types=(),
            client=client,
        )

    session.refresh(account)
    assert account.status == ConnectionStatus.disconnected


@pytest.mark.asyncio
async def test_due_purge_revokes_provider_and_cascades_current_user_data() -> None:
    engine = create_engine("sqlite://")

    @event.listens_for(engine, "connect")
    def enable_foreign_keys(connection, connection_record) -> None:
        del connection_record
        connection.execute("PRAGMA foreign_keys=ON")

    Base.metadata.create_all(engine)
    session = Session(engine)
    now = utcnow()
    user = User(deletion_requested_at=now - DELETION_GRACE_PERIOD, deletion_scheduled_for=now)
    session.add(user)
    session.flush()
    account = GoogleAccount(
        user_id=user.id,
        status=ConnectionStatus.disconnected,
        encrypted_refresh_token=encrypt_secret("provider-token"),
    )
    session.add_all([account, UserProfile(user_id=user.id)])
    session.flush()
    raw = RawHealthRecord(
        user_id=user.id,
        google_account_id=account.id,
        data_type="heart-rate",
        source_record_id="source",
        raw_json={},
        content_hash="hash",
    )
    session.add(raw)
    session.flush()
    session.add_all([
        MetricSample(
            user_id=user.id,
            raw_record_id=raw.id,
            metric="heart_rate",
            observed_at=now,
            value=60,
            unit="bpm",
        ),
        Workout(
            user_id=user.id,
            raw_record_id=raw.id,
            start_time=now,
            end_time=now,
            raw_summary={},
        ),
        DailySummary(user_id=user.id, summary_date=now.date()),
    ])
    session.commit()
    client = StubGoogleClient()

    result = await purge_due_accounts(session, now=now, google_client=client)

    assert result == {"purged": 1, "failed": 0, "revocation_failed": 0}
    assert client.revoked == ["provider-token"]
    assert session.get(User, user.id) is None
    for model in (UserProfile, GoogleAccount, RawHealthRecord, MetricSample, Workout, DailySummary):
        assert session.scalar(select(model).limit(1)) is None
    session.close()


@pytest.mark.asyncio
async def test_provider_failure_does_not_delay_local_erasure(session) -> None:
    now = utcnow()
    user = User(deletion_requested_at=now - DELETION_GRACE_PERIOD, deletion_scheduled_for=now)
    session.add(user)
    session.flush()
    session.add(GoogleAccount(
        user_id=user.id,
        status=ConnectionStatus.disconnected,
        encrypted_refresh_token=encrypt_secret("provider-token"),
    ))
    session.commit()

    result = await purge_due_accounts(session, now=now, google_client=FailingGoogleClient())

    assert result == {"purged": 1, "failed": 0, "revocation_failed": 1}
    assert session.get(User, user.id) is None


class StubGoogleClient:
    def __init__(self) -> None:
        self.revoked: list[str] = []

    async def revoke_token(self, token: str) -> None:
        self.revoked.append(token)


class FailingGoogleClient:
    async def revoke_token(self, token: str) -> None:
        del token
        raise RuntimeError("provider unavailable")


class DeletingDuringRefreshClient:
    def __init__(self, session: Session, user: User) -> None:
        self.session = session
        self.user = user

    async def refresh_access_token(self, token: str) -> dict[str, str]:
        del token
        schedule_account_deletion(self.session, self.user)
        return {"access_token": "unused"}
