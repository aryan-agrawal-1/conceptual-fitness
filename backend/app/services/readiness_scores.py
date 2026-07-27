from __future__ import annotations


from datetime import date, timedelta
from math import log
from statistics import median
from typing import Any
from sqlalchemy import func, select
from sqlalchemy.orm import Session
from app.models import (
    DailyContext,
    DailyScore,
    MetricSample,
    ScoreStatus,
    SleepSession,
    UserProfile,
)
from app.services.score_helpers import (
    READINESS_SCORE_VERSION,
    STRAIN_LOAD_VERSION,
    _baseline_for_metric,
    _baseline_value,
    _clamp,
    _core_sleep_need_minutes,
    _date_range,
    _get_or_create_score,
    _interpolate_anchors,
    _main_sleep,
    _mark_score_waiting,
    _reason,
    _residual_load_exposure,
    _robust_spread,
    _score_for_day,
    _set_score,
    _summary_for_day,
)
from app.services.sleep_scores import (
    _continuity_score,
    _duration_score,
    _valid_main_sleep,
    _valid_sleep_achieved_minutes,
)


READINESS_V3_CONFIG = {
    "base_weights": {
        "sleep_adequacy_debt": 0.55,
        "autonomic_recovery": 0.45,
    },
    "sleep_weights": {"duration": 0.60, "continuity": 0.25, "burden": 0.15},
    "autonomic_weights": {"hrv": 0.60, "rhr": 0.40},
    "current_autonomic_weight": 0.70,
    "recent_autonomic_weight": 0.30,
    "affected_load_weight": 0.70,
    "better_load_weight": 0.30,
    "load_penalty_weight": 0.40,
    "load_neutral_score": 90.0,
    "duration_ceiling_buffer": 15.0,
}

AUTONOMIC_SCORE_ANCHORS = [
    (-4.0, 0.0),
    (-3.0, 10.0),
    (-2.0, 35.0),
    (-1.5, 50.0),
    (-1.0, 65.0),
    (-0.5, 75.0),
    (0.0, 82.0),
    (0.5, 90.0),
    (1.0, 96.0),
    (1.5, 100.0),
]

LOAD_SCORE_ANCHORS = [
    (0.0, 90.0),
    (0.25, 90.0),
    (0.5, 85.0),
    (1.0, 75.0),
    (2.0, 55.0),
    (3.0, 30.0),
    (4.0, 10.0),
]

BURDEN_SCORE_ANCHORS = [
    (0.0, 95.0),
    (0.25, 90.0),
    (0.5, 82.0),
    (1.0, 68.0),
    (2.0, 42.0),
    (3.0, 20.0),
    (4.0, 0.0),
]


