from __future__ import annotations

from collections import defaultdict
from dataclasses import dataclass
from datetime import date
from statistics import mean

from fastapi import APIRouter, HTTPException, Query
from sqlalchemy import select

from app.api.deps import CurrentUser, DbSession
from app.models import (
    DailyBaseline,
    DailySummary,
    MetricInterval,
    MetricSample,
    SleepSession,
    Workout,
)
from app.services.interval_totals import interval_totals_by_date
from app.services.scores import BASELINE_VERSION


router = APIRouter(tags=["metrics"])


@dataclass(frozen=True)
class MetricDetailConfig:
    metric: str
    unit: str
    summary_field: str | None = None
    sample_metric: str | None = None
    interval_metric: str | None = None
    higher_is_better: bool | None = None
    baseline_metric: str | None = None


METRIC_DETAIL_CONFIGS: dict[str, MetricDetailConfig] = {
    "steps": MetricDetailConfig(
        metric="steps",
        unit="count",
        summary_field="steps",
        interval_metric="steps",
        higher_is_better=True,
    ),
    "active_calories": MetricDetailConfig(
        metric="active_calories",
        unit="kcal",
        summary_field="active_calories",
        interval_metric="active_calories",
    ),
    "total_calories": MetricDetailConfig(
        metric="total_calories",
        unit="kcal",
        summary_field="total_calories",
        interval_metric="total_calories",
    ),
    "distance": MetricDetailConfig(
        metric="distance",
        unit="meters",
        summary_field="distance_meters",
        interval_metric="distance",
    ),
    "heart_rate": MetricDetailConfig(
        metric="heart_rate",
        unit="bpm",
        sample_metric="heart_rate",
    ),
    "resting_heart_rate": MetricDetailConfig(
        metric="resting_heart_rate",
        unit="bpm",
        summary_field="resting_heart_rate",
        sample_metric="resting_heart_rate",
        higher_is_better=False,
        baseline_metric="resting_heart_rate",
    ),
    "heart_rate_variability": MetricDetailConfig(
        metric="heart_rate_variability",
        unit="ms",
        summary_field="heart_rate_variability",
        sample_metric="heart_rate_variability",
        higher_is_better=True,
        baseline_metric="heart_rate_variability",
    ),
    "oxygen_saturation": MetricDetailConfig(
        metric="oxygen_saturation",
        unit="percent",
        summary_field="oxygen_saturation",
        sample_metric="oxygen_saturation",
        baseline_metric="oxygen_saturation",
    ),
    "respiratory_rate": MetricDetailConfig(
        metric="respiratory_rate",
        unit="breaths_per_min",
        summary_field="respiratory_rate",
        sample_metric="respiratory_rate",
        higher_is_better=False,
        baseline_metric="respiratory_rate",
    ),
    "vo2_max": MetricDetailConfig(
        metric="vo2_max",
        unit="ml_per_kg_min",
        sample_metric="vo2_max",
        higher_is_better=True,
    ),
}


@router.get("/metrics/{metric}/detail")
def metric_detail(
    session: DbSession,
    user: CurrentUser,
    metric: str,
    start: date = Query(...),
    end: date = Query(...),
) -> dict[str, object]:
    config = METRIC_DETAIL_CONFIGS.get(metric)
    if config is None:
        raise HTTPException(status_code=404, detail="Unknown metric")
    if end < start:
        raise HTTPException(status_code=422, detail="end must be on or after start")

    summaries = _daily_summaries_by_date(session, user.id, start, end)
    points = _daily_metric_points(session, user.id, config, start, end, summaries)
    baselines = _baselines_by_date(session, user.id, config, start, end)
    populated = [point for point in points if point["value"] is not None]
    current = populated[-1] if populated else None
    previous = populated[-2] if len(populated) >= 2 else None

    return {
        "metric": metric,
        "unit": config.unit,
        "range": {"start": start, "end": end},
        "current": _compact_point(current),
        "previous": _compact_point(previous),
        "trend": _trend_payload(current, previous, populated),
        "baseline": _baseline_payload(current, _baseline_for_point(current, baselines)),
        "data_quality": current["data_quality"] if current else "missing",
        "higher_is_better": config.higher_is_better,
        "series": [_series_point_payload(point, baselines) for point in points],
    }


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


def _daily_summaries_by_date(
    session: DbSession,
    user_id: str,
    start: date,
    end: date,
) -> dict[date, DailySummary]:
    summaries = session.scalars(
        select(DailySummary).where(
            DailySummary.user_id == user_id,
            DailySummary.summary_date >= start,
            DailySummary.summary_date <= end,
        )
    ).all()
    return {summary.summary_date: summary for summary in summaries}


def _daily_metric_points(
    session: DbSession,
    user_id: str,
    config: MetricDetailConfig,
    start: date,
    end: date,
    summaries: dict[date, DailySummary],
) -> list[dict[str, object]]:
    sample_values = _sample_values_by_date(session, user_id, config.sample_metric, start, end)
    interval_totals = _interval_totals_by_date(session, user_id, config.interval_metric, start, end)
    points: list[dict[str, object]] = []
    current = start
    while current <= end:
        value = _summary_value(summaries.get(current), config.summary_field)
        if value is None and current in sample_values:
            value = mean(sample_values[current])
        if value is None and current in interval_totals:
            value = interval_totals[current]
        samples = sample_values.get(current, [])
        point: dict[str, object] = {
            "date": current,
            "value": _rounded(value),
            "unit": config.unit,
            "data_quality": _point_quality(summaries.get(current), value),
        }
        if config.metric == "heart_rate":
            point["min_value"] = _rounded(min(samples)) if samples else None
            point["max_value"] = _rounded(max(samples)) if samples else None
        points.append(point)
        current = date.fromordinal(current.toordinal() + 1)
    return points


