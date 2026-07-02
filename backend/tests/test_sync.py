from __future__ import annotations

from datetime import UTC, date, datetime, timedelta

import pytest
from fastapi.testclient import TestClient
from sqlalchemy import select

from app.api.routes import sync as sync_routes
from app.core.security import encrypt_secret
from app.google_health.client import GoogleHealthAPIError
from app.google_health.data_types import DATA_TYPE_SPECS, MVP_SYNC_DATA_TYPES
from app.main import app
from app.models import (
    ConnectionStatus,
    GoogleAccount,
    MetricDailyRollup,
    MetricHourlyRollup,
    MetricInterval,
    MetricMinuteRollup,
    MetricSample,
    RawHealthRecord,
    SyncCursor,
    SyncStatus,
    User,
    Workout,
)
from app.services import sync as sync_service
from app.services.sync import (
    SyncResult,
    SyncWindow,
    run_initial_backfill,
    sync_google_account_range,
    sync_window_from_cursors,
)
from app.tasks import sync as sync_tasks


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


class FixedDate(date):
    @classmethod
    def today(cls) -> date:
        return cls(2026, 6, 21)


def _add_success_cursors(
    session,
    account: GoogleAccount,
    cursor_dates: dict[str, date],
) -> None:
    for data_type, cursor_end in cursor_dates.items():
        session.add(
            SyncCursor(
                google_account_id=account.id,
                data_type=data_type,
                status=SyncStatus.succeeded,
                last_successful_start=cursor_end,
                last_successful_end=cursor_end,
            )
        )
    session.commit()


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


class FakeExerciseListClient:
    async def refresh_access_token(self, refresh_token: str) -> dict[str, str]:
        assert refresh_token == "refresh-token"
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
        assert data_type == "exercise"
        assert prefer_reconcile is False
        assert page_size == 25
        assert "2026-06-24" in str(filter_expr)
        yield [
            {
                "dataPointName": "users/me/dataTypes/exercise/dataPoints/keep",
                "exercise": {
                    "interval": {
                        "startTime": "2026-06-24T09:00:00Z",
                        "endTime": "2026-06-24T09:30:00Z",
                        "civilStartTime": {"date": {"year": 2026, "month": 6, "day": 24}},
                    },
                    "displayName": "Walk",
                    "exerciseType": "WALKING",
                },
            }
        ], None


def test_sync_specs_follow_google_page_size_limits() -> None:
    assert DATA_TYPE_SPECS["heart-rate"].page_size == 10000
    assert DATA_TYPE_SPECS["time-in-heart-rate-zone"].page_size == 10000
    assert DATA_TYPE_SPECS["steps"].page_size == 10000
    assert DATA_TYPE_SPECS["heart-rate"].use_timestamp_cursor is True
    assert DATA_TYPE_SPECS["time-in-heart-rate-zone"].use_timestamp_cursor is True
    assert DATA_TYPE_SPECS["active-energy-burned"].use_timestamp_cursor is True
    assert DATA_TYPE_SPECS["sleep"].page_size == 25
    assert DATA_TYPE_SPECS["exercise"].page_size == 25
    assert "weight" in MVP_SYNC_DATA_TYPES
    assert "height" in MVP_SYNC_DATA_TYPES


def test_sync_window_uses_initial_backfill_when_no_cursors(session) -> None:
    account = _connected_account(session)

    window = sync_window_from_cursors(
        session,
        account=account,
        data_types=("steps", "sleep"),
        today=date(2026, 6, 21),
    )

    assert window.start == date(2026, 6, 8)
    assert window.end == date(2026, 6, 21)
    assert window.is_initial_backfill is True


def test_sync_window_uses_oldest_cursor_with_overlap(session) -> None:
    account = _connected_account(session)
    _add_success_cursors(
        session,
        account,
        {
            "steps": date(2026, 6, 20),
            "sleep": date(2026, 6, 18),
        },
    )

    window = sync_window_from_cursors(
        session,
        account=account,
        data_types=("steps", "sleep"),
        today=date(2026, 6, 21),
    )

    assert window.start == date(2026, 6, 17)
    assert window.end == date(2026, 6, 21)
    assert window.is_initial_backfill is False


