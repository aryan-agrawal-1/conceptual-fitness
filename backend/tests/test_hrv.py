from __future__ import annotations

from datetime import UTC, date, datetime, timedelta
from importlib import import_module

import pytest
from sqlalchemy import select

from app.models import (
    DailyBaseline,
    DailySummary,
    HealthConnection,
    MetricSample,
    SleepSession,
    User,
    UserProfile,
)
from app.services import hrv
from app.services.hrv import RMSSD, SDNN, hrv_measurement, selected_hrv_type
from app.services.normalization import upsert_raw_and_normalized
from app.services.readiness_scores import _autonomic_metric_component
from app.services.score_baselines import rebuild_daily_baselines
from app.services.score_helpers import BASELINE_VERSION
from app.services.summaries import rebuild_daily_summaries

NIGHT = date(2026, 6, 15)


def connection(session) -> HealthConnection:
    user = User()
    session.add(user)
    session.flush()
    session.add(UserProfile(user_id=user.id, timezone="UTC"))
    account = HealthConnection(user_id=user.id, external_user_id="health-id", granted_scopes=[])
    session.add(account)
    session.flush()
    return account


def intraday_point(index: int, when: datetime, platform: str, **fields) -> dict:
    return {
        "name": f"users/me/dataTypes/heart-rate-variability/dataPoints/{index}",
        "dataSource": {"platform": platform},
        "heartRateVariability": {
            "sampleTime": {
                "physicalTime": when.isoformat().replace("+00:00", "Z"),
                "civilTime": {"date": {"year": when.year, "month": when.month, "day": when.day}},
            },
            **fields,
        },
    }


def daily_point(day: date, platform: str = "FITBIT", **fields) -> dict:
    return {
        "name": f"users/me/dataTypes/daily-heart-rate-variability/dataPoints/{day.isoformat()}",
        "dataSource": {"platform": platform},
        "dailyHeartRateVariability": {
            "date": {"year": day.year, "month": day.month, "day": day.day},
            **fields,
        },
    }


def store(session, account, data_type: str, point: dict) -> None:
    upsert_raw_and_normalized(session, account=account, data_type=data_type, data_point=point)


def add_main_sleep(session, account, day: date) -> None:
    session.add(
        SleepSession(
            user_id=account.user_id,
            start_time=datetime.combine(day - timedelta(days=1), datetime.min.time(), UTC) + timedelta(hours=23),
            end_time=datetime.combine(day, datetime.min.time(), UTC) + timedelta(hours=7),
            civil_date=day,
            minutes_asleep=440,
            minutes_in_sleep_period=480,
            is_main_sleep=True,
        )
    )
    session.flush()


def summary_for(session, account, day: date = NIGHT) -> DailySummary:
    rebuild_daily_summaries(session, user_id=account.user_id, start=day, end=day)
    return session.scalar(
        select(DailySummary).where(DailySummary.user_id == account.user_id, DailySummary.summary_date == day)
    )


@pytest.fixture
def health_kit_approved(monkeypatch):
    monkeypatch.setattr(hrv, "APPROVED_HRV_PLATFORMS", {"FITBIT", "HEALTH_KIT"})


@pytest.mark.parametrize(
    ("payload", "expected"),
    [
        ({"rootMeanSquareOfSuccessiveDifferencesMilliseconds": 61.5}, (61.5, RMSSD)),
        ({"standardDeviationMilliseconds": 48}, (48.0, SDNN)),
        ({"averageHeartRateVariabilityMilliseconds": 70.2, "deepSleepRootMeanSquareOfSuccessiveDifferencesMilliseconds": 50}, (70.2, RMSSD)),
        ({"rootMeanSquareOfSuccessiveDifferencesMilliseconds": 60, "standardDeviationMilliseconds": 45}, (60.0, RMSSD)),
        ({"entropy": 3.4, "nonRemHeartRateBeatsPerMinute": "56"}, (None, None)),
    ],
)
def test_hrv_values_come_only_from_named_fields(payload, expected) -> None:
    assert hrv_measurement(payload) == expected


def test_every_stored_hrv_sample_records_its_measurement_type(session) -> None:
    account = connection(session)
    when = datetime(2026, 6, 15, 3, 0, tzinfo=UTC)

    store(session, account, "heart-rate-variability", intraday_point(1, when, "FITBIT", rootMeanSquareOfSuccessiveDifferencesMilliseconds=64.0))
    store(session, account, "heart-rate-variability", intraday_point(2, when, "HEALTH_KIT", standardDeviationMilliseconds=41.0))
    store(session, account, "daily-heart-rate-variability", daily_point(NIGHT, averageHeartRateVariabilityMilliseconds=70.0))
    store(session, account, "daily-heart-rate-variability", daily_point(NIGHT - timedelta(days=1), entropy=3.1))

    samples = session.scalars(select(MetricSample).order_by(MetricSample.value)).all()
    assert [(sample.value, sample.measurement_type) for sample in samples] == [
        (41.0, SDNN),
        (64.0, RMSSD),
        (70.0, RMSSD),
    ]


