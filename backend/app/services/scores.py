from __future__ import annotations

from dataclasses import dataclass
from datetime import date, datetime, timedelta
from math import isfinite
from statistics import mean, median
from typing import Any

from sqlalchemy import select
from sqlalchemy.orm import Session

from app.core.security import utcnow
from app.models import (
    DailyBaseline,
    DailyContext,
    DailyScore,
    DailySummary,
    MetricInterval,
    MetricSample,
    RawHealthRecord,
    ScoreStatus,
    SleepSession,
    StrainTarget,
    UserProfile,
    Workout,
)
from app.services.health_dates import (
    estimated_max_heart_rate,
    get_or_create_profile,
    local_date_for_profile,
    local_week_start,
    timezone_for_profile,
)
from app.services.metric_rollups import RollupPoint, rollup_points_for_metric


BASELINE_VERSION = "baseline_v1"
SLEEP_SCORE_VERSION = "sleep_score_v1"
READINESS_SCORE_VERSION = "readiness_score_v1"
STRAIN_LOAD_VERSION = "strain_load_v1"

SCORE_VERSIONS = {
    "sleep": SLEEP_SCORE_VERSION,
    "readiness": READINESS_SCORE_VERSION,
    "strain": STRAIN_LOAD_VERSION,
}

BASELINE_METRICS = (
    "sleep_minutes",
    "sleep_start_minute",
    "sleep_end_minute",
    "sleep_efficiency",
    "heart_rate_variability",
    "resting_heart_rate",
    "respiratory_rate",
    "oxygen_saturation",
    "strain_load",
)


@dataclass(frozen=True)
class ScoreRebuildResult:
    user_id: str
    start: date
    end: date
    scores_rebuilt: int
    baselines_rebuilt: int
    targets_rebuilt: int


# rebuild scores (mainly for use during testing)
def rebuild_derived_scores(
    session: Session,
    *,
    user_id: str,
    start: date,
    end: date,
) -> ScoreRebuildResult:
    profile = get_or_create_profile(session, user_id)
    today = local_date_for_profile(profile)
    effective_end = min(end, today)
    if effective_end < start:
        effective_end = start

    scores_rebuilt = 0
    baselines_rebuilt = 0
    for day in _date_range(start, effective_end):
        _detect_timezone_shift_context(session, user_id=user_id, profile=profile, day=day)
        baselines_rebuilt += rebuild_daily_baselines(
            session,
            user_id=user_id,
            profile=profile,
            baseline_date=day,
        )
        _upsert_sleep_score(session, user_id=user_id, profile=profile, day=day)
        _upsert_strain_score(session, user_id=user_id, profile=profile, day=day)
        _upsert_readiness_score(session, user_id=user_id, profile=profile, day=day)
        scores_rebuilt += 3
        session.flush()

    targets_rebuilt = 0
    for week_start in sorted({local_week_start(day) for day in _date_range(start, effective_end)}):
        _upsert_strain_target(session, user_id=user_id, week_start=week_start)
        targets_rebuilt += 1
    session.flush()
    return ScoreRebuildResult(
        user_id=user_id,
        start=start,
        end=effective_end,
        scores_rebuilt=scores_rebuilt,
        baselines_rebuilt=baselines_rebuilt,
        targets_rebuilt=targets_rebuilt,
    )


# updating baseline stats
def rebuild_daily_baselines(
    session: Session,
    *,
    user_id: str,
    profile: UserProfile,
    baseline_date: date,
) -> int:
    count = 0
    for metric in BASELINE_METRICS:
        values, exclusions, window_days = _baseline_values(
            session,
            user_id=user_id,
            profile=profile,
            metric=metric,
            baseline_date=baseline_date,
        )
        baseline = _get_or_create_baseline(session, user_id, baseline_date, metric)
        baseline.window_days = window_days
        baseline.valid_day_count = len(values)
        baseline.confidence_phase = _phase_for_count(len(values))
        baseline.included_dates = [item[0].isoformat() for item in values]
        baseline.exclusions = exclusions
        numeric_values = [item[1] for item in values]
        if numeric_values:
            med = float(median(numeric_values))
            avg = float(mean(numeric_values))
            spread = _robust_spread(numeric_values)
            baseline.mean_value = avg
            baseline.median_value = med
            baseline.spread_value = spread
            if spread > 0:
                baseline.lower_bound = med - 2 * spread
                baseline.upper_bound = med + 2 * spread
            else:
                baseline.lower_bound = med
                baseline.upper_bound = med
        else:
            baseline.mean_value = None
            baseline.median_value = None
            baseline.spread_value = None
            baseline.lower_bound = None
            baseline.upper_bound = None
        session.add(baseline)
        count += 1
    session.flush()
    return count


# Score upserts, all the are calculations derived from research (../../../research)
def _upsert_sleep_score(
    session: Session,
    *,
    user_id: str,
    profile: UserProfile,
    day: date,
) -> DailyScore:
    score = _get_or_create_score(session, user_id, day, "sleep", SLEEP_SCORE_VERSION)
    sleep = _main_sleep(session, user_id, day)
    if sleep is None or sleep.minutes_asleep is None:
        return _mark_score_waiting(
            score,
            unit="score_0_100",
            status=ScoreStatus.waiting_for_sleep,
            reason_code="waiting_for_main_sleep",
            message="Sleep score is waiting for the main sleep session ending on this day.",
        )

    # get target + individual components and apply weights
    target = _adjusted_sleep_need_minutes(session, user_id, profile, day)
    duration = _duration_score(sleep.minutes_asleep, target)
    regularity = _regularity_score(session, user_id, profile, day, sleep)
    continuity = _continuity_score(sleep)
    timing = _timing_score(session, user_id, profile, day, sleep)
    physiology = _sleep_physiology_score(session, user_id, day)
    stages = _stage_score(sleep)
    components = {
        "duration": duration,
        "regularity": regularity,
        "continuity": continuity,
        "timing": timing,
        "physiology": physiology,
        "stages": stages,
    }
    weights = {
        "duration": 0.35,
        "regularity": 0.25,
        "continuity": 0.20,
        "timing": 0.10,
        "physiology": 0.05,
        "stages": 0.05,
    }
    value = _weighted_score(components, weights)
    reasons = _sleep_reasons(components)
    phase = _combined_phase(
        [
            _baseline_phase(session, user_id, day, "sleep_minutes"),
            _baseline_phase(session, user_id, day, "sleep_start_minute"),
            _baseline_phase(session, user_id, day, "sleep_efficiency"),
        ]
    )
    return _set_score(
        score,
        value=value,
        unit="score_0_100",
        status=ScoreStatus.scored,
        confidence_phase=phase,
        data_quality=_quality_for_components(components),
        components=components,
        inputs={
            "main_sleep_id": sleep.id,
            "sleep_target_minutes": profile.sleep_target_minutes,
            "adjusted_sleep_need_minutes": target,
            "sleep_target_source": "profile_or_default",
        },
        reasons=reasons,
    )