def test_sync_window_covers_initial_range_for_missing_requested_type(session) -> None:
    account = _connected_account(session)
    _add_success_cursors(session, account, {"steps": date(2026, 6, 20)})

    window = sync_window_from_cursors(
        session,
        account=account,
        data_types=("steps", "sleep"),
        today=date(2026, 6, 21),
    )

    assert window.start == date(2026, 6, 8)
    assert window.end == date(2026, 6, 21)
    assert window.is_initial_backfill is True


def test_sync_window_does_not_initial_backfill_for_known_failed_type(session) -> None:
    account = _connected_account(session)
    _add_success_cursors(session, account, {"steps": date(2026, 6, 20)})
    session.add(
        SyncCursor(
            google_account_id=account.id,
            data_type="nutrition-log",
            status=SyncStatus.failed,
            last_successful_start=None,
            last_successful_end=None,
            last_error="missing scope",
        )
    )
    session.commit()

    window = sync_window_from_cursors(
        session,
        account=account,
        data_types=("steps", "nutrition-log"),
        today=date(2026, 6, 21),
    )

    assert window.start == date(2026, 6, 19)
    assert window.end == date(2026, 6, 21)
    assert window.is_initial_backfill is False


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
    rollups = session.scalars(
        select(MetricMinuteRollup).where(MetricMinuteRollup.metric == "heart_rate")
    ).all()
    assert samples == []
    assert len(rollups) == 3
    assert {rollup.sample_count for rollup in rollups} == {1}

    cursor = session.scalar(
        select(SyncCursor).where(
            SyncCursor.google_account_id == account.id,
            SyncCursor.data_type == "heart-rate",
        )
    )
    cursor.last_successful_start = None
    cursor.last_successful_end = None
    cursor.last_successful_start_at = None
    cursor.last_successful_end_at = None
    session.commit()

    await sync_google_account_range(
        session,
        account=account,
        start=date(2026, 6, 16),
        end=date(2026, 6, 18),
        data_types=("heart-rate",),
        client=FakePagedGoogleHealthClient(),
    )

    rollups_after_resync = session.scalars(
        select(MetricMinuteRollup).where(MetricMinuteRollup.metric == "heart_rate")
    ).all()
    daily_after_resync = session.scalars(
        select(MetricDailyRollup).where(MetricDailyRollup.metric == "heart_rate")
    ).all()
    assert len(rollups_after_resync) == 3
    assert {rollup.sample_count for rollup in rollups_after_resync} == {1}
    assert len(daily_after_resync) == 3
    assert {daily.sample_count for daily in daily_after_resync} == {1}


