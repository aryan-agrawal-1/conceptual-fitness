from __future__ import annotations

from collections import Counter, defaultdict
from dataclasses import dataclass
from datetime import UTC, date, datetime, timedelta
from statistics import mean
from typing import Any

from fastapi import APIRouter, HTTPException, Query
from sqlalchemy import select

from app.api.deps import CurrentUser, DbSession
from app.models import (
    DailyBaseline,
    DailyScore,
    DailySummary,
    MetricInterval,
    MetricMinuteRollup,
    MetricSample,
    RawHealthRecord,
    SleepSession,
    UserProfile,
    Workout,
)
from app.services.interval_totals import interval_totals_by_date
from app.services.health_dates import (
    estimated_max_heart_rate,
    get_or_create_profile,
    local_date_for_profile,
    local_week_start,
    timezone_for_profile,
)
from app.services.scores import BASELINE_VERSION, SLEEP_SCORE_VERSION, _adjusted_sleep_need_minutes
from app.services.metric_rollups import (
    HIGH_VOLUME_METRICS,
    RollupPoint,
    SUM_METRICS,
    daily_rollup_values,
    rollup_points_for_metric,
)


router = APIRouter(tags=["metrics"])
_ONE_MINUTE = timedelta(minutes=1)


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
    "skin_temperature_variation": MetricDetailConfig(
        metric="skin_temperature_variation",
        unit="celsius",
        sample_metric="skin_temperature_variation",
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
    start: date | None = Query(default=None),
    end: date | None = Query(default=None),
    selected_date: date | None = Query(default=None, alias="date"),
    timeframe: str | None = Query(default=None, pattern="^(day|week|month|year)$"),
) -> dict[str, object]:
    config = METRIC_DETAIL_CONFIGS.get(metric)
    if config is None:
        raise HTTPException(status_code=404, detail="Unknown metric")
    if selected_date is not None or timeframe is not None or start is None or end is None:
        profile = get_or_create_profile(session, user.id)
        anchor = selected_date or local_date_for_profile(profile)
        selected_timeframe = timeframe or "week"
        start, end = _metric_detail_window(anchor, selected_timeframe)
    else:
        selected_timeframe = None

    if end < start:
        raise HTTPException(status_code=422, detail="end must be on or after start")

    return _metric_detail_payload(
        session,
        user_id=user.id,
        metric=metric,
        config=config,
        start=start,
        end=end,
        timeframe=selected_timeframe,
    )


def _metric_detail_payload(
    session: DbSession,
    *,
    user_id: str,
    metric: str,
    config: MetricDetailConfig,
    start: date,
    end: date,
    timeframe: str | None = None,
) -> dict[str, object]:
    summaries = _daily_summaries_by_date(session, user_id, start, end)
    points = _daily_metric_points(session, user_id, config, start, end, summaries)
    baselines = _baselines_by_date(session, user_id, config, start, end)
    previous_points: list[dict[str, object]] = []
    if timeframe is not None:
        previous_start, previous_end = _previous_metric_detail_window(start, end, timeframe)
        previous_summaries = _daily_summaries_by_date(session, user_id, previous_start, previous_end)
        previous_points = _daily_metric_points(
            session,
            user_id,
            config,
            previous_start,
            previous_end,
            previous_summaries,
        )
    populated = [point for point in points if point["value"] is not None]
    current = populated[-1] if populated else None
    previous = populated[-2] if len(populated) >= 2 else None
    series = [_series_point_payload(point, baselines) for point in points]

    return {
        "metric": metric,
        "unit": config.unit,
        "timeframe": timeframe,
        "range": {"start": start, "end": end},
        "current": _compact_point(current),
        "previous": _compact_point(previous),
        "trend": _trend_payload(current, previous, populated),
        "baseline": _baseline_payload(current, _baseline_for_point(current, baselines)),
        "data_quality": current["data_quality"] if current else "missing",
        "higher_is_better": config.higher_is_better,
        "summary": _metric_detail_summary(config, timeframe, points, previous_points, baselines, start, end),
        "chart": {
            "kind": _metric_chart_kind(config, timeframe),
            "points": series,
        },
        "distribution": _metric_detail_distribution(series),
        "coverage": _metric_detail_coverage(points, start, end),
        "series": series,
    }


def _metric_detail_window(anchor: date, timeframe: str) -> tuple[date, date]:
    if timeframe == "day":
        return anchor, anchor
    if timeframe == "week":
        start = local_week_start(anchor)
        return start, start + timedelta(days=6)
    if timeframe == "month":
        start = anchor.replace(day=1)
        if anchor.month == 12:
            next_month = date(anchor.year + 1, 1, 1)
        else:
            next_month = date(anchor.year, anchor.month + 1, 1)
        return start, next_month - timedelta(days=1)
    start = date(anchor.year, 1, 1)
    return start, date(anchor.year, 12, 31)


def _previous_metric_detail_window(start: date, end: date, timeframe: str) -> tuple[date, date]:
    if timeframe == "day":
        previous = start - timedelta(days=1)
        return previous, previous
    if timeframe == "week":
        previous_start = start - timedelta(days=7)
        return previous_start, previous_start + timedelta(days=6)
    if timeframe == "month":
        previous_end = start - timedelta(days=1)
        previous_start = previous_end.replace(day=1)
        return previous_start, previous_end
    previous_start = date(start.year - 1, 1, 1)
    return previous_start, date(start.year - 1, 12, 31)


def _metric_detail_summary(
    config: MetricDetailConfig,
    timeframe: str | None,
    points: list[dict[str, object]],
    previous_points: list[dict[str, object]],
    baselines: dict[date, DailyBaseline],
    start: date,
    end: date,
) -> dict[str, object]:
    populated = [point for point in points if point["value"] is not None]
    values = [float(point["value"]) for point in populated if point["value"] is not None]
    latest = populated[-1] if populated else None
    latest_value = float(latest["value"]) if latest and latest["value"] is not None else None
    current_average = mean(values) if values else None
    previous_values = [float(point["value"]) for point in previous_points if point["value"] is not None]
    previous_average = mean(previous_values) if previous_values else None
    absolute_change = (
        _rounded(current_average - previous_average)
        if current_average is not None and previous_average is not None
        else None
    )
    baseline = _period_baseline_payload(populated, baselines)
    period_days = (end - start).days + 1

    return {
        "title": _metric_detail_title(config, timeframe),
        "primary_value": _rounded(current_average),
        "latest_value": _rounded(latest_value),
        "previous_period_value": _rounded(previous_average),
        "baseline_value": baseline["value"],
        "baseline_lower_bound": baseline["lower_bound"],
        "baseline_upper_bound": baseline["upper_bound"],
        "baseline_relation": baseline["comparison"],
        "baseline_delta": baseline["delta"],
        "confidence_phase": baseline["confidence_phase"],
        "trend": _trend_direction(absolute_change),
        "absolute_change": absolute_change,
        "valid_days": len(values),
        "missing_days": period_days - len(values),
        "period_days": period_days,
        "data_quality": latest["data_quality"] if latest else "missing",
    }


def _metric_detail_title(config: MetricDetailConfig, timeframe: str | None) -> str:
    if config.metric == "heart_rate_variability":
        if timeframe == "year":
            return "Yearly HRV"
        if timeframe == "month":
            return "Monthly HRV"
        if timeframe == "week":
            return "Weekly HRV"
        if timeframe == "day":
            return "Daily HRV"
        return "HRV"
    if config.metric == "resting_heart_rate":
        if timeframe == "year":
            return "Yearly Resting HR"
        if timeframe == "month":
            return "Monthly Resting HR"
        if timeframe == "week":
            return "Weekly Resting HR"
        if timeframe == "day":
            return "Daily Resting HR"
        return "Resting HR"
    return config.metric.replace("_", " ").title()


def _period_baseline_payload(
    points: list[dict[str, object]],
    baselines: dict[date, DailyBaseline],
) -> dict[str, object]:
    entries: list[DailyBaseline] = []
    values: list[float] = []
    for point in points:
        point_date = point["date"]
        if not isinstance(point_date, date) or point["value"] is None:
            continue
        baseline = baselines.get(point_date)
        if baseline is None:
            continue
        entries.append(baseline)
        values.append(float(point["value"]))

    if not entries or not values:
        return {
            "value": None,
            "lower_bound": None,
            "upper_bound": None,
            "comparison": "unknown",
            "delta": None,
            "confidence_phase": None,
        }

    baseline_value = _rounded_mean([item.median_value for item in entries if item.median_value is not None])
    lower_bound = _rounded_mean([item.lower_bound for item in entries if item.lower_bound is not None])
    upper_bound = _rounded_mean([item.upper_bound for item in entries if item.upper_bound is not None])
    average_value = mean(values)
    return {
        "value": baseline_value,
        "lower_bound": lower_bound,
        "upper_bound": upper_bound,
        "comparison": _baseline_comparison_for_bounds(average_value, lower_bound, upper_bound),
        "delta": _rounded(average_value - baseline_value) if baseline_value is not None else None,
        "confidence_phase": entries[-1].confidence_phase,
    }


