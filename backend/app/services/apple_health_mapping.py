from __future__ import annotations

from dataclasses import dataclass
from datetime import date, datetime, time, timedelta
from statistics import mean, median
from typing import Any

from sqlalchemy import delete, select
from sqlalchemy.orm import Session

from app.models import HealthConnection, MetricSample, RawHealthRecord, SleepSession
from app.services.health_dates import get_or_create_profile, local_date_for_profile, timezone_for_profile
from app.services.hrv import HRV_METRIC, SDNN
from app.services.metric_rollups import HighVolumeRecord, replace_high_volume_rollups
from app.services.workout_records import normalize_provider_workout, remove_provider_workouts

APPLE_HEALTH_PLATFORM = "APPLE_HEALTH"
SLEEP_ANALYSIS = "HKCategoryTypeIdentifierSleepAnalysis"
WRIST_TEMPERATURE = "HKQuantityTypeIdentifierAppleSleepingWristTemperature"
WORKOUT = "HKWorkoutTypeIdentifier"
HEART_RATE = "HKQuantityTypeIdentifierHeartRate"
STEP_COUNT = "HKQuantityTypeIdentifierStepCount"
DISTANCE = "HKQuantityTypeIdentifierDistanceWalkingRunning"
ACTIVE_ENERGY = "HKQuantityTypeIdentifierActiveEnergyBurned"
BASAL_ENERGY = "HKQuantityTypeIdentifierBasalEnergyBurned"
WRIST_TEMPERATURE_METRIC = "wrist_temperature"
SKIN_TEMPERATURE_VARIATION = "skin_temperature_variation"
WATCH_PRODUCT_PREFIX = "Watch"
SLEEP_SESSION_GAP = timedelta(minutes=30)
TEMPERATURE_REFERENCE_DAYS = 60
TEMPERATURE_MIN_REFERENCE_NIGHTS = 5
NIGHTLY_WINDOW_METRICS = ("respiratory_rate", "oxygen_saturation")

IN_BED = 0
ASLEEP_UNSPECIFIED = 1
AWAKE = 2
SLEEP_STAGE_NAMES = {3: "light", 4: "deep", 5: "rem"}
ASLEEP_VALUES = {ASLEEP_UNSPECIFIED, *SLEEP_STAGE_NAMES}


@dataclass(frozen=True)
class SampleMapping:
    metric: str
    unit: str
    accepted_unit: str
    scale: float = 1.0
    measurement_type: str | None = None
    watch_only: bool = True


SAMPLE_MAPPINGS: dict[str, SampleMapping] = {
    "HKQuantityTypeIdentifierRestingHeartRate": SampleMapping("resting_heart_rate", "bpm", "count/min"),
    "HKQuantityTypeIdentifierHeartRateVariabilitySDNN": SampleMapping(
        HRV_METRIC, "ms", "ms", measurement_type=SDNN
    ),
    "HKQuantityTypeIdentifierRespiratoryRate": SampleMapping(
        "respiratory_rate", "breaths_per_min", "count/min"
    ),
    "HKQuantityTypeIdentifierOxygenSaturation": SampleMapping("oxygen_saturation", "percent", "%", scale=100),
    WRIST_TEMPERATURE: SampleMapping(WRIST_TEMPERATURE_METRIC, "celsius", "degC"),
    "HKQuantityTypeIdentifierVO2Max": SampleMapping("vo2_max", "ml_per_kg_min", "ml/kg*min"),
    "HKQuantityTypeIdentifierBodyMass": SampleMapping("weight", "kg", "kg", watch_only=False),
    "HKQuantityTypeIdentifierHeight": SampleMapping("height", "meters", "m", watch_only=False),
}
DATED_BY_END = frozenset({SLEEP_ANALYSIS, WRIST_TEMPERATURE})


@dataclass(frozen=True)
class RollupMapping:
    data_types: tuple[str, ...]
    unit: str
    accepted_unit: str
    instant: bool = False


