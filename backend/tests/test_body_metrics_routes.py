from __future__ import annotations

from datetime import UTC, date, datetime

from fastapi.testclient import TestClient

from app.main import app
from app.models import MetricSample, User, UserProfile


def test_body_metrics_returns_profile_values_and_bmi(session) -> None:
    user = User()
    session.add(user)
    session.flush()
    session.add(
        UserProfile(
            user_id=user.id,
            timezone="UTC",
            height_cm=180,
            weight_kg=81,
            sleep_target_minutes=480,
        )
    )
    session.commit()
    client = TestClient(app)

    response = client.get("/body-metrics", params={"user_id": user.id})

    assert response.status_code == 200
    payload = response.json()
    assert payload["height_cm"] == 180
    assert payload["weight_kg"] == 81
    assert payload["bmi"] == 25.0
    assert payload["samples"] == []
    assert payload["bmi_history"] == []


def test_body_metrics_returns_synced_history(session) -> None:
    user = User()
    session.add(user)
    session.flush()
    session.add(
        UserProfile(
            user_id=user.id,
            timezone="UTC",
            height_cm=180,
            weight_kg=81,
            sleep_target_minutes=480,
        )
    )
    session.add(
        MetricSample(
            user_id=user.id,
            metric="height",
            observed_at=datetime(2026, 6, 1, 8, tzinfo=UTC),
            civil_date=date(2026, 6, 1),
            value=1.82,
            unit="meters",
        )
    )
    session.add(
        MetricSample(
            user_id=user.id,
            metric="weight",
            observed_at=datetime(2026, 6, 15, 8, tzinfo=UTC),
            civil_date=date(2026, 6, 15),
            value=79.5,
            unit="kg",
        )
    )
    session.commit()
    client = TestClient(app)

    response = client.get(
        "/body-metrics",
        params={"user_id": user.id, "start": "2026-06-01", "end": "2026-06-30"},
    )

    assert response.status_code == 200
    payload = response.json()
    assert payload["height_cm"] == 182
    assert payload["weight_kg"] == 79.5
    assert payload["bmi"] == 24.0
    assert payload["samples"] == [
        {
            "metric": "height",
            "observed_at": "2026-06-01T08:00:00",
            "date": "2026-06-01",
            "value": 182.0,
            "unit": "cm",
            "source_platform": None,
            "source_device": None,
        },
        {
            "metric": "weight",
            "observed_at": "2026-06-15T08:00:00",
            "date": "2026-06-15",
            "value": 79.5,
            "unit": "kg",
            "source_platform": None,
            "source_device": None,
        },
    ]
    assert payload["bmi_history"] == [
        {
            "observed_at": "2026-06-15T08:00:00",
            "date": "2026-06-15",
            "bmi": 24.0,
            "weight_kg": 79.5,
            "height_cm": 182.0,
        }
    ]


def test_manual_body_metrics_update_creates_history_and_updates_profile(session) -> None:
    user = User()
    session.add(user)
    session.commit()
    client = TestClient(app)

    response = client.post(
        "/body-metrics",
        params={"user_id": user.id},
        json={
            "date": "2026-06-19",
            "height_cm": 181,
            "weight_kg": 78.5,
        },
    )

    assert response.status_code == 200
    payload = response.json()
    assert payload["height_cm"] == 181
    assert payload["weight_kg"] == 78.5
    assert payload["bmi"] == 24.0
    assert [
        (sample.metric, sample.value, sample.unit, sample.source_platform)
        for sample in session.query(MetricSample).order_by(MetricSample.metric).all()
    ] == [
        ("height", 1.81, "meters", "manual"),
        ("weight", 78.5, "kg", "manual"),
    ]
    profile = session.query(UserProfile).filter_by(user_id=user.id).one()
    assert profile.height_cm == 181
    assert profile.weight_kg == 78.5


def test_manual_body_metrics_update_reuses_same_day_manual_sample(session) -> None:
    user = User()
    session.add(user)
    session.commit()
    client = TestClient(app)

    first = client.post(
        "/body-metrics",
        params={"user_id": user.id},
        json={"date": "2026-06-19", "weight_kg": 78.5},
    )
    second = client.post(
        "/body-metrics",
        params={"user_id": user.id},
        json={"date": "2026-06-19", "weight_kg": 79.2},
    )

    assert first.status_code == 200
    assert second.status_code == 200
    samples = session.query(MetricSample).filter_by(user_id=user.id, metric="weight").all()
    assert len(samples) == 1
    assert samples[0].value == 79.2
    assert second.json()["weight_kg"] == 79.2


def test_backdated_manual_body_metric_does_not_replace_newer_current_value(session) -> None:
    user = User()
    session.add(user)
    session.flush()
    session.add(
        UserProfile(
            user_id=user.id,
            timezone="UTC",
            height_cm=180,
            weight_kg=80,
            sleep_target_minutes=480,
        )
    )
    session.add(
        MetricSample(
            user_id=user.id,
            metric="weight",
            observed_at=datetime(2026, 6, 19, 8, tzinfo=UTC),
            civil_date=date(2026, 6, 19),
            value=80,
            unit="kg",
            source_platform="FITBIT",
        )
    )
    session.commit()
    client = TestClient(app)

    response = client.post(
        "/body-metrics",
        params={"user_id": user.id},
        json={"date": "2026-06-01", "weight_kg": 82},
    )

    assert response.status_code == 200
    payload = response.json()
    assert payload["weight_kg"] == 80
    assert session.query(UserProfile).filter_by(user_id=user.id).one().weight_kg == 80
    assert session.query(MetricSample).filter_by(user_id=user.id, metric="weight").count() == 2


def test_manual_body_metrics_update_requires_a_metric(session) -> None:
    user = User()
    session.add(user)
    session.commit()
    client = TestClient(app)

    response = client.post(
        "/body-metrics",
        params={"user_id": user.id},
        json={"date": "2026-06-19"},
    )

    assert response.status_code == 422
