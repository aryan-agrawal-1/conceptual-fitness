from __future__ import annotations

from datetime import date, datetime, timedelta

import pytest
from sqlalchemy import select

from app.models import (
    DailyBaseline,
    ConnectionStatus,
    DailySummary,
    HealthConnection,
    MetricSample,
    RawHealthRecord,
    SleepSession,
)
from app.services.apple_health_mapping import (
    rebuild_apple_health_derived,
)
from app.services.health_dates import get_or_create_profile
from app.services.score_baselines import rebuild_daily_baselines
from app.services.summaries import rebuild_daily_summaries
from app.tasks import sync as sync_tasks
from tests.test_device_uploads import connected, rebuilds  # noqa: F401

pytestmark = pytest.mark.usefixtures("rebuilds")

RESTING_HR = "HKQuantityTypeIdentifierRestingHeartRate"
SDNN = "HKQuantityTypeIdentifierHeartRateVariabilitySDNN"
RESPIRATORY_RATE = "HKQuantityTypeIdentifierRespiratoryRate"
OXYGEN = "HKQuantityTypeIdentifierOxygenSaturation"
WRIST_TEMPERATURE = "HKQuantityTypeIdentifierAppleSleepingWristTemperature"
BODY_MASS = "HKQuantityTypeIdentifierBodyMass"
SLEEP = "HKCategoryTypeIdentifierSleepAnalysis"
WATCH = {"name": "Apple Watch", "device_name": "Apple Watch", "product_type": "Watch7,1"}
PHONE = {"name": "iPhone", "device_name": "iPhone", "product_type": "iPhone17,1"}


def at(value: str) -> datetime:
    return datetime.fromisoformat(value)


def reading(record_id, start, value, unit, *, minutes=1, source=WATCH, **extra) -> dict:
    begin = at(start)
    return {
        "id": record_id,
        "start": begin.isoformat(),
        "end": (begin + timedelta(minutes=minutes)).isoformat(),
        "value": value,
        "unit": unit,
        "source": source,
    } | extra


def stage(record_id, start, minutes, category_value, source=WATCH) -> dict:
    begin = at(start)
    return {
        "id": record_id,
        "start": begin.isoformat(),
        "end": (begin + timedelta(minutes=minutes)).isoformat(),
        "category_value": category_value,
        "source": source,
    }


def upload(client, data_type, samples, *, start="2026-11-01", end="2026-11-10", deleted_ids=()) -> None:
    response = client.post(
        "/ingest/apple-health/batches",
        json={
            "data_type": data_type,
            "phase": "current",
            "range_start": start,
            "range_end": end,
            "samples": samples,
            "deleted_ids": list(deleted_ids),
            "final": True,
        },
    )
    assert response.status_code == 200, response.text


def night(prefix: str, bedtime: str, *, unspecified: bool = False) -> list[dict]:
    begin = at(bedtime)
    plan = [(1, 30)] * 3 if unspecified else [(3, 60), (4, 45), (2, 10), (5, 50), (3, 90)]
    segments = [stage(f"{prefix}-bed", bedtime, 300, 0)]
    for index, (value, minutes) in enumerate(plan):
        segments.append(stage(f"{prefix}-{index}", begin.isoformat(), minutes, value))
        begin += timedelta(minutes=minutes)
    return segments


def test_watch_vitals_become_metric_samples_in_score_units(session) -> None:
    client, user = connected(session)
    upload(client, RESTING_HR, [reading("R1", "2026-11-09T08:00:00+00:00", 52, "count/min")])
    upload(client, OXYGEN, [reading("O1", "2026-11-09T02:00:00+00:00", 0.96, "%")])
    upload(client, SDNN, [reading("H1", "2026-11-09T02:00:00+00:00", 41, "ms")])
    upload(client, BODY_MASS, [reading("B1", "2026-11-09T07:00:00+00:00", 71.5, "kg", source=PHONE)])

    samples = {item.metric: item for item in session.scalars(select(MetricSample).where(MetricSample.user_id == user.id))}

    assert samples["resting_heart_rate"].value == 52
    assert samples["resting_heart_rate"].unit == "bpm"
    assert samples["oxygen_saturation"].value == 96
    assert samples["heart_rate_variability"].measurement_type == "sdnn"
    assert samples["weight"].value == 71.5
    assert {item.source_platform for item in samples.values()} == {"APPLE_HEALTH"}