@pytest.mark.asyncio
async def test_sync_resumes_from_saved_page_token(session) -> None:
    account = _connected_account(session)
    cursor = SyncCursor(
        google_account_id=account.id,
        data_type="heart-rate",
        status=SyncStatus.running,
        last_successful_start=date(2026, 6, 18),
        last_successful_end=date(2026, 6, 18),
        last_successful_start_at=datetime(2026, 6, 18, 0, tzinfo=UTC),
        last_successful_end_at=datetime(2026, 6, 19, 0, tzinfo=UTC),
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
        last_successful_start_at=datetime(2026, 6, 17, 0, tzinfo=UTC),
        last_successful_end_at=datetime(2026, 6, 18, 0, tzinfo=UTC),
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
async def test_incremental_timestamp_sync_uses_hour_overlap(session) -> None:
    account = _connected_account(session)
    for data_type in ("active-energy-burned", "time-in-heart-rate-zone"):
        session.add(
            SyncCursor(
                google_account_id=account.id,
                data_type=data_type,
                status=SyncStatus.succeeded,
                last_successful_start=date(2026, 6, 23),
                last_successful_end=date(2026, 6, 23),
                last_successful_start_at=datetime(2026, 6, 23, 11, tzinfo=UTC),
                last_successful_end_at=datetime(2026, 6, 23, 12, tzinfo=UTC),
            )
        )
    session.commit()
    client = FakeResumeGoogleHealthClient()

    await sync_google_account_range(
        session,
        account=account,
        start=date(2026, 6, 22),
        end=date(2026, 6, 23),
        data_types=("active-energy-burned", "time-in-heart-rate-zone"),
        client=client,
        now=datetime(2026, 6, 23, 15, tzinfo=UTC),
    )

    assert client.filters == [
        'active_energy_burned.interval.civil_start_time >= "2026-06-22T00:00:00" '
        'AND active_energy_burned.interval.civil_start_time < "2026-06-24T00:00:00"',
        'time_in_heart_rate_zone.interval.civil_start_time >= "2026-06-22T00:00:00" '
        'AND time_in_heart_rate_zone.interval.civil_start_time < "2026-06-24T00:00:00"',
    ]
    cursors = session.scalars(
        select(SyncCursor).where(SyncCursor.data_type.in_(("active-energy-burned", "time-in-heart-rate-zone")))
    ).all()
    assert {cursor.last_successful_end for cursor in cursors} == {date(2026, 6, 23)}


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
async def test_exercise_sync_lists_cursor_window_edits_and_prunes_deleted_records(session) -> None:
    account = _connected_account(session)
    session.add(
        SyncCursor(
            google_account_id=account.id,
            data_type="exercise",
            status=SyncStatus.succeeded,
            last_successful_start=date(2026, 6, 24),
            last_successful_end=date(2026, 6, 24),
        )
    )
    kept_raw = RawHealthRecord(
        user_id=account.user_id,
        google_account_id=account.id,
        data_type="exercise",
        source_record_id="users/me/dataTypes/exercise/dataPoints/keep",
        civil_date=date(2026, 6, 24),
        raw_json={"exercise": {"exerciseType": "CARDIO_WORKOUT"}},
        content_hash="keep-old",
    )
    deleted_raw = RawHealthRecord(
        user_id=account.user_id,
        google_account_id=account.id,
        data_type="exercise",
        source_record_id="users/me/dataTypes/exercise/dataPoints/delete",
        civil_date=date(2026, 6, 24),
        raw_json={"exercise": {"exerciseType": "CARDIO_WORKOUT"}},
        content_hash="delete-old",
    )
    session.add_all([kept_raw, deleted_raw])
    session.flush()
    session.add_all(
        [
            Workout(
                user_id=account.user_id,
                raw_record_id=kept_raw.id,
                workout_type="CARDIO_WORKOUT",
                start_time=datetime(2026, 6, 24, 9, tzinfo=UTC),
                end_time=datetime(2026, 6, 24, 9, 30, tzinfo=UTC),
                civil_date=date(2026, 6, 24),
                duration_seconds=1800,
                raw_summary=kept_raw.raw_json["exercise"],
            ),
            Workout(
                user_id=account.user_id,
                raw_record_id=deleted_raw.id,
                workout_type="CARDIO_WORKOUT",
                start_time=datetime(2026, 6, 24, 10, tzinfo=UTC),
                end_time=datetime(2026, 6, 24, 10, 30, tzinfo=UTC),
                civil_date=date(2026, 6, 24),
                duration_seconds=1800,
                raw_summary=deleted_raw.raw_json["exercise"],
            ),
        ]
    )
    session.commit()

    result = await sync_google_account_range(
        session,
        account=account,
        start=date(2026, 6, 24),
        end=date(2026, 6, 25),
        data_types=("exercise",),
        client=FakeExerciseListClient(),
        now=datetime(2026, 6, 25, 12, tzinfo=UTC),
    )

    workouts = session.scalars(select(Workout).where(Workout.user_id == account.user_id)).all()
    raw_records = session.scalars(
        select(RawHealthRecord).where(
            RawHealthRecord.google_account_id == account.id,
            RawHealthRecord.data_type == "exercise",
        )
    ).all()
    assert result.start == date(2026, 6, 24)
    assert len(workouts) == 1
    assert workouts[0].workout_type == "WALKING"
    assert len(raw_records) == 1
    assert raw_records[0].source_record_id == "users/me/dataTypes/exercise/dataPoints/keep"


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
    assert session.scalar(select(MetricInterval).where(MetricInterval.metric == "steps")) is None
    steps_minute_rollups = session.scalars(
        select(MetricMinuteRollup).where(MetricMinuteRollup.metric == "steps")
    ).all()
    assert steps_minute_rollups == []
    steps_hourly_rollups = session.scalars(
        select(MetricHourlyRollup).where(MetricHourlyRollup.metric == "steps")
    ).all()
    assert len(steps_hourly_rollups) == 1
    assert sum(row.sum_value or 0 for row in steps_hourly_rollups) == 100
    steps_daily_rollups = session.scalars(
        select(MetricDailyRollup).where(MetricDailyRollup.metric == "steps")
    ).all()
    assert sum(row.sum_value or 0 for row in steps_daily_rollups) == 100

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
    monkeypatch.setattr(sync_service, "date", FixedDate)

    await run_initial_backfill(session, account=account)

    assert captured["end"] - captured["start"] == timedelta(days=13)


@pytest.mark.asyncio
async def test_initial_backfill_uses_cursor_window_when_account_was_already_synced(
    session,
    monkeypatch,
) -> None:
    account = _connected_account(session)
    _add_success_cursors(
        session,
        account,
        {data_type: date(2026, 6, 20) for data_type in MVP_SYNC_DATA_TYPES},
    )
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
    monkeypatch.setattr(sync_service, "date", FixedDate)

    await run_initial_backfill(session, account=account)

    assert captured["start"] == date(2026, 6, 19)
    assert captured["end"] == date(2026, 6, 21)


def test_sync_all_connected_accounts_uses_cursor_window(session, monkeypatch) -> None:
    account = _connected_account(session)
    _add_success_cursors(
        session,
        account,
        {data_type: date(2026, 6, 20) for data_type in MVP_SYNC_DATA_TYPES},
    )
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

    monkeypatch.setattr(sync_tasks, "sync_google_account_range", fake_sync_google_account_range)
    monkeypatch.setattr(sync_tasks, "date", FixedDate)

    result = sync_tasks.sync_all_connected_accounts()

    assert result["synced"] == [account.id]
    assert result["failed"] == {}
    assert captured["start"] == date(2026, 6, 19)
    assert captured["end"] == date(2026, 6, 21)
    assert result["ranges"][account.id] == {
        "start": "2026-06-19",
        "end": "2026-06-21",
        "is_initial_backfill": False,
    }


def test_sync_all_connected_accounts_skips_fresh_accounts(session, monkeypatch) -> None:
    account = _connected_account(session)
    account.last_sync_at = datetime.now(UTC)
    session.commit()

    async def fail_sync(*args, **kwargs):
        raise AssertionError("fresh accounts should not sync")

    monkeypatch.setattr(sync_tasks, "sync_google_account_range", fail_sync)

    result = sync_tasks.sync_all_connected_accounts()

    assert result["synced"] == []
    assert result["skipped"] == {account.id: "fresh"}
    assert result["failed"] == {}


def test_sync_all_connected_accounts_skips_running_accounts(session, monkeypatch) -> None:
    account = _connected_account(session)
    session.add(
        SyncCursor(
            google_account_id=account.id,
            data_type="steps",
            status=SyncStatus.running,
        )
    )
    session.commit()

    async def fail_sync(*args, **kwargs):
        raise AssertionError("running accounts should not sync")

    monkeypatch.setattr(sync_tasks, "sync_google_account_range", fail_sync)

    result = sync_tasks.sync_all_connected_accounts()

    assert result["synced"] == []
    assert result["skipped"] == {account.id: "already_running"}
    assert result["failed"] == {}


def test_current_sync_skips_fresh_account(session, auth_headers, monkeypatch) -> None:
    account = _connected_account(session)
    account.last_sync_at = datetime.now(UTC)
    session.commit()
    user = session.get(User, account.user_id)

    async def fail_sync(*args, **kwargs):
        raise AssertionError("fresh accounts should not sync")

    monkeypatch.setattr(sync_routes, "sync_google_account_range", fail_sync)

    response = TestClient(app).post("/sync/current", headers=auth_headers(user))

    assert response.status_code == 200
    payload = response.json()
    assert payload["status"] == "skipped_fresh"
    assert payload["account_id"] == account.id
    assert payload["is_fresh"] is True


def test_current_sync_never_synced_account_runs_cursor_window(
    session,
    auth_headers,
    monkeypatch,
) -> None:
    account = _connected_account(session)
    _add_success_cursors(
        session,
        account,
        {data_type: date(2026, 6, 20) for data_type in MVP_SYNC_DATA_TYPES},
    )
    user = session.get(User, account.user_id)
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
        account.last_sync_at = datetime.now(UTC)
        session.add(account)
        session.commit()
        return SyncResult(
            google_account_id=account.id,
            start=start,
            end=end,
            records_seen=3,
            records_stored=2,
            data_types=["steps"],
        )

    monkeypatch.setattr(sync_routes, "sync_google_account_range", fake_sync_google_account_range)
    monkeypatch.setattr(sync_routes, "date", FixedDate)

    response = TestClient(app).post("/sync/current", headers=auth_headers(user))

    assert response.status_code == 200
    payload = response.json()
    assert payload["status"] == "synced"
    assert payload["account_id"] == account.id
    assert payload["records_seen"] == 3
    assert captured["start"] == date(2026, 6, 19)
    assert captured["end"] == date(2026, 6, 21)


def test_current_sync_reports_already_running(session, auth_headers, monkeypatch) -> None:
    account = _connected_account(session)
    session.add(
        SyncCursor(
            google_account_id=account.id,
            data_type="steps",
            status=SyncStatus.running,
        )
    )
    session.commit()
    user = session.get(User, account.user_id)

    async def fail_sync(*args, **kwargs):
        raise AssertionError("running accounts should not sync")

    monkeypatch.setattr(sync_routes, "sync_google_account_range", fail_sync)

    response = TestClient(app).post("/sync/current", headers=auth_headers(user))

    assert response.status_code == 200
    payload = response.json()
    assert payload["status"] == "already_running"
    assert payload["is_running"] is True


def test_current_sync_status_is_scoped_to_current_user(session, auth_headers) -> None:
    account = _connected_account(session)
    other_user = User()
    session.add(other_user)
    session.flush()
    other = GoogleAccount(
        user_id=other_user.id,
        health_user_id="other-health-id",
        legacy_user_id="other-legacy-id",
        granted_scopes=[],
        encrypted_refresh_token=encrypt_secret("refresh-token"),
        status=ConnectionStatus.connected,
    )
    session.add(other)
    session.flush()
    session.add(
        SyncCursor(
            google_account_id=other.id,
            data_type="steps",
            status=SyncStatus.running,
        )
    )
    session.commit()
    user = session.get(User, account.user_id)

    response = TestClient(app).get("/sync/current/status", headers=auth_headers(user))

    assert response.status_code == 200
    payload = response.json()
    assert payload["account_id"] == account.id
    assert payload["is_running"] is False
    assert payload["cursors"] == []


def test_manual_sync_without_dates_uses_cursor_window(session, monkeypatch) -> None:
    account = _connected_account(session)
    session.commit()
    captured: dict[str, object] = {}

    def fake_sync_window_from_cursors(
        session,
        *,
        account,
        data_types,
        today,
    ):
        captured["window_data_types"] = data_types
        return SyncWindow(
            start=date(2026, 6, 17),
            end=date(2026, 6, 21),
            is_initial_backfill=False,
        )

    async def fake_sync_google_account_range(
        session,
        *,
        account,
        start: date,
        end: date,
        data_types,
        client=None,
    ):
        captured["start"] = start
        captured["end"] = end
        captured["data_types"] = data_types
        return SyncResult(
            google_account_id=account.id,
            start=start,
            end=end,
            records_seen=0,
            records_stored=0,
            data_types=list(data_types),
        )

    monkeypatch.setattr(sync_routes, "sync_window_from_cursors", fake_sync_window_from_cursors)
    monkeypatch.setattr(sync_routes, "sync_google_account_range", fake_sync_google_account_range)
    client = TestClient(app)

    response = client.post(
        f"/sync/manual?account_id={account.id}&data_type=steps&data_type=sleep"
    )

    assert response.status_code == 200
    assert captured["start"] == date(2026, 6, 17)
    assert captured["end"] == date(2026, 6, 21)
    assert captured["data_types"] == ("steps", "sleep")
    assert captured["window_data_types"] == ("steps", "sleep")
    assert response.json()["start"] == "2026-06-17"
    assert response.json()["end"] == "2026-06-21"


def test_manual_sync_with_explicit_dates_keeps_requested_range(session, monkeypatch) -> None:
    account = _connected_account(session)
    session.commit()
    captured: dict[str, object] = {}

    async def fake_sync_google_account_range(
        session,
        *,
        account,
        start: date,
        end: date,
        data_types,
        client=None,
    ):
        captured["start"] = start
        captured["end"] = end
        return SyncResult(
            google_account_id=account.id,
            start=start,
            end=end,
            records_seen=0,
            records_stored=0,
            data_types=list(data_types),
        )

    monkeypatch.setattr(sync_routes, "sync_google_account_range", fake_sync_google_account_range)
    client = TestClient(app)

    response = client.post(
        f"/sync/manual?account_id={account.id}&start=2026-06-01&end=2026-06-03"
    )

    assert response.status_code == 200
    assert captured["start"] == date(2026, 6, 1)
    assert captured["end"] == date(2026, 6, 3)