def _baseline_comparison_for_bounds(
    value: float | None,
    lower_bound: float | None,
    upper_bound: float | None,
) -> str:
    if value is None or lower_bound is None or upper_bound is None:
        return "unknown"
    if value < lower_bound:
        return "below"
    if value > upper_bound:
        return "above"
    return "normal"


def _rounded_mean(values: list[float]) -> float | None:
    return _rounded(mean(values)) if values else None


def _metric_chart_kind(config: MetricDetailConfig, timeframe: str | None) -> str:
    if config.metric == "heart_rate_variability":
        return "daily_hrv_baseline" if timeframe != "year" else "yearly_hrv_baseline"
    return "daily_metric_baseline"


def _metric_detail_distribution(series: list[dict[str, object]]) -> dict[str, object]:
    counts = Counter(point.get("comparison") for point in series)
    return {
        "within_count": counts.get("normal", 0),
        "below_count": counts.get("below", 0),
        "above_count": counts.get("above", 0),
        "missing_count": len([point for point in series if point.get("value") is None]),
        "unknown_count": counts.get("unknown", 0),
        "longest_below_streak": _longest_comparison_streak(series, "below"),
    }


def _longest_comparison_streak(series: list[dict[str, object]], comparison: str) -> int:
    longest = 0
    current = 0
    for point in series:
        if point.get("comparison") == comparison:
            current += 1
            longest = max(longest, current)
        else:
            current = 0
    return longest


def _metric_detail_coverage(
    points: list[dict[str, object]],
    start: date,
    end: date,
) -> dict[str, object]:
    expected_days = (end - start).days + 1
    valid_days = len([point for point in points if point["value"] is not None])
    quality_counts = Counter(str(point["data_quality"]) for point in points if point.get("data_quality"))
    return {
        "expected_days": expected_days,
        "valid_days": valid_days,
        "completeness": round(valid_days / expected_days, 3) if expected_days else None,
        "quality_counts": dict(quality_counts),
    }


DEFAULT_DASHBOARD_METRICS = (
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
)


@router.get("/metrics/dashboard-summary")
def metrics_dashboard_summary(
    session: DbSession,
    user: CurrentUser,
    metrics: str | None = Query(
        default=None,
        description="Comma-separated metric keys. Defaults to the dashboard card metrics.",
    ),
    date: date | None = Query(default=None),
    window_days: int = Query(default=30, ge=1, le=365),
) -> dict[str, object]:
    profile = get_or_create_profile(session, user.id)
    end = date or datetime.now(timezone_for_profile(profile)).date()
    metric_names = _parse_dashboard_metric_names(metrics)
    return {
        "user_id": user.id,
        "date": end,
        "window_days": window_days,
        "metrics": dashboard_metric_summaries(
            session,
            user_id=user.id,
            metric_names=metric_names,
            end=end,
            window_days=window_days,
        ),
    }


def dashboard_metric_summaries(
    session: DbSession,
    *,
    user_id: str,
    metric_names: list[str],
    end: date,
    window_days: int,
) -> dict[str, object]:
    start = date.fromordinal(end.toordinal() - window_days + 1)
    summaries = _daily_summaries_by_date(session, user_id, start, end)
    payload: dict[str, object] = {}
    for metric_name in metric_names:
        if metric_name == "sleep":
            payload[metric_name] = _sleep_dashboard_summary(session, user_id, start, end)
            continue
        if metric_name == "heart_rate":
            payload[metric_name] = _latest_heart_rate_dashboard_summary(
                session,
                user_id=user_id,
                start=start,
                end=end,
                summaries=summaries,
            )
            continue

        config = METRIC_DETAIL_CONFIGS.get(metric_name)
        if config is None:
            raise HTTPException(status_code=404, detail=f"Unknown metric: {metric_name}")
        points = _daily_metric_points(session, user_id, config, start, end, summaries)
        baselines = _baselines_by_date(session, user_id, config, start, end)
        populated = [point for point in points if point["value"] is not None]
        current = populated[-1] if populated else None
        previous = populated[-2] if len(populated) >= 2 else None
        payload[metric_name] = {
            "metric": metric_name,
            "unit": config.unit,
            "current": _compact_point(current),
            "previous": _compact_point(previous),
            "trend": _trend_payload(current, previous, populated),
            "baseline": _baseline_payload(current, _baseline_for_point(current, baselines)),
            "data_quality": current["data_quality"] if current else "missing",
            "higher_is_better": config.higher_is_better,
        }
    return payload


def _latest_heart_rate_dashboard_summary(
    session: DbSession,
    *,
    user_id: str,
    start: date,
    end: date,
    summaries: dict[date, DailySummary],
) -> dict[str, object]:
    config = METRIC_DETAIL_CONFIGS["heart_rate"]
    points = _latest_heart_rate_points(session, user_id=user_id, start=start, end=end, summaries=summaries)
    if not points:
        points = _daily_metric_points(session, user_id, config, start, end, summaries)
    populated = [point for point in points if point["value"] is not None]
    current = populated[-1] if populated else None
    previous = populated[-2] if len(populated) >= 2 else None
    return {
        "metric": "heart_rate",
        "unit": config.unit,
        "current": _compact_point(current),
        "previous": _compact_point(previous),
        "trend": _trend_payload(current, previous, populated),
        "baseline": None,
        "data_quality": current["data_quality"] if current else "missing",
        "higher_is_better": config.higher_is_better,
    }


def _latest_heart_rate_points(
    session: DbSession,
    *,
    user_id: str,
    start: date,
    end: date,
    summaries: dict[date, DailySummary],
) -> list[dict[str, object]]:
    rollups = [
        row
        for row in session.scalars(
            select(MetricMinuteRollup)
            .where(
                MetricMinuteRollup.user_id == user_id,
                MetricMinuteRollup.metric == "heart_rate",
                MetricMinuteRollup.civil_date >= start,
                MetricMinuteRollup.civil_date <= end,
                MetricMinuteRollup.avg_value.is_not(None),
            )
            .order_by(MetricMinuteRollup.bucket_start.desc())
            .limit(2)
        ).all()
        if row.avg_value is not None
    ]
    if rollups:
        return [
            {
                "date": row.bucket_start,
                "value": _rounded(row.avg_value),
                "unit": row.unit,
                "data_quality": _point_quality(summaries.get(row.civil_date), row.avg_value),
            }
            for row in reversed(rollups)
        ]

    samples = session.scalars(
        select(MetricSample)
        .where(
            MetricSample.user_id == user_id,
            MetricSample.metric == "heart_rate",
            MetricSample.civil_date >= start,
            MetricSample.civil_date <= end,
        )
        .order_by(MetricSample.observed_at.desc())
        .limit(2)
    ).all()
    return [
        {
            "date": sample.observed_at,
            "value": _rounded(sample.value),
            "unit": sample.unit,
            "data_quality": _point_quality(summaries.get(sample.civil_date), sample.value),
        }
        for sample in reversed(samples)
    ]


def _parse_dashboard_metric_names(metrics: str | None) -> list[str]:
    if metrics is None:
        return list(DEFAULT_DASHBOARD_METRICS)
    names = [item.strip() for item in metrics.split(",") if item.strip()]
    return names or list(DEFAULT_DASHBOARD_METRICS)


