from __future__ import annotations

from datetime import UTC, date, datetime, timedelta

from sqlalchemy import select

from app.models import (
    DailySummary,
    GoogleAccount,
    MetricDailyRollup,
    MetricHourlyRollup,
    MetricInterval,
    MetricSample,
    RawHealthRecord,
    SleepSession,
    User,
    UserProfile,
)
from app.services.metric_rollups import (
    STEP_HOURLY_RETENTION_DAYS,
    HighVolumeRecord,
    cleanup_high_volume_storage,
    replace_high_volume_rollups,
)
from app.services.normalization import _content_hash, upsert_raw_and_normalized
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


def test_upsert_merges_legacy_hash_record_when_data_point_name_exists(session) -> None:
    account = _account(session)
    data_point = {
        "dataPointName": "users/me/dataTypes/sleep/dataPoints/legacy-1",
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
            },
            "metadata": {},
            "stages": [],
        },
    }
    raw_hash = _content_hash(data_point)
    session.add(
        RawHealthRecord(
            user_id=account.user_id,
            google_account_id=account.id,
            data_type="sleep",
            source_record_id=f"sleep:{raw_hash}",
            raw_json=data_point,
            content_hash=raw_hash,
        )
    )
    session.flush()

    upsert_raw_and_normalized(session, account=account, data_type="sleep", data_point=data_point)
    session.commit()

    raw_records = session.scalars(select(RawHealthRecord)).all()
    sleeps = session.scalars(select(SleepSession)).all()
    assert len(raw_records) == 1
    assert raw_records[0].source_record_id == data_point["dataPointName"]
    assert len(sleeps) == 1
    assert sleeps[0].minutes_asleep == 430


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