ROLLUP_MAPPINGS: dict[str, RollupMapping] = {
    "heart_rate": RollupMapping((HEART_RATE,), "bpm", "count/min", instant=True),
    "steps": RollupMapping((STEP_COUNT,), "count", "count"),
    "distance": RollupMapping((DISTANCE,), "meters", "m"),
    "active_calories": RollupMapping((ACTIVE_ENERGY,), "kcal", "kcal"),
    "total_calories": RollupMapping((ACTIVE_ENERGY, BASAL_ENERGY), "kcal", "kcal"),
}
ROLLUP_DATA_TYPES = frozenset(data_type for item in ROLLUP_MAPPINGS.values() for data_type in item.data_types)
WORKOUT_TYPES = {
    "traditional_strength_training": "strength_training",
    "functional_strength_training": "strength_training",
    "core_training": "strength_training",
    "high_intensity_interval_training": "hiit",
    "cross_training": "circuit_training",
    "mixed_cardio": "cardio",
    "cardio_dance": "cardio_dance",
    "stair_climbing": "stair_climbing_cardio",
}


def recorded_by_watch(sample: dict[str, Any]) -> bool:
    product_type = (sample.get("source") or {}).get("product_type") or ""
    return product_type.startswith(WATCH_PRODUCT_PREFIX)


def normalize_apple_sample(session: Session, connection: HealthConnection, record: RawHealthRecord) -> bool:
    session.execute(delete(MetricSample).where(MetricSample.raw_record_id == record.id))
    sample = record.raw_json or {}
    if record.data_type == WORKOUT:
        return normalize_apple_workout(session, connection, record)
    mapping = SAMPLE_MAPPINGS.get(record.data_type)
    value = sample.get("value")
    if mapping is None or value is None or sample.get("unit") != mapping.accepted_unit:
        return False
    if mapping.watch_only and not recorded_by_watch(sample):
        return False
    session.add(
        MetricSample(
            user_id=record.user_id,
            raw_record_id=record.id,
            metric=mapping.metric,
            observed_at=record.end_time if record.data_type in DATED_BY_END else record.start_time,
            civil_date=record.civil_date,
            value=float(value) * mapping.scale,
            unit=mapping.unit,
            source_platform=APPLE_HEALTH_PLATFORM,
            source_device=record.source_device,
            measurement_type=mapping.measurement_type,
        )
    )
    return True


def normalize_apple_workout(session: Session, connection: HealthConnection, record: RawHealthRecord) -> bool:
    sample = record.raw_json or {}
    if not recorded_by_watch(sample):
        remove_provider_workouts(session, raw_record_ids=[record.id])
        return False
    details = sample.get("workout") or {}
    activity = str(details.get("activity_type") or "other")
    normalize_provider_workout(
        session,
        account=connection,
        raw_record=record,
        payload={**details, "exerciseType": WORKOUT_TYPES.get(activity, activity)},
        start_time=record.start_time,
        end_time=record.end_time,
    )
    return True


def remove_apple_records(session: Session, raw_record_ids: list[str]) -> None:
    remove_provider_workouts(session, raw_record_ids=raw_record_ids)


def rebuild_apple_health_derived(session: Session, *, user_id: str, start: date, end: date) -> date:
    rebuild_apple_activity_rollups(session, user_id=user_id, start=start, end=end)
    rebuild_apple_sleep_sessions(session, user_id=user_id, start=start, end=end)
    return rebuild_wrist_temperature_variation(session, user_id=user_id, start=start, end=end)


