from __future__ import annotations


from datetime import date, datetime
from math import atan2, cos, log, pi, sin
from statistics import mean, median
from typing import Any
from sqlalchemy import select
from sqlalchemy.orm import Session
from app.core.security import utcnow
from app.models import (
    DailyBaseline,
    DailyScore,
    DailySummary,
    MetricSample,
    RawHealthRecord,
    ScoreStatus,
    SleepSession,
    StrainTarget,
    UserProfile,
    Workout,
)
from app.services.health_dates import (
    timezone_for_profile,
)
from app.services.metric_rollups import RollupPoint, rollup_points_for_metric


BASELINE_VERSION = "baseline_v2"

SLEEP_SCORE_VERSION = "sleep_score_v2"

READINESS_SCORE_VERSION = "readiness_score_v1"

STRAIN_LOAD_VERSION = "strain_load_v2"

SCORE_VERSIONS = {
    "sleep": SLEEP_SCORE_VERSION,
    "readiness": READINESS_SCORE_VERSION,
    "strain": STRAIN_LOAD_VERSION,
}


def _get_or_create_score(
    session: Session,
    user_id: str,
    score_date: date,
    score_type: str,
    algorithm_version: str,
) -> DailyScore:
    score = _score_for_day(session, user_id, score_date, score_type, algorithm_version)
    if score is not None:
        return score
    score = DailyScore(
        user_id=user_id,
        score_date=score_date,
        score_type=score_type,
        algorithm_version=algorithm_version,
        value_unit="score_0_100" if score_type != "strain" else "load_points",
    )
    session.add(score)
    session.flush()
    return score


def _get_or_create_baseline(
    session: Session,
    user_id: str,
    baseline_date: date,
    metric: str,
) -> DailyBaseline:
    baseline = session.scalar(
        select(DailyBaseline).where(
            DailyBaseline.user_id == user_id,
            DailyBaseline.baseline_date == baseline_date,
            DailyBaseline.metric == metric,
            DailyBaseline.algorithm_version == BASELINE_VERSION,
        )
    )
    if baseline:
        return baseline
    baseline = DailyBaseline(
        user_id=user_id,
        baseline_date=baseline_date,
        metric=metric,
        algorithm_version=BASELINE_VERSION,
        window_days=28,
    )
    session.add(baseline)
    session.flush()
    return baseline


def _get_or_create_strain_target(session: Session, user_id: str, week_start: date) -> StrainTarget:
    target = session.scalar(
        select(StrainTarget).where(
            StrainTarget.user_id == user_id,
            StrainTarget.week_start_date == week_start,
            StrainTarget.algorithm_version == STRAIN_LOAD_VERSION,
        )
    )
    if target:
        return target
    target = StrainTarget(
        user_id=user_id,
        week_start_date=week_start,
        algorithm_version=STRAIN_LOAD_VERSION,
    )
    session.add(target)
    session.flush()
    return target


def _set_score(
    score: DailyScore,
    *,
    value: float | None,
    unit: str,
    status: ScoreStatus,
    confidence_phase: str,
    data_quality: str,
    components: dict[str, Any],
    inputs: dict[str, Any],
    reasons: list[dict[str, Any]],
) -> DailyScore:
    score.value = None if value is None else round(float(value), 1)
    score.value_unit = unit
    score.status = status
    score.confidence_phase = confidence_phase
    score.data_quality = data_quality
    score.components = components
    score.inputs = inputs
    score.reasons = reasons
    score.computed_at = utcnow()
    return score


def _mark_score_waiting(
    score: DailyScore,
    *,
    unit: str,
    status: ScoreStatus,
    reason_code: str,
    message: str,
) -> DailyScore:
    return _set_score(
        score,
        value=None,
        unit=unit,
        status=status,
        confidence_phase="missing",
        data_quality="missing",
        components={},
        inputs={},
        reasons=[_reason(reason_code, "info", message)],
    )