def _sleep_dashboard_summary(
    session: DbSession,
    user_id: str,
    start: date,
    end: date,
) -> dict[str, object]:
    sessions = _sleep_sessions_for_range(session, user_id, start, end)
    main_by_date = _main_sleeps_by_date(sessions)
    scores = _sleep_scores_by_date(session, user_id, start, end)
    points = [
        {
            "date": day,
            "value": main_by_date[day].minutes_asleep,
            "unit": "minutes",
            "data_quality": scores[day].data_quality if day in scores else "weak",
        }
        for day in _date_range(start, end)
        if day in main_by_date and main_by_date[day].minutes_asleep is not None
    ]
    current = points[-1] if points else None
    previous = points[-2] if len(points) >= 2 else None
    return {
        "metric": "sleep",
        "unit": "minutes",
        "current": _compact_point(current),
        "previous": _compact_point(previous),
        "trend": _trend_payload(current, previous, points),
        "baseline": None,
        "data_quality": current["data_quality"] if current else "missing",
        "higher_is_better": True,
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
    rollup_points = (
        rollup_points_for_metric(session, user_id=user.id, metric=metric, start=start, end=end)
        if metric in HIGH_VOLUME_METRICS
        else []
    )
    samples = []
    intervals = []
    if not rollup_points:
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
                "observed_at": point.observed_at,
                "date": point.civil_date,
                "value": point.value,
                "unit": point.unit,
                "source_platform": point.source_platform,
                "source_device": point.source_device,
            }
            for point in [*rollup_points, *samples]
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
@router.get("/sleep/detail")
def sleep_detail(
    session: DbSession,
    user: CurrentUser,
    start: date | None = Query(default=None),
    end: date | None = Query(default=None),
    selected_date: date | None = Query(default=None, alias="date"),
    timeframe: str | None = Query(default=None, pattern="^(day|week|month|year)$"),
) -> dict[str, object]:
    if selected_date is not None or timeframe is not None or start is None or end is None:
        profile = get_or_create_profile(session, user.id)
        anchor = selected_date or local_date_for_profile(profile)
        selected_timeframe = timeframe or "week"
        period_start, period_end = _sleep_detail_window(anchor, selected_timeframe)
        return _sleep_score_detail(
            session,
            user_id=user.id,
            profile=profile,
            timeframe=selected_timeframe,
            start=period_start,
            end=period_end,
        )

    if end < start:
        raise HTTPException(status_code=422, detail="end must be on or after start")

    profile = get_or_create_profile(session, user.id)
    sessions = _sleep_sessions_for_range(session, user.id, start, end)
    main_by_date = _main_sleeps_by_date(sessions)
    scores = _sleep_scores_by_date(session, user.id, start, end)
    main_sleeps = [main_by_date[day] for day in _date_range(start, end) if day in main_by_date]
    current = main_sleeps[-1] if main_sleeps else None
    previous = main_sleeps[-2] if len(main_sleeps) >= 2 else None
    current_score = scores.get(current.civil_date) if current and current.civil_date else None
    series = [_sleep_series_point(day, profile, main_by_date.get(day), scores.get(day)) for day in _date_range(start, end)]

    return {
        "range": {"start": start, "end": end},
        "current": _sleep_session_payload(profile, current, include_stages=True),
        "previous": _sleep_session_payload(profile, previous),
        "score": _sleep_score_payload(current_score),
        "consistency": _sleep_consistency_payload(current_score),
        "trend": _sleep_trend_payload(current, previous, series),
        "series": series,
        "sessions": [
            _sleep_session_payload(profile, item)
            for item in sessions
        ],
    }


def _sleep_score_detail(
    session: DbSession,
    *,
    user_id: str,
    profile: UserProfile,
    timeframe: str,
    start: date,
    end: date,
) -> dict[str, object]:
    sessions = _sleep_sessions_for_range(session, user_id, start, end)
    main_by_date = _main_sleeps_by_date(sessions)
    scores_by_date = _sleep_scores_by_date(session, user_id, start, end)
    scores = [scores_by_date[day] for day in _date_range(start, end) if day in scores_by_date]
    main_sleeps = [main_by_date[day] for day in _date_range(start, end) if day in main_by_date]
    latest_sleep = main_sleeps[-1] if main_sleeps else None
    latest_score = _latest_sleep_score(scores)

    return {
        "timeframe": timeframe,
        "start": start,
        "end": end,
        "summary": _sleep_detail_summary(
            session,
            user_id=user_id,
            profile=profile,
            timeframe=timeframe,
            start=start,
            end=end,
            main_by_date=main_by_date,
            scores=scores,
            latest_sleep=latest_sleep,
            latest_score=latest_score,
        ),
        "chart": _sleep_detail_chart(
            session,
            user_id=user_id,
            profile=profile,
            timeframe=timeframe,
            start=start,
            end=end,
            main_by_date=main_by_date,
            scores_by_date=scores_by_date,
            latest_sleep=latest_sleep,
        ),
        "components": _sleep_detail_components(scores),
        "context": _sleep_detail_context(
            session,
            user_id=user_id,
            profile=profile,
            timeframe=timeframe,
            start=start,
            end=end,
            main_by_date=main_by_date,
            scores=scores,
            latest_sleep=latest_sleep,
            latest_score=latest_score,
        ),
        "guidance": _sleep_detail_guidance(timeframe, scores, main_sleeps),
        "reasons": latest_score.reasons if latest_score else [],
        "sessions": [_sleep_session_payload(profile, item) for item in sessions],
        "data_quality": _sleep_detail_data_quality(scores, start, end),
    }


def _sleep_detail_window(anchor: date, timeframe: str) -> tuple[date, date]:
    if timeframe == "day":
        return anchor, anchor
    if timeframe == "week":
        start = local_week_start(anchor)
        return start, start + timedelta(days=6)
    if timeframe == "month":
        start = anchor.replace(day=1)
        next_month = (
            date(anchor.year + 1, 1, 1)
            if anchor.month == 12
            else date(anchor.year, anchor.month + 1, 1)
        )
        return start, next_month - timedelta(days=1)
    return date(anchor.year, 1, 1), date(anchor.year, 12, 31)


def _sleep_detail_summary(
    session: DbSession,
    *,
    user_id: str,
    profile: UserProfile,
    timeframe: str,
    start: date,
    end: date,
    main_by_date: dict[date, SleepSession],
    scores: list[DailyScore],
    latest_sleep: SleepSession | None,
    latest_score: DailyScore | None,
) -> dict[str, object]:
    stats = _sleep_period_stats(session, user_id, profile, start, end, main_by_date)
    score_values = [float(score.value) for score in scores if score.value is not None]
    average_score = round(mean(score_values), 1) if score_values else None
    primary = latest_score.value if timeframe == "day" and latest_score else average_score
    title = {
        "day": "Last night's sleep",
        "week": "Weekly sleep",
        "month": "Monthly sleep",
        "year": "Yearly sleep",
    }[timeframe]

    summary: dict[str, object] = {
        "title": title,
        "primary_value": primary,
        "average_score": average_score,
        "latest_score": latest_score.value if latest_score else None,
        "sleep_band": _sleep_band(primary),
        "status": latest_score.status.value if latest_score else "missing_data",
        "valid_days": len(score_values),
        "period_days": (end - start).days + 1,
        "average_sleep_minutes": stats["average_sleep_minutes"],
        "target_sleep_minutes": stats["average_target_minutes"],
        "target_met_nights": stats["target_met_nights"],
        "slept_nights": stats["slept_nights"],
        "sleep_debt_minutes": stats["sleep_debt_minutes"],
    }
    if timeframe == "day":
        target = _sleep_target_for_day(session, user_id, profile, start)
        summary.update(
            {
                "sleep_minutes": latest_sleep.minutes_asleep if latest_sleep else None,
                "target_sleep_minutes": target,
                "bedtime": _local_clock_time(profile, latest_sleep.start_time) if latest_sleep else None,
                "wake_time": _local_clock_time(profile, latest_sleep.end_time) if latest_sleep else None,
                "data_quality": latest_score.data_quality if latest_score else "missing",
            }
        )
    return summary


def _sleep_detail_chart(
    session: DbSession,
    *,
    user_id: str,
    profile: UserProfile,
    timeframe: str,
    start: date,
    end: date,
    main_by_date: dict[date, SleepSession],
    scores_by_date: dict[date, DailyScore],
    latest_sleep: SleepSession | None,
) -> dict[str, object]:
    if timeframe == "day":
        return {
            "kind": "stage_timeline",
            "points": _sleep_stage_timeline(profile, latest_sleep),
            "stage_summary": _sleep_stages_summary(latest_sleep) if latest_sleep else [],
        }
    if timeframe in {"week", "month"}:
        points = [
            _sleep_daily_chart_point(
                session,
                user_id=user_id,
                profile=profile,
                day=day,
                sleep=main_by_date.get(day),
                score=scores_by_date.get(day),
            )
            for day in _date_range(start, end)
        ]
        return {
            "kind": "weekly_sleep_pattern" if timeframe == "week" else "daily_sleep_bars",
            "points": points,
        }

    sleeps_by_month: dict[date, dict[date, SleepSession]] = defaultdict(dict)
    scores_by_month: dict[date, list[DailyScore]] = defaultdict(list)
    for day, sleep in main_by_date.items():
        sleeps_by_month[date(day.year, day.month, 1)][day] = sleep
    for score in scores_by_date.values():
        scores_by_month[date(score.score_date.year, score.score_date.month, 1)].append(score)

    points = []
    month = date(start.year, 1, 1)
    while month <= date(start.year, 12, 1):
        month_end = (
            date(month.year + 1, 1, 1) - timedelta(days=1)
            if month.month == 12
            else date(month.year, month.month + 1, 1) - timedelta(days=1)
        )
        stats = _sleep_period_stats(
            session,
            user_id,
            profile,
            month,
            min(month_end, end),
            sleeps_by_month.get(month, {}),
        )
        values = [float(score.value) for score in scores_by_month.get(month, []) if score.value is not None]
        points.append(
            {
                "month_start_date": month,
                "average_sleep_minutes": stats["average_sleep_minutes"],
                "target_sleep_minutes": stats["average_target_minutes"],
                "target_met_nights": stats["target_met_nights"],
                "sleep_debt_minutes": stats["sleep_debt_minutes"],
                "average_score": round(mean(values), 1) if values else None,
                "scored_days": len(values),
            }
        )
        month = date(month.year + 1, 1, 1) if month.month == 12 else date(month.year, month.month + 1, 1)
    return {"kind": "monthly_sleep_bars", "points": points}


