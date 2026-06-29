from __future__ import annotations

from datetime import UTC, date, datetime, time, timedelta

from fastapi.testclient import TestClient

from app.main import app
from app.models import (
    DailyBaseline,
    DailySummary,
    MetricDailyRollup,
    MetricInterval,
    MetricMinuteRollup,
    MetricSample,
    SleepSession,
    User,
    Workout,
)
from app.services.scores import BASELINE_VERSION


def _user(session) -> User:
    user = User()
    session.add(user)
    session.flush()
    return user


def _dt(day: date, hour: int, minute: int = 0) -> datetime:
    return datetime.combine(day, time(hour, minute), tzinfo=UTC)


def test_metric_detail_returns_daily_points_trend_and_baseline(session, auth_headers) -> None:
    user = _user(session)
    start = date(2026, 6, 17)
    days = [start + timedelta(days=offset) for offset in range(3)]
    values = [50.0, 54.0, 58.0]
    for day, hrv in zip(days, values, strict=True):
        session.add(
            DailySummary(
                user_id=user.id,
                summary_date=day,
                heart_rate_variability=hrv,
                data_quality="strong",
            )
        )
        session.add(
            DailyBaseline(
                user_id=user.id,
                baseline_date=day,
                metric="heart_rate_variability",
                algorithm_version=BASELINE_VERSION,
                window_days=28,
                valid_day_count=20,
                mean_value=52.0,
                median_value=52.0,
                spread_value=3.0,
                lower_bound=46.0,
                upper_bound=58.0,
                confidence_phase="personalized",
            )
        )
    session.commit()

    response = TestClient(app).get(
        "/metrics/heart_rate_variability/detail",
        params={"start": days[0].isoformat(), "end": days[-1].isoformat()},
        headers=auth_headers(user),
    )

    assert response.status_code == 200
    payload = response.json()
    assert payload["metric"] == "heart_rate_variability"
    assert payload["unit"] == "ms"
    assert payload["current"] == {"date": "2026-06-19", "value": 58.0, "unit": "ms"}
    assert payload["previous"] == {"date": "2026-06-18", "value": 54.0, "unit": "ms"}
    assert payload["trend"]["direction"] == "up"
    assert payload["trend"]["absolute_change"] == 4.0
    assert payload["trend"]["window_average"] == 54.0
    assert payload["baseline"] == {
        "value": 52.0,
        "lower_bound": 46.0,
        "upper_bound": 58.0,
        "comparison": "normal",
        "delta": 6.0,
        "confidence_phase": "personalized",
    }
    assert payload["data_quality"] == "strong"
    assert payload["higher_is_better"] is True
    assert [point["value"] for point in payload["series"]] == [50.0, 54.0, 58.0]
    assert {point["comparison"] for point in payload["series"]} == {"normal"}
    assert payload["chart"]["points"][0]["baseline_lower_bound"] == 46.0
    assert payload["summary"]["primary_value"] == 54.0


def test_hrv_metric_detail_accepts_timeframe_selector_payload(session, auth_headers) -> None:
    user = _user(session)
    week_start = date(2026, 6, 15)
    previous_week_start = week_start - timedelta(days=7)
    for offset in range(7):
        day = previous_week_start + timedelta(days=offset)
        session.add(
            DailySummary(
                user_id=user.id,
                summary_date=day,
                heart_rate_variability=45.0,
                data_quality="strong",
            )
        )
    values = [50.0, 44.0, 52.0, 55.0, 61.0, None, 54.0]
    for offset, hrv in enumerate(values):
        day = week_start + timedelta(days=offset)
        session.add(
            DailySummary(
                user_id=user.id,
                summary_date=day,
                heart_rate_variability=hrv,
                data_quality="strong" if hrv is not None else "missing",
            )
        )
        session.add(
            DailyBaseline(
                user_id=user.id,
                baseline_date=day,
                metric="heart_rate_variability",
                algorithm_version=BASELINE_VERSION,
                window_days=28,
                valid_day_count=20,
                mean_value=52.0,
                median_value=52.0,
                spread_value=3.0,
                lower_bound=46.0,
                upper_bound=58.0,
                confidence_phase="personalized",
            )
        )
    session.commit()

    response = TestClient(app).get(
        "/metrics/heart_rate_variability/detail",
        params={"date": "2026-06-18", "timeframe": "week"},
        headers=auth_headers(user),
    )

    assert response.status_code == 200
    payload = response.json()
    assert payload["timeframe"] == "week"
    assert payload["range"] == {"start": "2026-06-15", "end": "2026-06-21"}
    assert payload["summary"]["primary_value"] == 52.67
    assert payload["summary"]["latest_value"] == 54.0
    assert payload["summary"]["previous_period_value"] == 45.0
    assert payload["summary"]["trend"] == "up"
    assert payload["summary"]["absolute_change"] == 7.67
    assert payload["summary"]["baseline_relation"] == "normal"
    assert payload["distribution"]["within_count"] == 4
    assert payload["distribution"]["below_count"] == 1
    assert payload["distribution"]["above_count"] == 1
    assert payload["distribution"]["missing_count"] == 1
    assert payload["chart"]["kind"] == "daily_hrv_baseline"
    assert payload["coverage"]["valid_days"] == 6


