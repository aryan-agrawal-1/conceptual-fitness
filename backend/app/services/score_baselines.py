from __future__ import annotations


from collections import Counter
from dataclasses import dataclass
from datetime import date, timedelta
from math import exp, isfinite, log
from statistics import mean, median
from typing import Any
from sqlalchemy import select
from sqlalchemy.orm import Session
from app.models import (
    DailyContext,
    MetricSample,
    RawHealthRecord,
    UserProfile,
)
from app.services.health_dates import (
    timezone_for_profile,
)
from app.services.score_helpers import (
    STRAIN_LOAD_VERSION,
    _circular_mean_minutes,
    _circular_median_minutes,
    _circular_minutes_diff,
    _circular_robust_spread,
    _core_sleep_need_minutes,
    _date_range,
    _get_or_create_baseline,
    _main_sleep,
    _phase_for_count,
    _robust_spread,
    _score_for_day,
    _sleep_efficiency,
    _sleep_source_signature,
    _summary_for_day,
)


BASELINE_METRICS = (
    "sleep_minutes",
    "sleep_start_minute",
    "sleep_end_minute",
    "sleep_efficiency",
    "heart_rate_variability",
    "resting_heart_rate",
    "skin_temperature_variation",
    "respiratory_rate",
    "oxygen_saturation",
    "strain_load",
)


@dataclass(frozen=True)
class BaselineObservation:
    day: date
    value: float
    source: str

@dataclass(frozen=True)
class BaselineCalculation:
    observations: list[BaselineObservation]
    exclusions: list[dict[str, Any]]
    window_days: int
    mean_value: float | None
    median_value: float | None
    spread_value: float | None
    lower_bound: float | None
    upper_bound: float | None
    metadata: dict[str, Any]


def rebuild_daily_baselines(
    session: Session,
    *,
    user_id: str,
    profile: UserProfile,
    baseline_date: date,
) -> int:
    count = 0
    for metric in BASELINE_METRICS:
        calculation = _calculate_personal_baseline(
            session,
            user_id=user_id,
            profile=profile,
            metric=metric,
            baseline_date=baseline_date,
        )
        baseline = _get_or_create_baseline(session, user_id, baseline_date, metric)
        baseline.window_days = calculation.window_days
        baseline.valid_day_count = len(calculation.observations)
        baseline.confidence_phase = _baseline_confidence_phase(calculation)
        baseline.included_dates = [item.day.isoformat() for item in calculation.observations]
        baseline.exclusions = calculation.exclusions
        baseline.mean_value = calculation.mean_value
        baseline.median_value = calculation.median_value
        baseline.spread_value = calculation.spread_value
        baseline.lower_bound = calculation.lower_bound
        baseline.upper_bound = calculation.upper_bound
        baseline.metadata_json = calculation.metadata
        session.add(baseline)
        count += 1
    session.flush()
    return count


