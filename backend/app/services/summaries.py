from __future__ import annotations

from collections import defaultdict
from datetime import date, timedelta
from statistics import median

from sqlalchemy import select
from sqlalchemy.orm import Session

from app.models import DailySummary, MetricSample, RawHealthRecord, SleepSession, User, Workout
from app.services.body_metrics import preferred_body_sample
from app.services.health_dates import get_or_create_profile, local_date_for_profile
from app.services.interval_totals import interval_totals_by_date
from app.services.hrv import (
    HRV_METRIC,
    RMSSD,
    RMSSD_CALIBRATION_WINDOW_DAYS,
    SDNN,
    hrv_source_approved,
    selected_hrv_type,
)
from app.services.metric_rollups import daily_rollup_values
from app.services.score_helpers import _main_sleep

PREFERRED_SAMPLE_DATA_TYPES: dict[str, str] = {
    HRV_METRIC: "daily-heart-rate-variability",
    "oxygen_saturation": "daily-oxygen-saturation",
    "respiratory_rate": "daily-respiratory-rate",
}


def rebuild_daily_summaries(
    session: Session,
    *,
    user_id: str,
    start: date,
    end: date,
) -> list[DailySummary]:
    session.execute(select(User.id).where(User.id == user_id).with_for_update())
    dates = _date_range(start, end)
    summaries = [_get_or_create_summary(session, user_id, day) for day in dates]
    by_date = {summary.summary_date: summary for summary in summaries}

    interval_totals = interval_totals_by_date(
        session,
        user_id=user_id,
        metrics={
            "steps",
            "active_calories",
            "total_calories",
            "distance",
        },
        start=start,
        end=end,
    )
    rollup_totals = {
        metric: daily_rollup_values(
            session,
            user_id=user_id,
            metric=metric,
            start=start,
            end=end,
            value_kind="sum",
        )
        for metric in ("steps", "active_calories", "total_calories", "distance")
    }
    rollup_sample_averages = {
        metric: daily_rollup_values(
            session,
            user_id=user_id,
            metric=metric,
            start=start,
            end=end,
            value_kind="avg",
        )
        for metric in ("oxygen_saturation",)
    }

    samples = session.scalars(
        select(MetricSample).where(
            MetricSample.user_id == user_id,
            MetricSample.civil_date >= start,
            MetricSample.civil_date <= end,
        )
    ).all()
    sample_values: dict[date, dict[str, list[float]]] = defaultdict(lambda: defaultdict(list))
    preferred_sample_values: dict[date, dict[str, list[float]]] = defaultdict(
        lambda: defaultdict(list)
    )
    for sample in samples:
        if sample.civil_date is None or not _counts_toward_summary(sample):
            continue
        sample_values[sample.civil_date][sample.metric].append(sample.value)
        if _is_preferred_sample(session, sample):
            preferred_sample_values[sample.civil_date][sample.metric].append(sample.value)
    rmssd_nights = _earlier_rmssd_nights(session, user_id, start)

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
            Workout.status == "completed",
            Workout.deleted_at.is_(None),
        )
    ).all()
    workout_counts: dict[date, int] = defaultdict(int)
    for workout in workouts:
        if workout.civil_date:
            workout_counts[workout.civil_date] += 1

    for day, summary in by_date.items():
        totals = interval_totals[day]
        values = sample_values[day]
        preferred_values = preferred_sample_values[day]
        summary.steps = _optional_int(totals.get("steps") or rollup_totals["steps"].get(day))
        summary.active_calories = _optional_float(
            totals.get("active_calories") or rollup_totals["active_calories"].get(day)
        )
        summary.total_calories = _optional_float(
            totals.get("total_calories") or rollup_totals["total_calories"].get(day)
        )
        summary.distance_meters = _optional_float(
            totals.get("distance") or rollup_totals["distance"].get(day)
        )
        summary.resting_heart_rate = _mean(values.get("resting_heart_rate"))
        summary.hrv_rmssd = _preferred_mean(preferred_values, values, HRV_METRIC)
        summary.hrv_sdnn = _nightly_sdnn(session, user_id, day)
        recent_rmssd_nights = sum(
            1 for night in rmssd_nights if day - timedelta(days=RMSSD_CALIBRATION_WINDOW_DAYS) <= night < day
        )
        summary.heart_rate_variability_type = selected_hrv_type(
            summary.hrv_rmssd, summary.hrv_sdnn, recent_rmssd_nights
        )
        summary.heart_rate_variability = {
            RMSSD: summary.hrv_rmssd,
            SDNN: summary.hrv_sdnn,
        }.get(summary.heart_rate_variability_type)
        if summary.hrv_rmssd is not None:
            rmssd_nights.append(day)
        summary.oxygen_saturation = (
            _preferred_mean(preferred_values, values, "oxygen_saturation")
            or rollup_sample_averages["oxygen_saturation"].get(day)
        )
        summary.respiratory_rate = _preferred_mean(preferred_values, values, "respiratory_rate")
        summary.sleep_minutes = sleep_minutes.get(day) or None
        summary.workout_count = workout_counts.get(day, 0)
        summary.data_quality = _data_quality(summary)
        session.add(summary)

    _update_profile_body_metrics(session, user_id=user_id, end=end)
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


