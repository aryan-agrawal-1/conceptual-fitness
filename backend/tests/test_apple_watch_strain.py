from __future__ import annotations

from datetime import date, datetime, timedelta

import pytest
from sqlalchemy import select

from app.models import DailyScore, DailySummary, MetricMinuteRollup, Workout, WorkoutSource
from app.services.health_dates import get_or_create_profile
from app.tasks import sync as sync_tasks
from tests.test_apple_health_mapping import PHONE, WATCH, at, upload
from tests.test_device_uploads import connected, rebuilds  # noqa: F401

pytestmark = pytest.mark.usefixtures("rebuilds")

HEART_RATE = "HKQuantityTypeIdentifierHeartRate"
STEPS = "HKQuantityTypeIdentifierStepCount"
ACTIVE_ENERGY = "HKQuantityTypeIdentifierActiveEnergyBurned"
BASAL_ENERGY = "HKQuantityTypeIdentifierBasalEnergyBurned"
WORKOUT = "HKWorkoutTypeIdentifier"
DAY = date(2026, 11, 9)


def heart_rates(prefix: str, start: str, minutes: int, every_seconds: int, bpm: float) -> list[dict]:
    begin = at(start)
    count = minutes * 60 // every_seconds
    return [
        {
            "id": f"{prefix}{index}",
            "start": (moment := begin + timedelta(seconds=index * every_seconds)).isoformat(),
            "end": moment.isoformat(),
            "value": bpm,
            "unit": "count/min",
            "source": WATCH,
        }
        for index in range(count)
    ]


def workout(record_id: str, start: str, minutes: int, activity: str, source=WATCH) -> dict:
    begin = at(start)
    return {
        "id": record_id,
        "start": begin.isoformat(),
        "end": (begin + timedelta(minutes=minutes)).isoformat(),
        "source": source,
        "workout": {"activity_type": activity, "duration_seconds": minutes * 60},
    }


def amount(record_id: str, start: str, minutes: int, value: float, unit: str) -> dict:
    begin = at(start)
    return {
        "id": record_id,
        "start": begin.isoformat(),
        "end": (begin + timedelta(minutes=minutes)).isoformat(),
        "value": value,
        "unit": unit,
        "source": WATCH,
    }


def athlete(session):
    client, user = connected(session)
    profile = get_or_create_profile(session, user.id)
    profile.birth_year = 1996
    profile.sex = "female"
    session.commit()
    return client, user


def strain_for(session, user_id: str) -> DailyScore:
    session.expire_all()
    return session.scalar(
        select(DailyScore).where(
            DailyScore.user_id == user_id, DailyScore.score_type == "strain", DailyScore.score_date == DAY
        )
    )


def test_workout_heart_rate_builds_minute_level_strain(session) -> None:
    client, user = athlete(session)
    upload(client, WORKOUT, [workout("W1", "2026-11-09T07:00:00+00:00", 30, "running")])
    upload(client, HEART_RATE, heart_rates("hr", "2026-11-09T07:00:00+00:00", 30, 5, 160))

    sync_tasks.rebuild_scores(user.id, "2026-11-09", "2026-11-09")
    strain = strain_for(session, user.id)
    cardio = strain.components["cardio_load"]

    assert session.scalars(select(MetricMinuteRollup).where(MetricMinuteRollup.user_id == user.id)).all()
    assert cardio["workout_load_points"] > 0
    assert cardio["covered_minutes"] == pytest.approx(29, abs=1)
    assert cardio["zone_fallback_load_points"] == 0


def test_sparse_background_heart_rate_adds_no_invented_minutes(session) -> None:
    client, user = athlete(session)
    upload(client, HEART_RATE, heart_rates("bg", "2026-11-09T09:00:00+00:00", 240, 300, 120))
    upload(client, STEPS, [amount(f"S{index}", f"2026-11-09T{9 + index // 60:02d}:{index % 60:02d}:00+00:00", 1, 90, "count") for index in range(0, 240, 5)])

    sync_tasks.rebuild_scores(user.id, "2026-11-09", "2026-11-09")
    cardio = strain_for(session, user.id).components["cardio_load"]

    assert cardio["general_activity_load_points"] == 0
    assert cardio["covered_minutes"] == 0
    assert cardio["long_gap_count"] > 0
    assert cardio["confidence"] == "weak"


def test_apple_workout_joins_a_logged_strength_session(session) -> None:
    client, user = athlete(session)
    logged = Workout(
        user_id=user.id,
        workout_type="strength",
        title="Push",
        start_time=datetime(2026, 11, 9, 18, 0),
        end_time=datetime(2026, 11, 9, 19, 0),
        civil_date=DAY,
        duration_seconds=3600,
        status="completed",
        origin="manual",
        is_user_edited=True,
        awaiting_wearable=True,
    )
    session.add(logged)
    session.commit()

    upload(client, WORKOUT, [workout("W1", "2026-11-09T18:02:00+00:00", 58, "traditional_strength_training")])
    session.expire_all()
    workouts = session.scalars(select(Workout).where(Workout.user_id == user.id)).all()
    source = session.scalar(select(WorkoutSource).where(WorkoutSource.user_id == user.id))

    assert [item.id for item in workouts] == [logged.id]
    assert workouts[0].origin == "mixed"
    assert workouts[0].awaiting_wearable is False
    assert source.provider == "apple_health"

    upload(client, WORKOUT, [], deleted_ids=["W1"])
    session.expire_all()
    remaining = session.scalars(select(Workout).where(Workout.user_id == user.id)).all()

    assert [(item.id, item.origin) for item in remaining] == [(logged.id, "manual")]


def test_workouts_from_the_phone_are_not_scored(session) -> None:
    client, user = athlete(session)
    upload(client, WORKOUT, [workout("W1", "2026-11-09T07:00:00+00:00", 30, "running", source=PHONE)])

    assert session.scalars(select(Workout).where(Workout.user_id == user.id)).all() == []


def test_watch_workout_types_use_the_strength_vocabulary(session) -> None:
    client, user = athlete(session)
    upload(client, WORKOUT, [workout("W1", "2026-11-09T07:00:00+00:00", 30, "high_intensity_interval_training")])

    assert session.scalar(select(Workout.workout_type).where(Workout.user_id == user.id)) == "hiit"


def test_activity_totals_reach_the_daily_summary(session) -> None:
    client, user = athlete(session)
    upload(client, STEPS, [amount("S1", "2026-11-09T10:00:00+00:00", 10, 1200, "count")])
    upload(client, ACTIVE_ENERGY, [amount("A1", "2026-11-09T10:00:00+00:00", 10, 80, "kcal")])
    upload(client, BASAL_ENERGY, [amount("B1", "2026-11-09T10:00:00+00:00", 10, 20, "kcal")])

    sync_tasks.rebuild_scores(user.id, "2026-11-09", "2026-11-09")
    session.expire_all()
    summary = session.scalar(
        select(DailySummary).where(DailySummary.user_id == user.id, DailySummary.summary_date == DAY)
    )

    assert summary.steps == 1200
    assert summary.active_calories == 80
    assert summary.total_calories == 100