def rebuild_apple_sleep_sessions(session: Session, *, user_id: str, start: date, end: date) -> int:
    records = session.scalars(
        select(RawHealthRecord).where(
            RawHealthRecord.user_id == user_id,
            RawHealthRecord.data_type == SLEEP_ANALYSIS,
            RawHealthRecord.source_platform == APPLE_HEALTH_PLATFORM,
            RawHealthRecord.civil_date >= start - timedelta(days=1),
            RawHealthRecord.civil_date <= end + timedelta(days=1),
        )
    ).all()
    session.execute(
        delete(SleepSession).where(
            SleepSession.user_id == user_id,
            SleepSession.raw_record_id.in_([record.id for record in records]),
            SleepSession.civil_date >= start,
            SleepSession.civil_date <= end,
        )
    )
    segments = sorted(
        (
            record
            for record in records
            if recorded_by_watch(record.raw_json or {})
            and (record.raw_json or {}).get("category_value") in ASLEEP_VALUES | {AWAKE}
        ),
        key=lambda record: (record.start_time, record.end_time),
    )
    profile = get_or_create_profile(session, user_id)
    sessions = [
        sleep_session_from_segments(user_id, group, local_date_for_profile(profile, group[-1].end_time))
        for group in group_segments(segments)
    ]
    sessions = [sleep for sleep in sessions if sleep is not None and start <= sleep.civil_date <= end]
    longest_by_night: dict[date, SleepSession] = {}
    for sleep in sessions:
        current = longest_by_night.get(sleep.civil_date)
        if current is None or (sleep.minutes_asleep or 0) > (current.minutes_asleep or 0):
            longest_by_night[sleep.civil_date] = sleep
    for sleep in sessions:
        sleep.is_main_sleep = longest_by_night[sleep.civil_date] is sleep
    session.add_all(sessions)
    session.flush()
    return len(sessions)


def group_segments(segments: list[RawHealthRecord]) -> list[list[RawHealthRecord]]:
    groups: list[list[RawHealthRecord]] = []
    for segment in segments:
        if groups and segment.start_time - max(item.end_time for item in groups[-1]) <= SLEEP_SESSION_GAP:
            groups[-1].append(segment)
        else:
            groups.append([segment])
    return groups


def sleep_session_from_segments(
    user_id: str, segments: list[RawHealthRecord], wake_date: date
) -> SleepSession | None:
    values = [(segment.raw_json or {}).get("category_value") for segment in segments]
    asleep_minutes = sum(
        minutes_between(segment.start_time, segment.end_time)
        for segment, value in zip(segments, values)
        if value in ASLEEP_VALUES
    )
    if asleep_minutes <= 0:
        return None
    awake_minutes = sum(
        minutes_between(segment.start_time, segment.end_time)
        for segment, value in zip(segments, values)
        if value == AWAKE
    )
    start_time = min(segment.start_time for segment in segments)
    end_time = max(segment.end_time for segment in segments)
    staged = ASLEEP_UNSPECIFIED not in values
    stages = [
        {
            "type": SLEEP_STAGE_NAMES.get(value, "awake"),
            "startTime": segment.start_time.isoformat(),
            "endTime": segment.end_time.isoformat(),
        }
        for segment, value in zip(segments, values)
    ] if staged else []
    return SleepSession(
        user_id=user_id,
        raw_record_id=segments[0].id,
        start_time=start_time,
        end_time=end_time,
        civil_date=wake_date,
        minutes_asleep=round(asleep_minutes),
        minutes_awake=round(awake_minutes),
        minutes_in_sleep_period=round(minutes_between(start_time, end_time)),
        stages_summary=stage_summary(stages),
        stages=stages,
    )


def stage_summary(stages: list[dict[str, str]]) -> list[dict[str, Any]]:
    totals: dict[str, float] = {}
    counts: dict[str, int] = {}
    for stage in stages:
        minutes = minutes_between(
            datetime.fromisoformat(stage["startTime"]), datetime.fromisoformat(stage["endTime"])
        )
        totals[stage["type"]] = totals.get(stage["type"], 0.0) + minutes
        counts[stage["type"]] = counts.get(stage["type"], 0) + 1
    return [
        {"type": stage_type, "minutes": round(minutes), "count": counts[stage_type]}
        for stage_type, minutes in totals.items()
    ]


def minutes_between(start: datetime, end: datetime) -> float:
    return max(0.0, (end - start).total_seconds() / 60)