# Creating a score instead of just a 1-100 rating was interesting
def _upsert_strain_score(
    session: Session,
    *,
    user_id: str,
    profile: UserProfile,
    day: date,
) -> DailyScore:
    score = _get_or_create_score(session, user_id, day, "strain", STRAIN_LOAD_VERSION)
    samples = _heart_rate_samples(session, user_id, day)
    workouts = _workouts_for_day(session, user_id, day)
    summary = _summary_for_day(session, user_id, day)
    today = local_date_for_profile(profile)

    if not samples and not workouts and summary is None:
        status = ScoreStatus.in_progress if day == today else ScoreStatus.missing_data
        return _mark_score_waiting(
            score,
            unit="load_points",
            status=status,
            reason_code="waiting_for_activity_data",
            message="Strain load is waiting for heart-rate, workout, or activity data.",
        )

    max_hr, max_hr_source = estimated_max_heart_rate(profile, day)
    max_hr, max_hr_source = _credible_observed_max_hr(samples, workouts, max_hr, max_hr_source)
    rhr, rhr_source = _resting_hr_for_strain(session, user_id, day, samples, summary)
    cardio = _cardio_load_from_hr(samples, workouts, rhr=rhr, max_hr=max_hr)
    source_zone = _source_zone_load(workouts) if cardio["confidence"] == "weak" else None
    if source_zone is None and cardio["confidence"] == "weak":
        source_zone = _source_zone_load_from_intervals(session, user_id, day, workouts)
    activity = _daily_activity_load(summary, cardio_confidence=cardio["confidence"])
    muscular = _muscular_load(workouts)
    total = cardio["load_points"]
    if source_zone is not None:
        total += source_zone["load_points"]
    total += activity["load_points"] + muscular["load_points"]
    total = round(total, 2)

    components = {
        "cardio_load": cardio,
        "source_zone_load": source_zone,
        "daily_activity_load": activity,
        "muscular_load": muscular,
        "rpe_load": None,
        "total_load": total,
    }
    components["workout_contributions"] = _workout_contributions(components, workouts)
    confidence = _strain_confidence_phase(session, user_id, day)
    status = ScoreStatus.in_progress if day == today else ScoreStatus.scored
    reasons = _strain_reasons(total, components)
    return _set_score(
        score,
        value=total,
        unit="load_points",
        status=status,
        confidence_phase=confidence,
        data_quality=cardio["confidence"],
        components=components,
        inputs={
            "max_hr": max_hr,
            "max_hr_source": max_hr_source,
            "resting_hr": rhr,
            "resting_hr_source": rhr_source,
            "hr_sample_count": len(samples),
            "workout_count": len(workouts),
        },
        reasons=reasons,
    )


def _upsert_readiness_score(
    session: Session,
    *,
    user_id: str,
    profile: UserProfile,
    day: date,
) -> DailyScore:
    score = _get_or_create_score(session, user_id, day, "readiness", READINESS_SCORE_VERSION)
    sleep = _main_sleep(session, user_id, day)
    if sleep is None or sleep.minutes_asleep is None:
        return _mark_score_waiting(
            score,
            unit="score_0_100",
            status=ScoreStatus.waiting_for_sleep,
            reason_code="waiting_for_main_sleep",
            message="Readiness is waiting for the sleep session that ended on this day.",
        )

    # again getting targets and components so i can apply them
    target = _adjusted_sleep_need_minutes(session, user_id, profile, day)
    sleep_component = _readiness_sleep_component(session, user_id, day, sleep, target)
    autonomic = _autonomic_component(session, user_id, day)
    load_fit = _load_fit_component(session, user_id, day)
    anomaly = _anomaly_component(session, user_id, day, autonomic)
    confidence = _confidence_component(session, user_id, day)
    components = {
        "sleep_adequacy_debt": sleep_component,
        "autonomic_recovery": autonomic,
        "recent_load_fit": load_fit,
        "illness_anomaly_context": anomaly,
        "confidence": confidence,
    }
    weights = {
        "sleep_adequacy_debt": 0.30,
        "autonomic_recovery": 0.30,
        "recent_load_fit": 0.25,
        "illness_anomaly_context": 0.10,
        "confidence": 0.05,
    }
    value = _weighted_score(components, weights)
    cap = anomaly.get("readiness_cap")
    if cap is not None and value is not None:
        value = min(value, float(cap))
    phase = _combined_phase(
        [
            _baseline_phase(session, user_id, day, "heart_rate_variability"),
            _baseline_phase(session, user_id, day, "resting_heart_rate"),
            _strain_confidence_phase(session, user_id, day),
        ]
    )
    return _set_score(
        score,
        value=value,
        unit="score_0_100",
        status=ScoreStatus.scored,
        confidence_phase=phase,
        data_quality=_quality_for_components(components),
        components=components,
            inputs={
                "main_sleep_id": sleep.id,
                "uses_same_day_strain": False,
                "load_window": load_fit.get("window") if load_fit else None,
                "adjusted_sleep_need_minutes": target,
            },
        reasons=_readiness_reasons(components, cap),
    )


