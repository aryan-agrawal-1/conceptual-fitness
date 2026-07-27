from __future__ import annotations


from datetime import UTC, date, datetime, timedelta
from statistics import median
from typing import Any
from sqlalchemy import select
from sqlalchemy.orm import Session
from app.models import (
    DailyScore,
    ScoreStatus,
    SleepSession,
    UserProfile,
)
from app.services.score_helpers import (
    SLEEP_SCORE_VERSION,
    _baseline_for_metric,
    _circular_mean_minutes,
    _circular_midpoint,
    _circular_minutes_diff,
    _core_sleep_need_minutes,
    _date_range,
    _get_or_create_score,
    _interpolate_anchors,
    _local_minute,
    _main_sleep,
    _mark_score_waiting,
    _profile_age,
    _reason,
    _robust_spread,
    _set_score,
    _sleep_efficiency,
    _sleep_source_signature,
    _summary_for_day,
    _to_float,
    _weighted_score,
)
from app.services.score_baselines import _metric_value_for_baseline


SLEEP_V3_CONFIG = {
    "behavioural_weights": {
        "duration": 0.45,
        "regularity": 0.20,
        "continuity": 0.25,
        "timing": 0.10,
    },
    "behavioural_share_with_stages": 0.95,
    "stage_weight": 0.05,
    "missing_one_optional_cap": 97.0,
    "missing_both_optional_cap": 95.0,
}

DURATION_SCORE_ANCHORS = [
    (0, 100),
    (15, 97),
    (30, 94),
    (60, 84),
    (90, 70),
    (120, 55),
    (180, 30),
    (240, 10),
    (300, 0),
]

REGULARITY_SCORE_ANCHORS = [
    (0, 100),
    (15, 100),
    (30, 95),
    (60, 85),
    (90, 70),
    (120, 50),
    (180, 20),
    (240, 0),
]

CONTINUITY_SCORE_ANCHORS = [
    (0, 100),
    (10, 100),
    (20, 95),
    (30, 85),
    (40, 70),
    (50, 50),
    (60, 30),
    (90, 0),
]

TIMING_SCORE_ANCHORS = [
    (0, 100),
    (15, 100),
    (30, 95),
    (60, 85),
    (90, 70),
    (120, 50),
    (180, 0),
]

PHYSIOLOGY_SCORE_PENALTIES = {100: 0.0, 80: 3.0, 60: 6.0, 40: 9.0}


