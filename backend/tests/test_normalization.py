from __future__ import annotations

from datetime import date

from sqlalchemy import select

from app.models import (
    DailySummary,
    GoogleAccount,
    MetricInterval,
    MetricSample,
    RawHealthRecord,
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


def test_normalizes_reconciled_heart_rate_with_data_point_name(session) -> None:
    account = _account(session)
    data_point = {
        "dataPointName": "users/me/dataTypes/heart-rate/dataPoints/reconciled-1",
        "heartRate": {
            "sampleTime": {
                "physicalTime": "2026-06-15T12:00:00Z",
                "civilTime": {"date": {"year": 2026, "month": 6, "day": 15}},
            },
            "beatsPerMinute": "74",
        },
    }

    upsert_raw_and_normalized(
        session,
        account=account,
        data_type="heart-rate",
        data_point=data_point,
    )
    upsert_raw_and_normalized(
        session,
        account=account,
        data_type="heart-rate",
        data_point=data_point,
    )
    session.commit()

    raw_records = session.scalars(select(RawHealthRecord)).all()
    samples = session.scalars(select(MetricSample)).all()
    assert len(raw_records) == 1
    assert raw_records[0].source_record_id == data_point["dataPointName"]
    assert len(samples) == 1
    assert samples[0].metric == "heart_rate"
    assert samples[0].value == 74


def test_normalizes_daily_resting_heart_rate_date_sample(session) -> None:
    account = _account(session)
    data_point = {
        "name": "users/me/dataTypes/daily-resting-heart-rate/dataPoints/2026-06-15",
        "dailyRestingHeartRate": {
            "date": {"year": 2026, "month": 6, "day": 15},
            "beatsPerMinute": "57",
        },
    }

    upsert_raw_and_normalized(
        session,
        account=account,
        data_type="daily-resting-heart-rate",
        data_point=data_point,
    )
    rebuild_daily_summaries(
        session,
        user_id=account.user_id,
        start=date(2026, 6, 15),
        end=date(2026, 6, 15),
    )
    session.commit()

    sample = session.scalar(select(MetricSample))
    assert sample.metric == "resting_heart_rate"
    assert sample.observed_at.date() == date(2026, 6, 15)
    assert sample.civil_date == date(2026, 6, 15)
    assert sample.value == 57

    summary = session.scalar(select(DailySummary))
    assert summary.resting_heart_rate == 57


def test_normalizes_time_in_heart_rate_zone_interval_duration(session) -> None:
    account = _account(session)
    data_point = {
        "name": "users/me/dataTypes/time-in-heart-rate-zone/dataPoints/1",
        "timeInHeartRateZone": {
            "interval": {
                "startTime": "2026-06-15T08:00:00Z",
                "endTime": "2026-06-15T08:20:00Z",
                "civilStartTime": {"date": {"year": 2026, "month": 6, "day": 15}},
            },
            "heartRateZoneType": "VIGOROUS",
        },
    }

    upsert_raw_and_normalized(
        session,
        account=account,
        data_type="time-in-heart-rate-zone",
        data_point=data_point,
    )
    session.commit()

    interval = session.scalar(select(MetricInterval))
    assert interval.metric == "time_in_heart_rate_zone"
    assert interval.value == 1200
    assert interval.unit == "seconds"


def test_normalizes_daily_rollup_interval(session) -> None:
    account = _account(session)
    data_point = {
        "name": "users/me/dataTypes/total-calories/dailyRollUp/2026-06-15",
        "dataSource": {"platform": "GOOGLE_HEALTH_DAILY_ROLLUP"},
        "totalCalories": {
            "interval": {
                "civilStartTime": {
                    "date": {"year": 2026, "month": 6, "day": 15},
                    "time": {},
                },
                "civilEndTime": {
                    "date": {"year": 2026, "month": 6, "day": 15},
                    "time": {"hours": 23, "minutes": 59, "seconds": 59},
                },
            },
            "kcalSum": 2210.5,
        },
    }

    upsert_raw_and_normalized(
        session,
        account=account,
        data_type="total-calories",
        data_point=data_point,
    )
    rebuild_daily_summaries(
        session,
        user_id=account.user_id,
        start=date(2026, 6, 15),
        end=date(2026, 6, 15),
    )
    session.commit()

    interval = session.scalar(select(MetricInterval))
    assert interval.metric == "total_calories"
    assert interval.civil_date == date(2026, 6, 15)
    assert interval.value == 2210.5

    summary = session.scalar(select(DailySummary))
    assert summary.total_calories == 2210.5