# Creating our strain target
def _upsert_strain_target(session: Session, *, user_id: str, week_start: date) -> StrainTarget:
    target = _get_or_create_strain_target(session, user_id, week_start)
    week_end = week_start + timedelta(days=6)
    prior_loads = _strain_loads(session, user_id, week_start - timedelta(days=60), week_start - timedelta(days=1))
    current_loads = _strain_loads(session, user_id, week_start, week_end)
    chronic = _chronic_load(prior_loads)
    progress = sum(value for _, value in current_loads)
    phase = _phase_for_count(len(prior_loads))
    target_points = None if chronic is None else round(chronic * 7, 2)
    ratio = None if not target_points else round(progress / target_points, 3)
    target.target_load_points = target_points
    target.chronic_load_points = None if chronic is None else round(chronic * 7, 2)
    target.acute_load_points = round(sum(value for _, value in current_loads[-7:]), 2)
    target.progress_load_points = round(progress, 2)
    target.progress_ratio = ratio
    target.load_band = _load_band_for_ratio(ratio)
    target.confidence_phase = phase
    target.components = {
        "current_week_loads": [{"date": d.isoformat(), "load": v} for d, v in current_loads],
        "prior_valid_days": len(prior_loads),
    }
    target.inputs = {"week_start_date": week_start.isoformat(), "week_end_date": week_end.isoformat()}
    target.computed_at = utcnow()
    session.add(target)
    return target


def _baseline_values(
    session: Session,
    *,
    user_id: str,
    profile: UserProfile,
    metric: str,
    baseline_date: date,
) -> tuple[list[tuple[date, float]], list[dict[str, Any]], int]:
    exclusions: list[dict[str, Any]] = []
    values: list[tuple[date, float]] = []
    for window_days in (28, 60):
        start = baseline_date - timedelta(days=window_days)
        end = baseline_date - timedelta(days=1)
        values.clear()
        exclusions.clear()
        for day in _date_range(start, end):
            context_exclusion = _baseline_context_exclusion(session, user_id, day)
            if context_exclusion:
                exclusions.append({"date": day.isoformat(), "reason": context_exclusion})
                continue
            value = _metric_value_for_baseline(session, user_id, profile, day, metric)
            if value is None or not isfinite(value):
                exclusions.append({"date": day.isoformat(), "reason": "missing_metric"})
                continue
            summary = _summary_for_day(session, user_id, day)
            if summary and summary.data_quality == "missing" and metric not in {
                "sleep_start_minute",
                "sleep_end_minute",
                "sleep_efficiency",
                "strain_load",
            }:
                exclusions.append({"date": day.isoformat(), "reason": "missing_daily_summary"})
                continue
            values.append((day, value))
        if len(values) >= 14 or window_days == 60:
            return _drop_extreme_outliers(values), exclusions, window_days
    return values, exclusions, 60


def _metric_value_for_baseline(
    session: Session,
    user_id: str,
    profile: UserProfile,
    day: date,
    metric: str,
) -> float | None:
    summary = _summary_for_day(session, user_id, day)
    if metric == "strain_load":
        score = _score_for_day(session, user_id, day, "strain", STRAIN_LOAD_VERSION)
        return score.value if score and score.value is not None else None
    if metric in {"sleep_start_minute", "sleep_end_minute", "sleep_efficiency"}:
        sleep = _main_sleep(session, user_id, day)
        if sleep is None:
            return None
        if metric == "sleep_efficiency":
            return _sleep_efficiency(sleep)
        tz = timezone_for_profile(profile)
        dt = sleep.start_time if metric == "sleep_start_minute" else sleep.end_time
        if dt.tzinfo is None:
            return dt.hour * 60 + dt.minute
        local = dt.astimezone(tz)
        return local.hour * 60 + local.minute
    if summary is None:
        return None
    value = getattr(summary, metric, None)
    return float(value) if value is not None else None


def _cardio_load_from_hr(
    samples: list[MetricSample],
    workouts: list[Workout],
    *,
    rhr: float | None,
    max_hr: float | None,
) -> dict[str, Any]:
    if len(samples) < 2 or rhr is None or max_hr is None or max_hr <= rhr + 20:
        return {
            "load_points": 0.0,
            "covered_minutes": 0.0,
            "long_gap_count": 0,
            "workout_coverage_ratio": 0.0,
            "confidence": "weak",
            "workouts": [],
        }
    sorted_samples = sorted(samples, key=lambda item: item.observed_at)
    load = 0.0
    workout_load = 0.0
    general_activity_load = 0.0
    workout_contributions: dict[str, float] = {}
    covered_seconds = 0.0
    long_gap_count = 0
    workout_seconds = sum(
        max(0.0, (workout.end_time - workout.start_time).total_seconds()) for workout in workouts
    )
    workout_covered = 0.0
    for current, nxt in zip(sorted_samples, sorted_samples[1:]):
        gap = (nxt.observed_at - current.observed_at).total_seconds()
        if gap <= 0:
            continue
        if gap > 120:
            long_gap_count += 1
        seconds = min(gap, 120)
        hr = current.value
        if hr < 35 or hr > 230:
            continue
        intensity = max(0.0, min(1.1, (hr - rhr) / (max_hr - rhr)))
        if intensity < 0.30:
            points_per_minute = 0.0
        else:
            points_per_minute = 2.5 * ((intensity - 0.30) / 0.70) ** 1.7
        minutes = seconds / 60
        contribution = points_per_minute * minutes
        load += contribution
        covered_seconds += seconds
        workout = _workout_for_timestamp(current.observed_at, workouts)
        if workout is not None:
            workout_load += contribution
            workout_contributions[workout.id] = workout_contributions.get(workout.id, 0.0) + contribution
            workout_covered += seconds
        else:
            general_activity_load += contribution
    covered_minutes = covered_seconds / 60
    workout_ratio = 0.0 if workout_seconds <= 0 else min(1.0, workout_covered / workout_seconds)
    if covered_minutes >= 720 or workout_ratio >= 0.70:
        confidence = "strong"
    elif covered_minutes >= 240 or workout_ratio >= 0.30:
        confidence = "moderate"
    else:
        confidence = "weak"
    return {
        "load_points": round(load, 2),
        "workout_load_points": round(workout_load, 2),
        "general_activity_load_points": round(general_activity_load, 2),
        "covered_minutes": round(covered_minutes, 1),
        "long_gap_count": long_gap_count,
        "workout_coverage_ratio": round(workout_ratio, 3),
        "confidence": confidence,
        "workouts": [
            {"workout_id": workout_id, "load_points": round(value, 2)}
            for workout_id, value in workout_contributions.items()
            if round(value, 2) > 0
        ],
    }