def _calculate_personal_baseline(
    session: Session,
    *,
    user_id: str,
    profile: UserProfile,
    metric: str,
    baseline_date: date,
) -> BaselineCalculation:
    window_days = _baseline_window_days(metric)
    observations, exclusions = _baseline_observations(
        session,
        user_id=user_id,
        profile=profile,
        metric=metric,
        baseline_date=baseline_date,
        window_days=window_days,
    )
    observations, source_metadata = _source_consistent_observations(observations)
    observations = _drop_observation_outliers(observations, metric)
    values = [item.value for item in observations]
    metadata: dict[str, Any] = {
        "method": _baseline_method(metric),
        "reference_window_days": window_days,
        "recent_trend": _recent_baseline_trend(values, metric),
        "latest_observation_date": observations[-1].day.isoformat() if observations else None,
        "days_since_latest_observation": (
            (baseline_date - observations[-1].day).days if observations else None
        ),
        **source_metadata,
    }
    if metric in {"sleep_minutes", "sleep_start_minute", "sleep_end_minute"}:
        metadata["day_type"] = "free_day" if baseline_date.weekday() >= 5 else "workday"
    if metric == "sleep_minutes":
        metadata["adequacy_target_minutes"] = _core_sleep_need_minutes(profile, baseline_date)
        metadata["naps_included"] = False
    if metric == "skin_temperature_variation":
        metadata["provider_relative_measurement"] = True
        metadata["cycle_aware"] = False
    if metric == "strain_load":
        metadata["weekday"] = baseline_date.weekday()
        metadata["weekday_recent_mean"] = _weekday_mean(observations, baseline_date.weekday())
        metadata["missing_days_are_zero"] = False
        metadata["genuine_rest_days_are_zero"] = True

    if not values:
        return BaselineCalculation(
            observations=observations,
            exclusions=exclusions,
            window_days=window_days,
            mean_value=None,
            median_value=None,
            spread_value=None,
            lower_bound=None,
            upper_bound=None,
            metadata=metadata,
        )

    # calculate metric-specific centre, spread, and alert bounds
    if metric in {"sleep_start_minute", "sleep_end_minute"}:
        centre = _circular_median_minutes(values)
        spread = _circular_robust_spread(values, centre)
        avg = _circular_mean_minutes(values)
        lower, upper = (centre - 2 * spread) % 1440, (centre + 2 * spread) % 1440
    elif metric == "heart_rate_variability":
        positive = [value for value in values if value > 0]
        log_values = [log(value) for value in positive]
        centre_log = float(median(log_values))
        spread_log = _robust_spread(log_values)
        centre = exp(centre_log)
        avg = exp(mean(log_values))
        lower = exp(centre_log - 2 * spread_log)
        upper = exp(centre_log + 2 * spread_log)
        spread = (upper - lower) / 4
        metadata["transform"] = "natural_log_rmssd"
        metadata["log_spread"] = spread_log
    elif metric == "oxygen_saturation":
        centre = float(median(values))
        avg = float(mean(values))
        spread = _robust_spread(values)
        lower = _percentile(values, 0.10)
        upper = 100.0
        metadata["lower_tail_percentile"] = 10
        metadata["one_sided"] = "lower"
    elif metric == "strain_load":
        centre = _ewma(values, half_life=28)
        avg = float(mean(values))
        spread = _robust_spread(values)
        lower = max(0.0, centre - 2 * spread)
        upper = centre + 2 * spread
        metadata["ewma_half_life_days"] = 28
    else:
        centre = float(median(values))
        avg = float(mean(values))
        spread = _robust_spread(values)
        lower = centre - 2 * spread if spread > 0 else centre
        upper = centre + 2 * spread if spread > 0 else centre
        if metric == "sleep_efficiency":
            lower, upper = max(0.0, lower), min(1.0, upper)

    return BaselineCalculation(
        observations=observations,
        exclusions=exclusions,
        window_days=window_days,
        mean_value=float(avg),
        median_value=float(centre),
        spread_value=float(spread),
        lower_bound=float(lower),
        upper_bound=float(upper),
        metadata=metadata,
    )