def _upsert_readiness_score(
    session: Session,
    *,
    user_id: str,
    profile: UserProfile,
    day: date,
) -> DailyScore:
    score = _get_or_create_score(session, user_id, day, "readiness", READINESS_SCORE_VERSION)
    sleep = _main_sleep(session, user_id, day)
    if sleep is None or not _valid_main_sleep(sleep):
        return _mark_score_waiting(
            score,
            unit="score_0_100",
            status=ScoreStatus.waiting_for_sleep,
            reason_code="waiting_for_main_sleep",
            message="Readiness is waiting for the sleep session that ended on this day.",
        )

    sleep_component = _readiness_sleep_component(session, user_id, profile, day, sleep)
    autonomic = _autonomic_component(session, user_id, day)
    load_recovery = _load_recovery_component(session, user_id, day)
    anomaly = _anomaly_component(session, user_id, day, autonomic)
    components = {
        "sleep_adequacy_debt": sleep_component,
        "autonomic_recovery": autonomic,
        "recent_load_fit": load_recovery,
        "illness_anomaly_context": anomaly,
    }
    missing_blocks = [
        key
        for key in ("sleep_adequacy_debt", "autonomic_recovery", "recent_load_fit")
        if not isinstance(components.get(key), dict) or components[key].get("score") is None
    ]
    confidence = _readiness_confidence(components, score_available=not missing_blocks)
    components["confidence"] = confidence
    if missing_blocks:
        return _set_score(
            score,
            value=None,
            unit="score_0_100",
            status=ScoreStatus.missing_data,
            confidence_phase=confidence["phase"],
            data_quality=confidence["data_quality"],
            components=components,
            inputs={
                "main_sleep_id": sleep.id,
                "uses_same_day_strain": False,
                "required_blocks_missing": missing_blocks,
                "algorithm_config": READINESS_V3_CONFIG,
            },
            reasons=[
                _reason(
                    "readiness_calibrating",
                    "info",
                    "Readiness needs sleep, an autonomic reference, and three days of reliable load history.",
                    "neutral",
                )
            ],
        )

    base_readiness = sum(
        float(components[key]["score"]) * weight
        for key, weight in READINESS_V3_CONFIG["base_weights"].items()
    )
    load_penalty = READINESS_V3_CONFIG["load_penalty_weight"] * max(
        0.0,
        READINESS_V3_CONFIG["load_neutral_score"] - float(load_recovery["score"]),
    )
    value = _clamp(base_readiness - load_penalty - float(anomaly["penalty"]), 0, 100)
    cap_rules = [*sleep_component["readiness_caps"]]
    duration_ceiling = float(sleep_component["duration_ceiling"])
    if value > duration_ceiling:
        cap_rules.append({"reason": "sleep_duration_ceiling", "value": duration_ceiling})
    if anomaly.get("readiness_cap") is not None:
        cap_rules.append(
            {
                "reason": anomaly.get("cap_reason") or "illness_anomaly",
                "value": float(anomaly["readiness_cap"]),
            }
        )
    caps = [cap for cap in cap_rules if value > float(cap["value"])]
    if cap_rules:
        value = min(value, *(float(cap["value"]) for cap in cap_rules))
    value = round(value)
    return _set_score(
        score,
        value=value,
        unit="score_0_100",
        status=ScoreStatus.scored,
        confidence_phase=confidence["phase"],
        data_quality=confidence["data_quality"],
        components=components,
        inputs={
            "main_sleep_id": sleep.id,
            "uses_same_day_strain": False,
            "base_readiness": round(base_readiness, 2),
            "load_penalty": round(load_penalty, 2),
            "anomaly_penalty": anomaly["penalty"],
            "caps_applied": caps,
            "algorithm_config": READINESS_V3_CONFIG,
        },
        reasons=_readiness_reasons(components, caps),
    )


# combine acute sleep loss, fragmentation, and carried sleep burden
def _readiness_sleep_component(
    session: Session,
    user_id: str,
    profile: UserProfile,
    day: date,
    sleep: SleepSession,
) -> dict[str, Any]:
    core_need = _core_sleep_need_minutes(profile, day)
    achieved = _valid_sleep_achieved_minutes(session, user_id, day, sleep)
    duration = _duration_score(achieved, core_need)
    continuity = _continuity_score(sleep)
    burden = _sleep_burden_state(session, user_id, profile, day)
    burden_score = _interpolate_anchors(
        burden["burden_before_latest_shortfall_minutes"] / core_need,
        BURDEN_SCORE_ANCHORS,
    )
    score = None
    if burden["precise"]:
        numerator = (
            READINESS_V3_CONFIG["sleep_weights"]["duration"] * float(duration["score"])
            + READINESS_V3_CONFIG["sleep_weights"]["burden"] * burden_score
        )
        denominator = (
            READINESS_V3_CONFIG["sleep_weights"]["duration"]
            + READINESS_V3_CONFIG["sleep_weights"]["burden"]
        )
        if continuity is not None:
            numerator += (
                READINESS_V3_CONFIG["sleep_weights"]["continuity"] * float(continuity["score"])
            )
            denominator += READINESS_V3_CONFIG["sleep_weights"]["continuity"]
        score = round(numerator / denominator, 1)

    caps: list[dict[str, Any]] = []
    if continuity and continuity.get("severe_fragmentation"):
        caps.append({"reason": "severe_fragmentation", "value": 65.0})
    duration_ceiling = min(
        100.0,
        float(duration["score"]) + READINESS_V3_CONFIG["duration_ceiling_buffer"],
    )
    return {
        "score": score,
        "duration": duration,
        "continuity": continuity,
        "burden_score": round(burden_score, 1),
        "sleep_burden_minutes": round(burden["current_burden_minutes"], 1),
        "burden_before_latest_shortfall_minutes": round(
            burden["burden_before_latest_shortfall_minutes"],
            1,
        ),
        "burden_nights": round(
            burden["burden_before_latest_shortfall_minutes"] / core_need,
            3,
        ),
        "missing_sleep_nights_7d": burden["missing_nights_7d"],
        "duration_ceiling": round(duration_ceiling, 1),
        "readiness_caps": caps,
    }


