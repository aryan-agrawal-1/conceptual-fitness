from __future__ import annotations

from datetime import date, timedelta

import pytest
from sqlalchemy import select

from app.core.security import encrypt_secret
from app.google_health.client import GoogleHealthAPIError
from app.google_health.data_types import DATA_TYPE_SPECS, MVP_SYNC_DATA_TYPES
from app.models import (
    ConnectionStatus,
    GoogleAccount,
    MetricInterval,
    MetricSample,
    RawHealthRecord,
    SyncCursor,
    SyncStatus,
    User,
)
from app.services.sync import run_initial_backfill, sync_google_account_range


def _connected_account(session) -> GoogleAccount:
    user = User()
    session.add(user)
    session.flush()
    account = GoogleAccount(
        user_id=user.id,
        health_user_id="health-id",
        legacy_user_id="legacy-id",
        granted_scopes=[],
        encrypted_refresh_token=encrypt_secret("refresh-token"),
        status=ConnectionStatus.connected,
    )
    session.add(account)
    session.flush()
    return account


class FakePagedGoogleHealthClient:
    def __init__(self) -> None:
        self.calls: list[dict[str, object]] = []

    async def refresh_access_token(self, refresh_token: str) -> dict[str, str]:
        assert refresh_token == "refresh-token"
        return {"access_token": "access-token"}

    async def iter_data_point_pages(
        self,
        data_type: str,
        access_token: str,
        *,
        filter_expr: str | None = None,
        prefer_reconcile: bool = False,
        page_size: int | None = None,
    ):
        async for points, _next_page_token in self.iter_data_point_pages_with_tokens(
            data_type,
            access_token,
            filter_expr=filter_expr,
            prefer_reconcile=prefer_reconcile,
            page_size=page_size,
        ):
            yield points

    async def iter_data_point_pages_with_tokens(
        self,
        data_type: str,
        access_token: str,
        *,
        filter_expr: str | None = None,
        prefer_reconcile: bool = False,
        page_size: int | None = None,
        page_token: str | None = None,
    ):
        assert access_token == "access-token"
        call_index = len(self.calls)
        self.calls.append(
            {
                "data_type": data_type,
                "filter_expr": filter_expr,
                "prefer_reconcile": prefer_reconcile,
                "page_size": page_size,
                "page_token": page_token,
            }
        )
        observed_day = date(2026, 6, 16) + timedelta(days=call_index)
        yield [
            {
                "dataPointName": f"users/me/dataTypes/heart-rate/dataPoints/{call_index}",
                "heartRate": {
                    "sampleTime": {
                        "physicalTime": f"{observed_day.isoformat()}T12:00:00Z",
                        "civilTime": {
                            "date": {
                                "year": observed_day.year,
                                "month": observed_day.month,
                                "day": observed_day.day,
                            }
                        },
                    },
                    "beatsPerMinute": "72",
                },
            }
        ], None


class FakeHeartRateFailureClient:
    async def refresh_access_token(self, refresh_token: str) -> dict[str, str]:
        return {"access_token": "access-token"}

    async def iter_data_point_pages(
        self,
        data_type: str,
        access_token: str,
        *,
        filter_expr: str | None = None,
        prefer_reconcile: bool = False,
        page_size: int | None = None,
    ):
        async for points, _next_page_token in self.iter_data_point_pages_with_tokens(
            data_type,
            access_token,
            filter_expr=filter_expr,
            prefer_reconcile=prefer_reconcile,
            page_size=page_size,
        ):
            yield points

    async def iter_data_point_pages_with_tokens(
        self,
        data_type: str,
        access_token: str,
        *,
        filter_expr: str | None = None,
        prefer_reconcile: bool = False,
        page_size: int | None = None,
        page_token: str | None = None,
    ):
        if data_type == "heart-rate":
            raise GoogleHealthAPIError("Google Health API request timed out after 30s")
        yield [
            {
                "name": "users/me/dataTypes/steps/dataPoints/1",
                "dataSource": {"platform": "FITBIT"},
                "steps": {
                    "interval": {
                        "startTime": "2026-06-18T08:00:00Z",
                        "endTime": "2026-06-18T08:05:00Z",
                        "civilStartTime": {"date": {"year": 2026, "month": 6, "day": 18}},
                    },
                    "count": "100",
                },
            }
        ], None