def _sleep_daily_chart_point(
    session: DbSession,
    *,
    user_id: str,
    profile: UserProfile,
    day: date,
    sleep: SleepSession | None,
    score: DailyScore | None,
) -> dict[str, object]:
    target = _sleep_target_for_day(session, user_id, profile, day)
    minutes = sleep.minutes_asleep if sleep else None
    return {
        "date": day,
        "bedtime": _local_clock_time(profile, sleep.start_time) if sleep else None,
        "wake_time": _local_clock_time(profile, sleep.end_time) if sleep else None,
        "sleep_start_minute": _sleep_local_minute(profile, sleep.start_time) if sleep else None,
        "sleep_end_minute": _sleep_local_minute(profile, sleep.end_time) if sleep else None,
        "duration_minutes": minutes,
        "target_sleep_minutes": target,
        "sleep_debt_minutes": max(0, target - minutes) if minutes is not None else None,
        "target_met": minutes >= target if minutes is not None else False,
        "score": _rounded(score.value) if score and score.value is not None else None,
        "sleep_band": _sleep_band(score.value if score else None),
        "data_quality": score.data_quality if score else ("weak" if sleep else "missing"),
    }


def _sleep_stage_timeline(profile: UserProfile, sleep: SleepSession | None) -> list[dict[str, object]]:
    if sleep is None:
        return []
    points = []
    covered_minutes = 0.0
    for stage in sleep.stages or []:
        stage_type = stage.get("type") or stage.get("stage")
        start_time = _parse_stage_datetime(stage.get("startTime"))
        end_time = _parse_stage_datetime(stage.get("endTime"))
        if not stage_type or start_time is None or end_time is None:
            continue
        minutes = max(0.0, (end_time - start_time).total_seconds() / 60)
        if minutes <= 0:
            continue
        covered_minutes += minutes
        points.append(
            {
                "stage": str(stage_type).upper(),
                "start_time": start_time,
                "end_time": end_time,
                "start_clock": _local_clock_time(profile, start_time),
                "end_clock": _local_clock_time(profile, end_time),
                "start_minute": _sleep_local_minute(profile, start_time),
                "end_minute": _sleep_local_minute(profile, end_time),
                "offset_start_minutes": round(
                    max(0.0, (start_time - sleep.start_time).total_seconds() / 60),
                    1,
                ),
                "offset_end_minutes": round(
                    max(0.0, (end_time - sleep.start_time).total_seconds() / 60),
                    1,
                ),
                "duration_minutes": round(minutes, 1),
            }
        )
    if not _stage_timeline_has_usable_coverage(sleep, covered_minutes):
        return []
    return points


def _sleep_detail_components(scores: list[DailyScore]) -> dict[str, object]:
    valid_scores = [score for score in scores if score.value is not None]
    latest = _latest_sleep_score(scores)
    latest_items = _sleep_component_items(latest)
    averages: dict[str, list[float]] = defaultdict(list)
    for score in valid_scores:
        for item in _sleep_component_items(score):
            component_score = item.get("score")
            if isinstance(component_score, int | float):
                averages[str(item["key"])].append(float(component_score))
    return {
        "items": latest_items,
        "average_items": [
            {
                "key": key,
                "label": _SLEEP_COMPONENT_LABELS.get(key, key.replace("_", " ").title()),
                "score": round(mean(values), 1),
                "weight": _SLEEP_COMPONENT_WEIGHTS.get(key),
            }
            for key, values in averages.items()
            if values
        ],
    }


def _sleep_component_items(score: DailyScore | None) -> list[dict[str, object]]:
    if score is None:
        return []
    items = []
    components = score.components or {}
    for key, label in _SLEEP_COMPONENT_LABELS.items():
        raw = components.get(key)
        if not isinstance(raw, dict):
            continue
        component_score = raw.get("score")
        if not isinstance(component_score, int | float):
            continue
        item: dict[str, object] = {
            "key": key,
            "label": label,
            "score": round(float(component_score), 1),
            "weight": _SLEEP_COMPONENT_WEIGHTS.get(key),
            "message": _sleep_component_message(key, raw),
        }
        detail = {k: v for k, v in raw.items() if k != "score" and isinstance(v, int | float | str)}
        if detail:
            item["detail"] = detail
        items.append(item)
    return items


def _sleep_component_message(key: str, component: dict[str, Any]) -> str | None:
    if key == "duration":
        minutes = component.get("minutes")
        target = component.get("target_minutes")
        if isinstance(minutes, int | float) and isinstance(target, int | float):
            return f"{_hours_text(float(minutes))} slept against a {_hours_text(float(target))} target."
    if key == "regularity":
        drift = component.get("average_drift_minutes")
        if isinstance(drift, int | float):
            return f"Average bedtime/wake drift was {round(float(drift)):g} min."
    if key == "continuity":
        efficiency = component.get("sleep_efficiency")
        if isinstance(efficiency, int | float):
            return f"Sleep efficiency was {round(float(efficiency) * 100):g}%."
    if key == "timing":
        drift = component.get("start_drift_minutes")
        if isinstance(drift, int | float):
            return f"Sleep start drift was {round(float(drift)):g} min."
    if key == "physiology":
        return "Overnight physiology is compared with your baseline."
    if key == "stages":
        rem = component.get("rem_minutes")
        deep = component.get("deep_minutes")
        if isinstance(rem, int | float) or isinstance(deep, int | float):
            return f"REM {_hours_text(float(rem or 0))}, deep {_hours_text(float(deep or 0))}."
    return None


def _sleep_detail_context(
    session: DbSession,
    *,
    user_id: str,
    profile: UserProfile,
    timeframe: str,
    start: date,
    end: date,
    main_by_date: dict[date, SleepSession],
    scores: list[DailyScore],
    latest_sleep: SleepSession | None,
    latest_score: DailyScore | None,
) -> dict[str, object]:
    stats = _sleep_period_stats(session, user_id, profile, start, end, main_by_date)
    context_stats = stats
    if timeframe == "day":
        debt_start = start - timedelta(days=6)
        debt_sessions = _sleep_sessions_for_range(session, user_id, debt_start, start)
        context_stats = _sleep_period_stats(
            session,
            user_id,
            profile,
            debt_start,
            start,
            _main_sleeps_by_date(debt_sessions),
        )
    latest_components = latest_score.components if latest_score and latest_score.components else {}
    physiology = latest_components.get("physiology") if isinstance(latest_components.get("physiology"), dict) else {}
    base_need = _base_sleep_need_minutes(profile)
    return {
        "sleep_target_minutes": profile.sleep_target_minutes,
        "adjusted_sleep_need_minutes": _sleep_target_for_day(session, user_id, profile, start)
        if timeframe == "day"
        else stats["average_target_minutes"],
        "base_sleep_need_minutes": base_need,
        "sleep_debt_minutes": context_stats["sleep_debt_minutes"],
        "sleep_debt_period_days": 7 if timeframe == "day" else (end - start).days + 1,
        "target_met_nights": context_stats["target_met_nights"],
        "slept_nights": context_stats["slept_nights"],
        "strain_adjusted_nights": context_stats["strain_adjusted_nights"],
        "hrv_baseline_relation": _sleep_physiology_relation(physiology, "hrv", higher_is_better=True),
        "rhr_baseline_relation": _sleep_physiology_relation(physiology, "rhr", higher_is_better=False),
        "confidence_phase": latest_score.confidence_phase if latest_score else None,
        "data_quality": latest_score.data_quality if latest_score else ("weak" if latest_sleep else "missing"),
    }