def test_hrv_metric_detail_handles_missing_previous_period(session, auth_headers) -> None:
    user = _user(session)
    day = date(2026, 6, 15)
    session.add(
        DailySummary(
            user_id=user.id,
            summary_date=day,
            heart_rate_variability=50.0,
            data_quality="strong",
        )
    )
    session.commit()

    response = TestClient(app).get(
        "/metrics/heart_rate_variability/detail",
        params={"date": day.isoformat(), "timeframe": "week"},
        headers=auth_headers(user),
    )

    assert response.status_code == 200
    payload = response.json()
    assert payload["summary"]["previous_period_value"] is None
    assert payload["summary"]["trend"] == "unknown"
    assert payload["summary"]["absolute_change"] is None


def test_metrics_dashboard_summary_batches_metric_cards(session, auth_headers) -> None:
    user = _user(session)
    start = date(2026, 6, 17)
    days = [start + timedelta(days=offset) for offset in range(3)]
    for offset, day in enumerate(days):
        session.add(
            DailySummary(
                user_id=user.id,
                summary_date=day,
                steps=7000 + offset * 500,
                heart_rate_variability=50 + offset * 4,
                data_quality="strong",
            )
        )
        session.add(
            DailyBaseline(
                user_id=user.id,
                baseline_date=day,
                metric="heart_rate_variability",
                algorithm_version=BASELINE_VERSION,
                window_days=28,
                valid_day_count=20,
                mean_value=52.0,
                median_value=52.0,
                spread_value=3.0,
                lower_bound=46.0,
                upper_bound=58.0,
                confidence_phase="personalized",
            )
        )
    session.commit()

    response = TestClient(app).get(
        "/metrics/dashboard-summary",
        params={
            "metrics": "heart_rate_variability,steps",
            "date": days[-1].isoformat(),
            "window_days": 3,
        },
        headers=auth_headers(user),
    )

    assert response.status_code == 200
    payload = response.json()
    assert payload["date"] == "2026-06-19"
    assert set(payload["metrics"]) == {"heart_rate_variability", "steps"}
    assert payload["metrics"]["heart_rate_variability"]["current"] == {
        "date": "2026-06-19",
        "value": 58.0,
        "unit": "ms",
    }
    assert payload["metrics"]["heart_rate_variability"]["baseline"]["comparison"] == "normal"
    assert payload["metrics"]["heart_rate_variability"]["trend"]["absolute_change"] == 4.0
    assert payload["metrics"]["steps"]["current"]["value"] == 8000.0


def test_metrics_dashboard_summary_default_metric_order(session, auth_headers) -> None:
    user = _user(session)

    response = TestClient(app).get(
        "/metrics/dashboard-summary",
        params={"date": "2026-06-19", "window_days": 3},
        headers=auth_headers(user),
    )

    assert response.status_code == 200
    assert list(response.json()["metrics"]) == [
        "heart_rate_variability",
        "resting_heart_rate",
        "heart_rate",
        "skin_temperature_variation",
        "oxygen_saturation",
        "respiratory_rate",
        "vo2_max",
        "sleep",
        "steps",
        "total_calories",
        "distance",
    ]