def test_readings_from_other_sources_or_units_are_kept_raw_but_not_scored(session) -> None:
    client, user = connected(session)
    upload(
        client,
        RESTING_HR,
        [
            reading("R1", "2026-11-09T08:00:00+00:00", 52, "count/min", source=PHONE),
            reading("R2", "2026-11-09T09:00:00+00:00", 0.9, "count/s"),
        ],
    )

    assert session.scalars(select(MetricSample).where(MetricSample.user_id == user.id)).all() == []
    assert len(session.scalars(select(RawHealthRecord).where(RawHealthRecord.user_id == user.id)).all()) == 2


def test_a_changed_reading_replaces_its_metric_sample(session) -> None:
    client, user = connected(session)
    upload(client, RESTING_HR, [reading("R1", "2026-11-09T08:00:00+00:00", 52, "count/min")])
    upload(client, RESTING_HR, [reading("R1", "2026-11-09T08:00:00+00:00", 54, "count/min")])

    values = session.scalars(select(MetricSample.value).where(MetricSample.user_id == user.id)).all()

    assert values == [54]


def test_stage_segments_become_one_main_sleep_session_dated_by_wake(session) -> None:
    client, user = connected(session)
    nap = [stage("nap-0", "2026-11-09T14:00:00+00:00", 25, 3)]
    upload(client, SLEEP, night("n1", "2026-11-08T23:00:00+00:00") + nap)

    rebuild_apple_health_derived(session, user_id=user.id, start=date(2026, 11, 9), end=date(2026, 11, 9))
    sleeps = session.scalars(select(SleepSession).where(SleepSession.user_id == user.id)).all()
    main = next(sleep for sleep in sleeps if sleep.is_main_sleep)

    assert len(sleeps) == 2
    assert main.civil_date == date(2026, 11, 9)
    assert main.minutes_asleep == 245
    assert main.minutes_awake == 10
    assert main.minutes_in_sleep_period == 255
    assert [item["type"] for item in main.stages] == ["light", "deep", "awake", "rem", "light"]
    assert {item["type"]: item["minutes"] for item in main.stages_summary}["light"] == 150


def test_unstaged_sleep_keeps_stages_unknown(session) -> None:
    client, user = connected(session)
    upload(client, SLEEP, night("n1", "2026-11-08T23:00:00+00:00", unspecified=True))

    rebuild_apple_health_derived(session, user_id=user.id, start=date(2026, 11, 9), end=date(2026, 11, 9))
    sleep = session.scalar(select(SleepSession).where(SleepSession.user_id == user.id))

    assert sleep.minutes_asleep == 90
    assert sleep.stages == [] and sleep.stages_summary == []


def test_deleting_a_segment_rebuilds_the_session(session) -> None:
    client, user = connected(session)
    upload(client, SLEEP, night("n1", "2026-11-08T23:00:00+00:00"))
    upload(client, SLEEP, [], deleted_ids=["n1-4"])

    sync_tasks.rebuild_scores(user.id, "2026-11-09", "2026-11-09")
    session.expire_all()
    sleep = session.scalar(select(SleepSession).where(SleepSession.user_id == user.id))

    assert sleep.minutes_asleep == 155
    assert len(sleep.stages) == 4


def test_nightly_vitals_use_the_main_sleep_window_only(session) -> None:
    client, user = connected(session)
    upload(client, SLEEP, night("n1", "2026-11-08T23:00:00+00:00"))
    upload(
        client,
        SDNN,
        [
            reading("H1", "2026-11-08T23:30:00+00:00", 30, "ms"),
            reading("H2", "2026-11-09T01:30:00+00:00", 50, "ms"),
            reading("H3", "2026-11-09T03:00:00+00:00", 44, "ms"),
            reading("H4", "2026-11-09T15:00:00+00:00", 90, "ms"),
        ],
    )
    upload(
        client,
        RESPIRATORY_RATE,
        [
            reading("B1", "2026-11-08T23:40:00+00:00", 14, "count/min"),
            reading("B2", "2026-11-09T02:40:00+00:00", 16, "count/min"),
            reading("B3", "2026-11-09T12:00:00+00:00", 22, "count/min"),
        ],
    )
    upload(client, OXYGEN, [reading("O1", "2026-11-09T12:00:00+00:00", 0.99, "%")])

    sync_tasks.rebuild_scores(user.id, "2026-11-09", "2026-11-09")
    session.expire_all()
    summary = session.scalar(
        select(DailySummary).where(DailySummary.user_id == user.id, DailySummary.summary_date == date(2026, 11, 9))
    )

    assert summary.hrv_sdnn == 44
    assert summary.heart_rate_variability_type == "sdnn"
    assert summary.heart_rate_variability == 44
    assert summary.respiratory_rate == 15
    assert summary.oxygen_saturation is None


