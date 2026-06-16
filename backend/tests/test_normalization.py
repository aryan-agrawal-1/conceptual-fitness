from __future__ import annotations

from datetime import date

from sqlalchemy import select

from app.models import (
    DailySummary,
    GoogleAccount,
    MetricInterval,
    MetricSample,
    SleepSession,
    User,
)
from app.services.normalization import upsert_raw_and_normalized
from app.services.summaries import rebuild_daily_summaries


def _account(session) -> GoogleAccount:
    user = User()
    session.add(user)
    session.flush()
    account = GoogleAccount(
        user_id=user.id,
        health_user_id="health-id",
        legacy_user_id="legacy-id",
        granted_scopes=[],
    )
    session.add(account)
    session.flush()
    return account


def test_normalizes_interval_and_rebuilds_daily_summary(session) -> None:
    account = _account(session)
    data_point = {
        "name": "users/me/dataTypes/steps/dataPoints/1",
        "dataSource": {"platform": "FITBIT", "device": {"displayName": "Charge 6"}},
        "steps": {
            "interval": {
                "startTime": "2026-06-15T08:00:00Z",
                "endTime": "2026-06-15T08:05:00Z",
                "civilStartTime": {"date": {"year": 2026, "month": 6, "day": 15}},
            },
            "count": "320",
        },
    }

    upsert_raw_and_normalized(session, account=account, data_type="steps", data_point=data_point)
    upsert_raw_and_normalized(session, account=account, data_type="steps", data_point=data_point)
    rebuild_daily_summaries(
        session,
        user_id=account.user_id,
        start=date(2026, 6, 15),
        end=date(2026, 6, 15),
    )
    session.commit()

    intervals = session.scalars(select(MetricInterval)).all()
    assert len(intervals) == 1
    assert intervals[0].value == 320
    assert intervals[0].source_device == "Charge 6"

    summary = session.scalar(select(DailySummary))
    assert summary.steps == 320
    assert summary.data_quality == "weak"


def test_normalizes_sample_and_sleep(session) -> None:
    account = _account(session)
    hrv_point = {
        "name": "users/me/dataTypes/daily-heart-rate-variability/dataPoints/1",
        "dataSource": {"platform": "FITBIT"},
        "dailyHeartRateVariability": {
            "sampleTime": {
                "physicalTime": "2026-06-15T06:00:00Z",
                "civilTime": {"date": {"year": 2026, "month": 6, "day": 15}},
            },
            "milliseconds": "56",
        },
    }
    sleep_point = {
        "name": "users/me/dataTypes/sleep/dataPoints/1",
        "dataSource": {"platform": "FITBIT"},
        "sleep": {
            "interval": {
                "startTime": "2026-06-14T22:30:00Z",
                "endTime": "2026-06-15T06:30:00Z",
                "civilEndTime": {"date": {"year": 2026, "month": 6, "day": 15}},
            },
            "summary": {
                "minutesAsleep": "430",
                "minutesAwake": "50",
                "minutesInSleepPeriod": "480",
                "stagesSummary": [{"type": "REM", "minutes": "90"}],
            },
            "metadata": {"main": True},
            "stages": [],
        },
    }

    upsert_raw_and_normalized(
        session,
        account=account,
        data_type="daily-heart-rate-variability",
        data_point=hrv_point,
    )
    upsert_raw_and_normalized(session, account=account, data_type="sleep", data_point=sleep_point)
    rebuild_daily_summaries(
        session,
        user_id=account.user_id,
        start=date(2026, 6, 15),
        end=date(2026, 6, 15),
    )
    session.commit()

    sample = session.scalar(select(MetricSample))
    assert sample.metric == "heart_rate_variability"
    assert sample.value == 56

    sleep = session.scalar(select(SleepSession))
    assert sleep.minutes_asleep == 430
    assert sleep.is_main_sleep is True

    summary = session.scalar(select(DailySummary))
    assert summary.heart_rate_variability == 56
    assert summary.sleep_minutes == 430