# carry sleep burden forward with slow decay and partial recovery credit
def _sleep_burden_state(
    session: Session,
    user_id: str,
    profile: UserProfile,
    day: date,
) -> dict[str, Any]:
    first_sleep_day = session.scalar(
        select(func.min(SleepSession.civil_date)).where(
            SleepSession.user_id == user_id,
            SleepSession.civil_date.is_not(None),
            SleepSession.civil_date <= day,
        )
    )
    if first_sleep_day is None:
        return {
            "current_burden_minutes": 0.0,
            "burden_before_latest_shortfall_minutes": 0.0,
            "missing_nights_7d": 7,
            "precise": False,
        }

    burden = 0.0
    latest_shortfall = 0.0
    for current in _date_range(first_sleep_day, day):
        sleep = _main_sleep(session, user_id, current)
        if sleep is None or not _valid_main_sleep(sleep):
            continue
        need = _core_sleep_need_minutes(profile, current)
        achieved = _valid_sleep_achieved_minutes(session, user_id, current, sleep)
        latest_shortfall = max(0.0, need - achieved - 30)
        extra_sleep = min(120.0, max(0.0, achieved - need))
        burden = max(0.0, 0.90 * burden + latest_shortfall - 0.50 * extra_sleep)

    missing_nights = sum(
        (
            (sleep := _main_sleep(session, user_id, current)) is None
            or not _valid_main_sleep(sleep)
        )
        for current in _date_range(day - timedelta(days=6), day)
    )
    return {
        "current_burden_minutes": burden,
        "burden_before_latest_shortfall_minutes": max(0.0, burden - latest_shortfall),
        "missing_nights_7d": missing_nights,
        "precise": missing_nights < 2,
    }


# combine the current autonomic deviation with the previous three-night median
def _autonomic_component(session: Session, user_id: str, day: date) -> dict[str, Any] | None:
    hrv = _autonomic_metric_component(session, user_id, day, "heart_rate_variability")
    rhr = _autonomic_metric_component(session, user_id, day, "resting_heart_rate")
    if hrv is None and rhr is None:
        return None
    if hrv is not None and rhr is not None:
        score = (
            READINESS_V3_CONFIG["autonomic_weights"]["hrv"] * float(hrv["score"])
            + READINESS_V3_CONFIG["autonomic_weights"]["rhr"] * float(rhr["score"])
        )
    else:
        score = float((hrv or rhr or {})["score"])
    return {
        "score": round(score, 1),
        "hrv": hrv,
        "rhr": rhr,
        "available_metrics": sum(item is not None for item in (hrv, rhr)),
    }


