from __future__ import annotations

from datetime import UTC, date, datetime, time, timedelta

from fastapi.testclient import TestClient

from app.main import app
from app.models import DailyBaseline, DailySummary, MetricInterval, MetricSample, User
from app.services.scores import BASELINE_VERSION


def _user(session) -> User:
    user = User()
    session.add(user)
    session.flush()
    return user


def _dt(day: date, hour: int, minute: int = 0) -> datetime:
    return datetime.combine(day, time(hour, minute), tzinfo=UTC)


def test_metric_detail_returns_daily_points_trend_and_baseline(session) -> None:
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
        params={"user_id": user.id, "start": days[0].isoformat(), "end": days[-1].isoformat()},
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


def test_heart_rate_metric_detail_aggregates_daily_samples(session) -> None:
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
        params={"user_id": user.id, "start": day.isoformat(), "end": day.isoformat()},
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
            "baseline_value": None,
            "comparison": "unknown",
        }
    ]


def test_metric_detail_prefers_fitbit_activity_interval_totals(session) -> None:
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
        params={"user_id": user.id, "start": day.isoformat(), "end": day.isoformat()},
    )

    assert response.status_code == 200
    payload = response.json()
    assert payload["current"] == {"date": "2026-06-19", "value": 1609.34, "unit": "meters"}
    assert payload["series"][0]["value"] == 1609.34


def test_metric_detail_handles_missing_data_and_unknown_metric(session) -> None:
    user = _user(session)
    day = date(2026, 6, 19)
    session.commit()
    client = TestClient(app)

    missing = client.get(
        "/metrics/vo2_max/detail",
        params={"user_id": user.id, "start": day.isoformat(), "end": day.isoformat()},
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
        params={"user_id": user.id, "start": day.isoformat(), "end": day.isoformat()},
    )
    assert unknown.status_code == 404