def _resting_hr_for_strain(
    session: Session,
    user_id: str,
    day: date,
    samples: list[MetricSample],
    summary: DailySummary | None,
) -> tuple[float | None, str | None]:
    baseline = _baseline_value(session, user_id, day, "resting_heart_rate")
    if baseline is not None:
        return baseline, "baseline"
    if summary and summary.resting_heart_rate:
        return summary.resting_heart_rate, "daily_summary"
    observed = _observed_resting_hr_estimate(samples)
    if observed is not None:
        return observed, "observed_low_percentile"
    return None, None


def _observed_resting_hr_estimate(samples: list[MetricSample]) -> float | None:
    values = sorted(sample.value for sample in samples if 35 <= sample.value <= 230)
    if len(values) < 30:
        return None
    percentile_index = max(0, min(len(values) - 1, round((len(values) - 1) * 0.10)))
    return round(_clamp(values[percentile_index], 40, 90), 1)


def _daily_activity_load(summary: DailySummary | None, *, cardio_confidence: str) -> dict[str, Any]:
    if summary is None:
        return {"load_points": 0.0, "source": "missing"}
    step_load = min(10.0, (summary.steps or 0) / 10000 * 8)
    calorie_load = min(12.0, (summary.active_calories or 0) / 600 * 12)
    load = max(step_load, calorie_load)
    if cardio_confidence == "strong":
        high_movement_load = max(0.0, load - 8.0)
        load = min(high_movement_load, 1.0)
    elif cardio_confidence == "moderate":
        load = min(load, 6.0)
    return {
        "load_points": round(load, 2),
        "source": "steps_active_calories_gap_fill",
        "cardio_confidence": cardio_confidence,
    }


def _muscular_load(workouts: list[Workout]) -> dict[str, Any]:
    load = 0.0
    contributing: list[dict[str, Any]] = []
    strength_terms = ("strength", "weight", "resistance", "crossfit", "hiit", "circuit")
    for workout in workouts:
        workout_type = (workout.workout_type or "").lower()
        if not any(term in workout_type for term in strength_terms):
            continue
        minutes = (workout.duration_seconds or 0) / 60
        contribution = min(20.0, minutes * 0.18)
        load += contribution
        contributing.append(
            {
                "workout_id": workout.id,
                "workout_type": workout.workout_type,
                "load_points": round(contribution, 2),
            }
        )
    return {"load_points": round(load, 2), "workouts": contributing}


def _source_zone_load(workouts: list[Workout]) -> dict[str, Any] | None:
    total = 0.0
    zones_seen = 0
    weights = [0.1, 0.35, 0.8, 1.4, 2.0]
    contributing: list[dict[str, Any]] = []
    for workout in workouts:
        workout_total = 0.0
        zones = _extract_zone_summaries(workout.raw_summary)
        for index, zone in enumerate(zones):
            minutes = _zone_minutes(zone)
            if minutes is None:
                continue
            weight = weights[min(index, len(weights) - 1)]
            contribution = minutes * weight
            total += contribution
            workout_total += contribution
            zones_seen += 1
        if workout_total > 0:
            contributing.append(
                {
                    "workout_id": workout.id,
                    "workout_type": workout.workout_type,
                    "load_points": round(workout_total, 2),
                }
            )
    if zones_seen == 0:
        return None
    return {
        "load_points": round(total, 2),
        "zones_seen": zones_seen,
        "source": "provider_zones",
        "workout_load_points": round(total, 2),
        "general_activity_load_points": 0.0,
        "workouts": contributing,
    }


def _source_zone_load_from_intervals(
    session: Session,
    user_id: str,
    day: date,
    workouts: list[Workout],
) -> dict[str, Any] | None:
    rows = session.execute(
        select(MetricInterval, RawHealthRecord)
        .join(RawHealthRecord, MetricInterval.raw_record_id == RawHealthRecord.id)
        .where(
            MetricInterval.user_id == user_id,
            MetricInterval.metric == "time_in_heart_rate_zone",
            MetricInterval.civil_date == day,
        )
    ).all()
    weights = {
        "LIGHT": 0.1,
        "MODERATE": 0.35,
        "VIGOROUS": 0.8,
        "PEAK": 1.4,
    }
    total = 0.0
    workout_total = 0.0
    general_activity_total = 0.0
    workout_contributions: dict[str, float] = {}
    zones_seen = 0
    for interval, raw_record in rows:
        payload = raw_record.raw_json.get("timeInHeartRateZone") or {}
        zone_type = payload.get("heartRateZoneType")
        weight = weights.get(str(zone_type))
        if weight is None:
            continue
        interval_load = (interval.value / 60) * weight
        total += interval_load
        attributed_load = 0.0
        interval_seconds = max(0.0, (interval.end_time - interval.start_time).total_seconds())
        for workout in workouts:
            overlap = _overlap_seconds(
                interval.start_time,
                interval.end_time,
                workout.start_time,
                workout.end_time,
            )
            if overlap <= 0 or interval_seconds <= 0:
                continue
            contribution = interval_load * min(1.0, overlap / interval_seconds)
            attributed_load += contribution
            workout_total += contribution
            workout_contributions[workout.id] = workout_contributions.get(workout.id, 0.0) + contribution
        general_activity_total += max(0.0, interval_load - attributed_load)
        zones_seen += 1
    if zones_seen == 0:
        return None
    return {
        "load_points": round(total, 2),
        "zones_seen": zones_seen,
        "source": "time_in_heart_rate_zone",
        "workout_load_points": round(workout_total, 2),
        "general_activity_load_points": round(general_activity_total, 2),
        "workouts": [
            {"workout_id": workout_id, "load_points": round(value, 2)}
            for workout_id, value in workout_contributions.items()
            if round(value, 2) > 0
        ],
    }


