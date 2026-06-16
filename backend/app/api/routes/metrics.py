from __future__ import annotations

from datetime import date

from fastapi import APIRouter, Query
from sqlalchemy import select

from app.api.deps import CurrentUser, DbSession
from app.models import MetricInterval, MetricSample, SleepSession, Workout


router = APIRouter(tags=["metrics"])

# returns time series data for a metric (like for a hr graph)
@router.get("/metrics/{metric}")
def metric_series(
    session: DbSession,
    user: CurrentUser,
    metric: str,
    start: date = Query(...),
    end: date = Query(...),
) -> dict[str, object]:
    samples = session.scalars(
        select(MetricSample)
        .where(
            MetricSample.user_id == user.id,
            MetricSample.metric == metric,
            MetricSample.civil_date >= start,
            MetricSample.civil_date <= end,
        )
        .order_by(MetricSample.observed_at)
    ).all()
    intervals = session.scalars(
        select(MetricInterval)
        .where(
            MetricInterval.user_id == user.id,
            MetricInterval.metric == metric,
            MetricInterval.civil_date >= start,
            MetricInterval.civil_date <= end,
        )
        .order_by(MetricInterval.start_time)
    ).all()
    return {
        "metric": metric,
        "samples": [
            {
                "observed_at": sample.observed_at,
                "date": sample.civil_date,
                "value": sample.value,
                "unit": sample.unit,
                "source_platform": sample.source_platform,
                "source_device": sample.source_device,
            }
            for sample in samples
        ],
        "intervals": [
            {
                "start_time": interval.start_time,
                "end_time": interval.end_time,
                "date": interval.civil_date,
                "value": interval.value,
                "unit": interval.unit,
                "source_platform": interval.source_platform,
                "source_device": interval.source_device,
            }
            for interval in intervals
        ],
    }


# All the sleep data
@router.get("/sleep")
def sleep_sessions(
    session: DbSession,
    user: CurrentUser,
    start: date = Query(...),
    end: date = Query(...),
) -> list[dict[str, object]]:
    sessions = session.scalars(
        select(SleepSession)
        .where(
            SleepSession.user_id == user.id,
            SleepSession.civil_date >= start,
            SleepSession.civil_date <= end,
        )
        .order_by(SleepSession.start_time)
    ).all()
    return [
        {
            "start_time": item.start_time,
            "end_time": item.end_time,
            "date": item.civil_date,
            "minutes_asleep": item.minutes_asleep,
            "minutes_awake": item.minutes_awake,
            "minutes_in_sleep_period": item.minutes_in_sleep_period,
            "stages_summary": item.stages_summary,
            "is_main_sleep": item.is_main_sleep,
        }
        for item in sessions
    ]


# all the workout data
@router.get("/workouts")
def workouts(
    session: DbSession,
    user: CurrentUser,
    start: date = Query(...),
    end: date = Query(...),
) -> list[dict[str, object]]:
    items = session.scalars(
        select(Workout)
        .where(
            Workout.user_id == user.id,
            Workout.civil_date >= start,
            Workout.civil_date <= end,
        )
        .order_by(Workout.start_time)
    ).all()
    return [
        {
            "workout_type": item.workout_type,
            "start_time": item.start_time,
            "end_time": item.end_time,
            "date": item.civil_date,
            "duration_seconds": item.duration_seconds,
            "raw_summary": item.raw_summary,
        }
        for item in items
    ]