def test_metrics_dashboard_summary_includes_heart_rate_and_skin_temperature(
    session,
    auth_headers,
) -> None:
    user = _user(session)
    day = date(2026, 6, 19)
    session.add(
        MetricDailyRollup(
            user_id=user.id,
            metric="heart_rate",
            civil_date=day,
            avg_value=72.5,
            min_value=51,
            max_value=154,
            sum_value=8700,
            sample_count=120,
            unit="bpm",
        )
    )
    session.add(
        MetricMinuteRollup(
            user_id=user.id,
            metric="heart_rate",
            bucket_start=_dt(day, 8, 0),
            civil_date=day,
            avg_value=80,
            min_value=80,
            max_value=80,
            sum_value=80,
            sample_count=1,
            unit="bpm",
        )
    )
    session.add(
        MetricMinuteRollup(
            user_id=user.id,
            metric="heart_rate",
            bucket_start=_dt(day, 8, 1),
            civil_date=day,
            avg_value=81,
            min_value=81,
            max_value=81,
            sum_value=81,
            sample_count=1,
            unit="bpm",
        )
    )
    session.add(
        MetricSample(
            user_id=user.id,
            metric="skin_temperature_variation",
            observed_at=_dt(day, 0),
            civil_date=day,
            value=0.42,
            unit="celsius",
        )
    )
    session.commit()

    response = TestClient(app).get(
        "/metrics/dashboard-summary",
        params={
            "metrics": "heart_rate,skin_temperature_variation",
            "date": day.isoformat(),
            "window_days": 1,
        },
        headers=auth_headers(user),
    )

    assert response.status_code == 200
    payload = response.json()["metrics"]
    assert payload["heart_rate"]["current"]["value"] == 81.0
    assert payload["heart_rate"]["current"]["unit"] == "bpm"
    assert payload["heart_rate"]["current"]["date"].startswith("2026-06-19T08:01:00")
    assert payload["skin_temperature_variation"]["current"] == {
        "date": "2026-06-19",
        "value": 0.42,
        "unit": "celsius",
    }


def test_heart_rate_metric_detail_aggregates_daily_samples(session, auth_headers) -> None:
    user = _user(session)
    day = date(2026, 6, 19)
    for index, bpm in enumerate([60, 70, 80]):
        session.add(
            MetricSample(
                user_id=user.id,
                metric="heart_rate",
                observed_at=_dt(day, 8, index),
                civil_date=day,
                value=bpm,
                unit="bpm",
            )
        )
    session.commit()

    response = TestClient(app).get(
        "/metrics/heart_rate/detail",
        params={"start": day.isoformat(), "end": day.isoformat()},
        headers=auth_headers(user),
    )

    assert response.status_code == 200
    payload = response.json()
    assert payload["current"] == {"date": "2026-06-19", "value": 70.0, "unit": "bpm"}
    assert payload["series"] == [
        {
            "date": "2026-06-19",
            "value": 70.0,
            "unit": "bpm",
            "data_quality": "weak",
            "min_value": 60.0,
            "max_value": 80.0,
            "sample_count": 3,
            "baseline_value": None,
            "comparison": "unknown",
        }
    ]