def _workout_contributions(
    components: dict[str, Any],
    workouts: list[Workout] | None = None,
) -> list[dict[str, Any]]:
    contributions: dict[str, dict[str, Any]] = {}
    for workout in workouts or []:
        contributions[str(workout.id)] = {
            "workout_id": str(workout.id),
            "workout_type": workout.workout_type,
            "load_points": 0.0,
            "components": {},
        }
    sources = (
        ("cardio_load", "cardio"),
        ("source_zone_load", "zones"),
        ("muscular_load", "muscular"),
    )
    for component_key, contribution_key in sources:
        component = components.get(component_key)
        if not isinstance(component, dict):
            continue
        for item in component.get("workouts") or []:
            if not isinstance(item, dict):
                continue
            workout_id = item.get("workout_id")
            load = item.get("load_points")
            if not workout_id or not isinstance(load, int | float):
                continue
            contribution = contributions.setdefault(
                str(workout_id),
                {
                    "workout_id": str(workout_id),
                    "workout_type": item.get("workout_type"),
                    "load_points": 0.0,
                    "components": {},
                },
            )
            contribution["load_points"] += float(load)
            contribution["components"][contribution_key] = round(
                contribution["components"].get(contribution_key, 0.0) + float(load),
                2,
            )
            if contribution.get("workout_type") is None and item.get("workout_type") is not None:
                contribution["workout_type"] = item.get("workout_type")

    return [
        {
            **item,
            "load_points": round(item["load_points"], 2),
        }
        for item in contributions.values()
    ]

# MY SLEEP SCORE COMPONENTS
def _duration_score(minutes: int, target: int) -> dict[str, Any]:
    target = max(420, min(540, target))
    ratio = minutes / target
    if 0.94 <= ratio <= 1.12:
        score = 100.0
    elif ratio < 0.94:
        score = max(0.0, 100 - ((0.94 - ratio) / 0.44) * 80)
    else:
        score = max(70.0, 100 - ((ratio - 1.12) / 0.25) * 30)
    return {"score": round(score, 1), "minutes": minutes, "target_minutes": target}


def _regularity_score(
    session: Session,
    user_id: str,
    profile: UserProfile,
    day: date,
    sleep: SleepSession,
) -> dict[str, Any]:
    start_minute = _local_minute(profile, sleep.start_time)
    end_minute = _local_minute(profile, sleep.end_time)
    start_baseline = _baseline_for_metric(session, user_id, day, "sleep_start_minute")
    end_baseline = _baseline_for_metric(session, user_id, day, "sleep_end_minute")
    if not start_baseline or not end_baseline or start_baseline.valid_day_count < 4:
        return {"score": 75.0, "start_minute": start_minute, "end_minute": end_minute}
    start_diff = _circular_minutes_diff(start_minute, start_baseline.median_value or start_minute)
    end_diff = _circular_minutes_diff(end_minute, end_baseline.median_value or end_minute)
    avg_diff = (start_diff + end_diff) / 2
    score = max(0.0, 100 - max(0.0, avg_diff - 30) * 0.45)
    if start_minute >= 120 and start_minute <= 300:
        score -= 5
    return {
        "score": round(max(0.0, score), 1),
        "average_drift_minutes": round(avg_diff, 1),
        "start_minute": start_minute,
        "end_minute": end_minute,
    }


def _continuity_score(sleep: SleepSession) -> dict[str, Any]:
    efficiency = _sleep_efficiency(sleep)
    awake = sleep.minutes_awake
    if efficiency is None:
        period = max(1, int((sleep.end_time - sleep.start_time).total_seconds() / 60))
        efficiency = (sleep.minutes_asleep or 0) / period
    efficiency_score = _clamp((efficiency - 0.70) / 0.22 * 100, 0, 100)
    awake_score = 100.0 if awake is None else max(0.0, 100 - max(0, awake - 20) * 1.15)
    score = efficiency_score * 0.72 + awake_score * 0.28
    return {
        "score": round(score, 1),
        "sleep_efficiency": round(efficiency, 3),
        "minutes_awake": awake,
    }


def _timing_score(
    session: Session,
    user_id: str,
    profile: UserProfile,
    day: date,
    sleep: SleepSession,
) -> dict[str, Any]:
    start_minute = _local_minute(profile, sleep.start_time)
    baseline = _baseline_for_metric(session, user_id, day, "sleep_start_minute")
    if not baseline or baseline.valid_day_count < 4:
        score = 82.0
        drift = None
    else:
        drift = _circular_minutes_diff(start_minute, baseline.median_value or start_minute)
        score = max(0.0, 100 - max(0.0, drift - 45) * 0.35)
    if start_minute >= 120 and start_minute <= 300:
        score -= 6
    return {"score": round(max(0.0, score), 1), "start_drift_minutes": drift}