def _score_for_day(
    session: Session,
    user_id: str,
    score_date: date,
    score_type: str,
    algorithm_version: str,
) -> DailyScore | None:
    return session.scalar(
        select(DailyScore).where(
            DailyScore.user_id == user_id,
            DailyScore.score_date == score_date,
            DailyScore.score_type == score_type,
            DailyScore.algorithm_version == algorithm_version,
        )
    )


def _summary_for_day(session: Session, user_id: str, day: date) -> DailySummary | None:
    return session.scalar(
        select(DailySummary).where(
            DailySummary.user_id == user_id,
            DailySummary.summary_date == day,
        )
    )


def _main_sleep(session: Session, user_id: str, day: date) -> SleepSession | None:
    sleeps = session.scalars(
        select(SleepSession).where(
            SleepSession.user_id == user_id,
            SleepSession.civil_date == day,
        )
    ).all()
    if not sleeps:
        return None
    mains = [sleep for sleep in sleeps if sleep.is_main_sleep]
    candidates = mains or sleeps
    return max(
        candidates,
        key=lambda sleep: sleep.minutes_asleep
        or int((sleep.end_time - sleep.start_time).total_seconds() / 60),
    )


def _sleep_source_signature(session: Session, sleep: SleepSession) -> tuple[str, str] | None:
    if not sleep.raw_record_id:
        return None
    raw = session.get(RawHealthRecord, sleep.raw_record_id)
    if raw is None:
        return None
    source = ":".join(filter(None, (raw.source_platform, raw.source_device))) or "google_health"
    return raw.google_account_id, source


def _heart_rate_samples(session: Session, user_id: str, day: date) -> list[MetricSample | RollupPoint]:
    rollups = rollup_points_for_metric(
        session,
        user_id=user_id,
        metric="heart_rate",
        start=day,
        end=day,
    )
    if rollups:
        return rollups
    return session.scalars(
        select(MetricSample)
        .where(
            MetricSample.user_id == user_id,
            MetricSample.metric == "heart_rate",
            MetricSample.civil_date == day,
        )
        .order_by(MetricSample.observed_at)
    ).all()


def _workouts_for_day(session: Session, user_id: str, day: date) -> list[Workout]:
    return session.scalars(
        select(Workout)
        .where(
            Workout.user_id == user_id,
            Workout.civil_date == day,
            Workout.status == "completed",
            Workout.deleted_at.is_(None),
        )
        .order_by(Workout.start_time)
    ).all()


def _strain_loads(session: Session, user_id: str, start: date, end: date) -> list[tuple[date, float]]:
    if end < start:
        return []
    scores = session.scalars(
        select(DailyScore)
        .where(
            DailyScore.user_id == user_id,
            DailyScore.score_type == "strain",
            DailyScore.algorithm_version == STRAIN_LOAD_VERSION,
            DailyScore.score_date >= start,
            DailyScore.score_date <= end,
            DailyScore.value.is_not(None),
        )
        .order_by(DailyScore.score_date)
    ).all()
    return [(score.score_date, float(score.value or 0)) for score in scores]


def _baseline_for_metric(
    session: Session,
    user_id: str,
    day: date,
    metric: str,
) -> DailyBaseline | None:
    return session.scalar(
        select(DailyBaseline).where(
            DailyBaseline.user_id == user_id,
            DailyBaseline.baseline_date == day,
            DailyBaseline.metric == metric,
            DailyBaseline.algorithm_version == BASELINE_VERSION,
        )
    )


def _baseline_value(session: Session, user_id: str, day: date, metric: str) -> float | None:
    baseline = _baseline_for_metric(session, user_id, day, metric)
    return baseline.median_value if baseline else None


def _baseline_phase(session: Session, user_id: str, day: date, metric: str) -> str:
    baseline = _baseline_for_metric(session, user_id, day, metric)
    return baseline.confidence_phase if baseline else "missing"