def _sleep_period_stats(
    session: DbSession,
    user_id: str,
    profile: UserProfile,
    start: date,
    end: date,
    main_by_date: dict[date, SleepSession],
) -> dict[str, object]:
    slept_minutes: list[int] = []
    targets: list[int] = []
    target_met = 0
    debt = 0
    adjusted_nights = 0
    base_need = _base_sleep_need_minutes(profile)
    for day in _date_range(start, end):
        sleep = main_by_date.get(day)
        if sleep is None or sleep.minutes_asleep is None:
            continue
        target = _sleep_target_for_day(session, user_id, profile, day)
        targets.append(target)
        slept_minutes.append(sleep.minutes_asleep)
        if sleep.minutes_asleep >= target:
            target_met += 1
        debt += max(0, target - sleep.minutes_asleep)
        if target > base_need:
            adjusted_nights += 1
    return {
        "average_sleep_minutes": round(mean(slept_minutes), 1) if slept_minutes else None,
        "average_target_minutes": round(mean(targets), 1) if targets else base_need,
        "target_met_nights": target_met,
        "sleep_debt_minutes": debt,
        "slept_nights": len(slept_minutes),
        "strain_adjusted_nights": adjusted_nights,
    }


def _sleep_detail_guidance(
    timeframe: str,
    scores: list[DailyScore],
    sleeps: list[SleepSession],
) -> dict[str, object]:
    latest = _latest_sleep_score(scores)
    band = _sleep_band(latest.value if latest else None)
    if not sleeps:
        text = "Sleep detail will appear after a main sleep session is available for this period."
    elif timeframe == "day":
        if band == "good":
            text = "This sleep was enough to support recovery. Keep the next night consistent to protect the trend."
        elif band == "fair":
            text = "This sleep covered part of the need. Watch accumulated debt before adding extra strain."
        elif band == "low":
            text = "Sleep was limited or disrupted. Bias toward recovery and an earlier wind-down tonight."
        else:
            text = "Use sleep duration, timing, and continuity together before judging the night."
    else:
        text = "Use the pattern of target-met nights and sleep debt to judge whether your routine is supporting recovery."
    return {"message": text}


def _sleep_detail_data_quality(scores: list[DailyScore], start: date, end: date) -> dict[str, object]:
    expected_days = (end - start).days + 1
    valid_scores = [score for score in scores if score.value is not None]
    quality_counts = Counter(score.data_quality for score in scores if score.data_quality)
    confidence_counts = Counter(score.confidence_phase for score in scores if score.confidence_phase)
    status_counts = Counter(score.status.value for score in scores if score.status)
    return {
        "expected_days": expected_days,
        "scored_days": len(valid_scores),
        "completeness": round(len(valid_scores) / expected_days, 3) if expected_days else None,
        "quality_counts": dict(quality_counts),
        "confidence_counts": dict(confidence_counts),
        "status_counts": dict(status_counts),
    }


def _latest_sleep_score(scores: list[DailyScore]) -> DailyScore | None:
    return next((score for score in reversed(scores) if score.value is not None), scores[-1] if scores else None)


def _sleep_target_for_day(
    session: DbSession,
    user_id: str,
    profile: UserProfile,
    day: date,
) -> int:
    return _adjusted_sleep_need_minutes(session, user_id, profile, day)


def _base_sleep_need_minutes(profile: UserProfile) -> int:
    return max(420, min(540, profile.sleep_target_minutes or 480))


def _sleep_local_minute(profile: UserProfile, value: datetime) -> int:
    local = value.astimezone(timezone_for_profile(profile))
    return local.hour * 60 + local.minute


def _sleep_band(value: float | None) -> str | None:
    if value is None:
        return None
    if value >= 80:
        return "good"
    if value >= 60:
        return "fair"
    return "low"


def _sleep_physiology_relation(
    physiology: dict[str, Any],
    key: str,
    *,
    higher_is_better: bool,
) -> str | None:
    item = physiology.get(key)
    if not isinstance(item, dict):
        return None
    current = item.get("value")
    baseline = item.get("baseline")
    if not isinstance(current, int | float) or not isinstance(baseline, int | float):
        return None
    if abs(float(current) - float(baseline)) < 0.05:
        return "at_baseline"
    if higher_is_better:
        return "above_baseline" if float(current) > float(baseline) else "below_baseline"
    return "below_baseline" if float(current) < float(baseline) else "above_baseline"


def _hours_text(minutes: float) -> str:
    rounded = int(round(minutes))
    hours = rounded // 60
    mins = rounded % 60
    return f"{hours}h {mins:02d}m"


_SLEEP_COMPONENT_LABELS = {
    "duration": "Duration",
    "regularity": "Regularity",
    "continuity": "Continuity",
    "timing": "Timing",
    "physiology": "Physiology",
    "stages": "Stages",
}

_SLEEP_COMPONENT_WEIGHTS = {
    "duration": 0.35,
    "regularity": 0.25,
    "continuity": 0.20,
    "timing": 0.10,
    "physiology": 0.05,
    "stages": 0.05,
}


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


def _sleep_sessions_for_range(
    session: DbSession,
    user_id: str,
    start: date,
    end: date,
) -> list[SleepSession]:
    return session.scalars(
        select(SleepSession)
        .where(
            SleepSession.user_id == user_id,
            SleepSession.civil_date >= start,
            SleepSession.civil_date <= end,
        )
        .order_by(SleepSession.start_time)
    ).all()


def _main_sleeps_by_date(sessions: list[SleepSession]) -> dict[date, SleepSession]:
    grouped: dict[date, list[SleepSession]] = defaultdict(list)
    for item in sessions:
        if item.civil_date:
            grouped[item.civil_date].append(item)
    return {day: _main_sleep_from_sessions(items) for day, items in grouped.items()}


def _main_sleep_from_sessions(sessions: list[SleepSession]) -> SleepSession:
    mains = [item for item in sessions if item.is_main_sleep]
    candidates = mains or sessions
    return max(candidates, key=_sleep_selection_minutes)


def _sleep_selection_minutes(sleep: SleepSession) -> int:
    return sleep.minutes_asleep or _time_in_bed_minutes(sleep) or 0


def _sleep_scores_by_date(
    session: DbSession,
    user_id: str,
    start: date,
    end: date,
) -> dict[date, DailyScore]:
    scores = session.scalars(
        select(DailyScore).where(
            DailyScore.user_id == user_id,
            DailyScore.score_type == "sleep",
            DailyScore.algorithm_version == SLEEP_SCORE_VERSION,
            DailyScore.score_date >= start,
            DailyScore.score_date <= end,
        )
    ).all()
    return {score.score_date: score for score in scores}


def _sleep_session_payload(
    profile: UserProfile,
    sleep: SleepSession | None,
    *,
    include_stages: bool = False,
) -> dict[str, object] | None:
    if sleep is None:
        return None
    payload: dict[str, object] = {
        "id": sleep.id,
        "date": sleep.civil_date,
        "start_time": sleep.start_time,
        "end_time": sleep.end_time,
        "bedtime": _local_clock_time(profile, sleep.start_time),
        "wake_time": _local_clock_time(profile, sleep.end_time),
        "duration_minutes": sleep.minutes_asleep,
        "minutes_asleep": sleep.minutes_asleep,
        "time_in_bed_minutes": _time_in_bed_minutes(sleep),
        "minutes_awake": sleep.minutes_awake,
        "sleep_efficiency": _sleep_efficiency(sleep),
        "is_main_sleep": sleep.is_main_sleep,
        "stages_summary": _sleep_stages_summary(sleep),
    }
    if include_stages:
        payload["stages"] = sleep.stages
    return payload


def _sleep_series_point(
    day: date,
    profile: UserProfile,
    sleep: SleepSession | None,
    score: DailyScore | None,
) -> dict[str, object]:
    return {
        "date": day,
        "sleep_session_id": sleep.id if sleep else None,
        "bedtime": _local_clock_time(profile, sleep.start_time) if sleep else None,
        "wake_time": _local_clock_time(profile, sleep.end_time) if sleep else None,
        "duration_minutes": sleep.minutes_asleep if sleep else None,
        "time_in_bed_minutes": _time_in_bed_minutes(sleep) if sleep else None,
        "minutes_awake": sleep.minutes_awake if sleep else None,
        "sleep_efficiency": _sleep_efficiency(sleep) if sleep else None,
        "score": _rounded(score.value) if score and score.value is not None else None,
        "score_status": score.status.value if score else None,
        "data_quality": score.data_quality if score else ("weak" if sleep else "missing"),
    }