def _autonomic_metric_component(
    session: Session,
    user_id: str,
    day: date,
    metric: str,
) -> dict[str, Any] | None:
    current = _metric_z_for_day(session, user_id, day, metric)
    if current is None:
        return None
    recent = []
    for current_day in _date_range(day - timedelta(days=4), day - timedelta(days=1)):
        item = _metric_z_for_day(session, user_id, current_day, metric)
        if item is not None:
            recent.append(item)
    recent = recent[-3:]
    recent_z = float(median(item["z"] for item in recent)) if recent else float(current["z"])
    combined_z = (
        READINESS_V3_CONFIG["current_autonomic_weight"] * float(current["z"])
        + READINESS_V3_CONFIG["recent_autonomic_weight"] * recent_z
    )
    favourable = combined_z if metric == "heart_rate_variability" else -combined_z
    score = _interpolate_anchors(favourable, AUTONOMIC_SCORE_ANCHORS)
    return {
        "score": round(score, 1),
        "value": current["value"],
        "baseline": current["baseline"],
        "spread": current["spread"],
        "current_z": round(float(current["z"]), 3),
        "recent_z": round(recent_z, 3),
        "favourable_deviation": round(favourable, 3),
        "adverse_deviation": round(max(0.0, -favourable), 3),
        "recent_valid_nights": len(recent),
        "reference_days": current["reference_days"],
        "measurement_type": current.get("measurement_type"),
    }


def _metric_z_for_day(
    session: Session,
    user_id: str,
    day: date,
    metric: str,
) -> dict[str, Any] | None:
    summary = _summary_for_day(session, user_id, day)
    value = getattr(summary, metric, None) if summary is not None else None
    baseline = _baseline_for_metric(session, user_id, day, metric)
    if (
        value is None
        or baseline is None
        or baseline.median_value is None
        or baseline.valid_day_count < 7
    ):
        return None
    metadata = baseline.metadata_json or {}
    if metric == "heart_rate_variability":
        if value <= 0 or baseline.median_value <= 0:
            return None
        spread = float(metadata.get("log_spread") or 0)
        if spread <= 0:
            return None
        z_value = (log(float(value)) - log(float(baseline.median_value))) / spread
    else:
        spread = float(baseline.spread_value or 0)
        if spread <= 0:
            return None
        z_value = (float(value) - float(baseline.median_value)) / spread
    return {
        "z": z_value,
        "value": float(value),
        "baseline": float(baseline.median_value),
        "spread": spread,
        "reference_days": baseline.valid_day_count,
        "measurement_type": metadata.get("hrv_measurement_type"),
    }


# score decayed cardio and muscular exposure against separate personal references
def _load_recovery_component(session: Session, user_id: str, day: date) -> dict[str, Any] | None:
    cardio = _load_channel_component(session, user_id, day, "cardio")
    muscular = _load_channel_component(session, user_id, day, "muscular")
    if cardio is None and muscular is None:
        return None
    channel_scores = [
        float(component["score"]) for component in (cardio, muscular) if component is not None
    ]
    if len(channel_scores) == 2:
        lower, higher = sorted(channel_scores)
        score = (
            READINESS_V3_CONFIG["affected_load_weight"] * lower
            + READINESS_V3_CONFIG["better_load_weight"] * higher
        )
    else:
        score = channel_scores[0]
    return {
        "score": round(score, 1),
        "cardio": cardio,
        "muscular": muscular,
        "available_channels": len(channel_scores),
        "valid_strain_days": max(
            (
                int(component["reference_days"])
                for component in (cardio, muscular)
                if component is not None
            ),
            default=0,
        ),
        "local_readiness_warnings": _local_muscle_warnings(session, user_id, day),
    }