def test_unapproved_sources_are_kept_but_not_scored(session) -> None:
    account = connection(session)
    when = datetime(2026, 6, 15, 3, 0, tzinfo=UTC)
    add_main_sleep(session, account, NIGHT)
    store(session, account, "heart-rate-variability", intraday_point(1, when, "HEALTH_KIT", rootMeanSquareOfSuccessiveDifferencesMilliseconds=150.0))
    store(session, account, "heart-rate-variability", intraday_point(2, when, "HEALTH_KIT", standardDeviationMilliseconds=140.0))

    summary = summary_for(session, account)

    assert len(session.scalars(select(MetricSample)).all()) == 2
    assert summary.hrv_rmssd is None
    assert summary.hrv_sdnn is None
    assert summary.heart_rate_variability is None
    assert summary.heart_rate_variability_type is None


def test_fitbit_rmssd_is_scored_as_rmssd(session) -> None:
    account = connection(session)
    store(session, account, "daily-heart-rate-variability", daily_point(NIGHT, averageHeartRateVariabilityMilliseconds=70.0))

    summary = summary_for(session, account)

    assert summary.hrv_rmssd == 70.0
    assert summary.heart_rate_variability == 70.0
    assert summary.heart_rate_variability_type == RMSSD


def test_nightly_sdnn_is_the_median_inside_the_main_sleep(session, health_kit_approved) -> None:
    account = connection(session)
    add_main_sleep(session, account, NIGHT)
    night = datetime(2026, 6, 15, 0, 0, tzinfo=UTC)
    for index, (hour, value) in enumerate([(-0.5, 40.0), (2, 44.0), (4, 50.0), (13, 90.0)]):
        store(session, account, "heart-rate-variability", intraday_point(index, night + timedelta(hours=hour), "HEALTH_KIT", standardDeviationMilliseconds=value))

    summary = summary_for(session, account)

    assert summary.hrv_sdnn == 44.0
    assert summary.heart_rate_variability == 44.0
    assert summary.heart_rate_variability_type == SDNN


def test_single_sdnn_sample_in_the_sleep_window_is_the_nightly_value(session, health_kit_approved) -> None:
    account = connection(session)
    add_main_sleep(session, account, NIGHT)
    store(session, account, "heart-rate-variability", intraday_point(1, datetime(2026, 6, 15, 3, tzinfo=UTC), "HEALTH_KIT", standardDeviationMilliseconds=47.0))

    assert summary_for(session, account).hrv_sdnn == 47.0


@pytest.mark.parametrize(
    ("rmssd", "sdnn", "rmssd_nights", "expected"),
    [
        (60.0, None, 0, RMSSD),
        (None, 45.0, 40, SDNN),
        (60.0, 45.0, 27, SDNN),
        (60.0, 45.0, 28, RMSSD),
        (None, None, 40, None),
    ],
)
def test_sdnn_is_scored_until_rmssd_has_calibrated(rmssd, sdnn, rmssd_nights, expected) -> None:
    assert selected_hrv_type(rmssd, sdnn, rmssd_nights) == expected


def test_scoring_switches_to_rmssd_after_28_calibrated_nights(session, health_kit_approved) -> None:
    account = connection(session)
    start = NIGHT - timedelta(days=29)
    for offset in range(30):
        day = start + timedelta(days=offset)
        add_main_sleep(session, account, day)
        store(session, account, "daily-heart-rate-variability", daily_point(day, averageHeartRateVariabilityMilliseconds=60.0))
        store(
            session,
            account,
            "heart-rate-variability",
            intraday_point(offset, datetime.combine(day, datetime.min.time(), UTC) + timedelta(hours=3), "HEALTH_KIT", standardDeviationMilliseconds=45.0),
        )

    rebuild_daily_summaries(session, user_id=account.user_id, start=start, end=NIGHT)
    summaries = session.scalars(
        select(DailySummary).where(DailySummary.user_id == account.user_id).order_by(DailySummary.summary_date)
    ).all()

    assert [item.heart_rate_variability_type for item in summaries] == [SDNN] * 28 + [RMSSD] * 2
    assert [item.heart_rate_variability for item in summaries] == [45.0] * 28 + [60.0] * 2


