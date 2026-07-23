from __future__ import annotations


from datetime import date, datetime, timedelta
from math import exp, log
from statistics import mean, median
from typing import Any
from sqlalchemy import select
from sqlalchemy.orm import Session
from app.core.security import utcnow
from app.models import (
    DailyScore,
    DailySummary,
    ExerciseCatalogItem,
    MetricInterval,
    MetricSample,
    RawHealthRecord,
    ScoreStatus,
    StrainTarget,
    UserProfile,
    Workout,
    WorkoutExercise,
    WorkoutSet,
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
from app.services.metric_rollups import hourly_rollup_points_for_metric


STRAIN_V2_CONFIG = {
    "cardio_k": {"male": 1.92, "female": 1.67, "fallback": 1.795},
    "hrr_eligibility_start": 0.30,
    "hrr_full_credit": 0.40,
    "max_interpolation_seconds": 90,
    "local_dose_threshold": 5.0,
    "local_dose_scale": 10.0,
    "generic_active_fraction": {
        "upper": 0.35,
        "lower": 0.35,
        "full_body": 0.35,
        "calisthenics": 0.60,
        "circuit": 0.70,
    },
    "generic_points_per_active_minute": {
        "upper": 0.8,
        "lower": 1.0,
        "full_body": 1.1,
        "calisthenics": 0.8,
        "circuit": 0.9,
    },
}


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
    movement_hours = _movement_hours(session, user_id, day)
    cardio = _cardio_load_from_hr(
        samples,
        workouts,
        movement_hours=movement_hours,
        rhr=rhr,
        max_hr=max_hr,
        sex=profile.sex,
    )
    source_zone = _source_zone_load_from_intervals(
        session,
        user_id,
        day,
        workouts,
        cardio["covered_minute_starts"],
        sex=profile.sex,
    )
    if source_zone is None:
        source_zone = _source_zone_load(
            workouts,
            cardio["workout_coverage"],
            sex=profile.sex,
        )
    rpe_fallback = _cardio_rpe_fallback(
        workouts,
        cardio["workout_coverage"],
        source_zone,
    )
    cardio_total = round(
        cardio["load_points"]
        + (source_zone["load_points"] if source_zone else 0.0)
        + rpe_fallback["load_points"],
        2,
    )
    cardio["hrr_load_points"] = cardio["load_points"]
    cardio["zone_fallback_load_points"] = source_zone["load_points"] if source_zone else 0.0
    cardio["rpe_fallback_load_points"] = rpe_fallback["load_points"]
    cardio["load_points"] = cardio_total
    cardio["workout_load_points"] = round(
        cardio["workout_load_points"]
        + ((source_zone or {}).get("workout_load_points") or 0.0)
        + rpe_fallback["load_points"],
        2,
    )
    cardio["general_activity_load_points"] = round(
        cardio["general_activity_load_points"]
        + ((source_zone or {}).get("general_activity_load_points") or 0.0),
        2,
    )
    cardio.pop("covered_minute_starts")
    muscular = _muscular_load(
        session,
        user_id=user_id,
        profile=profile,
        day=day,
        workouts=workouts,
    )
    # combine the two independent physiological load channels
    total = cardio_total + muscular["load_points"]
    total = round(total, 2)

    components = {
        "cardio_load": cardio,
        "source_zone_load": source_zone,
        "muscular_load": muscular,
        "rpe_load": rpe_fallback,
        "total_load": total,
    }
    components["workout_contributions"] = _workout_contributions(components, workouts)
    confidence = _strain_confidence_phase(session, user_id, day)
    status = ScoreStatus.in_progress if day == today else ScoreStatus.scored
    has_load_evidence = cardio["covered_minutes"] > 0 or source_zone is not None or workouts
    if not has_load_evidence and day != today:
        status = ScoreStatus.missing_data
    reasons = _strain_reasons(total, components)
    return _set_score(
        score,
        value=None if status == ScoreStatus.missing_data else total,
        unit="load_points",
        status=status,
        confidence_phase=confidence,
        data_quality=_strain_data_quality(cardio, muscular),
        components=components,
        inputs={
            "max_hr": max_hr,
            "max_hr_source": max_hr_source,
            "resting_hr": rhr,
            "resting_hr_source": rhr_source,
            "hr_sample_count": len(samples),
            "workout_count": len(workouts),
            "movement_evidence_hours": len(movement_hours),
            "cardio_k": _cardio_k(profile.sex),
        },
        reasons=reasons,
    )


def _upsert_strain_target(session: Session, *, user_id: str, week_start: date) -> StrainTarget:
    target = _get_or_create_strain_target(session, user_id, week_start)
    week_end = week_start + timedelta(days=6)
    prior_loads = _strain_loads(
        session, user_id, week_start - timedelta(days=60), week_start - timedelta(days=1)
    )
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


# accumulate movement-gated hrr dose from usable minute coverage
def _cardio_load_from_hr(
    samples: list[MetricSample],
    workouts: list[Workout],
    *,
    movement_hours: set[datetime],
    rhr: float | None,
    max_hr: float | None,
    sex: str | None,
) -> dict[str, Any]:
    if len(samples) < 2 or rhr is None or max_hr is None or max_hr <= rhr + 20:
        return {
            "load_points": 0.0,
            "covered_minutes": 0.0,
            "long_gap_count": 0,
            "workout_coverage_ratio": 0.0,
            "confidence": "weak",
            "workouts": [],
            "workout_load_points": 0.0,
            "general_activity_load_points": 0.0,
            "workout_coverage": {},
            "covered_minute_starts": [],
        }
    sorted_samples = sorted(samples, key=lambda item: item.observed_at)
    load = 0.0
    workout_load = 0.0
    general_activity_load = 0.0
    workout_contributions: dict[str, float] = {}
    eligible_seconds = 0.0
    long_gap_count = 0
    workout_seconds = sum(
        max(0.0, (workout.end_time - workout.start_time).total_seconds()) for workout in workouts
    )
    workout_covered_seconds: dict[str, float] = {workout.id: 0.0 for workout in workouts}
    covered_minute_starts: set[datetime] = set()
    k = _cardio_k(sex)
    for current, nxt in zip(sorted_samples, sorted_samples[1:]):
        gap = (nxt.observed_at - current.observed_at).total_seconds()
        if gap <= 0:
            continue
        workout = _workout_for_timestamp(current.observed_at, workouts)
        if gap > STRAIN_V2_CONFIG["max_interpolation_seconds"]:
            long_gap_count += 1
            continue
        if gap > 75 and workout is None:
            continue
        seconds = min(gap, 60)
        if seconds < 30:
            continue
        hr = (
            mean((current.value, nxt.value))
            if gap > 60 and workout is not None
            else current.value
        )
        if hr < 35 or hr > 230:
            continue
        minute_start = current.observed_at.replace(second=0, microsecond=0)
        has_movement = workout is not None or minute_start.replace(minute=0) in movement_hours
        if not has_movement:
            continue
        # apply the modified banister dose after the movement gate
        intensity = _clamp((hr - rhr) / (max_hr - rhr), 0.0, 1.0)
        points_per_minute = _cardio_dose(intensity, k)
        minutes = seconds / 60
        contribution = points_per_minute * minutes
        load += contribution
        eligible_seconds += seconds
        covered_minute_starts.add(minute_start)
        if workout is not None:
            workout_load += contribution
            workout_contributions[workout.id] = (
                workout_contributions.get(workout.id, 0.0) + contribution
            )
            workout_covered_seconds[workout.id] += seconds
        else:
            general_activity_load += contribution
    covered_minutes = eligible_seconds / 60
    total_workout_covered = sum(workout_covered_seconds.values())
    workout_coverage = {
        workout.id: round(
            min(
                1.0,
                workout_covered_seconds[workout.id]
                / max(1.0, (workout.end_time - workout.start_time).total_seconds()),
            ),
            3,
        )
        for workout in workouts
    }
    workout_ratio = (
        0.0 if workout_seconds <= 0 else min(1.0, total_workout_covered / workout_seconds)
    )
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
        "workout_coverage": workout_coverage,
        "covered_minute_starts": sorted(covered_minute_starts),
    }