def _sleep_physiology_score(session: Session, user_id: str, day: date) -> dict[str, Any] | None:
    summary = _summary_for_day(session, user_id, day)
    if summary is None:
        return None
    inputs: list[float] = []
    details: dict[str, Any] = {}
    hrv = _metric_baseline_score(
        session,
        user_id,
        day,
        "heart_rate_variability",
        summary.heart_rate_variability,
        higher_is_better=True,
    )
    rhr = _metric_baseline_score(
        session,
        user_id,
        day,
        "resting_heart_rate",
        summary.resting_heart_rate,
        higher_is_better=False,
    )
    resp = _metric_baseline_score(
        session,
        user_id,
        day,
        "respiratory_rate",
        summary.respiratory_rate,
        higher_is_better=False,
    )
    spo2 = _spo2_score(summary.oxygen_saturation)
    for key, item in (("hrv", hrv), ("rhr", rhr), ("respiratory_rate", resp), ("spo2", spo2)):
        if item is None:
            continue
        inputs.append(item["score"])
        details[key] = item
    if not inputs:
        return None
    details["score"] = round(mean(inputs), 1)
    return details


def _stage_score(sleep: SleepSession) -> dict[str, Any] | None:
    total = sleep.minutes_asleep
    if not total:
        return None
    stage_totals = _stage_totals_for_score(sleep)
    rem = stage_totals.get("rem", 0.0)
    deep = stage_totals.get("deep", 0.0)
    if rem == 0 and deep == 0:
        return None
    rem_pct = rem / total
    deep_pct = deep / total
    rem_score = _range_score(rem_pct, 0.15, 0.30, 0.08, 0.38)
    deep_score = _range_score(deep_pct, 0.10, 0.25, 0.04, 0.33)
    return {
        "score": round((rem_score + deep_score) / 2, 1),
        "rem_minutes": rem,
        "deep_minutes": deep,
        "rem_percent": round(rem_pct, 3),
        "deep_percent": round(deep_pct, 3),
    }


def _stage_totals_for_score(sleep: SleepSession) -> dict[str, float]:
    timeline_totals = _stage_totals_from_timeline(sleep)
    if timeline_totals:
        return timeline_totals
    return _stage_totals_from_summary(sleep.stages_summary)


def _stage_totals_from_timeline(sleep: SleepSession) -> dict[str, float]:
    totals = {"rem": 0.0, "deep": 0.0}
    covered_minutes = 0.0
    for item in sleep.stages or []:
        stage_type = str(item.get("type") or item.get("stage") or "").lower()
        start = _parse_stage_datetime(item.get("startTime"))
        end = _parse_stage_datetime(item.get("endTime"))
        if start is None or end is None:
            continue
        minutes = max(0.0, (end - start).total_seconds() / 60)
        if minutes <= 0:
            continue
        covered_minutes += minutes
        if "rem" in stage_type:
            totals["rem"] += minutes
        if "deep" in stage_type or "slow" in stage_type:
            totals["deep"] += minutes
    expected = sleep.minutes_in_sleep_period or sleep.minutes_asleep
    if not expected or covered_minutes < expected * 0.65:
        return {}
    return totals


def _stage_totals_from_summary(items: list[dict[str, Any]]) -> dict[str, float]:
    totals = {"rem": 0.0, "deep": 0.0}
    seen: set[tuple[str, str, str]] = set()
    for item in items or []:
        stage_type = str(item.get("type") or item.get("stage") or "").lower()
        minutes = _to_float(item.get("minutes") or item.get("durationMinutes"))
        if minutes is None:
            continue
        dedupe_key = (stage_type, str(item.get("minutes")), str(item.get("count")))
        if dedupe_key in seen:
            continue
        seen.add(dedupe_key)
        if "rem" in stage_type:
            totals["rem"] += minutes
        if "deep" in stage_type or "slow" in stage_type:
            totals["deep"] += minutes
    return totals


def _parse_stage_datetime(value: Any) -> datetime | None:
    if not isinstance(value, str) or not value:
        return None
    try:
        return datetime.fromisoformat(value.replace("Z", "+00:00"))
    except ValueError:
        return None

# MY READINESS SCORE COMPONENTS
def _readiness_sleep_component(
    session: Session,
    user_id: str,
    day: date,
    sleep: SleepSession,
    target: int,
) -> dict[str, Any]:
    duration = _duration_score(sleep.minutes_asleep or 0, target)["score"]
    continuity = _continuity_score(sleep)["score"]
    debt = _sleep_debt_minutes(session, user_id, target, day)
    debt_penalty = min(28.0, debt / 420 * 28)
    score = max(0.0, duration * 0.65 + continuity * 0.35 - debt_penalty)
    return {"score": round(score, 1), "sleep_debt_minutes_7d": debt}


def _autonomic_component(session: Session, user_id: str, day: date) -> dict[str, Any] | None:
    summary = _summary_for_day(session, user_id, day)
    if summary is None:
        return None
    hrv = _metric_baseline_score(
        session,
        user_id,
        day,
        "heart_rate_variability",
        summary.heart_rate_variability,
        higher_is_better=True,
    )
    rhr = _metric_baseline_score(
        session,
        user_id,
        day,
        "resting_heart_rate",
        summary.resting_heart_rate,
        higher_is_better=False,
    )
    scores = [item["score"] for item in (hrv, rhr) if item is not None]
    if not scores:
        return None
    trend_penalty = _autonomic_trend_penalty(session, user_id, day)
    score = max(0.0, mean(scores) - trend_penalty)
    return {"score": round(score, 1), "hrv": hrv, "rhr": rhr, "trend_penalty": trend_penalty}


def _load_fit_component(session: Session, user_id: str, day: date) -> dict[str, Any] | None:
    previous_loads = _strain_loads(session, user_id, day - timedelta(days=60), day - timedelta(days=1))
    if len(previous_loads) <= 3:
        return None
    window = _adaptive_load_window(len(previous_loads))
    if window["acute_days"] is None:
        yesterday = previous_loads[-1][1]
        avg = mean(value for _, value in previous_loads)
        ratio = None if avg <= 0 else yesterday / avg
    else:
        acute_values = [value for _, value in previous_loads[-window["acute_days"] :]]
        chronic_pool = previous_loads[: -window["acute_days"]] or previous_loads
        chronic_values = [value for _, value in chronic_pool[-window["chronic_days"] :]]
        ratio = None if not chronic_values or mean(chronic_values) <= 0 else mean(acute_values) / mean(chronic_values)
    if ratio is None:
        score = 80.0
    elif ratio <= 1.20:
        score = 100.0
    elif ratio <= 1.50:
        score = 100 - (ratio - 1.20) / 0.30 * 25
    elif ratio <= 2.0:
        score = 75 - (ratio - 1.50) / 0.50 * 35
    else:
        score = 35.0
    yesterday = previous_loads[-1][1]
    chronic = _chronic_load(previous_loads)
    if chronic and yesterday > chronic * 2.0:
        score -= 12
    return {
        "score": round(max(0.0, score), 1),
        "load_ratio": None if ratio is None else round(ratio, 3),
        "yesterday_load": round(yesterday, 2),
        "window": window,
        "valid_strain_days": len(previous_loads),
    }