def _sample_values_by_date(
    session: DbSession,
    user_id: str,
    sample_metric: str | None,
    start: date,
    end: date,
) -> dict[date, list[float]]:
    if sample_metric is None:
        return {}
    samples = session.scalars(
        select(MetricSample).where(
            MetricSample.user_id == user_id,
            MetricSample.metric == sample_metric,
            MetricSample.civil_date >= start,
            MetricSample.civil_date <= end,
        )
    ).all()
    values: dict[date, list[float]] = defaultdict(list)
    for sample in samples:
        if sample.civil_date:
            values[sample.civil_date].append(sample.value)
    return values


def _interval_totals_by_date(
    session: DbSession,
    user_id: str,
    interval_metric: str | None,
    start: date,
    end: date,
) -> dict[date, float]:
    if interval_metric is None:
        return {}
    totals = interval_totals_by_date(
        session,
        user_id=user_id,
        metrics={interval_metric},
        start=start,
        end=end,
    )
    return {
        day: metric_totals[interval_metric]
        for day, metric_totals in totals.items()
        if interval_metric in metric_totals
    }


def _baselines_by_date(
    session: DbSession,
    user_id: str,
    config: MetricDetailConfig,
    start: date,
    end: date,
) -> dict[date, DailyBaseline]:
    if config.baseline_metric is None:
        return {}
    baselines = session.scalars(
        select(DailyBaseline).where(
            DailyBaseline.user_id == user_id,
            DailyBaseline.metric == config.baseline_metric,
            DailyBaseline.algorithm_version == BASELINE_VERSION,
            DailyBaseline.baseline_date >= start,
            DailyBaseline.baseline_date <= end,
        )
    ).all()
    return {baseline.baseline_date: baseline for baseline in baselines}


def _summary_value(summary: DailySummary | None, field: str | None) -> float | None:
    if summary is None or field is None:
        return None
    value = getattr(summary, field)
    return float(value) if value is not None else None


def _point_quality(summary: DailySummary | None, value: float | None) -> str:
    if value is None:
        return "missing"
    if summary is not None:
        return summary.data_quality
    return "weak"


def _compact_point(point: dict[str, object] | None) -> dict[str, object] | None:
    if point is None:
        return None
    return {"date": point["date"], "value": point["value"], "unit": point["unit"]}


def _trend_payload(
    current: dict[str, object] | None,
    previous: dict[str, object] | None,
    populated: list[dict[str, object]],
) -> dict[str, object]:
    values = [float(point["value"]) for point in populated if point["value"] is not None]
    current_value = float(current["value"]) if current and current["value"] is not None else None
    previous_value = float(previous["value"]) if previous and previous["value"] is not None else None
    absolute_change = (
        _rounded(current_value - previous_value)
        if current_value is not None and previous_value is not None
        else None
    )
    percent_change = (
        _rounded((current_value - previous_value) / abs(previous_value) * 100)
        if current_value is not None and previous_value not in (None, 0)
        else None
    )
    return {
        "direction": _trend_direction(absolute_change),
        "absolute_change": absolute_change,
        "percent_change": percent_change,
        "window_average": _rounded(mean(values)) if values else None,
    }


def _trend_direction(change: float | None) -> str:
    if change is None:
        return "unknown"
    if abs(change) < 0.01:
        return "flat"
    return "up" if change > 0 else "down"


def _baseline_payload(
    current: dict[str, object] | None,
    baseline: DailyBaseline | None,
) -> dict[str, object] | None:
    if current is None or baseline is None:
        return None
    value = current["value"]
    baseline_value = baseline.median_value
    delta = (
        _rounded(float(value) - baseline_value)
        if value is not None and baseline_value is not None
        else None
    )
    return {
        "value": _rounded(baseline_value),
        "lower_bound": _rounded(baseline.lower_bound),
        "upper_bound": _rounded(baseline.upper_bound),
        "comparison": _baseline_comparison(value, baseline),
        "delta": delta,
        "confidence_phase": baseline.confidence_phase,
    }


def _series_baseline_value(baseline: DailyBaseline | None) -> float | None:
    return _rounded(baseline.median_value) if baseline else None


def _series_point_payload(
    point: dict[str, object],
    baselines: dict[date, DailyBaseline],
) -> dict[str, object]:
    baseline = _baseline_for_point(point, baselines)
    return {
        **point,
        "baseline_value": _series_baseline_value(baseline),
        "comparison": _series_baseline_comparison(point, baseline),
    }


def _series_baseline_comparison(
    point: dict[str, object],
    baseline: DailyBaseline | None,
) -> str:
    if baseline is None:
        return "unknown"
    return _baseline_comparison(point["value"], baseline)


def _baseline_for_point(
    point: dict[str, object] | None,
    baselines: dict[date, DailyBaseline],
) -> DailyBaseline | None:
    if point is None or point["value"] is None:
        return None
    point_date = point["date"]
    return baselines.get(point_date) if isinstance(point_date, date) else None


def _baseline_comparison(value: object, baseline: DailyBaseline) -> str:
    if value is None or baseline.lower_bound is None or baseline.upper_bound is None:
        return "unknown"
    numeric_value = float(value)
    if numeric_value < baseline.lower_bound:
        return "below"
    if numeric_value > baseline.upper_bound:
        return "above"
    return "normal"


def _rounded(value: float | None) -> float | None:
    if value is None:
        return None
    return round(float(value), 2)


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