class FakeResumeGoogleHealthClient:
    def __init__(self) -> None:
        self.page_tokens: list[str | None] = []
        self.filters: list[str | None] = []
        self.page_sizes: list[int | None] = []

    async def refresh_access_token(self, refresh_token: str) -> dict[str, str]:
        return {"access_token": "access-token"}

    async def iter_data_point_pages_with_tokens(
        self,
        data_type: str,
        access_token: str,
        *,
        filter_expr: str | None = None,
        prefer_reconcile: bool = False,
        page_size: int | None = None,
        page_token: str | None = None,
    ):
        self.page_tokens.append(page_token)
        self.filters.append(filter_expr)
        self.page_sizes.append(page_size)
        yield [], None


class FakeOutOfRangeDailyZonesClient:
    async def refresh_access_token(self, refresh_token: str) -> dict[str, str]:
        return {"access_token": "access-token"}

    async def iter_data_point_pages_with_tokens(
        self,
        data_type: str,
        access_token: str,
        *,
        filter_expr: str | None = None,
        prefer_reconcile: bool = False,
        page_size: int | None = None,
        page_token: str | None = None,
    ):
        yield [
            {
                "dailyHeartRateZones": {
                    "date": {"year": 2026, "month": 6, "day": 18},
                    "heartRateZones": [{"heartRateZoneType": "LIGHT"}],
                },
            },
            {
                "dailyHeartRateZones": {
                    "date": {"year": 9997, "month": 8, "day": 20},
                    "heartRateZones": [{"heartRateZoneType": "LIGHT"}],
                },
            },
        ], None


def test_sync_specs_follow_google_page_size_limits() -> None:
    assert DATA_TYPE_SPECS["heart-rate"].page_size == 10000
    assert DATA_TYPE_SPECS["time-in-heart-rate-zone"].page_size == 10000
    assert DATA_TYPE_SPECS["steps"].page_size == 10000
    assert DATA_TYPE_SPECS["sleep"].page_size == 25
    assert DATA_TYPE_SPECS["exercise"].page_size == 25
    assert "weight" in MVP_SYNC_DATA_TYPES
    assert "height" in MVP_SYNC_DATA_TYPES


@pytest.mark.asyncio
async def test_heart_rate_sync_uses_daily_reconcile_chunks(session) -> None:
    account = _connected_account(session)
    client = FakePagedGoogleHealthClient()

    result = await sync_google_account_range(
        session,
        account=account,
        start=date(2026, 6, 16),
        end=date(2026, 6, 18),
        data_types=("heart-rate",),
        client=client,
    )

    assert result.records_seen == 3
    assert result.data_types == ["heart-rate"]
    assert len(client.calls) == 3
    assert {call["page_size"] for call in client.calls} == {10000}
    assert {call["prefer_reconcile"] for call in client.calls} == {True}
    assert client.calls[0]["filter_expr"] == (
        'heart_rate.sample_time.physical_time >= "2026-06-16T00:00:00Z" '
        'AND heart_rate.sample_time.physical_time < "2026-06-17T00:00:00Z"'
    )

    samples = session.scalars(select(MetricSample).where(MetricSample.metric == "heart_rate")).all()
    assert len(samples) == 3


@pytest.mark.asyncio
async def test_sync_resumes_from_saved_page_token(session) -> None:
    account = _connected_account(session)
    cursor = SyncCursor(
        google_account_id=account.id,
        data_type="heart-rate",
        status=SyncStatus.running,
        last_successful_start=date(2026, 6, 18),
        last_successful_end=date(2026, 6, 18),
        last_page_token="page-2",
    )
    session.add(cursor)
    session.commit()
    client = FakeResumeGoogleHealthClient()

    await sync_google_account_range(
        session,
        account=account,
        start=date(2026, 6, 18),
        end=date(2026, 6, 18),
        data_types=("heart-rate",),
        client=client,
    )

    assert client.page_tokens == ["page-2"]