def _cardio_k(sex: str | None) -> float:
    return STRAIN_V2_CONFIG["cardio_k"].get(
        (sex or "").lower(),
        STRAIN_V2_CONFIG["cardio_k"]["fallback"],
    )


def _cardio_dose(hrr: float, k: float) -> float:
    # apply the eligibility ramp to the exponential hrr dose
    if hrr < STRAIN_V2_CONFIG["hrr_eligibility_start"]:
        return 0.0
    if hrr < STRAIN_V2_CONFIG["hrr_full_credit"]:
        eligibility = (hrr - STRAIN_V2_CONFIG["hrr_eligibility_start"]) / (
            STRAIN_V2_CONFIG["hrr_full_credit"] - STRAIN_V2_CONFIG["hrr_eligibility_start"]
        )
    else:
        eligibility = 1.0
    return 0.64 * hrr * exp(k * hrr) * eligibility


def _movement_hours(session: Session, user_id: str, day: date) -> set[datetime]:
    points = []
    for metric in ("steps", "distance"):
        points.extend(
            hourly_rollup_points_for_metric(
                session,
                user_id=user_id,
                metric=metric,
                start=day,
                end=day,
            )
        )
    return {
        point.observed_at.replace(minute=0, second=0, microsecond=0)
        for point in points
        if point.value > 0
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


def _muscular_load(
    session: Session,
    *,
    user_id: str,
    profile: UserProfile,
    day: date,
    workouts: list[Workout],
) -> dict[str, Any]:
    total = 0.0
    contributing: list[dict[str, Any]] = []
    for workout in workouts:
        exercises = session.scalars(
            select(WorkoutExercise)
            .where(WorkoutExercise.workout_id == workout.id)
            .order_by(WorkoutExercise.order_index)
        ).all()
        detailed = _detailed_muscular_load(
            session,
            profile=profile,
            workout=workout,
            exercises=exercises,
        )
        if detailed is not None:
            contribution = detailed
        elif _is_strength_workout(workout):
            contribution = _generic_muscular_load(
                session,
                user_id=user_id,
                day=day,
                workout=workout,
            )
        else:
            continue
        total += contribution["load_points"]
        contributing.append(contribution)
    confidence = "weak"
    if contributing and all(item["source"] == "detailed_sets" for item in contributing):
        confidence = (
            "strong" if all(item["e1rm_coverage"] >= 0.7 for item in contributing) else "moderate"
        )
    elif any(item["source"] == "detailed_sets" for item in contributing):
        confidence = "moderate"
    return {
        "load_points": round(total, 2),
        "confidence": confidence,
        "workouts": contributing,
    }


# route completed sets through e1rm, muscle allocation, and local compression
def _detailed_muscular_load(
    session: Session,
    *,
    profile: UserProfile,
    workout: Workout,
    exercises: list[WorkoutExercise],
) -> dict[str, Any] | None:
    local_doses: dict[str, float] = {}
    completed_sets = 0
    baseline_sets = 0
    working_sets = 0
    rir_sets = 0
    exercise_details: list[dict[str, Any]] = []
    for exercise in exercises:
        if exercise.measurement_schema == "cardio":
            continue
        sets = session.scalars(
            select(WorkoutSet)
            .where(
                WorkoutSet.workout_exercise_id == exercise.id,
                WorkoutSet.status == "completed",
            )
            .order_by(WorkoutSet.order_index)
        ).all()
        if not sets:
            continue
        e1rm, e1rm_source = _exercise_e1rm(session, workout, exercise, sets, profile)
        involvement = _exercise_involvement(session, exercise)
        exercise_dose = 0.0
        for item in sets:
            dose = _set_dose(item, exercise, profile, e1rm, involvement)
            if dose is None:
                continue
            completed_sets += 1
            if e1rm is not None:
                baseline_sets += 1
            if item.set_type != "warmup":
                working_sets += 1
                if item.rir is not None:
                    rir_sets += 1
            exercise_dose += dose
            for muscle, share in _muscle_shares(exercise).items():
                local_doses[muscle] = local_doses.get(muscle, 0.0) + dose * share
        if exercise_dose > 0:
            exercise_details.append(
                {
                    "exercise_id": exercise.exercise_id,
                    "name": exercise.name_snapshot,
                    "raw_set_dose": round(exercise_dose, 2),
                    "e1rm_kg": round(e1rm, 2) if e1rm is not None else None,
                    "e1rm_source": e1rm_source,
                    "involvement": involvement,
                }
            )
    if completed_sets == 0:
        return None
    local_points = {muscle: _local_muscular_points(dose) for muscle, dose in local_doses.items()}
    load = sum(local_points.values())
    rir_coverage = rir_sets / working_sets if working_sets else 0.0
    effort_modifier = 1.0
    if rir_coverage < 0.70 and workout.session_rpe is not None:
        effort_modifier = _session_effort_modifier(workout.session_rpe)
        load *= effort_modifier
    category = _muscular_category(workout, exercises)
    active_minutes = _detailed_active_minutes(session, exercises)
    return {
        "workout_id": workout.id,
        "workout_type": workout.workout_type,
        "load_points": round(load, 2),
        "source": "detailed_sets",
        "category": category,
        "active_minutes": round(active_minutes, 1),
        "completed_sets": completed_sets,
        "rir_coverage": round(rir_coverage, 3),
        "e1rm_coverage": round(baseline_sets / completed_sets, 3),
        "session_effort_modifier": round(effort_modifier, 3),
        "local_muscle_points": {
            muscle: round(points * effort_modifier, 2) for muscle, points in local_points.items()
        },
        "exercises": exercise_details,
    }


def _set_dose(
    item: WorkoutSet,
    exercise: WorkoutExercise,
    profile: UserProfile,
    e1rm: float | None,
    involvement: float,
) -> float | None:
    difficulty = _set_difficulty(item.rir)
    status_factor = 0.25 if item.set_type == "warmup" else 1.0
    if exercise.measurement_schema in {"duration", "duration_load"}:
        if not item.duration_seconds:
            return None
        relative_intensity = _relative_load(_effective_load_kg(item, exercise, profile), e1rm)
        if relative_intensity is None:
            relative_intensity = 1.0
        return (
            (item.duration_seconds / 30)
            * relative_intensity
            * involvement
            * difficulty
            * status_factor
        )
    if exercise.measurement_schema == "carry":
        if not item.distance_meters:
            return None
        carried = _effective_load_kg(item, exercise, profile)
        if carried is None or carried <= 0:
            return None
        relative_intensity = _relative_load(carried, e1rm) or 1.0
        return (
            (item.distance_meters / 30)
            * relative_intensity
            * involvement
            * difficulty
            * status_factor
        )
    if item.reps is None or item.reps <= 0:
        return None
    relative_load = _relative_load(_effective_load_kg(item, exercise, profile), e1rm)
    if relative_load is None:
        return None
    return item.reps * relative_load * involvement * difficulty * status_factor


# select and slowly decay the strongest credible recent exercise baseline
def _exercise_e1rm(
    session: Session,
    workout: Workout,
    exercise: WorkoutExercise,
    current_sets: list[WorkoutSet],
    profile: UserProfile,
) -> tuple[float | None, str]:
    start = workout.start_time - timedelta(days=90)
    identity = (
        WorkoutExercise.exercise_id == exercise.exercise_id
        if exercise.exercise_id is not None
        else WorkoutExercise.name_snapshot == exercise.name_snapshot
    )
    historical = session.execute(
        select(WorkoutSet, Workout)
        .join(WorkoutExercise, WorkoutSet.workout_exercise_id == WorkoutExercise.id)
        .join(Workout, WorkoutExercise.workout_id == Workout.id)
        .where(
            Workout.user_id == workout.user_id,
            Workout.start_time >= start,
            Workout.start_time < workout.start_time,
            WorkoutSet.status == "completed",
            identity,
        )
        .order_by(Workout.start_time.desc())
    ).all()
    estimates = [
        (estimate, prior_workout.start_time)
        for item, prior_workout in historical
        if (estimate := _set_e1rm(item, exercise, profile)) is not None
    ]
    if estimates:
        best, observed_at = max(estimates, key=lambda value: (value[0], value[1]))
        inactive_days = (workout.start_time - observed_at).days
        if inactive_days > 42:
            decay_weeks = (inactive_days - 42) / 7
            best *= max(0.90, 1 - 0.005 * decay_weeks)
        return best, "prior_90_day_best"
    provisional = [
        estimate
        for item in current_sets
        if (estimate := _set_e1rm(item, exercise, profile)) is not None
    ]
    return (max(provisional), "current_session_provisional") if provisional else (None, "missing")


def _set_e1rm(
    item: WorkoutSet,
    exercise: WorkoutExercise,
    profile: UserProfile,
) -> float | None:
    if item.reps is None or item.reps < 1 or item.reps > 10:
        return None
    load = _effective_load_kg(item, exercise, profile)
    if load is None or load <= 0:
        return None
    rir = item.rir if item.rir is not None and 0 <= item.rir <= 3 else 0
    return load * (1 + (item.reps + rir) / 30)


def _effective_load_kg(
    item: WorkoutSet,
    exercise: WorkoutExercise,
    profile: UserProfile,
) -> float | None:
    if item.load_per_implement is not None and item.implement_count:
        load = item.load_per_implement * item.implement_count
    elif item.load_value is not None:
        load = item.load_value
    elif exercise.measurement_schema in {"bodyweight_reps", "assisted_reps"}:
        load = profile.weight_kg
    else:
        load = None
    if load is None:
        return None
    if item.load_unit == "lb":
        load *= 0.45359237
    load += item.added_load_kg or 0.0
    load -= item.assistance_kg or 0.0
    return max(0.0, load)


def _relative_load(load: float | None, e1rm: float | None) -> float | None:
    if load is None or e1rm is None or e1rm <= 0:
        return None
    return _clamp(load / e1rm, 0.0, 1.5)


def _exercise_involvement(session: Session, exercise: WorkoutExercise) -> float:
    catalog = (
        session.get(ExerciseCatalogItem, exercise.exercise_id) if exercise.exercise_id else None
    )
    primary = {str(muscle).lower() for muscle in exercise.primary_muscles or []}
    lower = {"quadriceps", "hamstrings", "glutes", "calves", "adductors"}
    if catalog and catalog.mechanic == "compound":
        return 1.2 if primary & lower else 1.0
    if len(primary) > 1:
        return 1.2 if primary & lower else 1.0
    return 0.8 if primary & lower else 0.6


def _set_difficulty(rir: float | None) -> float:
    if rir is None or rir <= 3:
        return 1.0
    if rir <= 5:
        return 0.85
    if rir <= 7:
        return 0.70
    return 0.55


def _muscle_shares(exercise: WorkoutExercise) -> dict[str, float]:
    primary = list(dict.fromkeys(exercise.primary_muscles or []))
    secondary = list(dict.fromkeys(exercise.secondary_muscles or []))
    if not primary and not secondary:
        return {exercise.name_snapshot: 1.0}
    if not secondary:
        return {muscle: 1 / len(primary) for muscle in primary}
    if not primary:
        return {muscle: 1 / len(secondary) for muscle in secondary}
    return {
        **{muscle: 0.70 / len(primary) for muscle in primary},
        **{muscle: 0.30 / len(secondary) for muscle in secondary},
    }


def _local_muscular_points(dose: float) -> float:
    threshold = STRAIN_V2_CONFIG["local_dose_threshold"]
    scale = STRAIN_V2_CONFIG["local_dose_scale"]
    if dose <= threshold:
        return dose
    return threshold + scale * log(1 + (dose - threshold) / scale)


def _session_effort_modifier(rpe: float) -> float:
    return _clamp(0.80 + 0.04 * rpe, 0.80, 1.20)


def _generic_muscular_load(
    session: Session,
    *,
    user_id: str,
    day: date,
    workout: Workout,
) -> dict[str, Any]:
    category = _generic_strength_category(workout)
    rate, source = _personal_category_rate(session, user_id, day, category)
    active_minutes = (
        (workout.duration_seconds or 0) / 60 * STRAIN_V2_CONFIG["generic_active_fraction"][category]
    )
    modifier = _session_effort_modifier(workout.session_rpe or 5.0)
    load = rate * active_minutes * modifier
    return {
        "workout_id": workout.id,
        "workout_type": workout.workout_type,
        "load_points": round(load, 2),
        "source": source,
        "category": category,
        "active_minutes": round(active_minutes, 1),
        "points_per_active_minute": round(rate, 3),
        "session_effort_modifier": round(modifier, 3),
        "e1rm_coverage": 0.0,
    }


def _personal_category_rate(
    session: Session,
    user_id: str,
    day: date,
    category: str,
) -> tuple[float, str]:
    scores = session.scalars(
        select(DailyScore)
        .where(
            DailyScore.user_id == user_id,
            DailyScore.score_type == "strain",
            DailyScore.algorithm_version == "strain_load_v2",
            DailyScore.score_date >= day - timedelta(days=90),
            DailyScore.score_date < day,
        )
        .order_by(DailyScore.score_date.desc())
    ).all()
    rates = []
    for score in scores:
        workouts = ((score.components or {}).get("muscular_load") or {}).get("workouts") or []
        for item in workouts:
            if item.get("source") != "detailed_sets" or item.get("category") != category:
                continue
            if item.get("active_minutes"):
                rates.append(float(item["load_points"]) / float(item["active_minutes"]))
            if len(rates) >= 8:
                break
        if len(rates) >= 8:
            break
    if len(rates) >= 3:
        return median(rates), "personal_category_history"
    return STRAIN_V2_CONFIG["generic_points_per_active_minute"][category], "generic_category_prior"


def _detailed_active_minutes(session: Session, exercises: list[WorkoutExercise]) -> float:
    seconds = 0.0
    completed_count = 0
    for exercise in exercises:
        sets = session.scalars(
            select(WorkoutSet).where(
                WorkoutSet.workout_exercise_id == exercise.id,
                WorkoutSet.status == "completed",
            )
        ).all()
        for item in sets:
            completed_count += 1
            seconds += item.duration_seconds or 30
    return seconds / 60 if seconds else completed_count * 0.5


def _muscular_category(workout: Workout, exercises: list[WorkoutExercise]) -> str:
    workout_type = (workout.workout_type or "").lower()
    if "circuit" in workout_type or "crossfit" in workout_type:
        return "circuit"
    if any(exercise.measurement_schema == "bodyweight_reps" for exercise in exercises):
        return "calisthenics"
    muscles = {
        str(muscle).lower() for exercise in exercises for muscle in (exercise.primary_muscles or [])
    }
    lower = {"quadriceps", "hamstrings", "glutes", "calves", "adductors"}
    if muscles and muscles <= lower:
        return "lower"
    if muscles & lower:
        return "full_body"
    return "upper"


def _generic_strength_category(workout: Workout) -> str:
    value = " ".join(filter(None, (workout.workout_type, workout.title))).lower()
    if any(term in value for term in ("circuit", "crossfit", "hiit")):
        return "circuit"
    if any(term in value for term in ("calisthen", "bodyweight")):
        return "calisthenics"
    if "lower" in value or "leg" in value:
        return "lower"
    if "upper" in value:
        return "upper"
    return "full_body"


def _is_strength_workout(workout: Workout) -> bool:
    value = " ".join(filter(None, (workout.workout_type, workout.title))).lower()
    return any(
        term in value
        for term in (
            "strength",
            "weight",
            "resistance",
            "free_weight",
            "crossfit",
            "hiit",
            "circuit",
        )
    )


def _source_zone_load(
    workouts: list[Workout],
    workout_coverage: dict[str, float],
    *,
    sex: str | None,
) -> dict[str, Any] | None:
    total = 0.0
    zones_seen = 0
    hrr_midpoints = [0.35, 0.50, 0.725, 0.925, 0.925]
    k = _cardio_k(sex)
    contributing: list[dict[str, Any]] = []
    for workout in workouts:
        workout_total = 0.0
        uncovered_ratio = max(0.0, 1 - workout_coverage.get(workout.id, 0.0))
        if uncovered_ratio <= 0:
            continue
        zones = _extract_zone_summaries(workout.raw_summary)
        for index, zone in enumerate(zones):
            minutes = _zone_minutes(zone)
            if minutes is None:
                continue
            midpoint = hrr_midpoints[min(index, len(hrr_midpoints) - 1)]
            # use provider zones only for the portion not covered by hrr samples
            contribution = minutes * _cardio_dose(midpoint, k) * uncovered_ratio
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
        "covered_workout_ids": [item["workout_id"] for item in contributing],
        "workouts": contributing,
    }