def test_baselines_are_built_from_the_selected_type_only(session) -> None:
    account = connection(session)
    baseline_day = date(2026, 7, 20)
    for offset in range(1, 21):
        session.add(
            DailySummary(
                user_id=account.user_id,
                summary_date=baseline_day - timedelta(days=offset),
                heart_rate_variability=45.0,
                heart_rate_variability_type=SDNN,
                hrv_sdnn=45.0,
                hrv_rmssd=90.0,
            )
        )
    session.add(
        DailySummary(
            user_id=account.user_id,
            summary_date=baseline_day,
            heart_rate_variability=40.0,
            heart_rate_variability_type=SDNN,
            hrv_sdnn=40.0,
        )
    )
    session.flush()
    profile = session.scalar(select(UserProfile).where(UserProfile.user_id == account.user_id))

    rebuild_daily_baselines(session, user_id=account.user_id, profile=profile, baseline_date=baseline_day)

    baseline = session.scalar(
        select(DailyBaseline).where(
            DailyBaseline.user_id == account.user_id,
            DailyBaseline.metric == "heart_rate_variability",
            DailyBaseline.algorithm_version == BASELINE_VERSION,
        )
    )
    assert round(baseline.median_value, 4) == 45.0
    assert baseline.metadata_json["transform"] == "natural_log_sdnn"
    assert baseline.metadata_json["hrv_measurement_type"] == SDNN
    assert baseline.metadata_json["method"] == "provider_specific_log_sdnn_median_mad"


def test_readiness_never_compares_hrv_across_measurement_types(session) -> None:
    account = connection(session)
    day = NIGHT
    session.add(
        DailySummary(
            user_id=account.user_id,
            summary_date=day,
            heart_rate_variability=60.0,
            heart_rate_variability_type=RMSSD,
            hrv_rmssd=60.0,
        )
    )
    session.add(
        DailyBaseline(
            user_id=account.user_id,
            baseline_date=day,
            metric="heart_rate_variability",
            algorithm_version=BASELINE_VERSION,
            window_days=60,
            valid_day_count=30,
            median_value=45.0,
            spread_value=5.0,
            confidence_phase="personalized",
            metadata_json={"transform": "natural_log_sdnn", "log_spread": 0.1, "hrv_measurement_type": SDNN},
        )
    )
    session.flush()

    assert _autonomic_metric_component(session, account.user_id, day, "heart_rate_variability") is None


def test_migration_types_existing_values_by_their_source_field() -> None:
    migration = import_module("migrations.versions.0031_hrv_measurement_type")

    assert migration.matching_type({"heartRateVariability": {"standardDeviationMilliseconds": 41.0}}, 41.0) == SDNN
    assert migration.matching_type(
        {"heartRateVariability": {"rootMeanSquareOfSuccessiveDifferencesMilliseconds": 60.0, "standardDeviationMilliseconds": 41.0}},
        41.0,
    ) == SDNN
    assert migration.matching_type({"dailyHeartRateVariability": {"averageHeartRateVariabilityMilliseconds": 70.0}}, 70.0) == RMSSD
    assert migration.matching_type({"heartRateVariability": {"entropy": 3.0}}, 3.0) is None


def test_recent_nights_of_the_other_type_do_not_feed_todays_hrv(session) -> None:
    account = connection(session)
    for offset in range(3, -1, -1):
        day = NIGHT - timedelta(days=offset)
        measurement_type = RMSSD if offset == 0 else SDNN
        value = 60.0 if offset == 0 else 30.0
        session.add(
            DailySummary(
                user_id=account.user_id,
                summary_date=day,
                heart_rate_variability=value,
                heart_rate_variability_type=measurement_type,
                hrv_rmssd=value if measurement_type == RMSSD else None,
                hrv_sdnn=value if measurement_type == SDNN else None,
            )
        )
        session.add(
            DailyBaseline(
                user_id=account.user_id,
                baseline_date=day,
                metric="heart_rate_variability",
                algorithm_version=BASELINE_VERSION,
                window_days=60,
                valid_day_count=30,
                median_value=60.0 if measurement_type == RMSSD else 45.0,
                spread_value=5.0,
                confidence_phase="personalized",
                metadata_json={
                    "transform": f"natural_log_{measurement_type}",
                    "log_spread": 0.1,
                    "hrv_measurement_type": measurement_type,
                },
            )
        )
    session.flush()

    component = _autonomic_metric_component(session, account.user_id, NIGHT, "heart_rate_variability")

    assert component["measurement_type"] == RMSSD
    assert component["recent_valid_nights"] == 0
    assert component["current_z"] == 0