def _upsert_sleep_score(
    session: Session,
    *,
    user_id: str,
    profile: UserProfile,
    day: date,
) -> DailyScore:
    score = _get_or_create_score(session, user_id, day, "sleep", SLEEP_SCORE_VERSION)
    sleep = _main_sleep(session, user_id, day)
    if sleep is None or not _valid_main_sleep(sleep):
        return _mark_score_waiting(
            score,
            unit="score_0_100",
            status=ScoreStatus.waiting_for_sleep,
            reason_code="waiting_for_main_sleep",
            message="Sleep score is waiting for the main sleep session ending on this day.",
        )

    core_need = _core_sleep_need_minutes(profile, day)
    achieved = _valid_sleep_achieved_minutes(session, user_id, day, sleep)
    duration = _duration_score(achieved, core_need)
    regularity = _regularity_score(session, user_id, profile, day, sleep)
    continuity = _continuity_score(sleep, age=_profile_age(profile, day))
    timing = _timing_score(session, user_id, profile, day, sleep)
    physiology = _sleep_physiology_score(session, user_id, profile, day)
    stages = _stage_score(session, user_id, profile, day, sleep)
    timing_is_duplicate = _timing_duplicates_regularity(regularity, timing)
    if timing_is_duplicate:
        timing = {
            **timing,
            "excluded_from_score": True,
            "exclusion_reason": "duplicates_regularity_without_latency",
        }
    components = {
        "duration": duration,
        "regularity": regularity,
        "continuity": continuity,
        "timing": timing,
        "physiology": physiology,
        "stages": stages,
    }
    scored_components = {**components}
    if timing_is_duplicate:
        scored_components["timing"] = None
    core_weights = SLEEP_V3_CONFIG["behavioural_weights"]
    supporting_core_count = sum(
        scored_components[key] is not None and scored_components[key].get("score") is not None
        for key in ("regularity", "continuity", "timing")
    )
    if supporting_core_count < 2:
        return _set_score(
            score,
            value=None,
            unit="score_0_100",
            status=ScoreStatus.missing_data,
            confidence_phase="missing",
            data_quality="weak",
            components=components,
            inputs={
                "main_sleep_id": sleep.id,
                "core_sleep_need_minutes": core_need,
                "valid_sleep_achieved_minutes": achieved,
            },
            reasons=[
                _reason(
                    "insufficient_sleep_components",
                    "info",
                    "A sleep score needs duration and at least two other core sleep components.",
                )
            ],
        )

    core_score = float(_weighted_score(scored_components, core_weights) or 0)
    stage_adjusted_score = _stage_adjusted_sleep_score(core_score, stages)
    physiology_penalty = _sleep_physiology_penalty(physiology)
    value = max(0.0, min(100.0, stage_adjusted_score - physiology_penalty))
    cap_rules: list[dict[str, Any]] = []
    missing_optional_count = sum(component is None for component in (physiology, stages))
    if missing_optional_count == 2:
        cap_rules.append(
            {
                "reason": "missing_physiology_and_stages",
                "value": SLEEP_V3_CONFIG["missing_both_optional_cap"],
            }
        )
    elif missing_optional_count == 1:
        cap_rules.append(
            {
                "reason": "missing_optional_sleep_evidence",
                "value": SLEEP_V3_CONFIG["missing_one_optional_cap"],
            }
        )
    shortfall = duration["shortfall_minutes"]
    if shortfall >= 300:
        cap_rules.append({"reason": "duration_shortfall_5h", "value": 20.0})
    elif shortfall >= 240:
        cap_rules.append({"reason": "duration_shortfall_4h", "value": 30.0})
    elif shortfall >= 180:
        cap_rules.append({"reason": "duration_shortfall_3h", "value": 45.0})
    if continuity.get("severe_fragmentation"):
        cap_rules.append({"reason": "severe_fragmentation", "value": 50.0})
    caps = [cap for cap in cap_rules if value > float(cap["value"])]
    if cap_rules:
        value = min(value, *(float(cap["value"]) for cap in cap_rules))
    reasons = _sleep_reasons(components)
    if caps:
        evidence_only = all(
            cap["reason"] in {"missing_optional_sleep_evidence", "missing_physiology_and_stages"}
            for cap in caps
        )
        reasons.insert(
            0,
            _reason(
                "sleep_score_capped",
                "info" if evidence_only else "high",
                (
                    "Missing optional evidence limited the highest supported sleep score."
                    if evidence_only
                    else "A severe sleep shortfall or fragmented night capped the score."
                ),
            ),
        )
    phase = _sleep_confidence_phase(components, sleep)
    return _set_score(
        score,
        value=value,
        unit="score_0_100",
        status=ScoreStatus.scored,
        confidence_phase=phase,
        data_quality={"personalized": "strong", "calibrating": "moderate"}.get(phase, "weak"),
        components=components,
        inputs={
            "main_sleep_id": sleep.id,
            "core_sleep_need_minutes": core_need,
            "valid_sleep_achieved_minutes": achieved,
            "main_sleep_minutes": sleep.minutes_asleep,
            "valid_nap_minutes": max(0, achieved - int(sleep.minutes_asleep or 0)),
            "behavioural_core": round(core_score, 2),
            "stage_adjusted_score": round(stage_adjusted_score, 2),
            "physiology_penalty": physiology_penalty,
            "caps_applied": caps,
            "algorithm_config": SLEEP_V3_CONFIG,
        },
        reasons=reasons,
    )


def _duration_score(minutes: int, target: int) -> dict[str, Any]:
    shortfall = max(0, target - minutes)
    score = _interpolate_anchors(shortfall, DURATION_SCORE_ANCHORS)
    return {
        "score": round(score, 1),
        "minutes": minutes,
        "core_sleep_need_minutes": target,
        "allowance_minutes": 0,
        "shortfall_minutes": shortfall,
        "unusually_long": minutes > target + 120,
    }


