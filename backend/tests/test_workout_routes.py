from __future__ import annotations

from datetime import UTC, date, datetime, timedelta

from fastapi.testclient import TestClient

from app.main import app
from app.models import (
    DailySummary,
    GoogleAccount,
    MetricInterval,
    MetricSample,
    RawHealthRecord,
    User,
    UserProfile,
    Workout,
)


def _dt(day: date, hour: int, minute: int = 0) -> datetime:
    return datetime.combine(day, datetime.min.time(), tzinfo=UTC) + timedelta(
        hours=hour,
        minutes=minute,
    )


def _user(session) -> User:
    user = User()
    session.add(user)
    session.flush()
    session.add(
        UserProfile(
            user_id=user.id,
            timezone="UTC",
            birth_year=1990,
            sleep_target_minutes=480,
        )
    )
    session.flush()
    return user


def _workout(session, user: User, day: date, raw_summary: dict | None = None) -> Workout:
    workout = Workout(
        user_id=user.id,
        workout_type="run",
        start_time=_dt(day, 8),
        end_time=_dt(day, 8, 40),
        civil_date=day,
        duration_seconds=2400,
        raw_summary=raw_summary or {},
    )
    session.add(workout)
    session.flush()
    return workout


def test_workout_list_returns_enriched_provider_zone_summary(session, auth_headers) -> None:
    user = _user(session)
    day = date(2026, 6, 19)
    workout = _workout(
        session,
        user,
        day,
        {
            "metricsSummary": {
                "distanceMillimeters": 5000000,
                "caloriesKcal": 420,
                "heartRateZoneDurations": {
                    "lightTime": "300s",
                    "moderateTime": "1200s",
                    "vigorousTime": "600s",
                    "peakTime": "300s",
                },
            },
        },
    )
    for index, bpm in enumerate((120, 130, 150)):
        session.add(
            MetricSample(
                user_id=user.id,
                metric="heart_rate",
                observed_at=workout.start_time + timedelta(minutes=index * 10),
                civil_date=day,
                value=bpm,
                unit="bpm",
            )
        )
    session.commit()

    response = TestClient(app).get(
        f"/workouts?start={day}&end={day}",
        headers=auth_headers(user),
    )

    assert response.status_code == 200
    payload = response.json()
    assert payload[0]["id"] == workout.id
    assert payload[0]["distance_meters"] == 5000.0
    assert payload[0]["active_calories"] == 420.0
    assert payload[0]["heart_rate"]["average_bpm"] == 133.33
    assert payload[0]["zone_source"] == "provider_workout_summary"
    assert [zone["zone"] for zone in payload[0]["heart_rate_zones"]] == [
        "zone_1",
        "zone_2",
        "zone_3",
        "zone_4",
    ]
    assert [zone["minutes"] for zone in payload[0]["heart_rate_zones"]] == [
        5.0,
        20.0,
        10.0,
        5.0,
    ]
    assert payload[0]["intensity"] == "moderate"


def test_workout_detail_uses_time_in_zone_intervals_when_provider_zones_missing(session, auth_headers) -> None:
    user = _user(session)
    day = date(2026, 6, 19)
    account = GoogleAccount(user_id=user.id, health_user_id="health-id", granted_scopes=[])
    session.add(account)
    session.flush()
    workout = _workout(session, user, day)
    raw = RawHealthRecord(
        user_id=user.id,
        google_account_id=account.id,
        data_type="time-in-heart-rate-zone",
        source_record_id="zone-1",
        civil_date=day,
        raw_json={"timeInHeartRateZone": {"heartRateZoneType": "VIGOROUS"}},
        content_hash="zone-1",
    )
    session.add(raw)
    session.flush()
    session.add(
        MetricInterval(
            user_id=user.id,
            raw_record_id=raw.id,
            metric="time_in_heart_rate_zone",
            start_time=_dt(day, 8, 10),
            end_time=_dt(day, 8, 30),
            civil_date=day,
            value=1200,
            unit="seconds",
        )
    )
    session.add(
        MetricSample(
            user_id=user.id,
            metric="heart_rate",
            observed_at=_dt(day, 8, 12),
            civil_date=day,
            value=155,
            unit="bpm",
        )
    )
    session.commit()

    response = TestClient(app).get(f"/workouts/{workout.id}", headers=auth_headers(user))

    assert response.status_code == 200
    payload = response.json()
    assert payload["zone_source"] == "time_in_heart_rate_zone"
    assert payload["heart_rate_zones"][2]["zone"] == "zone_3"
    assert payload["heart_rate_zones"][2]["minutes"] == 20.0
    assert payload["heart_rate_zones"][2]["source_zones"] == ["VIGOROUS"]
    assert payload["heart_rate_samples"] == [
        {
            "observed_at": "2026-06-19T08:12:00",
            "value": 155.0,
            "unit": "bpm",
            "source_platform": None,
            "source_device": None,
        }
    ]


def test_workout_detail_infers_zones_from_heart_rate_reserve(session, auth_headers) -> None:
    user = _user(session)
    day = date(2026, 6, 19)
    workout = _workout(session, user, day)
    session.add(
        DailySummary(
            user_id=user.id,
            summary_date=day,
            resting_heart_rate=60,
            data_quality="weak",
        )
    )
    for minute, bpm in ((0, 100), (10, 140), (20, 150), (30, 170), (40, 170)):
        session.add(
            MetricSample(
                user_id=user.id,
                metric="heart_rate",
                observed_at=workout.start_time + timedelta(minutes=minute),
                civil_date=day,
                value=bpm,
                unit="bpm",
            )
        )
    session.commit()

    response = TestClient(app).get(f"/workouts/{workout.id}", headers=auth_headers(user))

    assert response.status_code == 200
    payload = response.json()
    assert payload["zone_source"] == "heart_rate_reserve_inferred"
    assert [zone["seconds"] for zone in payload["heart_rate_zones"]] == [120, 120, 120, 120]
    assert payload["heart_rate_zones"][0]["thresholds"]["zone_2"]["min_bpm"] == 136.78
    assert payload["heart_rate_zones"][0]["max_heart_rate_source"] == "hunt_age_formula"
    assert payload["intensity"] == "light"


def test_workout_detail_404s_for_other_users_workout(session, auth_headers) -> None:
    owner = _user(session)
    other = _user(session)
    workout = _workout(session, owner, date(2026, 6, 19))
    session.commit()

    response = TestClient(app).get(f"/workouts/{workout.id}", headers=auth_headers(other))

    assert response.status_code == 404