def _sleep_score_payload(score: DailyScore | None) -> dict[str, object] | None:
    if score is None:
        return None
    return {
        "date": score.score_date,
        "value": _rounded(score.value),
        "unit": score.value_unit,
        "status": score.status.value,
        "confidence_phase": score.confidence_phase,
        "data_quality": score.data_quality,
        "components": score.components,
        "inputs": score.inputs,
        "reasons": score.reasons,
        "computed_at": score.computed_at,
    }


def _sleep_consistency_payload(score: DailyScore | None) -> dict[str, object] | None:
    if score is None:
        return None
    regularity = score.components.get("regularity")
    if not isinstance(regularity, dict):
        return None
    value = regularity.get("score")
    numeric_score = float(value) if isinstance(value, int | float) else None
    return {
        "source": "sleep_score.regularity",
        "score": _rounded(numeric_score),
        "status": _consistency_status(numeric_score),
        "details": regularity,
    }


def _consistency_status(value: float | None) -> str:
    if value is None:
        return "unknown"
    if value >= 80:
        return "consistent"
    if value >= 60:
        return "variable"
    return "irregular"


def _sleep_trend_payload(
    current: SleepSession | None,
    previous: SleepSession | None,
    series: list[dict[str, object]],
) -> dict[str, object]:
    durations = [
        float(point["duration_minutes"])
        for point in series
        if point["duration_minutes"] is not None
    ]
    efficiencies = [
        float(point["sleep_efficiency"])
        for point in series
        if point["sleep_efficiency"] is not None
    ]
    scores = [
        float(point["score"])
        for point in series
        if point["score"] is not None
    ]
    current_duration = current.minutes_asleep if current else None
    previous_duration = previous.minutes_asleep if previous else None
    duration_change = (
        current_duration - previous_duration
        if current_duration is not None and previous_duration is not None
        else None
    )
    return {
        "duration_change_minutes": duration_change,
        "window_average_duration_minutes": _rounded(mean(durations)) if durations else None,
        "window_average_efficiency": _rounded(mean(efficiencies)) if efficiencies else None,
        "window_average_score": _rounded(mean(scores)) if scores else None,
    }


def _time_in_bed_minutes(sleep: SleepSession) -> int | None:
    if sleep.minutes_in_sleep_period is not None:
        return sleep.minutes_in_sleep_period
    return int((sleep.end_time - sleep.start_time).total_seconds() / 60)


def _sleep_efficiency(sleep: SleepSession) -> float | None:
    if sleep.minutes_asleep is None:
        return None
    period = _time_in_bed_minutes(sleep)
    if not period or period <= 0:
        return None
    return round(sleep.minutes_asleep / period, 3)


SLEEP_STAGE_ORDER = ("AWAKE", "LIGHT", "DEEP", "REM")


def _sleep_stages_summary(sleep: SleepSession) -> list[dict[str, object]]:
    from_timeline = _stage_summary_from_timeline(sleep)
    if from_timeline:
        return from_timeline
    return _deduped_provider_stage_summary(sleep.stages_summary)


def _stage_summary_from_timeline(sleep: SleepSession) -> list[dict[str, object]]:
    totals: dict[str, float] = defaultdict(float)
    counts: dict[str, int] = defaultdict(int)
    covered_minutes = 0.0
    for stage in sleep.stages:
        stage_type = stage.get("type") or stage.get("stage")
        start_time = _parse_stage_datetime(stage.get("startTime"))
        end_time = _parse_stage_datetime(stage.get("endTime"))
        if not stage_type or start_time is None or end_time is None:
            continue
        minutes = max(0.0, (end_time - start_time).total_seconds() / 60)
        if minutes <= 0:
            continue
        key = str(stage_type).upper()
        covered_minutes += minutes
        totals[key] += minutes
        counts[key] += 1
    if not _stage_timeline_has_usable_coverage(sleep, covered_minutes):
        return []
    return _stage_summary_payloads(totals, counts)


def _stage_timeline_has_usable_coverage(sleep: SleepSession, covered_minutes: float) -> bool:
    expected = sleep.minutes_in_sleep_period or sleep.minutes_asleep
    if not expected or expected <= 0:
        return covered_minutes > 0
    return covered_minutes >= expected * 0.65


def _deduped_provider_stage_summary(items: list[dict[str, Any]]) -> list[dict[str, object]]:
    seen: set[tuple[str, str, str]] = set()
    totals: dict[str, float] = defaultdict(float)
    counts: dict[str, int] = defaultdict(int)
    for item in items:
        stage_type = item.get("type") or item.get("stage")
        if not stage_type:
            continue
        key = str(stage_type).upper()
        minutes = _float_from_stage_value(item.get("minutes"))
        count = int(_float_from_stage_value(item.get("count")) or 0)
        dedupe_key = (key, str(item.get("minutes")), str(item.get("count")))
        if dedupe_key in seen:
            continue
        seen.add(dedupe_key)
        totals[key] += minutes or 0
        counts[key] += count
    return _stage_summary_payloads(totals, counts)


def _stage_summary_payloads(
    totals: dict[str, float],
    counts: dict[str, int],
) -> list[dict[str, object]]:
    ordered = [stage for stage in SLEEP_STAGE_ORDER if stage in totals]
    ordered.extend(sorted(stage for stage in totals if stage not in SLEEP_STAGE_ORDER))
    return [
        {
            "type": stage,
            "minutes": int(round(totals[stage])),
            "count": counts[stage],
        }
        for stage in ordered
    ]


def _parse_stage_datetime(value: object) -> datetime | None:
    if not isinstance(value, str) or not value:
        return None
    try:
        return datetime.fromisoformat(value.replace("Z", "+00:00"))
    except ValueError:
        return None


def _float_from_stage_value(value: object) -> float | None:
    if value is None:
        return None
    try:
        return float(value)
    except (TypeError, ValueError):
        return None


def _local_clock_time(profile: UserProfile, value: datetime) -> str:
    if value.tzinfo is None:
        value = value.replace(tzinfo=UTC)
    return value.astimezone(timezone_for_profile(profile)).strftime("%H:%M")


def _date_range(start: date, end: date) -> list[date]:
    days: list[date] = []
    current = start
    while current <= end:
        days.append(current)
        current = date.fromordinal(current.toordinal() + 1)
    return days


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
    sample_mins = (
        daily_rollup_values(
            session,
            user_id=user_id,
            metric=config.sample_metric,
            start=start,
            end=end,
            value_kind="min",
        )
        if config.sample_metric in HIGH_VOLUME_METRICS
        else {}
    )
    sample_maxes = (
        daily_rollup_values(
            session,
            user_id=user_id,
            metric=config.sample_metric,
            start=start,
            end=end,
            value_kind="max",
        )
        if config.sample_metric in HIGH_VOLUME_METRICS
        else {}
    )
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
            point["min_value"] = _rounded(sample_mins.get(current) or (min(samples) if samples else None))
            point["max_value"] = _rounded(sample_maxes.get(current) or (max(samples) if samples else None))
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
    if sample_metric in HIGH_VOLUME_METRICS:
        rollup_values = {
            day: [value]
            for day, value in daily_rollup_values(
                session,
                user_id=user_id,
                metric=sample_metric,
                start=start,
                end=end,
                value_kind="avg",
            ).items()
        }
        if rollup_values:
            return rollup_values
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
    payload = {
        **point,
        "baseline_value": _series_baseline_value(baseline),
        "comparison": _series_baseline_comparison(point, baseline),
    }
    if baseline is not None:
        payload["baseline_lower_bound"] = _rounded(baseline.lower_bound)
        payload["baseline_upper_bound"] = _rounded(baseline.upper_bound)
    return payload


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
    profile = get_or_create_profile(session, user.id)
    return [
        _workout_summary_payload(session, user.id, profile, item)
        for item in items
    ]


@router.get("/workouts/{workout_id}")
def workout_detail(
    session: DbSession,
    user: CurrentUser,
    workout_id: str,
) -> dict[str, object]:
    workout = session.get(Workout, workout_id)
    if workout is None or workout.user_id != user.id:
        raise HTTPException(status_code=404, detail="Workout not found")

    profile = get_or_create_profile(session, user.id)
    samples = _workout_heart_rate_samples(session, user.id, workout)
    payload = _workout_summary_payload(session, user.id, profile, workout, samples=samples)
    payload["heart_rate_samples"] = [
        {
            "observed_at": sample.observed_at,
            "value": sample.value,
            "unit": sample.unit,
            "source_platform": sample.source_platform,
            "source_device": sample.source_device,
        }
        for sample in samples
    ]
    payload["raw_summary"] = workout.raw_summary
    return payload