def _load_channel_component(
    session: Session,
    user_id: str,
    day: date,
    channel: str,
) -> dict[str, Any] | None:
    exposure = _residual_load_exposure(session, user_id, day, channel)
    baseline = _baseline_for_metric(session, user_id, day, f"{channel}_residual_exposure")
    if (
        exposure is None
        or baseline is None
        or baseline.median_value is None
        or baseline.valid_day_count < 7
    ):
        return None
    spread = float(baseline.spread_value or 0)
    if spread <= 0:
        if exposure[0] > float(baseline.median_value):
            return None
        z_value = 0.0
    else:
        z_value = (exposure[0] - float(baseline.median_value)) / spread
    adverse = max(0.0, z_value)
    score = _interpolate_anchors(adverse, LOAD_SCORE_ANCHORS)
    return {
        "score": round(score, 1),
        "residual_exposure": round(exposure[0], 3),
        "daily_loads": [round(value, 3) for value in exposure[1]],
        "baseline": round(float(baseline.median_value), 3),
        "spread": round(spread, 3),
        "adverse_deviation": round(adverse, 3),
        "reference_days": baseline.valid_day_count,
    }


def _local_muscle_warnings(
    session: Session,
    user_id: str,
    day: date,
) -> list[dict[str, Any]]:
    current = _local_muscle_residuals(session, user_id, day)
    if current is None:
        return []
    history: dict[str, list[float]] = {muscle: [] for muscle in current}
    for reference_day in _date_range(day - timedelta(days=60), day - timedelta(days=1)):
        residuals = _local_muscle_residuals(session, user_id, reference_day)
        if residuals is None:
            continue
        for muscle in history:
            history[muscle].append(residuals.get(muscle, 0.0))

    warnings = []
    for muscle, exposure in current.items():
        values = history[muscle][-28:] if len(history[muscle]) >= 28 else history[muscle]
        if len(values) < 7:
            continue
        centre = float(median(values))
        spread = _robust_spread(values)
        if spread <= 0:
            continue
        adverse = max(0.0, (exposure - centre) / spread)
        if adverse <= 2:
            continue
        warnings.append(
            {
                "muscle": muscle,
                "level": "very_reduced" if adverse > 3 else "reduced",
                "adverse_deviation": round(adverse, 2),
                "residual_exposure": round(exposure, 2),
            }
        )
    return sorted(warnings, key=lambda item: item["adverse_deviation"], reverse=True)


def _local_muscle_residuals(
    session: Session,
    user_id: str,
    day: date,
) -> dict[str, float] | None:
    if _residual_load_exposure(session, user_id, day, "muscular") is None:
        return None
    weights = (0.50, 0.30, 0.20)
    daily = [
        _local_muscle_loads_for_day(session, user_id, day - timedelta(days=offset))
        for offset in range(1, 4)
    ]
    muscles = {muscle for values in daily for muscle in values}
    return {
        muscle: sum(weight * values.get(muscle, 0.0) for weight, values in zip(weights, daily))
        for muscle in muscles
    }


def _local_muscle_loads_for_day(
    session: Session,
    user_id: str,
    day: date,
) -> dict[str, float]:
    score = _score_for_day(session, user_id, day, "strain", STRAIN_LOAD_VERSION)
    muscular = (score.components or {}).get("muscular_load") if score is not None else None
    workouts = muscular.get("workouts") if isinstance(muscular, dict) else None
    totals: dict[str, float] = {}
    for workout in workouts or []:
        local_points = workout.get("local_muscle_points")
        if not isinstance(local_points, dict):
            continue
        for muscle, value in local_points.items():
            if isinstance(value, (int, float)):
                totals[str(muscle)] = totals.get(str(muscle), 0.0) + float(value)
    return totals