def test_wrist_temperature_becomes_variation_from_a_personal_rolling_median(session) -> None:
    client, user = connected(session)
    temperatures = [35.0, 35.2, 34.8, 35.1, 34.9, 35.6]
    upload(
        client,
        WRIST_TEMPERATURE,
        [
            reading(f"T{index}", f"2026-11-0{index + 1}T23:00:00+00:00", value, "degC", minutes=420)
            for index, value in enumerate(temperatures)
        ],
    )

    rebuild_apple_health_derived(session, user_id=user.id, start=date(2026, 11, 1), end=date(2026, 11, 7))
    variations = session.scalars(
        select(MetricSample).where(
            MetricSample.user_id == user.id, MetricSample.metric == "skin_temperature_variation"
        )
    ).all()

    assert len(variations) == 1
    assert variations[0].civil_date == date(2026, 11, 7)
    assert round(variations[0].value, 3) == 0.6


def test_apple_temperature_reference_is_not_re_centred(session) -> None:
    client, user = connected(session)
    upload(
        client,
        WRIST_TEMPERATURE,
        [
            reading(f"T{day}", f"2026-10-{day:02d}T23:00:00+00:00", 35.4 if day % 2 else 35.0, "degC", minutes=420)
            for day in range(1, 31)
        ],
        start="2026-10-01",
        end="2026-10-31",
    )
    upload(
        client,
        RESTING_HR,
        [reading(f"R{day}", f"2026-10-{day:02d}T08:00:00+00:00", 50, "count/min") for day in range(1, 32)],
        start="2026-10-01",
        end="2026-10-31",
    )
    rebuild_apple_health_derived(session, user_id=user.id, start=date(2026, 10, 1), end=date(2026, 10, 31))
    rebuild_daily_summaries(session, user_id=user.id, start=date(2026, 10, 1), end=date(2026, 10, 31))

    profile = get_or_create_profile(session, user.id)
    rebuild_daily_baselines(session, user_id=user.id, profile=profile, baseline_date=date(2026, 11, 1))
    baseline = session.scalar(
        select(DailyBaseline).where(
            DailyBaseline.user_id == user.id, DailyBaseline.metric == "skin_temperature_variation"
        )
    )

    assert baseline.median_value == 0
    assert baseline.metadata_json["reference_centre_fixed"] is True
    assert baseline.lower_bound == -baseline.upper_bound


def test_switching_to_apple_watch_restarts_device_measured_baselines(session) -> None:
    client, user = connected(session)
    fitbit = HealthConnection(user_id=user.id, provider="google_health", status=ConnectionStatus.disconnected)
    session.add(fitbit)
    session.flush()
    for day in range(1, 11):
        raw = RawHealthRecord(
            user_id=user.id,
            connection_id=fitbit.id,
            data_type="daily-resting-heart-rate",
            source_record_id=f"fitbit-{day}",
            raw_json={},
            content_hash=f"fitbit-{day}",
            source_platform="FITBIT",
        )
        session.add(raw)
        session.flush()
        session.add(
            MetricSample(
                user_id=user.id,
                raw_record_id=raw.id,
                metric="resting_heart_rate",
                observed_at=at(f"2026-10-{day:02d}T08:00:00+00:00"),
                civil_date=date(2026, 10, day),
                value=60,
                unit="bpm",
                source_platform="FITBIT",
            )
        )
    session.commit()
    upload(
        client,
        RESTING_HR,
        [reading(f"R{day}", f"2026-10-{day:02d}T08:00:00+00:00", 50, "count/min") for day in range(11, 21)],
        start="2026-10-11",
        end="2026-10-20",
    )
    rebuild_daily_summaries(session, user_id=user.id, start=date(2026, 10, 1), end=date(2026, 10, 20))

    profile = get_or_create_profile(session, user.id)
    rebuild_daily_baselines(session, user_id=user.id, profile=profile, baseline_date=date(2026, 10, 21))
    baselines = {
        item.metric: item
        for item in session.scalars(select(DailyBaseline).where(DailyBaseline.user_id == user.id))
    }

    assert baselines["resting_heart_rate"].valid_day_count == 10
    assert baselines["resting_heart_rate"].median_value == 50
    assert "APPLE_HEALTH" in baselines["resting_heart_rate"].metadata_json["source"]
    assert baselines["strain_load"].metadata_json["source"] != baselines["resting_heart_rate"].metadata_json["source"]