def _anomaly_component(
    session: Session,
    user_id: str,
    day: date,
    autonomic: dict[str, Any] | None,
) -> dict[str, Any]:
    summary = _summary_for_day(session, user_id, day)
    anomalies: list[str] = []
    score = 100.0
    if summary:
        resp = _metric_baseline_score(
            session,
            user_id,
            day,
            "respiratory_rate",
            summary.respiratory_rate,
            higher_is_better=False,
        )
        if resp and resp["score"] < 65:
            anomalies.append("respiratory_rate_elevated")
        if summary.oxygen_saturation is not None and summary.oxygen_saturation < 94:
            anomalies.append("oxygen_saturation_low")
    if autonomic:
        hrv = autonomic.get("hrv") or {}
        rhr = autonomic.get("rhr") or {}
        if hrv.get("score", 100) < 65:
            anomalies.append("hrv_suppressed")
        if rhr.get("score", 100) < 65:
            anomalies.append("resting_hr_elevated")
    if _has_context(session, user_id, day, "illness"):
        anomalies.append("illness_tag")
    score -= min(70, len(anomalies) * 18)
    cap = None
    if len(anomalies) >= 3:
        cap = 55
    elif len(anomalies) >= 2:
        cap = 70
    return {"score": max(0.0, score), "anomalies": anomalies, "readiness_cap": cap}


def _confidence_component(session: Session, user_id: str, day: date) -> dict[str, Any]:
    phases = [
        _baseline_phase(session, user_id, day, "heart_rate_variability"),
        _baseline_phase(session, user_id, day, "resting_heart_rate"),
        _baseline_phase(session, user_id, day, "strain_load"),
        _baseline_phase(session, user_id, day, "sleep_minutes"),
    ]
    phase = _combined_phase(phases)
    score = {"missing": 30, "provisional": 55, "calibrating": 78, "personalized": 100}[phase]
    return {"score": score, "phase": phase}


def _strain_confidence_phase(session: Session, user_id: str, day: date) -> str:
    prior_loads = _strain_loads(session, user_id, day - timedelta(days=60), day - timedelta(days=1))
    return _phase_for_count(len(prior_loads))


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
        .where(Workout.user_id == user_id, Workout.civil_date == day)
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
    spread = baseline.spread_value or max(abs(baseline.median_value) * 0.08, 1.0)
    delta = (value - baseline.median_value) / spread
    signed = delta if higher_is_better else -delta
    score = _clamp(80 + signed * 12, 0, 100)
    return {
        "score": round(score, 1),
        "value": value,
        "baseline": baseline.median_value,
        "z_like_delta": round(delta, 2),
    }


def _credible_observed_max_hr(
    samples: list[MetricSample],
    workouts: list[Workout],
    formula_max: float | None,
    formula_source: str,
) -> tuple[float | None, str]:
    if formula_max is None or not samples:
        return formula_max, formula_source
    workout_samples = [
        sample.value for sample in samples if _timestamp_inside_workout(sample.observed_at, workouts)
    ]
    candidates = workout_samples or [sample.value for sample in samples]
    high_values = sorted([value for value in candidates if 80 <= value <= 230], reverse=True)
    if len(high_values) < 2:
        return formula_max, formula_source
    observed = mean(high_values[: min(3, len(high_values))])
    if observed >= formula_max + 5:
        return round(observed, 1), "observed_sustained_workout"
    return formula_max, formula_source


def _timestamp_inside_workout(timestamp: datetime, workouts: list[Workout]) -> bool:
    return _workout_for_timestamp(timestamp, workouts) is not None


def _workout_for_timestamp(timestamp: datetime, workouts: list[Workout]) -> Workout | None:
    for workout in workouts:
        if workout.start_time <= timestamp <= workout.end_time:
            return workout
    return None


def _overlap_seconds(
    start: datetime,
    end: datetime,
    window_start: datetime,
    window_end: datetime,
) -> float:
    latest_start = max(start, window_start)
    earliest_end = min(end, window_end)
    return max(0.0, (earliest_end - latest_start).total_seconds())


def _sleep_efficiency(sleep: SleepSession) -> float | None:
    if sleep.minutes_asleep is None:
        return None
    period = sleep.minutes_in_sleep_period
    if not period:
        period = int((sleep.end_time - sleep.start_time).total_seconds() / 60)
    if period <= 0:
        return None
    return sleep.minutes_asleep / period


def _adjusted_sleep_need_minutes(
    session: Session,
    user_id: str,
    profile: UserProfile,
    day: date,
) -> int:
    base = max(420, min(540, profile.sleep_target_minutes or 480))
    yesterday = _score_for_day(
        session,
        user_id,
        day - timedelta(days=1),
        "strain",
        STRAIN_LOAD_VERSION,
    )
    baseline = _baseline_value(session, user_id, day, "strain_load")
    if yesterday and yesterday.value is not None and baseline and yesterday.value > baseline * 1.5:
        return min(570, base + 30)
    return base


def _sleep_debt_minutes(session: Session, user_id: str, target: int, day: date) -> int:
    debt = 0
    for prev in _date_range(day - timedelta(days=6), day):
        sleep = _main_sleep(session, user_id, prev)
        if sleep is None or sleep.minutes_asleep is None:
            continue
        debt += max(0, target - sleep.minutes_asleep)
    return debt