def _preferred_mean(
    preferred_values: dict[str, list[float]],
    values: dict[str, list[float]],
    metric: str,
) -> float | None:
    return _mean(preferred_values.get(metric)) or _mean(values.get(metric))


def _counts_toward_summary(sample: MetricSample) -> bool:
    if sample.metric != HRV_METRIC:
        return True
    return sample.measurement_type == RMSSD and hrv_source_approved(sample.source_platform)


def _earlier_rmssd_nights(session: Session, user_id: str, start: date) -> list[date]:
    return list(
        session.scalars(
            select(DailySummary.summary_date).where(
                DailySummary.user_id == user_id,
                DailySummary.summary_date >= start - timedelta(days=RMSSD_CALIBRATION_WINDOW_DAYS),
                DailySummary.summary_date < start,
                DailySummary.hrv_rmssd.is_not(None),
            )
        ).all()
    )


def _nightly_sdnn(session: Session, user_id: str, day: date) -> float | None:
    sleep = _main_sleep(session, user_id, day)
    if sleep is None:
        return None
    samples = session.scalars(
        select(MetricSample).where(
            MetricSample.user_id == user_id,
            MetricSample.metric == HRV_METRIC,
            MetricSample.measurement_type == SDNN,
            MetricSample.observed_at >= sleep.start_time,
            MetricSample.observed_at <= sleep.end_time,
        )
    ).all()
    values = [
        sample.value
        for sample in samples
        if sample.value > 0 and hrv_source_approved(sample.source_platform)
    ]
    return float(median(values)) if values else None


def _is_preferred_sample(session: Session, sample: MetricSample) -> bool:
    preferred_data_type = PREFERRED_SAMPLE_DATA_TYPES.get(sample.metric)
    if preferred_data_type is None or sample.raw_record_id is None:
        return False
    raw_record = session.get(RawHealthRecord, sample.raw_record_id)
    return raw_record is not None and raw_record.data_type == preferred_data_type


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


def _update_profile_body_metrics(session: Session, *, user_id: str, end: date) -> None:
    profile = get_or_create_profile(session, user_id)
    end = local_date_for_profile(profile)
    latest_weight = preferred_body_sample(
        session,
        user_id=user_id,
        metric="weight",
        preference=profile.weight_source_preference,
        end=end,
    )
    latest_height = preferred_body_sample(
        session,
        user_id=user_id,
        metric="height",
        preference=profile.height_source_preference,
        end=end,
    )
    if latest_weight is not None:
        profile.weight_kg = latest_weight.value
    if latest_height is not None:
        profile.height_cm = latest_height.value * 100
    if latest_weight is not None or latest_height is not None:
        session.add(profile)