# fill only hrr minutes not already covered by direct samples
def _source_zone_load_from_intervals(
    session: Session,
    user_id: str,
    day: date,
    workouts: list[Workout],
    covered_minute_starts: list[datetime],
    *,
    sex: str | None,
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
    hrr_midpoints = {
        "LIGHT": 0.35,
        "MODERATE": 0.50,
        "VIGOROUS": 0.725,
        "PEAK": 0.925,
    }
    k = _cardio_k(sex)
    covered = set(covered_minute_starts)
    total = 0.0
    workout_total = 0.0
    general_activity_total = 0.0
    workout_contributions: dict[str, float] = {}
    zones_seen = 0
    for interval, raw_record in rows:
        payload = raw_record.raw_json.get("timeInHeartRateZone") or {}
        zone_type = payload.get("heartRateZoneType")
        midpoint = hrr_midpoints.get(str(zone_type))
        if midpoint is None:
            continue
        interval_minutes = interval.value / 60
        uncovered_minutes = _uncovered_interval_minutes(
            interval.start_time,
            interval.end_time,
            covered,
        )
        uncovered_ratio = (
            0.0 if interval_minutes <= 0 else min(1.0, uncovered_minutes / interval_minutes)
        )
        interval_load = interval_minutes * _cardio_dose(midpoint, k) * uncovered_ratio
        if interval_load <= 0:
            continue
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
            workout_contributions[workout.id] = (
                workout_contributions.get(workout.id, 0.0) + contribution
            )
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


def _uncovered_interval_minutes(
    start: datetime,
    end: datetime,
    covered_minute_starts: set[datetime],
) -> float:
    cursor = start.replace(second=0, microsecond=0)
    uncovered_seconds = 0.0
    while cursor < end:
        minute_end = cursor + timedelta(minutes=1)
        overlap = max(0.0, (min(end, minute_end) - max(start, cursor)).total_seconds())
        if cursor not in covered_minute_starts:
            uncovered_seconds += overlap
        cursor = minute_end
    return uncovered_seconds / 60


def _cardio_rpe_fallback(
    workouts: list[Workout],
    workout_coverage: dict[str, float],
    source_zone: dict[str, Any] | None,
) -> dict[str, Any]:
    zone_workout_ids = {
        str(item.get("workout_id"))
        for item in ((source_zone or {}).get("workouts") or [])
        if item.get("workout_id")
    }
    total = 0.0
    contributing = []
    for workout in workouts:
        if workout.session_rpe is None or str(workout.id) in zone_workout_ids:
            continue
        if not _supports_cardio_rpe_fallback(workout):
            continue
        uncovered_ratio = max(0.0, 1 - workout_coverage.get(workout.id, 0.0))
        active_minutes = (workout.duration_seconds or 0) / 60 * uncovered_ratio
        contribution = active_minutes * workout.session_rpe / 10
        if contribution <= 0:
            continue
        total += contribution
        contributing.append(
            {
                "workout_id": workout.id,
                "workout_type": workout.workout_type,
                "active_minutes": round(active_minutes, 1),
                "session_rpe": workout.session_rpe,
                "load_points": round(contribution, 2),
            }
        )
    return {
        "load_points": round(total, 2),
        "source": "session_rpe_uncovered_cardio",
        "workouts": contributing,
    }


def _supports_cardio_rpe_fallback(workout: Workout) -> bool:
    value = " ".join(filter(None, (workout.workout_type, workout.title))).lower()
    if _is_strength_workout(workout) and not any(
        term in value for term in ("circuit", "crossfit", "hiit")
    ):
        return False
    return any(
        term in value
        for term in (
            "run",
            "walk",
            "cycle",
            "bike",
            "row",
            "swim",
            "sport",
            "cardio",
            "circuit",
            "crossfit",
            "hiit",
        )
    )


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
        ("rpe_load", "rpe"),
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
        sample.value
        for sample in samples
        if _timestamp_inside_workout(sample.observed_at, workouts)
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
    values = [value for _, value in loads]
    rolling_mean = mean(values[-28:])
    alpha = 2 / 29
    ewma = values[0]
    for value in values[1:]:
        ewma = alpha * value + (1 - alpha) * ewma
    # retain the higher reference so a short break does not collapse the target
    return max(rolling_mean, ewma)


def _strain_data_quality(cardio: dict[str, Any], muscular: dict[str, Any]) -> str:
    cardio_quality = cardio["confidence"]
    muscular_quality = muscular["confidence"]
    if muscular["load_points"] <= 0:
        return cardio_quality
    if cardio["load_points"] <= 0:
        return muscular_quality
    rank = {"weak": 0, "moderate": 1, "strong": 2}
    return min((cardio_quality, muscular_quality), key=lambda value: rank[value])


def _strain_reasons(total: float, components: dict[str, Any]) -> list[dict[str, Any]]:
    reasons = []
    cardio = components["cardio_load"]["load_points"]
    muscular = components["muscular_load"]["load_points"]
    if total == 0:
        reasons.append(_reason("no_strain_detected", "info", "No meaningful strain was detected."))
    elif cardio >= max(muscular, 1):
        reasons.append(
            _reason(
                "cardio_load_primary",
                "low",
                "Most strain came from cardiovascular load.",
                "neutral",
            )
        )
    if muscular > 0:
        reasons.append(
            _reason(
                "muscular_load_estimated",
                "low",
                "Strength-like activity added muscular load.",
                "neutral",
            )
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