# group persistent or concordant illness-like signals before applying one modifier
def _anomaly_component(
    session: Session,
    user_id: str,
    day: date,
    autonomic: dict[str, Any] | None,
) -> dict[str, Any]:
    respiratory = _respiratory_group(session, user_id, day)
    temperature = _temperature_group(session, user_id, day)
    impaired_autonomic = bool(autonomic and float(autonomic["score"]) < 70)
    active_groups = sum(group["active"] for group in (respiratory, temperature))
    penalty = 0.0
    cap = None
    cap_reason = None
    if active_groups == 1:
        penalty = 10.0 if impaired_autonomic else 5.0
        if impaired_autonomic:
            cap = 75.0
            cap_reason = "persistent_anomaly_with_impaired_autonomic_recovery"
    elif active_groups == 2:
        penalty = 18.0 if impaired_autonomic else 12.0
        if impaired_autonomic:
            cap = 60.0
            cap_reason = "multiple_persistent_anomalies_with_impaired_autonomic_recovery"

    summary = _summary_for_day(session, user_id, day)
    severe_oxygen = bool(
        summary
        and summary.oxygen_saturation is not None
        and float(summary.oxygen_saturation) < 90
    )
    explicit_illness = _has_context(session, user_id, day, "illness")
    if severe_oxygen or explicit_illness:
        cap = min(cap or 100.0, 40.0)
        cap_reason = "severe_oxygen_warning" if severe_oxygen else "explicit_illness"
    anomalies = [
        signal
        for group in (respiratory, temperature)
        for signal in group["signals"]
    ]
    if impaired_autonomic:
        anomalies.append("autonomic_recovery_impaired")
    if explicit_illness:
        anomalies.append("illness_tag")
    if severe_oxygen:
        anomalies.append("oxygen_saturation_severe")
    return {
        "penalty": penalty,
        "readiness_cap": cap,
        "cap_reason": cap_reason,
        "anomalies": anomalies,
        "autonomic_impaired": impaired_autonomic,
        "respiratory_group": respiratory,
        "temperature_group": temperature,
        "optional_groups_complete": respiratory["complete"] and temperature["complete"],
    }


def _respiratory_group(session: Session, user_id: str, day: date) -> dict[str, Any]:
    respiratory = _metric_alert(session, user_id, day, "respiratory_rate", "high")
    oxygen = _metric_alert(session, user_id, day, "oxygen_saturation", "low")
    respiratory_previous = _metric_alert(
        session,
        user_id,
        day - timedelta(days=1),
        "respiratory_rate",
        "high",
    )
    oxygen_previous = _metric_alert(
        session,
        user_id,
        day - timedelta(days=1),
        "oxygen_saturation",
        "low",
    )
    persistent = (
        respiratory["crossed"] and respiratory_previous["crossed"]
    ) or (oxygen["crossed"] and oxygen_previous["crossed"])
    concordant = respiratory["crossed"] and oxygen["crossed"]
    signals = []
    if respiratory["crossed"]:
        signals.append("respiratory_rate_elevated")
    if oxygen["crossed"]:
        signals.append("oxygen_saturation_low")
    return {
        "active": bool(persistent or concordant),
        "persistent": bool(persistent),
        "current_night_concordant": bool(concordant),
        "signals": signals,
        "complete": respiratory["valid"] and oxygen["valid"],
    }


def _temperature_group(session: Session, user_id: str, day: date) -> dict[str, Any]:
    current = _metric_alert(session, user_id, day, "skin_temperature_variation", "high")
    previous = _metric_alert(
        session,
        user_id,
        day - timedelta(days=1),
        "skin_temperature_variation",
        "high",
    )
    persistent = current["crossed"] and previous["crossed"]
    return {
        "active": bool(persistent),
        "persistent": bool(persistent),
        "current_night_concordant": False,
        "signals": ["skin_temperature_elevated"] if current["crossed"] else [],
        "complete": current["valid"],
    }