def _autonomic_trend_penalty(session: Session, user_id: str, day: date) -> float:
    penalty = 0.0
    hrv_values: list[float] = []
    rhr_values: list[float] = []
    for prev in _date_range(day - timedelta(days=2), day):
        summary = _summary_for_day(session, user_id, prev)
        if summary and summary.heart_rate_variability is not None:
            hrv_values.append(summary.heart_rate_variability)
        if summary and summary.resting_heart_rate is not None:
            rhr_values.append(summary.resting_heart_rate)
    hrv_baseline = _baseline_for_metric(session, user_id, day, "heart_rate_variability")
    rhr_baseline = _baseline_for_metric(session, user_id, day, "resting_heart_rate")
    if hrv_values and hrv_baseline and hrv_baseline.lower_bound is not None:
        if mean(hrv_values) < hrv_baseline.lower_bound:
            penalty += 8
    if rhr_values and rhr_baseline and rhr_baseline.upper_bound is not None:
        if mean(rhr_values) > rhr_baseline.upper_bound:
            penalty += 8
    return penalty


def _adaptive_load_window(valid_days: int) -> dict[str, int | None]:
    if valid_days <= 6:
        return {"acute_days": None, "chronic_days": valid_days}
    if valid_days <= 13:
        return {"acute_days": 3, "chronic_days": valid_days - 3}
    if valid_days <= 27:
        return {"acute_days": 7, "chronic_days": valid_days - 7}
    return {"acute_days": 7, "chronic_days": 28}


def _chronic_load(loads: list[tuple[date, float]]) -> float | None:
    if not loads:
        return None
    values = [value for _, value in loads[-28:]]
    return mean(values) if values else None


def _detect_timezone_shift_context(
    session: Session,
    *,
    user_id: str,
    profile: UserProfile,
    day: date,
) -> None:
    current_sleep = _main_sleep(session, user_id, day)
    previous_sleep = _main_sleep(session, user_id, day - timedelta(days=1))
    if not current_sleep or not previous_sleep:
        return
    if not current_sleep.end_time.tzinfo or not previous_sleep.end_time.tzinfo:
        return
    current_offset = current_sleep.end_time.utcoffset()
    previous_offset = previous_sleep.end_time.utcoffset()
    if current_offset is None or previous_offset is None:
        return
    shift_hours = abs((current_offset - previous_offset).total_seconds()) / 3600
    if shift_hours < 2:
        return
    existing = session.scalar(
        select(DailyContext).where(
            DailyContext.user_id == user_id,
            DailyContext.context_date == day,
            DailyContext.context_type == "travel_timezone_shift",
            DailyContext.source == "automatic",
        )
    )
    if existing:
        return
    session.add(
        DailyContext(
            user_id=user_id,
            context_date=day,
            context_type="travel_timezone_shift",
            source="automatic",
            severity="moderate",
            value={
                "shift_hours": shift_hours,
                "profile_timezone": profile.timezone,
            },
        )
    )


def _baseline_context_exclusion(session: Session, user_id: str, day: date) -> str | None:
    contexts = session.scalars(
        select(DailyContext).where(
            DailyContext.user_id == user_id,
            DailyContext.context_date == day,
        )
    ).all()
    excluded_types = {
        "illness",
        "travel",
        "travel_timezone_shift",
        "sensor_anomaly",
    }
    for context in contexts:
        if context.context_type in excluded_types:
            return context.context_type
    return None


def _has_context(session: Session, user_id: str, day: date, context_type: str) -> bool:
    return (
        session.scalar(
            select(DailyContext).where(
                DailyContext.user_id == user_id,
                DailyContext.context_date == day,
                DailyContext.context_type == context_type,
            )
        )
        is not None
    )


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
    if count < 14:
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


def _sleep_reasons(components: dict[str, Any]) -> list[dict[str, Any]]:
    reasons = []
    for key, component in components.items():
        if not isinstance(component, dict) or component.get("score") is None:
            continue
        if component["score"] < 70:
            reasons.append(
                _reason(f"sleep_{key}_low", "medium", f"Sleep {key} was below target.")
            )
        elif component["score"] >= 90:
            reasons.append(
                _reason(f"sleep_{key}_strong", "low", f"Sleep {key} supported recovery.", "positive")
            )
    return reasons[:3]


def _strain_reasons(total: float, components: dict[str, Any]) -> list[dict[str, Any]]:
    reasons = []
    cardio = components["cardio_load"]["load_points"]
    muscular = components["muscular_load"]["load_points"]
    if total == 0:
        reasons.append(_reason("no_strain_detected", "info", "No meaningful strain was detected."))
    elif cardio >= max(muscular, 1):
        reasons.append(
            _reason("cardio_load_primary", "low", "Most strain came from cardiovascular load.", "neutral")
        )
    if muscular > 0:
        reasons.append(
            _reason("muscular_load_estimated", "low", "Strength-like activity added muscular load.", "neutral")
        )
    return reasons[:3]


def _readiness_reasons(components: dict[str, Any], cap: float | None) -> list[dict[str, Any]]:
    reasons = []
    for key, component in components.items():
        if not isinstance(component, dict) or component.get("score") is None:
            continue
        if component["score"] < 70:
            reasons.append(_reason(f"readiness_{key}_low", "medium", f"{key} reduced readiness."))
        elif component["score"] >= 90:
            reasons.append(
                _reason(f"readiness_{key}_strong", "low", f"{key} supported readiness.", "positive")
            )
    if cap is not None:
        reasons.insert(
            0,
            _reason(
                "readiness_anomaly_cap",
                "high",
                "Multiple recovery signals were outside the normal range.",
            ),
        )
    return reasons[:4]


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


def _load_band_for_ratio(ratio: float | None) -> str:
    if ratio is None:
        return "unknown"
    if ratio < 0.7:
        return "below"
    if ratio <= 1.15:
        return "steady"
    if ratio <= 1.4:
        return "above"
    return "well_above"
