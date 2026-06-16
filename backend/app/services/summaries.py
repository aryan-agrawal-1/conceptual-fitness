from __future__ import annotations

from collections import defaultdict
from datetime import date

from sqlalchemy import select
from sqlalchemy.orm import Session

from app.models import DailySummary, MetricInterval, MetricSample, SleepSession, Workout


def rebuild_daily_summaries(
    session: Session,
    *,
    user_id: str,
    start: date,
    end: date,
) -> list[DailySummary]:
    dates = _date_range(start, end)
    summaries = [_get_or_create_summary(session, user_id, day) for day in dates]
    by_date = {summary.summary_date: summary for summary in summaries}

    intervals = session.scalars(
        select(MetricInterval).where(
            MetricInterval.user_id == user_id,
            MetricInterval.civil_date >= start,
            MetricInterval.civil_date <= end,
        )
    ).all()
    interval_totals: dict[date, dict[str, float]] = defaultdict(lambda: defaultdict(float))
    for interval in intervals:
        if interval.civil_date:
            interval_totals[interval.civil_date][interval.metric] += interval.value

    samples = session.scalars(
        select(MetricSample).where(
            MetricSample.user_id == user_id,
            MetricSample.civil_date >= start,
            MetricSample.civil_date <= end,
        )
    ).all()
    sample_values: dict[date, dict[str, list[float]]] = defaultdict(lambda: defaultdict(list))
    for sample in samples:
        if sample.civil_date:
            sample_values[sample.civil_date][sample.metric].append(sample.value)

    sleeps = session.scalars(
        select(SleepSession).where(
            SleepSession.user_id == user_id,
            SleepSession.civil_date >= start,
            SleepSession.civil_date <= end,
        )
    ).all()
    sleep_minutes: dict[date, int] = defaultdict(int)
    for sleep in sleeps:
        if sleep.civil_date and sleep.minutes_asleep:
            sleep_minutes[sleep.civil_date] += sleep.minutes_asleep

    workouts = session.scalars(
        select(Workout).where(
            Workout.user_id == user_id,
            Workout.civil_date >= start,
            Workout.civil_date <= end,
        )
    ).all()
    workout_counts: dict[date, int] = defaultdict(int)
    for workout in workouts:
        if workout.civil_date:
            workout_counts[workout.civil_date] += 1

    for day, summary in by_date.items():
        totals = interval_totals[day]
        values = sample_values[day]
        summary.steps = _optional_int(totals.get("steps"))
        summary.active_calories = _optional_float(totals.get("active_calories"))
        summary.total_calories = _optional_float(totals.get("total_calories"))
        summary.distance_meters = _optional_float(totals.get("distance"))
        summary.resting_heart_rate = _mean(values.get("resting_heart_rate"))
        summary.heart_rate_variability = _mean(values.get("heart_rate_variability"))
        summary.oxygen_saturation = _mean(values.get("oxygen_saturation"))
        summary.respiratory_rate = _mean(values.get("respiratory_rate"))
        summary.sleep_minutes = sleep_minutes.get(day) or None
        summary.workout_count = workout_counts.get(day, 0)
        summary.data_quality = _data_quality(summary)
        session.add(summary)

    session.flush()
    return summaries


def _get_or_create_summary(session: Session, user_id: str, summary_date: date) -> DailySummary:
    summary = session.scalar(
        select(DailySummary).where(
            DailySummary.user_id == user_id,
            DailySummary.summary_date == summary_date,
        )
    )
    if summary is not None:
        return summary
    summary = DailySummary(user_id=user_id, summary_date=summary_date)
    session.add(summary)
    session.flush()
    return summary


def _date_range(start: date, end: date) -> list[date]:
    days: list[date] = []
    current = start
    while current <= end:
        days.append(current)
        current = date.fromordinal(current.toordinal() + 1)
    return days


def _mean(values: list[float] | None) -> float | None:
    if not values:
        return None
    return sum(values) / len(values)


def _optional_int(value: float | None) -> int | None:
    if value is None or value == 0:
        return None
    return int(value)


def _optional_float(value: float | None) -> float | None:
    if value is None or value == 0:
        return None
    return float(value)


def _data_quality(summary: DailySummary) -> str:
    populated = sum(
        value is not None
        for value in (
            summary.steps,
            summary.active_calories,
            summary.total_calories,
            summary.distance_meters,
            summary.resting_heart_rate,
            summary.heart_rate_variability,
            summary.oxygen_saturation,
            summary.respiratory_rate,
            summary.sleep_minutes,
        )
    )
    if populated >= 6:
        return "strong"
    if populated >= 3:
        return "moderate"
    if populated >= 1:
        return "weak"
    return "missing"

