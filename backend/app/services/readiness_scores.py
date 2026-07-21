from __future__ import annotations


from datetime import date, timedelta
from statistics import mean
from typing import Any
from sqlalchemy import select
from sqlalchemy.orm import Session
from app.models import (
    DailyContext,
    DailyScore,
    ScoreStatus,
    SleepSession,
    UserProfile,
)
from app.services.score_helpers import (
    READINESS_SCORE_VERSION,
    STRAIN_LOAD_VERSION,
    _baseline_for_metric,
    _baseline_phase,
    _baseline_value,
    _combined_phase,
    _date_range,
    _get_or_create_score,
    _main_sleep,
    _mark_score_waiting,
    _metric_baseline_score,
    _quality_for_components,
    _reason,
    _score_for_day,
    _set_score,
    _strain_loads,
    _summary_for_day,
    _weighted_score,
)
from app.services.sleep_scores import _continuity_score, _duration_score
from app.services.strain_scores import _adaptive_load_window, _chronic_load, _strain_confidence_phase


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
    # combine available readiness components with normalized weights
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
    # blend duration and continuity before applying accumulated sleep debt
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
    # average autonomic signals and subtract the multi-day trend penalty
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
        # compare recent acute load with the preceding chronic average
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
    # reduce readiness as independent anomaly signals accumulate
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
