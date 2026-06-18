from __future__ import annotations

from datetime import UTC, date, datetime, time, timedelta

from fastapi.testclient import TestClient
from sqlalchemy import select

from app.main import app
from app.models import (
    DailyScore,
    DailySummary,
    GoogleAccount,
    MetricSample,
    SleepSession,
    User,
    UserProfile,
    Workout,
)
from app.services.scores import (
    READINESS_SCORE_VERSION,
    SLEEP_SCORE_VERSION,
    STRAIN_LOAD_VERSION,
    rebuild_derived_scores,
)
from app.services.normalization import upsert_raw_and_normalized


def _user_with_profile(session, *, birth_year: int = 1992) -> User:
    user = User()
    session.add(user)
    session.flush()
    session.add(
        UserProfile(
            user_id=user.id,
            timezone="UTC",
            birth_year=birth_year,
            sleep_target_minutes=480,
        )
    )
    session.add(
        GoogleAccount(
            user_id=user.id,
            health_user_id=f"health-{user.id}",
            legacy_user_id=f"legacy-{user.id}",
            granted_scopes=[],
        )
    )
    session.flush()
    return user


def _dt(day: date, hour: int, minute: int = 0) -> datetime:
    return datetime.combine(day, time(hour, minute), tzinfo=UTC)


def _add_sleep(
    session,
    user: User,
    day: date,
    *,
    minutes_asleep: int = 455,
    minutes_awake: int = 35,
    start_hour: int = 22,
    start_minute: int = 30,
) -> None:
    start_day = day - timedelta(days=1) if start_hour >= 12 else day
    start = _dt(start_day, start_hour, start_minute)
    end = start + timedelta(minutes=minutes_asleep + minutes_awake)
    session.add(
        SleepSession(
            user_id=user.id,
            start_time=start,
            end_time=end,
            civil_date=day,
            minutes_asleep=minutes_asleep,
            minutes_awake=minutes_awake,
            minutes_in_sleep_period=minutes_asleep + minutes_awake,
            stages_summary=[
                {"type": "REM", "minutes": 95},
                {"type": "DEEP", "minutes": 70},
            ],
            stages=[],
            is_main_sleep=True,
        )
    )


def _add_summary(
    session,
    user: User,
    day: date,
    *,
    hrv: float = 58,
    rhr: float = 56,
    sleep_minutes: int = 455,
    steps: int = 6500,
    active_calories: float = 320,
) -> None:
    session.add(
        DailySummary(
            user_id=user.id,
            summary_date=day,
            steps=steps,
            active_calories=active_calories,
            total_calories=2300,
            distance_meters=5200,
            resting_heart_rate=rhr,
            heart_rate_variability=hrv,
            oxygen_saturation=97,
            respiratory_rate=14.5,
            sleep_minutes=sleep_minutes,
            workout_count=0,
            data_quality="strong",
        )
    )


def _add_hr_workout(session, user: User, day: date, *, bpm: float = 152) -> None:
    start = _dt(day, 7, 0)
    end = start + timedelta(minutes=30)
    session.add(
        Workout(
            user_id=user.id,
            workout_type="running",
            start_time=start,
            end_time=end,
            civil_date=day,
            duration_seconds=1800,
            raw_summary={},
        )
    )
    for index in range(31):
        session.add(
            MetricSample(
                user_id=user.id,
                metric="heart_rate",
                observed_at=start + timedelta(minutes=index),
                civil_date=day,
                value=bpm,
                unit="bpm",
            )
        )


def test_scores_wait_for_required_sleep(session) -> None:
    user = _user_with_profile(session)
    day = date.today() - timedelta(days=1)
    _add_summary(session, user, day, sleep_minutes=0)

    rebuild_derived_scores(session, user_id=user.id, start=day, end=day)
    session.commit()

    sleep = session.scalar(
        select(DailyScore).where(
            DailyScore.user_id == user.id,
            DailyScore.score_type == "sleep",
        )
    )
    readiness = session.scalar(
        select(DailyScore).where(
            DailyScore.user_id == user.id,
            DailyScore.score_type == "readiness",
        )
    )

    assert sleep.value is None
    assert sleep.status.value == "waiting_for_sleep"
    assert readiness.value is None
    assert readiness.status.value == "waiting_for_sleep"