def _workout_summary_payload(
    session: DbSession,
    user_id: str,
    profile: UserProfile,
    workout: Workout,
    *,
    samples: list[MetricSample] | None = None,
) -> dict[str, object]:
    hr_samples = (
        samples
        if samples is not None
        else _workout_heart_rate_samples(session, user_id, workout)
    )
    hr_values = [sample.value for sample in hr_samples]
    zones, zone_source = _workout_zones(session, user_id, profile, workout, hr_samples)
    distance = _workout_distance_from_raw(workout.raw_summary)
    active_calories = _workout_calories_from_raw(workout.raw_summary)
    if distance is None:
        distance = _workout_metric_total(session, user_id, workout, "distance")
    if active_calories is None:
        active_calories = _workout_metric_total(session, user_id, workout, "active_calories")

    payload = {
        "id": workout.id,
        "workout_type": workout.workout_type,
        "start_time": workout.start_time,
        "end_time": workout.end_time,
        "date": workout.civil_date,
        "duration_seconds": workout.duration_seconds,
        "distance_meters": _rounded(distance),
        "active_calories": _rounded(active_calories),
        "heart_rate": {
            "average_bpm": _rounded(mean(hr_values)) if hr_values else None,
            "min_bpm": _rounded(min(hr_values)) if hr_values else None,
            "max_bpm": _rounded(max(hr_values)) if hr_values else None,
            "sample_count": len(hr_values),
        },
        "heart_rate_zones": zones,
        "zone_source": zone_source,
        "intensity": _workout_intensity(zones),
    }
    strain_load_points = _workout_strain_load_points(session, user_id, workout)
    if strain_load_points is not None:
        payload["strain_load_points"] = strain_load_points
    return payload


def _workout_strain_load_points(
    session: DbSession,
    user_id: str,
    workout: Workout,
) -> float | None:
    score = session.scalar(
        select(DailyScore).where(
            DailyScore.user_id == user_id,
            DailyScore.score_type == "strain",
            DailyScore.score_date == workout.civil_date,
        )
    )
    if score is None or not isinstance(score.components, dict):
        return None
    for item in score.components.get("workout_contributions") or []:
        if not isinstance(item, dict) or item.get("workout_id") != workout.id:
            continue
        load = item.get("load_points")
        if isinstance(load, int | float):
            return round(float(load), 2)
    return None


WORKOUT_DISTANCE_KEYS = {
    "distanceMeters",
    "distance_meters",
    "distanceInMeters",
    "meters",
}
WORKOUT_DISTANCE_MILLIMETER_KEYS = {
    "distanceMillimeters",
    "distance_millimeters",
    "millimeters",
}
WORKOUT_CALORIE_KEYS = {
    "activeCalories",
    "active_calories",
    "caloriesKcal",
    "calories",
    "kilocalories",
    "kcal",
}

ZONE_ORDER = ("zone_1", "zone_2", "zone_3", "zone_4")
SOURCE_ZONE_MAP = {
    "OUT_OF_RANGE": "zone_1",
    "BELOW_DEFAULT_ZONE_1": "zone_1",
    "LIGHT": "zone_1",
    "FAT_BURN": "zone_2",
    "MODERATE": "zone_2",
    "CARDIO": "zone_3",
    "VIGOROUS": "zone_3",
    "PEAK": "zone_4",
    "MAXIMUM": "zone_4",
}


def _workout_heart_rate_samples(
    session: DbSession,
    user_id: str,
    workout: Workout,
) -> list[object]:
    rollups = [
        row
        for row in session.scalars(
            select(MetricMinuteRollup)
            .where(
                MetricMinuteRollup.user_id == user_id,
                MetricMinuteRollup.metric == "heart_rate",
                MetricMinuteRollup.bucket_start >= workout.start_time,
                MetricMinuteRollup.bucket_start <= workout.end_time,
            )
            .order_by(MetricMinuteRollup.bucket_start)
        ).all()
        if row.avg_value is not None
    ]
    if rollups:
        return [
            RollupPoint(
                observed_at=row.bucket_start,
                civil_date=row.civil_date,
                value=row.avg_value,
                unit=row.unit,
                source_platform=row.source_platform,
                source_device=row.source_device,
            )
            for row in rollups
        ]
    return session.scalars(
        select(MetricSample)
        .where(
            MetricSample.user_id == user_id,
            MetricSample.metric == "heart_rate",
            MetricSample.observed_at >= workout.start_time,
            MetricSample.observed_at <= workout.end_time,
        )
        .order_by(MetricSample.observed_at)
    ).all()


def _workout_metric_total(
    session: DbSession,
    user_id: str,
    workout: Workout,
    metric: str,
) -> float | None:
    if metric in SUM_METRICS:
        rollups = session.scalars(
            select(MetricMinuteRollup).where(
                MetricMinuteRollup.user_id == user_id,
                MetricMinuteRollup.metric == metric,
                MetricMinuteRollup.bucket_start < workout.end_time,
                MetricMinuteRollup.bucket_start >= workout.start_time - _ONE_MINUTE,
            )
        ).all()
        total = 0.0
        for row in rollups:
            if row.sum_value is None:
                continue
            bucket_end = row.bucket_start + _ONE_MINUTE
            overlap = _overlap_seconds(row.bucket_start, bucket_end, workout.start_time, workout.end_time)
            if overlap > 0:
                total += row.sum_value * min(1.0, overlap / 60)
        if total > 0:
            return total

    intervals = session.scalars(
        select(MetricInterval).where(
            MetricInterval.user_id == user_id,
            MetricInterval.metric == metric,
            MetricInterval.end_time > workout.start_time,
            MetricInterval.start_time < workout.end_time,
        )
    ).all()
    total = 0.0
    for interval in intervals:
        overlap = _overlap_seconds(
            interval.start_time,
            interval.end_time,
            workout.start_time,
            workout.end_time,
        )
        interval_seconds = max(0.0, (interval.end_time - interval.start_time).total_seconds())
        if overlap <= 0 or interval_seconds <= 0:
            continue
        total += interval.value * min(1.0, overlap / interval_seconds)
    return total if total > 0 else None


def _workout_zones(
    session: DbSession,
    user_id: str,
    profile: UserProfile,
    workout: Workout,
    samples: list[MetricSample],
) -> tuple[list[dict[str, object]], str]:
    provider_zones = _provider_zone_payloads(workout.raw_summary)
    if provider_zones:
        return provider_zones, "provider_workout_summary"

    interval_zones = _zone_interval_payloads(session, user_id, workout)
    if interval_zones:
        return interval_zones, "time_in_heart_rate_zone"

    inferred_zones = _inferred_zone_payloads(session, user_id, profile, workout, samples)
    if inferred_zones:
        return inferred_zones, "heart_rate_reserve_inferred"

    return _empty_zone_payloads("missing"), "missing"


def _provider_zone_payloads(raw_summary: dict[str, Any]) -> list[dict[str, object]]:
    zones = _extract_zone_summaries(raw_summary)
    totals = _empty_zone_totals()
    sources: dict[str, set[str]] = defaultdict(set)
    for index, zone in enumerate(zones):
        seconds = _zone_seconds(zone)
        if seconds is None:
            continue
        source_zone = _source_zone_name(zone) or f"zone_{index + 1}"
        app_zone = _app_zone_from_source(source_zone) or f"zone_{min(index + 1, 4)}"
        totals[app_zone] += seconds
        sources[app_zone].add(source_zone)
    return _zone_payloads_from_totals(totals, "provider_workout_summary", sources)


def _zone_interval_payloads(
    session: DbSession,
    user_id: str,
    workout: Workout,
) -> list[dict[str, object]]:
    rows = session.execute(
        select(MetricInterval, RawHealthRecord)
        .join(RawHealthRecord, MetricInterval.raw_record_id == RawHealthRecord.id)
        .where(
            MetricInterval.user_id == user_id,
            MetricInterval.metric == "time_in_heart_rate_zone",
            MetricInterval.end_time > workout.start_time,
            MetricInterval.start_time < workout.end_time,
        )
    ).all()
    totals = _empty_zone_totals()
    sources: dict[str, set[str]] = defaultdict(set)
    for interval, raw_record in rows:
        payload = raw_record.raw_json.get("timeInHeartRateZone") or {}
        if not isinstance(payload, dict):
            continue
        source_zone = str(payload.get("heartRateZoneType") or "")
        app_zone = _app_zone_from_source(source_zone)
        if app_zone is None:
            continue
        overlap = _overlap_seconds(
            interval.start_time,
            interval.end_time,
            workout.start_time,
            workout.end_time,
        )
        if overlap <= 0:
            continue
        totals[app_zone] += overlap
        sources[app_zone].add(source_zone)
    return _zone_payloads_from_totals(totals, "time_in_heart_rate_zone", sources)


