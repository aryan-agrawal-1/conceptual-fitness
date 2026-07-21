from __future__ import annotations


from datetime import date, datetime, timedelta
from statistics import mean
from typing import Any
from sqlalchemy import select
from sqlalchemy.orm import Session
from app.core.security import utcnow
from app.models import (
    DailyScore,
    DailySummary,
    MetricInterval,
    MetricSample,
    RawHealthRecord,
    ScoreStatus,
    StrainTarget,
    UserProfile,
    Workout,
)
from app.services.health_dates import (
    estimated_max_heart_rate,
    local_date_for_profile,
)
from app.services.score_helpers import (
    STRAIN_LOAD_VERSION,
    _baseline_value,
    _clamp,
    _extract_zone_summaries,
    _get_or_create_score,
    _get_or_create_strain_target,
    _heart_rate_samples,
    _mark_score_waiting,
    _phase_for_count,
    _reason,
    _set_score,
    _strain_loads,
    _summary_for_day,
    _workouts_for_day,
    _zone_minutes,
)


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
    # sum independent cardio, zone, activity, and muscular load sources
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


def _upsert_strain_target(session: Session, *, user_id: str, week_start: date) -> StrainTarget:
    target = _get_or_create_strain_target(session, user_id, week_start)
    week_end = week_start + timedelta(days=6)
    prior_loads = _strain_loads(session, user_id, week_start - timedelta(days=60), week_start - timedelta(days=1))
    current_loads = _strain_loads(session, user_id, week_start, week_end)
    chronic = _chronic_load(prior_loads)
    progress = sum(value for _, value in current_loads)
    phase = _phase_for_count(len(prior_loads))
    target_points = None if chronic is None else round(chronic * 7, 2)
    # compare current weekly load with seven days of chronic load
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
    target.inputs = {
        "week_start_date": week_start.isoformat(),
        "week_end_date": week_end.isoformat(),
    }
    target.computed_at = utcnow()
    session.add(target)
    return target


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
        # normalize heart rate reserve and apply the nonlinear load curve
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
    # use the stronger movement proxy without double-counting both
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
        # convert strength duration into capped muscular load
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
            # weight each zone minute by its intensity band
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
            # allocate interval load in proportion to workout overlap
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


def _strain_confidence_phase(session: Session, user_id: str, day: date) -> str:
    prior_loads = _strain_loads(session, user_id, day - timedelta(days=60), day - timedelta(days=1))
    return _phase_for_count(len(prior_loads))


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