def test_rebuild_scores_materializes_sleep_strain_readiness_and_target(session) -> None:
    user = _user_with_profile(session, birth_year=1990)
    today = date.today()
    start = today - timedelta(days=30)
    for offset in range(31):
        day = start + timedelta(days=offset)
        _add_sleep(session, user, day)
        _add_summary(session, user, day)
    _add_hr_workout(session, user, today, bpm=154)

    result = rebuild_derived_scores(session, user_id=user.id, start=start, end=today)
    session.commit()

    assert result.scores_rebuilt == 93

    sleep = session.scalar(
        select(DailyScore).where(
            DailyScore.user_id == user.id,
            DailyScore.score_date == today,
            DailyScore.score_type == "sleep",
            DailyScore.algorithm_version == SLEEP_SCORE_VERSION,
        )
    )
    strain = session.scalar(
        select(DailyScore).where(
            DailyScore.user_id == user.id,
            DailyScore.score_date == today,
            DailyScore.score_type == "strain",
            DailyScore.algorithm_version == STRAIN_LOAD_VERSION,
        )
    )
    readiness = session.scalar(
        select(DailyScore).where(
            DailyScore.user_id == user.id,
            DailyScore.score_date == today,
            DailyScore.score_type == "readiness",
            DailyScore.algorithm_version == READINESS_SCORE_VERSION,
        )
    )

    assert sleep.status.value == "scored"
    assert sleep.confidence_phase == "personalized"
    assert set(sleep.components) == {
        "duration",
        "regularity",
        "continuity",
        "timing",
        "physiology",
        "stages",
    }
    assert sleep.value and sleep.value >= 80

    assert strain.value and strain.value > 10
    assert strain.value_unit == "load_points"
    assert strain.components["cardio_load"]["workout_coverage_ratio"] >= 0.9
    assert strain.inputs["max_hr_source"] in {"hunt_age_formula", "observed_sustained_workout"}

    assert readiness.status.value == "scored"
    assert readiness.value and readiness.value > 60
    assert readiness.inputs["uses_same_day_strain"] is False


def test_strain_uses_observed_resting_hr_when_daily_rhr_missing(session) -> None:
    user = _user_with_profile(session, birth_year=2005)
    day = date.today() - timedelta(days=1)
    _add_summary(session, user, day, rhr=None, steps=0, active_calories=0)
    start = _dt(day, 6, 0)
    for index in range(180):
        bpm = 58 if index < 30 else 128
        session.add(
            MetricSample(
                user_id=user.id,
                metric="heart_rate",
                observed_at=start + timedelta(minutes=index),
                civil_date=day,
                value=bpm,
                unit="bpm",
            )
        )

    rebuild_derived_scores(session, user_id=user.id, start=day, end=day)
    session.commit()

    strain = session.scalar(
        select(DailyScore).where(
            DailyScore.user_id == user.id,
            DailyScore.score_date == day,
            DailyScore.score_type == "strain",
            DailyScore.algorithm_version == STRAIN_LOAD_VERSION,
        )
    )

    assert strain.inputs["resting_hr_source"] == "observed_low_percentile"
    assert strain.inputs["hr_sample_count"] == 180
    assert strain.components["cardio_load"]["load_points"] > 0


def test_strain_uses_time_in_zone_intervals_when_hr_confidence_weak(session) -> None:
    user = _user_with_profile(session, birth_year=2005)
    account = session.scalar(select(GoogleAccount).where(GoogleAccount.user_id == user.id))
    day = date.today() - timedelta(days=1)
    _add_summary(session, user, day, rhr=None, steps=0, active_calories=0)
    upsert_raw_and_normalized(
        session,
        account=account,
        data_type="time-in-heart-rate-zone",
        data_point={
            "name": "users/me/dataTypes/time-in-heart-rate-zone/dataPoints/1",
            "timeInHeartRateZone": {
                "interval": {
                    "startTime": f"{day.isoformat()}T08:00:00Z",
                    "endTime": f"{day.isoformat()}T08:30:00Z",
                    "civilStartTime": {"date": {"year": day.year, "month": day.month, "day": day.day}},
                },
                "heartRateZoneType": "VIGOROUS",
            },
        },
    )

    rebuild_derived_scores(session, user_id=user.id, start=day, end=day)
    session.commit()

    strain = session.scalar(
        select(DailyScore).where(
            DailyScore.user_id == user.id,
            DailyScore.score_date == day,
            DailyScore.score_type == "strain",
            DailyScore.algorithm_version == STRAIN_LOAD_VERSION,
        )
    )

    assert strain.components["source_zone_load"] == {
        "load_points": 24.0,
        "zones_seen": 1,
        "source": "time_in_heart_rate_zone",
    }
    assert strain.value == 24.0


def test_scores_api_rebuild_and_history(session) -> None:
    user = _user_with_profile(session)
    day = date.today()
    _add_sleep(session, user, day)
    _add_summary(session, user, day)
    session.commit()

    client = TestClient(app)
    response = client.post(
        "/scores/rebuild",
        params={"user_id": user.id, "start": day.isoformat(), "end": day.isoformat()},
    )
    assert response.status_code == 200
    assert response.json()["scores_rebuilt"] == 3

    history = client.get(
        "/scores/daily",
        params={"user_id": user.id, "start": day.isoformat(), "end": day.isoformat()},
    )
    assert history.status_code == 200
    payload = history.json()
    assert {item["score_type"] for item in payload} == {"sleep", "readiness", "strain"}

    dashboard = client.get("/dashboard/today", params={"user_id": user.id})
    assert dashboard.status_code == 200
    assert set(dashboard.json()["scores"]) == {"sleep", "readiness", "strain"}