def _stage_adjusted_sleep_score(
    behavioural_core: float,
    stages: dict[str, Any] | None,
) -> float:
    if not stages or not isinstance(stages.get("score"), int | float):
        return behavioural_core
    return (
        SLEEP_V3_CONFIG["behavioural_share_with_stages"] * behavioural_core
        + SLEEP_V3_CONFIG["stage_weight"] * float(stages["score"])
    )


def _sleep_physiology_penalty(physiology: dict[str, Any] | None) -> float:
    if not physiology or not isinstance(physiology.get("score"), int | float):
        return 0.0
    return PHYSIOLOGY_SCORE_PENALTIES.get(round(float(physiology["score"])), 0.0)


def _regularity_score(
    session: Session,
    user_id: str,
    profile: UserProfile,
    day: date,
    sleep: SleepSession,
) -> dict[str, Any]:
    start_minute = _local_minute(profile, sleep.start_time)
    end_minute = _local_minute(profile, sleep.end_time)
    references = _sleep_timing_reference(session, user_id, profile, day)
    if references is None:
        return None
    start_diff = _circular_minutes_diff(start_minute, references["start_minute"])
    end_diff = _circular_minutes_diff(end_minute, references["end_minute"])
    # average bedtime and wake-time drift before interpolation
    avg_diff = (start_diff + end_diff) / 2
    score = _interpolate_anchors(avg_diff, REGULARITY_SCORE_ANCHORS)
    return {
        "score": round(score, 1),
        "average_drift_minutes": round(avg_diff, 1),
        "bedtime_drift_minutes": round(start_diff, 1),
        "wake_time_drift_minutes": round(end_diff, 1),
        "start_minute": start_minute,
        "end_minute": end_minute,
        "reference_nights": references["count"],
        "reference_day_type": references["day_type"],
        "established": references["count"] >= 7,
    }


def _continuity_score(sleep: SleepSession, *, age: int | None = None) -> dict[str, Any] | None:
    efficiency = _sleep_efficiency(sleep)
    awake = sleep.minutes_awake
    if awake is None:
        return None
    # map wake-after-sleep-onset minutes onto the continuity scale
    score = _interpolate_anchors(awake, CONTINUITY_SCORE_ANCHORS)
    caps: list[dict[str, Any]] = []
    if efficiency is not None:
        if efficiency < 0.65:
            caps.append({"reason": "maintenance_efficiency_below_65", "value": 15.0})
        elif efficiency < 0.75:
            caps.append({"reason": "maintenance_efficiency_below_75", "value": 30.0})
        elif efficiency < 0.85:
            caps.append({"reason": "maintenance_efficiency_below_85", "value": 65.0})
    long_awakenings = _long_awakening_count(sleep)
    if long_awakenings is not None:
        if long_awakenings >= 4:
            caps.append({"reason": "four_or_more_long_awakenings", "value": 45.0})
        elif long_awakenings >= 3:
            caps.append({"reason": "three_long_awakenings", "value": 70.0})
        elif long_awakenings == 2 and (age is None or age < 65):
            caps.append({"reason": "two_long_awakenings", "value": 85.0})
    if caps:
        score = min(score, *(cap["value"] for cap in caps))
    return {
        "score": round(score, 1),
        "maintenance_efficiency": round(efficiency, 3) if efficiency is not None else None,
        "waso_minutes": awake,
        "long_awakenings_over_5_minutes": long_awakenings,
        "caps_applied": caps,
        "severe_fragmentation": awake >= 90
        or (efficiency is not None and efficiency < 0.65)
        or (long_awakenings is not None and long_awakenings >= 4),
    }