def _inferred_zone_payloads(
    session: DbSession,
    user_id: str,
    profile: UserProfile,
    workout: Workout,
    samples: list[MetricSample],
) -> list[dict[str, object]]:
    if len(samples) < 2:
        return []
    resting_hr = _resting_heart_rate_for_day(session, user_id, workout.civil_date)
    max_hr, max_hr_source = estimated_max_heart_rate(profile, workout.civil_date or date.today())
    if resting_hr is None or max_hr is None or max_hr <= resting_hr:
        return []

    totals = _empty_zone_totals()
    for current, following in zip(samples, samples[1:]):
        seconds = min(
            120.0,
            max(0.0, (following.observed_at - current.observed_at).total_seconds()),
        )
        if seconds <= 0:
            continue
        reserve_fraction = (current.value - resting_hr) / (max_hr - resting_hr)
        totals[_zone_from_hrr_fraction(reserve_fraction)] += seconds

    payloads = _zone_payloads_from_totals(totals, "heart_rate_reserve_inferred", defaultdict(set))
    if not any(payload["seconds"] for payload in payloads):
        return []
    for payload in payloads:
        payload["thresholds"] = _zone_thresholds(resting_hr, max_hr)
        payload["max_heart_rate"] = _rounded(max_hr)
        payload["max_heart_rate_source"] = max_hr_source
        payload["resting_heart_rate"] = _rounded(resting_hr)
    return payloads


def _resting_heart_rate_for_day(
    session: DbSession,
    user_id: str,
    day: date | None,
) -> float | None:
    if day is None:
        return None
    summary = session.scalar(
        select(DailySummary).where(
            DailySummary.user_id == user_id,
            DailySummary.summary_date == day,
        )
    )
    if summary and summary.resting_heart_rate is not None:
        return float(summary.resting_heart_rate)
    samples = session.scalars(
        select(MetricSample).where(
            MetricSample.user_id == user_id,
            MetricSample.metric == "resting_heart_rate",
            MetricSample.civil_date == day,
        )
    ).all()
    if samples:
        return mean(sample.value for sample in samples)
    return None


def _zone_from_hrr_fraction(value: float) -> str:
    if value < 0.60:
        return "zone_1"
    if value < 0.70:
        return "zone_2"
    if value < 0.85:
        return "zone_3"
    return "zone_4"


def _zone_thresholds(resting_hr: float, max_hr: float) -> dict[str, dict[str, float | None]]:
    reserve = max_hr - resting_hr
    return {
        "zone_1": {"min_bpm": None, "max_bpm": _rounded(resting_hr + reserve * 0.60)},
        "zone_2": {
            "min_bpm": _rounded(resting_hr + reserve * 0.60),
            "max_bpm": _rounded(resting_hr + reserve * 0.70),
        },
        "zone_3": {
            "min_bpm": _rounded(resting_hr + reserve * 0.70),
            "max_bpm": _rounded(resting_hr + reserve * 0.85),
        },
        "zone_4": {"min_bpm": _rounded(resting_hr + reserve * 0.85), "max_bpm": None},
    }


def _zone_payloads_from_totals(
    totals: dict[str, float],
    source: str,
    source_zones: dict[str, set[str]],
) -> list[dict[str, object]]:
    if not any(totals.values()):
        return []
    return [
        {
            "zone": zone,
            "seconds": int(round(totals[zone])),
            "minutes": _rounded(totals[zone] / 60),
            "source": source,
            "source_zones": sorted(source_zones.get(zone, set())),
        }
        for zone in ZONE_ORDER
    ]


def _empty_zone_payloads(source: str) -> list[dict[str, object]]:
    return [
        {"zone": zone, "seconds": 0, "minutes": 0.0, "source": source, "source_zones": []}
        for zone in ZONE_ORDER
    ]


def _empty_zone_totals() -> dict[str, float]:
    return {zone: 0.0 for zone in ZONE_ORDER}


def _workout_intensity(zones: list[dict[str, object]]) -> str:
    seconds_by_zone = {str(zone["zone"]): int(zone["seconds"]) for zone in zones}
    if not seconds_by_zone or sum(seconds_by_zone.values()) == 0:
        return "unknown"
    dominant = max(ZONE_ORDER, key=lambda zone: seconds_by_zone.get(zone, 0))
    return {
        "zone_1": "light",
        "zone_2": "moderate",
        "zone_3": "vigorous",
        "zone_4": "peak",
    }[dominant]


def _overlap_seconds(
    start_a: datetime,
    end_a: datetime,
    start_b: datetime,
    end_b: datetime,
) -> float:
    return max(0.0, (min(end_a, end_b) - max(start_a, start_b)).total_seconds())


def _extract_zone_summaries(payload: Any) -> list[dict[str, Any]]:
    if isinstance(payload, list):
        zones: list[dict[str, Any]] = []
        for item in payload:
            zones.extend(_extract_zone_summaries(item))
        return zones
    if not isinstance(payload, dict):
        return []
    durations = payload.get("heartRateZoneDurations")
    if isinstance(durations, dict):
        return _zone_duration_summaries(durations)
    for key in ("heartRateZones", "heart_rate_zones", "heartRateZoneSummaries", "zones"):
        value = payload.get(key)
        if isinstance(value, list) and all(isinstance(item, dict) for item in value):
            return value
    zones = []
    for value in payload.values():
        zones.extend(_extract_zone_summaries(value))
    return zones


def _zone_duration_summaries(payload: dict[str, Any]) -> list[dict[str, Any]]:
    mapping = {
        "lightTime": "LIGHT",
        "moderateTime": "MODERATE",
        "vigorousTime": "VIGOROUS",
        "peakTime": "PEAK",
    }
    return [
        {"heartRateZoneType": zone, "seconds": value}
        for key, zone in mapping.items()
        if (value := payload.get(key)) is not None
    ]


def _zone_seconds(zone: dict[str, Any]) -> float | None:
    for key in ("seconds", "durationSeconds"):
        value = _duration_seconds(zone.get(key))
        if value is not None:
            return value
    for key in ("minutes", "minute", "durationMinutes"):
        value = _to_float(zone.get(key))
        if value is not None:
            return value * 60
    return None


def _source_zone_name(zone: dict[str, Any]) -> str | None:
    for key in ("heartRateZoneType", "zone", "name", "type"):
        value = zone.get(key)
        if value:
            return str(value)
    return None


def _app_zone_from_source(source_zone: str) -> str | None:
    normalized = source_zone.strip().upper().replace(" ", "_").replace("-", "_")
    if normalized in {"ZONE_1", "1"}:
        return "zone_1"
    if normalized in {"ZONE_2", "2"}:
        return "zone_2"
    if normalized in {"ZONE_3", "3"}:
        return "zone_3"
    if normalized in {"ZONE_4", "4"}:
        return "zone_4"
    return SOURCE_ZONE_MAP.get(normalized)


def _workout_distance_from_raw(payload: dict[str, Any]) -> float | None:
    meters = _first_numeric(payload, WORKOUT_DISTANCE_KEYS)
    if meters is not None:
        return meters
    millimeters = _first_numeric(payload, WORKOUT_DISTANCE_MILLIMETER_KEYS)
    return None if millimeters is None else millimeters / 1000


def _workout_calories_from_raw(payload: dict[str, Any]) -> float | None:
    return _first_numeric(payload, WORKOUT_CALORIE_KEYS)


def _first_numeric(payload: Any, keys: set[str]) -> float | None:
    if isinstance(payload, list):
        for item in payload:
            value = _first_numeric(item, keys)
            if value is not None:
                return value
        return None
    if not isinstance(payload, dict):
        return None
    for key, value in payload.items():
        if key in keys:
            parsed = _to_float(value)
            if parsed is not None:
                return parsed
        parsed = _first_numeric(value, keys)
        if parsed is not None:
            return parsed
    return None


def _to_float(value: Any) -> float | None:
    try:
        return float(value)
    except (TypeError, ValueError):
        return None


def _duration_seconds(value: Any) -> float | None:
    parsed = _to_float(value)
    if parsed is not None:
        return parsed
    if not isinstance(value, str):
        return None
    stripped = value.strip()
    if stripped.endswith("s"):
        return _to_float(stripped[:-1])
    return None