def _sleep_efficiency(sleep: SleepSession) -> float | None:
    if sleep.minutes_asleep is None:
        return None
    period = sleep.minutes_in_sleep_period
    if not period:
        period = int((sleep.end_time - sleep.start_time).total_seconds() / 60)
    if period <= 0:
        return None
    return sleep.minutes_asleep / period


def _metric_baseline_score(
    session: Session,
    user_id: str,
    day: date,
    metric: str,
    value: float | None,
    *,
    higher_is_better: bool,
) -> dict[str, Any] | None:
    if value is None:
        return None
    baseline = _baseline_for_metric(session, user_id, day, metric)
    if baseline is None or baseline.median_value is None:
        return {"score": 75.0, "value": value, "baseline": None}
    metadata = baseline.metadata_json or {}
    if (
        metric == "heart_rate_variability"
        and metadata.get("transform") == "natural_log_rmssd"
        and value > 0
        and baseline.median_value > 0
    ):
        spread = float(metadata.get("log_spread") or 0.08)
        delta = (log(value) - log(baseline.median_value)) / spread
    else:
        spread = baseline.spread_value or max(abs(baseline.median_value) * 0.08, 1.0)
        delta = (value - baseline.median_value) / spread
    # orient the standardized delta so positive always means better
    signed = delta if higher_is_better else -delta
    score = _clamp(80 + signed * 12, 0, 100)
    return {
        "score": round(score, 1),
        "value": value,
        "baseline": baseline.median_value,
        "z_like_delta": round(delta, 2),
    }


def _weighted_score(components: dict[str, Any], weights: dict[str, float]) -> float | None:
    numerator = 0.0
    denominator = 0.0
    for key, weight in weights.items():
        component = components.get(key)
        score = None
        if isinstance(component, dict):
            score = component.get("score")
        elif isinstance(component, (int, float)):
            score = component
        if score is None:
            continue
        numerator += float(score) * weight
        denominator += weight
    if denominator == 0:
        return None
    # normalize weights across only the available components
    return round(numerator / denominator, 1)


def _quality_for_components(components: dict[str, Any]) -> str:
    present = sum(
        isinstance(component, dict) and component.get("score") is not None
        for component in components.values()
    )
    if present >= 5:
        return "strong"
    if present >= 3:
        return "moderate"
    if present >= 1:
        return "weak"
    return "missing"


def _phase_for_count(count: int) -> str:
    if count <= 0:
        return "missing"
    if count < 7:
        return "provisional"
    if count < 28:
        return "calibrating"
    return "personalized"


def _combined_phase(phases: list[str]) -> str:
    rank = {"missing": 0, "provisional": 1, "calibrating": 2, "personalized": 3}
    if not phases:
        return "missing"
    return min(phases, key=lambda phase: rank.get(phase, 0))


def _robust_spread(values: list[float]) -> float:
    if len(values) <= 1:
        return 0.0
    med = median(values)
    deviations = [abs(value - med) for value in values]
    # scale median absolute deviation to a standard-deviation equivalent
    return float(median(deviations) * 1.4826)


def _drop_extreme_outliers(values: list[tuple[date, float]]) -> list[tuple[date, float]]:
    if len(values) < 8:
        return values
    numeric = [value for _, value in values]
    med = median(numeric)
    spread = _robust_spread(numeric)
    if spread == 0:
        return values
    return [(day, value) for day, value in values if abs(value - med) <= 4 * spread]


def _date_range(start: date, end: date) -> list[date]:
    days = []
    current = start
    while current <= end:
        days.append(current)
        current = date.fromordinal(current.toordinal() + 1)
    return days


def _local_minute(profile: UserProfile, value: datetime) -> int:
    if value.tzinfo is not None:
        value = value.astimezone(timezone_for_profile(profile))
    return value.hour * 60 + value.minute


def _circular_minutes_diff(a: float, b: float) -> float:
    diff = abs(a - b) % 1440
    return min(diff, 1440 - diff)