def _timing_score(
    session: Session,
    user_id: str,
    profile: UserProfile,
    day: date,
    sleep: SleepSession,
) -> dict[str, Any]:
    references = _sleep_timing_reference(session, user_id, profile, day)
    if references is None:
        return None
    actual_midpoint = _circular_midpoint(
        _local_minute(profile, sleep.start_time), _local_minute(profile, sleep.end_time)
    )
    target_midpoint = _circular_midpoint(references["start_minute"], references["end_minute"])
    drift = _circular_minutes_diff(actual_midpoint, target_midpoint)
    # score circular midpoint drift against the timing anchors
    score = _interpolate_anchors(drift, TIMING_SCORE_ANCHORS)
    return {
        "score": round(score, 1),
        "sleep_latency_minutes": None,
        "alignment_score": round(score, 1),
        "midsleep_alignment_drift_minutes": round(drift, 1),
        "reference_nights": references["count"],
    }


def _timing_duplicates_regularity(
    regularity: dict[str, Any] | None,
    timing: dict[str, Any] | None,
) -> bool:
    if not regularity or not timing or timing.get("sleep_latency_minutes") is not None:
        return False
    regularity_drift = regularity.get("average_drift_minutes")
    timing_drift = timing.get("midsleep_alignment_drift_minutes")
    return (
        isinstance(regularity_drift, int | float)
        and isinstance(timing_drift, int | float)
        and abs(float(regularity_drift) - float(timing_drift)) <= 0.1
    )


def _sleep_physiology_score(
    session: Session,
    user_id: str,
    profile: UserProfile,
    day: date,
) -> dict[str, Any] | None:
    summary = _summary_for_day(session, user_id, day)
    if summary is None:
        return None
    signals = {
        "heart_rate_variability": summary.heart_rate_variability,
        "resting_heart_rate": summary.resting_heart_rate,
        "respiratory_rate": summary.respiratory_rate,
        "oxygen_saturation": summary.oxygen_saturation,
        "skin_temperature_variation": _metric_value_for_baseline(
            session, user_id, profile, day, "skin_temperature_variation"
        ),
    }
    if all(value is None for value in signals.values()):
        return None

    current = {
        metric: _sleep_signal_abnormal(session, user_id, day, metric, value)
        for metric, value in signals.items()
    }
    previous_summary = _summary_for_day(session, user_id, day - timedelta(days=1))
    previous_values = {
        "heart_rate_variability": previous_summary.heart_rate_variability
        if previous_summary
        else None,
        "resting_heart_rate": previous_summary.resting_heart_rate if previous_summary else None,
        "respiratory_rate": previous_summary.respiratory_rate if previous_summary else None,
        "oxygen_saturation": previous_summary.oxygen_saturation if previous_summary else None,
        "skin_temperature_variation": _metric_value_for_baseline(
            session, user_id, profile, day - timedelta(days=1), "skin_temperature_variation"
        ),
    }
    previous = {
        metric: _sleep_signal_abnormal(session, user_id, day, metric, value)
        for metric, value in previous_values.items()
    }
    groups = {
        "autonomic": ("heart_rate_variability", "resting_heart_rate"),
        "respiratory": ("respiratory_rate", "oxygen_saturation"),
        "temperature": ("skin_temperature_variation",),
    }
    abnormal_groups: list[str] = []
    # count persistent or paired abnormalities by physiology group
    for group, metrics in groups.items():
        current_crossings = [metric for metric in metrics if current[metric]]
        persistent = any(current[metric] and previous[metric] for metric in metrics)
        paired = len(current_crossings) >= 2
        if persistent or paired:
            abnormal_groups.append(group)
    if signals["oxygen_saturation"] is not None and signals["oxygen_saturation"] < 90:
        if "respiratory" not in abnormal_groups:
            abnormal_groups.append("respiratory")
    score_by_count = {0: 100.0, 1: 80.0, 2: 60.0, 3: 40.0}
    signal_details: dict[str, dict[str, Any]] = {}
    for output_key, metric in (
        ("hrv", "heart_rate_variability"),
        ("rhr", "resting_heart_rate"),
        ("respiratory_rate", "respiratory_rate"),
        ("spo2", "oxygen_saturation"),
        ("temperature", "skin_temperature_variation"),
    ):
        value = signals[metric]
        if value is None:
            continue
        baseline = _baseline_for_metric(session, user_id, day, metric)
        signal_details[output_key] = {
            "value": value,
            "baseline": baseline.median_value if baseline else None,
            "crossed_alert_boundary": current[metric],
        }
    return {
        "score": score_by_count[len(abnormal_groups)],
        "abnormal_groups": abnormal_groups,
        "signal_crossings": current,
        "available_signals": [key for key, value in signals.items() if value is not None],
        **signal_details,
    }