def _metric_alert(
    session: Session,
    user_id: str,
    day: date,
    metric: str,
    direction: str,
) -> dict[str, Any]:
    baseline = _baseline_for_metric(session, user_id, day, metric)
    if metric == "skin_temperature_variation":
        value = session.scalar(
            select(func.avg(MetricSample.value)).where(
                MetricSample.user_id == user_id,
                MetricSample.metric == metric,
                MetricSample.civil_date == day,
            )
        )
    else:
        summary = _summary_for_day(session, user_id, day)
        value = getattr(summary, metric, None) if summary is not None else None
    boundary = (
        baseline.upper_bound
        if baseline is not None and direction == "high"
        else baseline.lower_bound if baseline is not None else None
    )
    valid = (
        value is not None
        and boundary is not None
        and baseline is not None
        and baseline.valid_day_count >= 7
    )
    crossed = bool(
        valid
        and (
            float(value) > float(boundary)
            if direction == "high"
            else float(value) < float(boundary)
        )
    )
    return {
        "valid": valid,
        "crossed": crossed,
        "value": float(value) if value is not None else None,
        "boundary": float(boundary) if boundary is not None else None,
    }


def _readiness_confidence(
    components: dict[str, Any],
    *,
    score_available: bool,
) -> dict[str, Any]:
    sleep = components.get("sleep_adequacy_debt") or {}
    autonomic = components.get("autonomic_recovery") or {}
    load = components.get("recent_load_fit") or {}
    anomaly = components.get("illness_anomaly_context") or {}
    reference_days = [
        int(item["reference_days"])
        for item in (
            autonomic.get("hrv"),
            autonomic.get("rhr"),
            load.get("cardio"),
            load.get("muscular"),
        )
        if isinstance(item, dict) and isinstance(item.get("reference_days"), int)
    ]
    minimum_reference_days = min(reference_days, default=0)
    supporting_missing = sum(
        (
            sleep.get("continuity") is None,
            int(autonomic.get("available_metrics") or 0) < 2,
            int(load.get("available_channels") or 0) < 2,
            not anomaly.get("optional_groups_complete", False),
            int(sleep.get("missing_sleep_nights_7d") or 0) > 0,
        )
    )
    if not score_available:
        level = "calibrating"
        phase = "provisional" if minimum_reference_days else "missing"
        data_quality = "weak"
    elif minimum_reference_days >= 28 and supporting_missing == 0:
        level = "high"
        phase = "personalized"
        data_quality = "strong"
    elif minimum_reference_days >= 14 or supporting_missing <= 1:
        level = "moderate"
        phase = "calibrating"
        data_quality = "moderate"
    else:
        level = "low"
        phase = "provisional"
        data_quality = "weak"
    return {
        "level": level,
        "phase": phase,
        "data_quality": data_quality,
        "minimum_reference_days": minimum_reference_days,
        "supporting_inputs_missing": supporting_missing,
    }


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


def _readiness_reasons(
    components: dict[str, Any],
    caps: list[dict[str, Any]],
) -> list[dict[str, Any]]:
    reasons = []
    for key in ("sleep_adequacy_debt", "autonomic_recovery", "recent_load_fit"):
        component = components[key]
        if key == "recent_load_fit":
            if component["score"] < READINESS_V3_CONFIG["load_neutral_score"]:
                reasons.append(
                    _reason(
                        "readiness_recent_load_fit_low",
                        "medium",
                        "Recent load reduced readiness.",
                    )
                )
            continue
        if component["score"] < 70:
            reasons.append(_reason(f"readiness_{key}_low", "medium", f"{key} reduced readiness."))
        elif component["score"] >= 90:
            reasons.append(
                _reason(f"readiness_{key}_strong", "low", f"{key} supported readiness.", "positive")
            )
    anomaly = components["illness_anomaly_context"]
    if anomaly["penalty"] > 0:
        reasons.insert(
            0,
            _reason(
                "readiness_anomaly_modifier",
                "high",
                "Persistent or concordant recovery signals reduced readiness.",
            ),
        )
    warnings = components["recent_load_fit"].get("local_readiness_warnings") or []
    if warnings:
        reasons.append(
            _reason(
                "readiness_local_muscular_warning",
                "medium",
                "One or more muscle groups still carry elevated residual load.",
            )
        )
    if caps:
        reasons.insert(
            0,
            _reason(
                "readiness_cap",
                "high",
                "A severe recovery signal capped readiness.",
            ),
        )
    return reasons[:4]
