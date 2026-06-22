from __future__ import annotations

from collections import defaultdict
from dataclasses import dataclass
from datetime import UTC, date, datetime
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
    timezone_for_profile,
)
from app.services.scores import BASELINE_VERSION, SLEEP_SCORE_VERSION


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


DEFAULT_DASHBOARD_METRICS = (
    "heart_rate_variability",
    "resting_heart_rate",
    "oxygen_saturation",
    "respiratory_rate",
    "vo2_max",
    "sleep",
    "steps",
    "active_calories",
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
@router.get("/sleep/detail")
def sleep_detail(
    session: DbSession,
    user: CurrentUser,
    start: date = Query(...),
    end: date = Query(...),
) -> dict[str, object]:
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
    from_timeline = _stage_summary_from_timeline(sleep.stages)
    if from_timeline:
        return from_timeline
    return _deduped_provider_stage_summary(sleep.stages_summary)


def _stage_summary_from_timeline(stages: list[dict[str, Any]]) -> list[dict[str, object]]:
    totals: dict[str, float] = defaultdict(float)
    counts: dict[str, int] = defaultdict(int)
    for stage in stages:
        stage_type = stage.get("type") or stage.get("stage")
        start_time = _parse_stage_datetime(stage.get("startTime"))
        end_time = _parse_stage_datetime(stage.get("endTime"))
        if not stage_type or start_time is None or end_time is None:
            continue
        minutes = max(0.0, (end_time - start_time).total_seconds() / 60)
        if minutes <= 0:
            continue
        key = str(stage_type).upper()
        totals[key] += minutes
        counts[key] += 1
    return _stage_summary_payloads(totals, counts)


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

    return {
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
) -> list[MetricSample]:
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