def _baseline_observations(
    session: Session,
    *,
    user_id: str,
    profile: UserProfile,
    metric: str,
    baseline_date: date,
    window_days: int,
) -> tuple[list[BaselineObservation], list[dict[str, Any]]]:
    exclusions: list[dict[str, Any]] = []
    observations: list[BaselineObservation] = []
    start = baseline_date - timedelta(days=window_days)
    end = baseline_date - timedelta(days=1)
    expected_day_type = "free_day" if baseline_date.weekday() >= 5 else "workday"
    for day in _date_range(start, end):
        context_exclusion = _baseline_context_exclusion(session, user_id, day, metric)
        if context_exclusion:
            exclusions.append({"date": day.isoformat(), "reason": context_exclusion})
            continue
        if metric in {"sleep_minutes", "sleep_start_minute", "sleep_end_minute"}:
            day_type = "free_day" if day.weekday() >= 5 else "workday"
            if day_type != expected_day_type:
                continue
        value = _metric_value_for_baseline(session, user_id, profile, day, metric)
        if value is None or not isfinite(value) or (metric == "heart_rate_variability" and value <= 0):
            exclusions.append({"date": day.isoformat(), "reason": "missing_metric"})
            continue
        summary = _summary_for_day(session, user_id, day)
        if (
            summary
            and summary.data_quality == "missing"
            and metric
            not in {
                "sleep_minutes",
                "sleep_start_minute",
                "sleep_end_minute",
                "sleep_efficiency",
                "strain_load",
            }
        ):
            exclusions.append({"date": day.isoformat(), "reason": "missing_daily_summary"})
            continue
        source = _metric_source_for_day(session, user_id, day, metric)
        observations.append(BaselineObservation(day=day, value=value, source=source))
    return observations, exclusions


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
    if metric in {
        "sleep_minutes",
        "sleep_start_minute",
        "sleep_end_minute",
        "sleep_efficiency",
    }:
        sleep = _main_sleep(session, user_id, day)
        if sleep is None:
            return None
        if metric == "sleep_minutes":
            return float(sleep.minutes_asleep) if sleep.minutes_asleep is not None else None
        if metric == "sleep_efficiency":
            return _sleep_efficiency(sleep)
        tz = timezone_for_profile(profile)
        dt = sleep.start_time if metric == "sleep_start_minute" else sleep.end_time
        if dt.tzinfo is None:
            return dt.hour * 60 + dt.minute
        local = dt.astimezone(tz)
        return local.hour * 60 + local.minute
    if metric == "skin_temperature_variation":
        values = session.scalars(
            select(MetricSample.value).where(
                MetricSample.user_id == user_id,
                MetricSample.metric == "skin_temperature_variation",
                MetricSample.civil_date == day,
                MetricSample.value.is_not(None),
            )
        ).all()
        return float(mean(values)) if values else None
    if summary is None:
        return None
    value = getattr(summary, metric, None)
    return float(value) if value is not None else None


def _baseline_window_days(metric: str) -> int:
    if metric in {"sleep_minutes", "sleep_start_minute", "sleep_end_minute"}:
        return 28
    return 60


def _baseline_method(metric: str) -> str:
    return {
        "sleep_minutes": "day_type_main_sleep_median_mad",
        "sleep_start_minute": "day_type_circular_median_mad",
        "sleep_end_minute": "day_type_circular_median_mad",
        "sleep_efficiency": "provider_specific_median_mad",
        "heart_rate_variability": "provider_specific_log_rmssd_median_mad",
        "resting_heart_rate": "provider_specific_median_mad",
        "skin_temperature_variation": "provider_relative_median_mad",
        "respiratory_rate": "provider_specific_sleep_window_median_mad",
        "oxygen_saturation": "provider_specific_median_lower_tail",
        "strain_load": "zero_preserving_28_day_half_life_ewma",
    }[metric]


def _metric_source_for_day(
    session: Session,
    user_id: str,
    day: date,
    metric: str,
) -> str:
    if metric == "strain_load":
        return STRAIN_LOAD_VERSION
    if metric.startswith("sleep_"):
        sleep = _main_sleep(session, user_id, day)
        if sleep is None:
            return "unknown"
        signature = _sleep_source_signature(session, sleep)
        return ":".join(signature) if signature else "unknown"
    samples = session.execute(
        select(
            MetricSample.raw_record_id,
            MetricSample.source_platform,
            MetricSample.source_device,
        ).where(
            MetricSample.user_id == user_id,
            MetricSample.metric == metric,
            MetricSample.civil_date == day,
        )
    ).all()
    if not samples:
        return "unknown"
    signatures: list[str] = []
    for raw_record_id, platform, device in samples:
        account_id = "unknown_account"
        if raw_record_id:
            raw = session.get(RawHealthRecord, raw_record_id)
            if raw is not None:
                account_id = raw.google_account_id
                platform = platform or raw.source_platform
                device = device or raw.source_device
        source = ":".join(filter(None, (platform, device))) or "google_health"
        signatures.append(f"{account_id}:{source}")
    return Counter(signatures).most_common(1)[0][0]