def test_normalizes_distance_millimeters_to_meters(session) -> None:
    account = _account(session)
    data_point = {
        "name": "users/me/dataTypes/distance/dataPoints/1",
        "dataSource": {"platform": "HEALTH_KIT"},
        "distance": {
            "interval": {
                "startTime": "2026-06-15T08:00:00Z",
                "endTime": "2026-06-15T08:05:00Z",
                "civilStartTime": {"date": {"year": 2026, "month": 6, "day": 15}},
            },
            "millimeters": "123456",
        },
    }

    upsert_raw_and_normalized(
        session,
        account=account,
        data_type="distance",
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
    assert interval.metric == "distance"
    assert interval.value == 123.456
    assert interval.unit == "meters"

    summary = session.scalar(select(DailySummary))
    assert summary.distance_meters == 123.456


def test_daily_summary_prefers_fitbit_activity_totals(session) -> None:
    account = _account(session)
    observed_at = datetime(2026, 6, 15, 8, tzinfo=UTC)
    for metric, unit, fitbit_value, healthkit_value in (
        ("steps", "count", 1200, 800),
        ("distance", "meters", 1500, 1000),
        ("active_calories", "kcal", 220, 110),
    ):
        session.add(
            MetricInterval(
                user_id=account.user_id,
                metric=metric,
                start_time=observed_at,
                end_time=observed_at,
                civil_date=date(2026, 6, 15),
                value=fitbit_value,
                unit=unit,
                source_platform="FITBIT",
            )
        )
        session.add(
            MetricInterval(
                user_id=account.user_id,
                metric=metric,
                start_time=observed_at,
                end_time=observed_at,
                civil_date=date(2026, 6, 15),
                value=healthkit_value,
                unit=unit,
                source_platform="HEALTH_KIT",
            )
        )

    rebuild_daily_summaries(
        session,
        user_id=account.user_id,
        start=date(2026, 6, 15),
        end=date(2026, 6, 15),
    )
    session.commit()

    summary = session.scalar(select(DailySummary))
    assert summary.steps == 1200
    assert summary.distance_meters == 1500
    assert summary.active_calories == 220


def test_high_volume_daily_rollups_prefer_fitbit_activity_totals(session) -> None:
    account = _account(session)
    day = date(2026, 6, 15)
    start = datetime(2026, 6, 15, 8, tzinfo=UTC)
    end = datetime(2026, 6, 15, 8, 5, tzinfo=UTC)

    for metric, unit, fitbit_value, healthkit_value in (
        ("steps", "count", 1200, 800),
        ("distance", "meters", 1500, 1000),
        ("active_calories", "kcal", 220, 110),
    ):
        replace_high_volume_rollups(
            session,
            account=account,
            metric=metric,
            records=[
                HighVolumeRecord(
                    data_type=metric,
                    metric=metric,
                    value=fitbit_value,
                    unit=unit,
                    source_platform="FITBIT",
                    source_device=None,
                    civil_date=day,
                    start_time=start,
                    end_time=end,
                ),
                HighVolumeRecord(
                    data_type=metric,
                    metric=metric,
                    value=healthkit_value,
                    unit=unit,
                    source_platform="HEALTH_KIT",
                    source_device=None,
                    civil_date=day,
                    start_time=start,
                    end_time=end,
                ),
            ],
            range_start=start,
            range_end=end,
        )

    rebuild_daily_summaries(session, user_id=account.user_id, start=day, end=day)
    session.commit()

    rollups = {
        row.metric: row
        for row in session.scalars(select(MetricDailyRollup)).all()
    }
    assert rollups["steps"].sum_value == 1200
    assert rollups["distance"].sum_value == 1500
    assert rollups["active_calories"].sum_value == 220

    summary = session.scalar(select(DailySummary))
    assert summary.steps == 1200
    assert summary.distance_meters == 1500
    assert summary.active_calories == 220


def test_steps_high_volume_rollups_store_hourly_buckets_with_source_priority(session) -> None:
    account = _account(session)
    day = date(2026, 6, 15)

    replace_high_volume_rollups(
        session,
        account=account,
        metric="steps",
        records=[
            HighVolumeRecord(
                data_type="steps",
                metric="steps",
                value=1200,
                unit="count",
                source_platform="FITBIT",
                source_device=None,
                civil_date=day,
                start_time=datetime(2026, 6, 15, 8, 30, tzinfo=UTC),
                end_time=datetime(2026, 6, 15, 10, 30, tzinfo=UTC),
            ),
            HighVolumeRecord(
                data_type="steps",
                metric="steps",
                value=800,
                unit="count",
                source_platform="HEALTH_KIT",
                source_device=None,
                civil_date=day,
                start_time=datetime(2026, 6, 15, 8, 30, tzinfo=UTC),
                end_time=datetime(2026, 6, 15, 10, 30, tzinfo=UTC),
            ),
            HighVolumeRecord(
                data_type="steps",
                metric="steps",
                value=200,
                unit="count",
                source_platform="HEALTH_KIT",
                source_device=None,
                civil_date=day,
                start_time=datetime(2026, 6, 15, 11, tzinfo=UTC),
                end_time=datetime(2026, 6, 15, 12, tzinfo=UTC),
            ),
        ],
        range_start=datetime(2026, 6, 15, tzinfo=UTC),
        range_end=datetime(2026, 6, 16, tzinfo=UTC),
    )
    session.commit()

    hourly = session.scalars(
        select(MetricHourlyRollup)
        .where(MetricHourlyRollup.metric == "steps")
        .order_by(MetricHourlyRollup.bucket_start)
    ).all()
    assert [(row.bucket_start.hour, row.sum_value, row.source_platform) for row in hourly] == [
        (8, 300, "FITBIT"),
        (9, 600, "FITBIT"),
        (10, 300, "FITBIT"),
        (11, 200, "HEALTH_KIT"),
    ]

    daily = session.scalar(select(MetricDailyRollup).where(MetricDailyRollup.metric == "steps"))
    assert daily is not None
    assert daily.sum_value == 1400


def test_cleanup_high_volume_storage_retains_recent_hourly_steps(session) -> None:
    account = _account(session)
    today = date(2026, 6, 15)
    old_day = today - timedelta(days=STEP_HOURLY_RETENTION_DAYS + 1)
    kept_day = today - timedelta(days=STEP_HOURLY_RETENTION_DAYS)

    for metric, day in (("steps", old_day), ("steps", kept_day), ("distance", today)):
        session.add(
            MetricHourlyRollup(
                user_id=account.user_id,
                metric=metric,
                bucket_start=datetime.combine(day, datetime.min.time(), tzinfo=UTC),
                civil_date=day,
                sum_value=100,
                sample_count=1,
                unit="count",
            )
        )
    session.commit()

    counts = cleanup_high_volume_storage(session, today=today)
    session.commit()

    remaining = session.scalars(
        select(MetricHourlyRollup).order_by(MetricHourlyRollup.metric, MetricHourlyRollup.civil_date)
    ).all()
    assert counts["metric_hourly_rollups"] == 2
    assert [(row.metric, row.civil_date) for row in remaining] == [("steps", kept_day)]


def test_daily_summary_prefers_daily_derived_samples(session) -> None:
    account = _account(session)
    day = date(2026, 6, 15)
    raw_daily = RawHealthRecord(
        user_id=account.user_id,
        google_account_id=account.id,
        data_type="daily-oxygen-saturation",
        source_record_id="daily-spo2-1",
        civil_date=day,
        raw_json={},
        content_hash="daily-spo2-1",
    )
    raw_intraday = RawHealthRecord(
        user_id=account.user_id,
        google_account_id=account.id,
        data_type="oxygen-saturation",
        source_record_id="spo2-1",
        civil_date=day,
        raw_json={},
        content_hash="spo2-1",
    )
    session.add_all([raw_daily, raw_intraday])
    session.flush()
    session.add(
        MetricSample(
            user_id=account.user_id,
            raw_record_id=raw_intraday.id,
            metric="oxygen_saturation",
            observed_at=datetime(2026, 6, 15, 1, tzinfo=UTC),
            civil_date=day,
            value=50,
            unit="percent",
        )
    )
    session.add(
        MetricSample(
            user_id=account.user_id,
            raw_record_id=raw_daily.id,
            metric="oxygen_saturation",
            observed_at=datetime(2026, 6, 15, tzinfo=UTC),
            civil_date=day,
            value=96.4,
            unit="percent",
        )
    )

    rebuild_daily_summaries(session, user_id=account.user_id, start=day, end=day)
    session.commit()

    summary = session.scalar(select(DailySummary))
    assert summary.oxygen_saturation == 96.4


def test_unchanged_raw_record_with_missing_normalized_row_is_rebuilt(session) -> None:
    account = _account(session)
    day = date(2026, 6, 15)
    data_point = {
        "dataSource": {"platform": "FITBIT"},
        "dailyOxygenSaturation": {
            "date": {"year": day.year, "month": day.month, "day": day.day},
            "averagePercentage": 96.6,
            "lowerBoundPercentage": 94,
            "upperBoundPercentage": 100,
        },
    }

    raw_record = upsert_raw_and_normalized(
        session,
        account=account,
        data_type="daily-oxygen-saturation",
        data_point=data_point,
    )
    session.flush()
    sample = session.scalar(select(MetricSample).where(MetricSample.raw_record_id == raw_record.id))
    assert sample is not None
    session.delete(sample)
    session.flush()

    upsert_raw_and_normalized(
        session,
        account=account,
        data_type="daily-oxygen-saturation",
        data_point=data_point,
    )
    session.flush()
    rebuilt = session.scalar(select(MetricSample).where(MetricSample.raw_record_id == raw_record.id))
    assert rebuilt is not None
    assert rebuilt.value == 96.6


def test_normalizes_skin_temperature_variation_from_daily_derivation(session) -> None:
    account = _account(session)
    day = date(2026, 6, 26)
    data_point = {
        "name": "users/me/dataTypes/daily-sleep-temperature-derivations/dailyRollUp/2026-06-26",
        "dataSource": {"platform": "FITBIT"},
        "dailySleepTemperatureDerivations": {
            "date": {"year": day.year, "month": day.month, "day": day.day},
            "nightlyTemperatureCelsius": 34.5008,
            "baselineTemperatureCelsius": 34.39593679458238,
            "relativeNightlyStddev30dCelsius": 0.7109127654436406,
        },
    }

    raw_record = upsert_raw_and_normalized(
        session,
        account=account,
        data_type="daily-sleep-temperature-derivations",
        data_point=data_point,
    )
    session.flush()

    sample = session.scalar(select(MetricSample).where(MetricSample.raw_record_id == raw_record.id))
    assert sample is not None
    assert sample.metric == "skin_temperature_variation"
    assert sample.civil_date == day
    assert sample.observed_at.date() == day
    assert sample.value == 34.5008 - 34.39593679458238
    assert sample.unit == "celsius"


def test_normalizes_body_metrics_and_updates_profile(session) -> None:
    account = _account(session)
    session.add(UserProfile(user_id=account.user_id, timezone="UTC", sleep_target_minutes=480))
    height_point = {
        "name": "users/me/dataTypes/height/dataPoints/1",
        "dataSource": {"platform": "FITBIT"},
        "height": {
            "sampleTime": {
                "physicalTime": "2026-06-15T08:00:00Z",
                "civilTime": {"date": {"year": 2026, "month": 6, "day": 15}},
            },
            "heightMillimeters": "1810",
        },
    }
    weight_point = {
        "name": "users/me/dataTypes/weight/dataPoints/1",
        "dataSource": {"platform": "FITBIT"},
        "weight": {
            "sampleTime": {
                "physicalTime": "2026-06-15T08:05:00Z",
                "civilTime": {"date": {"year": 2026, "month": 6, "day": 15}},
            },
            "weightKilograms": "78.5",
        },
    }

    upsert_raw_and_normalized(session, account=account, data_type="height", data_point=height_point)
    upsert_raw_and_normalized(session, account=account, data_type="weight", data_point=weight_point)
    rebuild_daily_summaries(
        session,
        user_id=account.user_id,
        start=date(2026, 6, 15),
        end=date(2026, 6, 15),
    )
    session.commit()

    samples = session.scalars(select(MetricSample).order_by(MetricSample.metric)).all()
    assert [(sample.metric, sample.value, sample.unit) for sample in samples] == [
        ("height", 1.81, "meters"),
        ("weight", 78.5, "kg"),
    ]

    profile = session.scalar(select(UserProfile).where(UserProfile.user_id == account.user_id))
    assert profile.height_cm == 181
    assert profile.weight_kg == 78.5