@pytest.mark.asyncio
async def test_sync_resume_skips_prior_completed_chunks(session) -> None:
    account = _connected_account(session)
    cursor = SyncCursor(
        google_account_id=account.id,
        data_type="heart-rate",
        status=SyncStatus.running,
        last_successful_start=date(2026, 6, 17),
        last_successful_end=date(2026, 6, 17),
        last_page_token="page-2",
    )
    session.add(cursor)
    session.commit()
    client = FakeResumeGoogleHealthClient()

    await sync_google_account_range(
        session,
        account=account,
        start=date(2026, 6, 16),
        end=date(2026, 6, 18),
        data_types=("heart-rate",),
        client=client,
    )

    assert client.page_tokens == ["page-2", None]
    assert client.filters == [
        'heart_rate.sample_time.physical_time >= "2026-06-17T00:00:00Z" '
        'AND heart_rate.sample_time.physical_time < "2026-06-18T00:00:00Z"',
        'heart_rate.sample_time.physical_time >= "2026-06-18T00:00:00Z" '
        'AND heart_rate.sample_time.physical_time < "2026-06-19T00:00:00Z"',
    ]


@pytest.mark.asyncio
async def test_daily_zone_sync_ignores_saved_page_token(session) -> None:
    account = _connected_account(session)
    cursor = SyncCursor(
        google_account_id=account.id,
        data_type="daily-heart-rate-zones",
        status=SyncStatus.running,
        last_successful_start=date(2026, 6, 5),
        last_successful_end=date(2026, 6, 18),
        last_page_token="old-page-token",
    )
    session.add(cursor)
    session.commit()
    client = FakeResumeGoogleHealthClient()

    await sync_google_account_range(
        session,
        account=account,
        start=date(2026, 6, 5),
        end=date(2026, 6, 18),
        data_types=("daily-heart-rate-zones",),
        client=client,
    )

    assert client.page_tokens == [None]
    assert client.page_sizes == [10000]
    assert client.filters == [
        'daily_heart_rate_zones.date >= "2026-06-05" '
        'AND daily_heart_rate_zones.date < "2026-06-19"'
    ]


@pytest.mark.asyncio
async def test_sync_discards_daily_points_outside_requested_range(session) -> None:
    account = _connected_account(session)

    result = await sync_google_account_range(
        session,
        account=account,
        start=date(2026, 6, 18),
        end=date(2026, 6, 18),
        data_types=("daily-heart-rate-zones",),
        client=FakeOutOfRangeDailyZonesClient(),
    )

    assert result.records_seen == 2
    assert result.records_stored == 1
    raw_records = session.scalars(select(RawHealthRecord)).all()
    assert len(raw_records) == 1
    assert raw_records[0].civil_date == date(2026, 6, 18)


@pytest.mark.asyncio
async def test_session_sync_uses_google_session_page_cap(session) -> None:
    account = _connected_account(session)
    client = FakeResumeGoogleHealthClient()

    await sync_google_account_range(
        session,
        account=account,
        start=date(2026, 6, 5),
        end=date(2026, 6, 18),
        data_types=("sleep", "exercise"),
        client=client,
    )

    assert client.page_sizes == [25, 25]


@pytest.mark.asyncio
async def test_heart_rate_failure_does_not_block_other_data_types(session) -> None:
    account = _connected_account(session)

    result = await sync_google_account_range(
        session,
        account=account,
        start=date(2026, 6, 18),
        end=date(2026, 6, 18),
        data_types=("heart-rate", "steps"),
        client=FakeHeartRateFailureClient(),
    )

    assert result.data_types == ["steps"]
    assert session.scalar(select(MetricInterval).where(MetricInterval.metric == "steps")).value == 100

    heart_rate_cursor = session.scalar(
        select(SyncCursor).where(
            SyncCursor.google_account_id == account.id,
            SyncCursor.data_type == "heart-rate",
        )
    )
    assert heart_rate_cursor.status.value == "failed"
    assert "timed out" in heart_rate_cursor.last_error

    steps_cursor = session.scalar(
        select(SyncCursor).where(
            SyncCursor.google_account_id == account.id,
            SyncCursor.data_type == "steps",
        )
    )
    assert steps_cursor.status.value == "succeeded"
    assert session.get(GoogleAccount, account.id).status == ConnectionStatus.connected


@pytest.mark.asyncio
async def test_initial_backfill_is_limited_to_fourteen_days(session, monkeypatch) -> None:
    account = _connected_account(session)
    captured: dict[str, date] = {}

    async def fake_sync_google_account_range(
        session,
        *,
        account,
        start: date,
        end: date,
        data_types=None,
        client=None,
    ):
        captured["start"] = start
        captured["end"] = end
        return None

    monkeypatch.setattr("app.services.sync.sync_google_account_range", fake_sync_google_account_range)

    await run_initial_backfill(session, account=account)

    assert captured["end"] - captured["start"] == timedelta(days=13)