def rebuild_wrist_temperature_variation(session: Session, *, user_id: str, start: date, end: date) -> date:
    profile = get_or_create_profile(session, user_id)
    last = max(end, min(end + timedelta(days=TEMPERATURE_REFERENCE_DAYS), local_date_for_profile(profile)))
    absolute = session.scalars(
        select(MetricSample)
        .where(
            MetricSample.user_id == user_id,
            MetricSample.metric == WRIST_TEMPERATURE_METRIC,
            MetricSample.civil_date >= start - timedelta(days=TEMPERATURE_REFERENCE_DAYS),
            MetricSample.civil_date <= last,
        )
        .order_by(MetricSample.observed_at)
    ).all()
    session.execute(
        delete(MetricSample).where(
            MetricSample.user_id == user_id,
            MetricSample.metric == SKIN_TEMPERATURE_VARIATION,
            MetricSample.source_platform == APPLE_HEALTH_PLATFORM,
            MetricSample.civil_date >= start,
            MetricSample.civil_date <= last,
        )
    )
    by_night: dict[date, list[MetricSample]] = {}
    for sample in absolute:
        by_night.setdefault(sample.civil_date, []).append(sample)
    nightly = {night: mean(sample.value for sample in samples) for night, samples in by_night.items()}
    for night, samples in sorted(by_night.items()):
        if not start <= night <= last:
            continue
        reference = [
            value
            for other, value in nightly.items()
            if night - timedelta(days=TEMPERATURE_REFERENCE_DAYS) <= other < night
        ]
        if len(reference) < TEMPERATURE_MIN_REFERENCE_NIGHTS:
            continue
        anchor = samples[-1]
        session.add(
            MetricSample(
                user_id=user_id,
                raw_record_id=anchor.raw_record_id,
                metric=SKIN_TEMPERATURE_VARIATION,
                observed_at=anchor.observed_at,
                civil_date=night,
                value=nightly[night] - float(median(reference)),
                unit="celsius",
                source_platform=APPLE_HEALTH_PLATFORM,
                source_device=anchor.source_device,
            )
        )
    session.flush()
    return last


def nightly_window_mean(
    session: Session, user_id: str, sleep: SleepSession | None, metric: str
) -> float | None:
    if sleep is None:
        return None
    values = session.scalars(
        select(MetricSample.value).where(
            MetricSample.user_id == user_id,
            MetricSample.metric == metric,
            MetricSample.source_platform == APPLE_HEALTH_PLATFORM,
            MetricSample.observed_at >= sleep.start_time,
            MetricSample.observed_at <= sleep.end_time,
        )
    ).all()
    return float(mean(values)) if values else None


def rebuild_apple_activity_rollups(session: Session, *, user_id: str, start: date, end: date) -> int:
    zone = timezone_for_profile(get_or_create_profile(session, user_id))
    range_start = datetime.combine(start, time.min, zone)
    range_end = datetime.combine(end + timedelta(days=1), time.min, zone)
    records = session.scalars(
        select(RawHealthRecord).where(
            RawHealthRecord.user_id == user_id,
            RawHealthRecord.source_platform == APPLE_HEALTH_PLATFORM,
            RawHealthRecord.data_type.in_(ROLLUP_DATA_TYPES),
            RawHealthRecord.start_time >= range_start,
            RawHealthRecord.start_time < range_end,
        )
    ).all()
    if not records:
        return 0
    connection = session.get(HealthConnection, records[0].connection_id)
    stored = 0
    for metric, mapping in ROLLUP_MAPPINGS.items():
        usable = [
            high_volume_record(record, metric, mapping)
            for record in records
            if record.data_type in mapping.data_types
            and recorded_by_watch(record.raw_json or {})
            and (record.raw_json or {}).get("unit") == mapping.accepted_unit
            and (record.raw_json or {}).get("value") is not None
        ]
        stored += replace_high_volume_rollups(
            session,
            account=connection,
            metric=metric,
            records=usable,
            range_start=range_start,
            range_end=range_end,
        )
    session.flush()
    return stored


def high_volume_record(record: RawHealthRecord, metric: str, mapping: RollupMapping) -> HighVolumeRecord:
    value = float(record.raw_json["value"])
    timing = (
        {"observed_at": record.start_time}
        if mapping.instant
        else {"start_time": record.start_time, "end_time": record.end_time}
    )
    return HighVolumeRecord(
        data_type=record.data_type,
        metric=metric,
        value=value,
        unit=mapping.unit,
        source_platform=APPLE_HEALTH_PLATFORM,
        source_device=record.source_device,
        civil_date=record.civil_date,
        **timing,
    )