def _stage_score(
    session: Session,
    user_id: str,
    profile: UserProfile,
    day: date,
    sleep: SleepSession,
) -> dict[str, Any] | None:
    total = sleep.minutes_asleep
    if not total:
        return None
    stage_totals, coverage = _validated_stage_totals(sleep)
    if not stage_totals:
        return None
    rem = stage_totals.get("rem", 0.0)
    deep = stage_totals.get("deep", 0.0)
    if rem <= 0 or deep <= 0:
        return None
    rem_pct = rem / total
    deep_pct = deep / total
    source_signature = _sleep_source_signature(session, sleep)
    references = _stage_references(session, user_id, day, source_signature=source_signature)
    if len(references) < 14:
        return None
    rem_values = [item[0] for item in references[-28:]]
    deep_values = [item[1] for item in references[-28:]]
    rem_delta = _spread_delta(rem_pct, rem_values)
    deep_delta = _spread_delta(deep_pct, deep_values)
    # grade stage deviations in robust spread units
    beyond_two = sum(delta > 2 for delta in (rem_delta, deep_delta))
    if rem_delta > 3 or deep_delta > 3 or beyond_two == 2:
        score = 60.0
    elif beyond_two == 1:
        score = 80.0
    else:
        score = 100.0
    persistent_stage = _persistent_stage_deviation(references, rem_pct, deep_pct)
    if persistent_stage:
        score = min(score, 40.0)
    age = _profile_age(profile, day)
    plausibility_cap = False
    if age is not None:
        if 13 <= age <= 17 and (rem_pct <= 0.10 or deep_pct <= 0.05):
            plausibility_cap = True
        elif 18 <= age <= 64 and (rem_pct >= 0.41 or deep_pct <= 0.05):
            plausibility_cap = True
        elif age >= 65 and rem_pct >= 0.41:
            plausibility_cap = True
    if plausibility_cap:
        score = min(score, 60.0)
    return {
        "score": round(score, 1),
        "rem_minutes": rem,
        "deep_minutes": deep,
        "rem_percent": round(rem_pct, 3),
        "deep_percent": round(deep_pct, 3),
        "timeline_coverage": round(coverage, 3),
        "reference_nights": len(references[-28:]),
        "rem_spread_delta": round(rem_delta, 2),
        "deep_spread_delta": round(deep_delta, 2),
        "persistent_deviation": persistent_stage,
        "age_plausibility_cap": plausibility_cap,
        "source_stable": source_signature is not None,
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


def _validated_stage_totals(sleep: SleepSession) -> tuple[dict[str, float], float]:
    expected_period = sleep.minutes_in_sleep_period
    expected_sleep = sleep.minutes_asleep
    if not expected_period or not expected_sleep or expected_period <= 0 or expected_sleep <= 0:
        return {}, 0.0
    intervals: list[tuple[datetime, datetime, str]] = []
    for item in sleep.stages or []:
        start = _parse_stage_datetime(item.get("startTime"))
        end = _parse_stage_datetime(item.get("endTime"))
        stage_type = str(item.get("type") or item.get("stage") or "").lower()
        if start is None or end is None or end <= start:
            return {}, 0.0
        session_start = _comparable_datetime(sleep.start_time)
        session_end = _comparable_datetime(sleep.end_time)
        if _comparable_datetime(start) < session_start or _comparable_datetime(end) > session_end:
            return {}, 0.0
        intervals.append((start, end, stage_type))
    if not intervals:
        return {}, 0.0
    intervals.sort(key=lambda item: item[0])
    if any(current[1] > nxt[0] for current, nxt in zip(intervals, intervals[1:])):
        return {}, 0.0
    covered = sum((end - start).total_seconds() / 60 for start, end, _ in intervals)
    # require stage intervals to cover ninety percent of the sleep period
    coverage = covered / expected_period
    if coverage < 0.90:
        return {}, coverage
    totals = {"rem": 0.0, "deep": 0.0}
    staged_sleep = 0.0
    for start, end, stage_type in intervals:
        minutes = (end - start).total_seconds() / 60
        if "awake" not in stage_type and "wake" not in stage_type:
            staged_sleep += minutes
        if "rem" in stage_type:
            totals["rem"] += minutes
        if "deep" in stage_type or "slow" in stage_type:
            totals["deep"] += minutes
    agreement_allowance = max(expected_sleep * 0.10, 30)
    if abs(staged_sleep - expected_sleep) > agreement_allowance:
        return {}, coverage
    return totals, coverage


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


def _comparable_datetime(value: datetime) -> datetime:
    if value.tzinfo is not None:
        return value.astimezone(UTC).replace(tzinfo=None)
    return value


def _sleep_timing_reference(
    session: Session,
    user_id: str,
    profile: UserProfile,
    day: date,
) -> dict[str, Any] | None:
    day_type = "free_day" if day.weekday() >= 5 else "workday"
    start = day - timedelta(days=60)
    sleeps = session.scalars(
        select(SleepSession).where(
            SleepSession.user_id == user_id,
            SleepSession.civil_date >= start,
            SleepSession.civil_date < day,
        )
    ).all()
    per_day: dict[date, SleepSession] = {}
    for candidate in sleeps:
        if candidate.civil_date is None:
            continue
        candidate_type = "free_day" if candidate.civil_date.weekday() >= 5 else "workday"
        if candidate_type != day_type or not _valid_main_sleep(candidate):
            continue
        existing = per_day.get(candidate.civil_date)
        if existing is None or (candidate.minutes_asleep or 0) > (existing.minutes_asleep or 0):
            per_day[candidate.civil_date] = candidate
    comparable = [per_day[key] for key in sorted(per_day)][-28:]
    if not comparable:
        return None
    return {
        "start_minute": _circular_mean_minutes(
            [_local_minute(profile, item.start_time) for item in comparable]
        ),
        "end_minute": _circular_mean_minutes(
            [_local_minute(profile, item.end_time) for item in comparable]
        ),
        "count": len(comparable),
        "day_type": day_type,
    }


def _valid_main_sleep(sleep: SleepSession) -> bool:
    if (
        sleep.minutes_asleep is None
        or sleep.minutes_asleep <= 0
        or sleep.end_time <= sleep.start_time
    ):
        return False
    period = sleep.minutes_in_sleep_period or int(
        (sleep.end_time - sleep.start_time).total_seconds() / 60
    )
    return period > 0 and sleep.minutes_asleep <= period + max(30, period * 0.10)


def _valid_sleep_achieved_minutes(
    session: Session,
    user_id: str,
    day: date,
    main_sleep: SleepSession,
) -> int:
    total = int(main_sleep.minutes_asleep or 0)
    accepted = [(main_sleep.start_time, main_sleep.end_time)]
    candidates = session.scalars(
        select(SleepSession)
        .where(
            SleepSession.user_id == user_id,
            SleepSession.civil_date == day,
            SleepSession.id != main_sleep.id,
        )
        .order_by(SleepSession.start_time)
    ).all()
    for candidate in candidates:
        if not _valid_main_sleep(candidate):
            continue
        overlaps = any(
            candidate.start_time < end and candidate.end_time > start for start, end in accepted
        )
        if overlaps:
            continue
        total += int(candidate.minutes_asleep or 0)
        accepted.append((candidate.start_time, candidate.end_time))
    return total


def _long_awakening_count(sleep: SleepSession) -> int | None:
    if not sleep.stages:
        return None
    parsed: list[tuple[datetime, datetime, str]] = []
    for item in sleep.stages:
        stage_type = str(item.get("type") or item.get("stage") or "").lower()
        start = _parse_stage_datetime(item.get("startTime"))
        end = _parse_stage_datetime(item.get("endTime"))
        if start is not None and end is not None and end > start:
            parsed.append((start, end, stage_type))
    sleep_indices = [
        index
        for index, (_, _, stage_type) in enumerate(parsed)
        if "awake" not in stage_type and "wake" not in stage_type
    ]
    if not sleep_indices:
        return None
    first_sleep, last_sleep = min(sleep_indices), max(sleep_indices)
    count = 0
    for index, (start, end, stage_type) in enumerate(parsed):
        if index <= first_sleep or index >= last_sleep:
            continue
        if "awake" not in stage_type and "wake" not in stage_type:
            continue
        if (end - start).total_seconds() / 60 > 5:
            count += 1
    return count


def _stage_references(
    session: Session,
    user_id: str,
    day: date,
    *,
    source_signature: tuple[str, str] | None,
) -> list[tuple[float, float]]:
    references: list[tuple[float, float]] = []
    for previous_day in _date_range(day - timedelta(days=60), day - timedelta(days=1)):
        sleep = _main_sleep(session, user_id, previous_day)
        if sleep is None or not sleep.minutes_asleep:
            continue
        if (
            source_signature is not None
            and _sleep_source_signature(session, sleep) != source_signature
        ):
            continue
        totals, _ = _validated_stage_totals(sleep)
        rem = totals.get("rem", 0)
        deep = totals.get("deep", 0)
        if rem > 0 and deep > 0:
            references.append((rem / sleep.minutes_asleep, deep / sleep.minutes_asleep))
    return references[-28:]


def _spread_delta(value: float, reference: list[float]) -> float:
    centre = float(median(reference))
    spread = _robust_spread(reference) or max(abs(centre) * 0.08, 0.01)
    return abs(value - centre) / spread


def _persistent_stage_deviation(
    references: list[tuple[float, float]],
    rem_pct: float,
    deep_pct: float,
) -> bool:
    if len(references) < 14 or len(references) < 2:
        return False
    rem_reference = [item[0] for item in references]
    deep_reference = [item[1] for item in references]
    for index, current in enumerate((rem_pct, deep_pct)):
        values = rem_reference if index == 0 else deep_reference
        centre = float(median(values))
        spread = _robust_spread(values) or max(abs(centre) * 0.08, 0.01)
        latest = values[-2:] + [current]
        if all(abs(value - centre) / spread > 2 for value in latest):
            directions = [value > centre for value in latest]
            if len(set(directions)) == 1:
                return True
    return False


def _sleep_signal_abnormal(
    session: Session,
    user_id: str,
    baseline_day: date,
    metric: str,
    value: float | None,
) -> bool:
    if value is None:
        return False
    if metric == "oxygen_saturation" and value < 94:
        return True
    baseline = _baseline_for_metric(session, user_id, baseline_day, metric)
    if baseline is None or baseline.median_value is None:
        return False
    lower = baseline.lower_bound
    upper = baseline.upper_bound
    if metric == "heart_rate_variability":
        return lower is not None and value < lower
    if metric == "oxygen_saturation":
        return lower is not None and value < lower
    if metric in {"resting_heart_rate", "respiratory_rate"}:
        return upper is not None and value > upper
    return (lower is not None and value < lower) or (upper is not None and value > upper)


def _sleep_confidence_phase(components: dict[str, Any], sleep: SleepSession) -> str:
    core = [components.get(key) for key in ("duration", "regularity", "continuity", "timing")]
    core_count = sum(isinstance(item, dict) and item.get("score") is not None for item in core)
    reference_nights = min(
        [
            int(item.get("reference_nights", 0))
            for item in (components.get("regularity"), components.get("timing"))
            if isinstance(item, dict)
        ]
        or [0]
    )
    stages = components.get("stages")
    stage_coverage = stages.get("timeline_coverage", 0) if isinstance(stages, dict) else 0
    all_optional = components.get("physiology") is not None and stages is not None
    source_stable = isinstance(stages, dict) and stages.get("source_stable") is True
    if (
        core_count == 4
        and reference_nights >= 28
        and stage_coverage >= 0.90
        and all_optional
        and source_stable
    ):
        return "personalized"
    if core_count == 4 and reference_nights >= 7:
        return "calibrating"
    return "provisional"


def _sleep_reasons(components: dict[str, Any]) -> list[dict[str, Any]]:
    reasons = []
    for key, component in components.items():
        if (
            not isinstance(component, dict)
            or component.get("score") is None
            or component.get("excluded_from_score")
        ):
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