def _source_consistent_observations(
    observations: list[BaselineObservation],
) -> tuple[list[BaselineObservation], dict[str, Any]]:
    if not observations:
        return [], {"source": None, "source_consistent": False}
    latest_source = observations[-1].source
    start_index = 0
    for index in range(len(observations) - 2, -1, -1):
        if observations[index].source != latest_source:
            start_index = index + 1
            break
    comparable = observations[start_index:]
    return comparable, {
        "source": latest_source,
        "source_consistent": latest_source != "unknown",
        "source_run_start": comparable[0].day.isoformat(),
    }


def _drop_observation_outliers(
    observations: list[BaselineObservation],
    metric: str,
) -> list[BaselineObservation]:
    if len(observations) < 8 or metric == "strain_load":
        return observations
    values = [item.value for item in observations]
    # exclude readings beyond four robust standard deviations
    if metric in {"sleep_start_minute", "sleep_end_minute"}:
        centre = _circular_median_minutes(values)
        spread = _circular_robust_spread(values, centre)
        if spread == 0:
            return observations
        return [
            item
            for item in observations
            if _circular_minutes_diff(item.value, centre) <= 4 * spread
        ]
    transformed = [log(value) for value in values] if metric == "heart_rate_variability" else values
    centre = float(median(transformed))
    spread = _robust_spread(transformed)
    if spread == 0:
        return observations
    return [
        item
        for item, transformed_value in zip(observations, transformed)
        if abs(transformed_value - centre) <= 4 * spread
    ]


def _recent_baseline_trend(values: list[float], metric: str) -> dict[str, Any]:
    recent = values[-7:]
    if not recent:
        return {"valid_readings": 0, "value": None}
    if metric in {"sleep_start_minute", "sleep_end_minute"}:
        value = _circular_mean_minutes(recent)
    elif metric == "heart_rate_variability":
        value = exp(mean([log(item) for item in recent]))
    else:
        value = mean(recent)
    return {"valid_readings": len(recent), "value": round(float(value), 4)}


def _weekday_mean(observations: list[BaselineObservation], weekday: int) -> float | None:
    values = [item.value for item in observations if item.day.weekday() == weekday]
    return round(float(mean(values)), 4) if values else None


# calculate an exponentially weighted moving average
def _ewma(values: list[float], *, half_life: float) -> float:
    # convert the half-life into a daily smoothing factor
    alpha = 1 - exp(log(0.5) / half_life)
    result = float(values[0])
    for value in values[1:]:
        result = alpha * value + (1 - alpha) * result
    return result


def _percentile(values: list[float], quantile: float) -> float:
    ordered = sorted(values)
    if len(ordered) == 1:
        return float(ordered[0])
    position = (len(ordered) - 1) * quantile
    lower_index = int(position)
    upper_index = min(lower_index + 1, len(ordered) - 1)
    fraction = position - lower_index
    # interpolate between the surrounding ordered readings
    return float(ordered[lower_index] + fraction * (ordered[upper_index] - ordered[lower_index]))


def _baseline_confidence_phase(calculation: BaselineCalculation) -> str:
    phase = _phase_for_count(len(calculation.observations))
    if calculation.metadata.get("source_consistent") is False and phase == "personalized":
        return "calibrating"
    return phase


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


def _baseline_context_exclusion(
    session: Session,
    user_id: str,
    day: date,
    metric: str,
) -> str | None:
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
        "device_change",
        "non_wear",
        "overload",
        "overreaching",
    }
    for context in contexts:
        if context.context_type in excluded_types:
            return context.context_type
        if context.context_type == "altitude" and metric in {
            "oxygen_saturation",
            "respiratory_rate",
            "resting_heart_rate",
        }:
            return context.context_type
    return None