def _circular_mean_minutes(values: list[float]) -> float:
    # average clock times as angles to handle midnight wraparound
    angles = [value / 1440 * 2 * pi for value in values]
    angle = atan2(mean([sin(item) for item in angles]), mean([cos(item) for item in angles]))
    return (angle % (2 * pi)) / (2 * pi) * 1440


def _circular_median_minutes(values: list[float]) -> float:
    return min(values, key=lambda candidate: sum(_circular_minutes_diff(candidate, item) for item in values))


def _circular_robust_spread(values: list[float], centre: float) -> float:
    deviations = [_circular_minutes_diff(value, centre) for value in values]
    return float(median(deviations) * 1.4826)


def _circular_midpoint(start_minute: float, end_minute: float) -> float:
    duration = (end_minute - start_minute) % 1440
    return (start_minute + duration / 2) % 1440


def _interpolate_anchors(value: float, anchors: list[tuple[float, float]]) -> float:
    if value <= anchors[0][0]:
        return float(anchors[0][1])
    for (x0, y0), (x1, y1) in zip(anchors, anchors[1:]):
        if value <= x1:
            # linearly interpolate between the surrounding research anchors
            ratio = (value - x0) / (x1 - x0)
            return float(y0 + ratio * (y1 - y0))
    return float(anchors[-1][1])


def _profile_age(profile: UserProfile, day: date) -> int | None:
    if profile.date_of_birth:
        return (
            day.year
            - profile.date_of_birth.year
            - ((day.month, day.day) < (profile.date_of_birth.month, profile.date_of_birth.day))
        )
    if profile.birth_year:
        return day.year - profile.birth_year
    return None


def _core_sleep_need_minutes(profile: UserProfile, day: date) -> int:
    age = _profile_age(profile, day)
    if age is not None and age <= 17:
        default = 540
        low, high = 480, 600
    elif age is not None and age >= 65:
        default = 450
        low, high = 420, 480
    else:
        default = 480
        low, high = 420, 540
    target = profile.sleep_target_minutes or default
    return max(low, min(high, target))


def _range_score(value: float, low_good: float, high_good: float, low_bad: float, high_bad: float) -> float:
    if low_good <= value <= high_good:
        return 100.0
    if value < low_good:
        return _clamp((value - low_bad) / (low_good - low_bad) * 100, 0, 100)
    return _clamp((high_bad - value) / (high_bad - high_good) * 100, 0, 100)


def _spo2_score(value: float | None) -> dict[str, Any] | None:
    if value is None:
        return None
    if value >= 96:
        score = 100.0
    elif value >= 94:
        score = 80.0
    elif value >= 92:
        score = 55.0
    else:
        score = 30.0
    return {"score": score, "value": value}


def _clamp(value: float, low: float, high: float) -> float:
    return max(low, min(high, value))


def _to_float(value: Any) -> float | None:
    try:
        return float(value)
    except (TypeError, ValueError):
        return None


def _extract_zone_summaries(payload: Any) -> list[dict[str, Any]]:
    if isinstance(payload, list):
        zones: list[dict[str, Any]] = []
        for item in payload:
            zones.extend(_extract_zone_summaries(item))
        return zones
    if not isinstance(payload, dict):
        return []
    for key in ("heartRateZones", "heart_rate_zones", "heartRateZoneSummaries", "zones"):
        value = payload.get(key)
        if isinstance(value, list) and all(isinstance(item, dict) for item in value):
            return value
    zones = []
    for value in payload.values():
        zones.extend(_extract_zone_summaries(value))
    return zones


def _zone_minutes(zone: dict[str, Any]) -> float | None:
    for key in ("minutes", "minute", "durationMinutes"):
        value = _to_float(zone.get(key))
        if value is not None:
            return value
    seconds = _to_float(zone.get("seconds") or zone.get("durationSeconds"))
    if seconds is not None:
        return seconds / 60
    return None


def _reason(
    code: str,
    severity: str,
    message: str,
    direction: str = "negative",
) -> dict[str, str]:
    return {
        "code": code,
        "severity": severity,
        "message": message,
        "direction": direction,
    }