def test_heart_rate_detail_includes_intraday_sleep_and_workout_drivers(session, auth_headers) -> None:
    user = _user(session)
    day = date(2026, 6, 19)
    session.add(
        DailySummary(
            user_id=user.id,
            summary_date=day,
            sleep_minutes=405,
            data_quality="strong",
        )
    )
    session.add(
        MetricDailyRollup(
            user_id=user.id,
            metric="heart_rate",
            civil_date=day,
            avg_value=82.0,
            min_value=54.0,
            max_value=173.0,
            sample_count=3,
            unit="bpm",
        )
    )
    for minute, bpm in enumerate([70.0, 86.0, 124.0]):
        session.add(
            MetricMinuteRollup(
                user_id=user.id,
                metric="heart_rate",
                bucket_start=_dt(day, 8, minute),
                civil_date=day,
                avg_value=bpm,
                min_value=bpm,
                max_value=bpm,
                sum_value=bpm,
                sample_count=1,
                unit="bpm",
            )
        )
    session.add(
        SleepSession(
            user_id=user.id,
            start_time=_dt(day, 0),
            end_time=_dt(day, 7),
            civil_date=day,
            minutes_asleep=405,
            minutes_in_sleep_period=420,
            is_main_sleep=True,
        )
    )
    workout = Workout(
        user_id=user.id,
        workout_type="run",
        start_time=_dt(day, 8),
        end_time=_dt(day, 9),
        civil_date=day,
        duration_seconds=3600,
        raw_summary={"heartRateZoneDurations": {"lightTime": 600, "vigorousTime": 1200}},
    )
    session.add(workout)
    session.commit()

    response = TestClient(app).get(
        "/metrics/heart_rate/detail",
        params={"date": day.isoformat(), "timeframe": "day"},
        headers=auth_headers(user),
    )

    assert response.status_code == 200
    payload = response.json()
    assert payload["summary"]["primary_value"] == 82.0
    assert payload["series"][0]["sample_count"] == 3
    assert payload["series"][0]["min_value"] == 54.0
    assert payload["series"][0]["max_value"] == 173.0
    assert payload["intraday"]["available"] is True
    assert payload["intraday"]["retention_days"] == 14
    assert [point["value"] for point in payload["intraday"]["points"]] == [70.0, 86.0, 124.0]
    assert payload["drivers"]["sleep"]["sleep_minutes"] == 405
    assert payload["drivers"]["sleep"]["short_sleep_nights"] == 1
    assert payload["drivers"]["workouts"][0]["id"] == workout.id
    assert payload["zones"]["items"][0]["seconds"] == 600
    assert payload["zones"]["items"][2]["seconds"] == 1200


def test_metric_detail_prefers_fitbit_activity_interval_totals(session, auth_headers) -> None:
    user = _user(session)
    day = date(2026, 6, 19)
    session.add(
        MetricInterval(
            user_id=user.id,
            metric="distance",
            start_time=_dt(day, 8),
            end_time=_dt(day, 8, 30),
            civil_date=day,
            value=1609.344,
            unit="meters",
            source_platform="FITBIT",
        )
    )
    session.add(
        MetricInterval(
            user_id=user.id,
            metric="distance",
            start_time=_dt(day, 9),
            end_time=_dt(day, 9, 30),
            civil_date=day,
            value=3218.688,
            unit="meters",
            source_platform="HEALTH_KIT",
        )
    )
    session.commit()

    response = TestClient(app).get(
        "/metrics/distance/detail",
        params={"start": day.isoformat(), "end": day.isoformat()},
        headers=auth_headers(user),
    )

    assert response.status_code == 200
    payload = response.json()
    assert payload["current"] == {"date": "2026-06-19", "value": 1609.34, "unit": "meters"}
    assert payload["series"][0]["value"] == 1609.34


def test_metric_detail_handles_missing_data_and_unknown_metric(session, auth_headers) -> None:
    user = _user(session)
    day = date(2026, 6, 19)
    session.commit()
    client = TestClient(app)

    missing = client.get(
        "/metrics/vo2_max/detail",
        params={"start": day.isoformat(), "end": day.isoformat()},
        headers=auth_headers(user),
    )
    assert missing.status_code == 200
    payload = missing.json()
    assert payload["current"] is None
    assert payload["previous"] is None
    assert payload["baseline"] is None
    assert payload["data_quality"] == "missing"
    assert payload["trend"]["direction"] == "unknown"
    assert payload["series"] == [
        {
            "date": "2026-06-19",
            "value": None,
            "unit": "ml_per_kg_min",
            "data_quality": "missing",
            "baseline_value": None,
            "comparison": "unknown",
        }
    ]

    unknown = client.get(
        "/metrics/sleep/detail",
        params={"start": day.isoformat(), "end": day.isoformat()},
        headers=auth_headers(user),
    )
    assert unknown.status_code == 404
