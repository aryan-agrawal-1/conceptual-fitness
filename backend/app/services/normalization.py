from __future__ import annotations

import hashlib
import json
from datetime import date, datetime
from typing import Any

from sqlalchemy import delete, select
from sqlalchemy.dialects.postgresql import insert as pg_insert
from sqlalchemy.orm import Session

from app.core.security import utcnow
from app.google_health.data_types import DATA_TYPE_SPECS, DataTypeSpec
from app.models import (
    GoogleAccount,
    MetricInterval,
    MetricSample,
    RawHealthRecord,
    SleepSession,
    Workout,
    new_uuid,
)
from app.services.metric_rollups import HighVolumeRecord

HEART_RATE_BULK_BATCH_SIZE = 2000
BULK_MEASUREMENT_DATA_TYPES = {
    "active-energy-burned",
    "time-in-heart-rate-zone",
    "steps",
    "distance",
    "oxygen-saturation",
}


# take a data point, create the raw record and rebuild the normalised rows derived from it
def upsert_raw_and_normalized(
    session: Session,
    *,
    account: GoogleAccount,
    data_type: str,
    data_point: dict[str, Any],
) -> RawHealthRecord:
    spec = DATA_TYPE_SPECS[data_type]
    raw_hash = _content_hash(data_point)
    source_record_id = (
        data_point.get("name") or data_point.get("dataPointName") or f"{data_type}:{raw_hash}"
    )
    legacy_source_record_id = f"{data_type}:{raw_hash}"
    payload = data_point.get(spec.payload_key, {})
    source = data_point.get("dataSource", {})
    device = source.get("device") or {}

    raw_record = _find_raw_record(
        session,
        account=account,
        data_type=data_type,
        source_record_id=source_record_id,
        legacy_source_record_id=legacy_source_record_id,
    )
    if raw_record is None:
        raw_record = RawHealthRecord(
            user_id=account.user_id,
            google_account_id=account.id,
            data_type=data_type,
            source_record_id=source_record_id,
            raw_json=data_point,
            content_hash=raw_hash,
        )
    else:
        if raw_record.content_hash == raw_hash and raw_record.source_record_id == source_record_id:
            if _normalized_exists(session, raw_record.id, storage=spec.storage):
                return raw_record
        raw_record.raw_json = data_point
        raw_record.content_hash = raw_hash
        raw_record.source_record_id = source_record_id

    raw_record.source_platform = source.get("platform")
    raw_record.source_device = device.get("displayName")
    raw_record.start_time, raw_record.end_time = _record_times(payload)
    raw_record.civil_date = _record_civil_date(payload) or (
        raw_record.start_time.date() if raw_record.start_time else None
    )
    session.add(raw_record)
    session.flush()

    _replace_normalized(session, raw_record.id, storage=spec.storage)
    if spec.storage == "interval":
        _normalize_interval(session, account, raw_record, spec, payload)
    elif spec.storage == "sample":
        _normalize_sample(session, account, raw_record, spec, payload)
    elif spec.storage == "sleep":
        _normalize_sleep(session, account, raw_record, payload)
    elif spec.storage == "workout":
        _normalize_workout(session, account, raw_record, payload)
    return raw_record


def _normalized_exists(session: Session, raw_record_id: str, *, storage: str) -> bool:
    if storage == "raw":
        return True
    models = {
        "interval": MetricInterval,
        "sample": MetricSample,
        "sleep": SleepSession,
        "workout": Workout,
    }
    model = models.get(storage)
    if model is None:
        return False
    return session.scalar(select(model.id).where(model.raw_record_id == raw_record_id).limit(1)) is not None


def _find_raw_record(
    session: Session,
    *,
    account: GoogleAccount,
    data_type: str,
    source_record_id: str,
    legacy_source_record_id: str,
) -> RawHealthRecord | None:
    raw_record = session.scalar(
        select(RawHealthRecord).where(
            RawHealthRecord.google_account_id == account.id,
            RawHealthRecord.data_type == data_type,
            RawHealthRecord.source_record_id == source_record_id,
        )
    )
    if raw_record is not None or source_record_id == legacy_source_record_id:
        return raw_record
    return session.scalar(
        select(RawHealthRecord).where(
            RawHealthRecord.google_account_id == account.id,
            RawHealthRecord.data_type == data_type,
            RawHealthRecord.source_record_id == legacy_source_record_id,
        )
    )


def high_volume_records_for_points(
    *,
    data_type: str,
    points: list[dict[str, Any]],
) -> list[HighVolumeRecord]:
    spec = DATA_TYPE_SPECS[data_type]
    return [
        record
        for point in points
        if (record := _high_volume_record(spec, data_type, point)) is not None
    ]


def upsert_measurement_points_fast(
    session: Session,
    *,
    account: GoogleAccount,
    data_type: str,
    points: list[dict[str, Any]],
) -> int:
    spec = DATA_TYPE_SPECS[data_type]
    bind = session.get_bind()
    if (
        bind.dialect.name != "postgresql"
        or data_type not in BULK_MEASUREMENT_DATA_TYPES
        or spec.storage not in {"interval", "sample"}
    ):
        for point in points:
            upsert_raw_and_normalized(
                session,
                account=account,
                data_type=data_type,
                data_point=point,
            )
        return len(points)

    raw_rows: dict[str, dict[str, Any]] = {}
    normalized_rows_by_source: dict[str, dict[str, Any]] = {}

    for point in points:
        raw_hash = _content_hash(point)
        source_record_id = point.get("name") or point.get("dataPointName") or f"{data_type}:{raw_hash}"
        payload = point.get(spec.payload_key, {})
        if not isinstance(payload, dict):
            payload = {}
        source = point.get("dataSource") or {}
        if not isinstance(source, dict):
            source = {}
        device = source.get("device") or {}
        if not isinstance(device, dict):
            device = {}

        start_time, end_time = _record_times(payload)
        civil_date = _record_civil_date(payload) or (start_time.date() if start_time else None)
        raw_rows[source_record_id] = {
            "id": new_uuid(),
            "user_id": account.user_id,
            "google_account_id": account.id,
            "data_type": data_type,
            "source_record_id": source_record_id,
            "source_platform": source.get("platform"),
            "source_device": device.get("displayName"),
            "start_time": start_time,
            "end_time": end_time,
            "civil_date": civil_date,
            "raw_json": point,
            "content_hash": raw_hash,
            "created_at": utcnow(),
            "updated_at": utcnow(),
        }

        normalized = _measurement_row(account, spec, payload, civil_date, source, device)
        if normalized is not None:
            normalized_rows_by_source[source_record_id] = normalized

    if not raw_rows:
        return 0

    raw_items = list(raw_rows.items())
    for offset in range(0, len(raw_items), HEART_RATE_BULK_BATCH_SIZE):
        raw_batch = dict(raw_items[offset : offset + HEART_RATE_BULK_BATCH_SIZE])
        rows_to_upsert, raw_ids = _changed_raw_rows(
            session,
            account=account,
            data_type=data_type,
            rows_by_source=raw_batch,
        )
        if not rows_to_upsert:
            continue
        raw_ids.update(_bulk_upsert_raw_rows(session, rows_to_upsert))

        normalized_rows: list[dict[str, Any]] = []
        for source_record_id in rows_to_upsert:
            row = normalized_rows_by_source.get(source_record_id)
            raw_record_id = raw_ids.get(source_record_id)
            if row is None or raw_record_id is None:
                continue
            normalized_rows.append({**row, "raw_record_id": raw_record_id})

        changed_raw_ids = [raw_ids[source_record_id] for source_record_id in rows_to_upsert]
        _replace_normalized_many(session, changed_raw_ids, storage=spec.storage)
        if normalized_rows:
            _bulk_upsert_normalized_rows(session, spec, normalized_rows)

    return len(points)


def _changed_raw_rows(
    session: Session,
    *,
    account: GoogleAccount,
    data_type: str,
    rows_by_source: dict[str, dict[str, Any]],
) -> tuple[dict[str, dict[str, Any]], dict[str, str]]:
    existing = {
        source_record_id: (raw_id, content_hash)
        for source_record_id, raw_id, content_hash in session.execute(
            select(
                RawHealthRecord.source_record_id,
                RawHealthRecord.id,
                RawHealthRecord.content_hash,
            ).where(
                RawHealthRecord.google_account_id == account.id,
                RawHealthRecord.data_type == data_type,
                RawHealthRecord.source_record_id.in_(rows_by_source),
            )
        )
    }
    rows_to_upsert: dict[str, dict[str, Any]] = {}
    raw_ids: dict[str, str] = {}
    for source_record_id, row in rows_by_source.items():
        existing_row = existing.get(source_record_id)
        if existing_row is None:
            rows_to_upsert[source_record_id] = row
            continue
        raw_id, content_hash = existing_row
        raw_ids[source_record_id] = raw_id
        if content_hash != row["content_hash"]:
            rows_to_upsert[source_record_id] = row
    return rows_to_upsert, raw_ids


def _bulk_upsert_raw_rows(session: Session, rows_by_source: dict[str, dict[str, Any]]) -> dict[str, str]:
    raw_insert = pg_insert(RawHealthRecord).values(list(rows_by_source.values()))
    raw_upsert = raw_insert.on_conflict_do_update(
        constraint="uq_raw_record",
        set_={
            "source_platform": raw_insert.excluded.source_platform,
            "source_device": raw_insert.excluded.source_device,
            "start_time": raw_insert.excluded.start_time,
            "end_time": raw_insert.excluded.end_time,
            "civil_date": raw_insert.excluded.civil_date,
            "raw_json": raw_insert.excluded.raw_json,
            "content_hash": raw_insert.excluded.content_hash,
            "updated_at": utcnow(),
        },
        where=RawHealthRecord.content_hash.is_distinct_from(raw_insert.excluded.content_hash),
    ).returning(RawHealthRecord.source_record_id, RawHealthRecord.id)
    return dict(session.execute(raw_upsert).all())


def _measurement_row(
    account: GoogleAccount,
    spec: DataTypeSpec,
    payload: dict[str, Any],
    civil_date: date | None,
    source: dict[str, Any],
    device: dict[str, Any],
) -> dict[str, Any] | None:
    value = _metric_numeric_value(spec, payload)
    if spec.storage == "interval":
        start_time, end_time = _record_times(payload)
        if value is None and start_time is not None and end_time is not None:
            value = max(0.0, (end_time - start_time).total_seconds())
        if start_time is None or end_time is None or value is None:
            return None
        return {
            "id": new_uuid(),
            "user_id": account.user_id,
            "metric": spec.metric,
            "start_time": start_time,
            "end_time": end_time,
            "civil_date": civil_date,
            "value": _normalize_interval_value(spec, payload, value),
            "unit": spec.unit,
            "source_platform": source.get("platform"),
            "source_device": device.get("displayName"),
            "created_at": utcnow(),
        }

    observed_at = _sample_time(payload)
    if observed_at is None or value is None:
        return None
    return {
        "id": new_uuid(),
        "user_id": account.user_id,
        "metric": spec.metric,
        "observed_at": observed_at,
        "civil_date": civil_date,
        "value": _normalize_sample_value(spec, payload, value),
        "unit": spec.unit,
        "source_platform": source.get("platform"),
        "source_device": device.get("displayName"),
        "created_at": utcnow(),
    }


def _high_volume_record(
    spec: DataTypeSpec,
    data_type: str,
    point: dict[str, Any],
) -> HighVolumeRecord | None:
    payload = point.get(spec.payload_key, {})
    if not isinstance(payload, dict):
        payload = {}
    source = point.get("dataSource") or {}
    if not isinstance(source, dict):
        source = {}
    device = source.get("device") or {}
    if not isinstance(device, dict):
        device = {}

    start_time, end_time = _record_times(payload)
    civil_date = _record_civil_date(payload) or (start_time.date() if start_time else None)
    value = _metric_numeric_value(spec, payload)
    if spec.storage == "sample":
        observed_at = _sample_time(payload)
        if observed_at is None or value is None:
            return None
        return HighVolumeRecord(
            data_type=data_type,
            metric=spec.metric,
            observed_at=observed_at,
            civil_date=civil_date or observed_at.date(),
            value=_normalize_sample_value(spec, payload, value),
            unit=spec.unit,
            source_platform=source.get("platform"),
            source_device=device.get("displayName"),
        )

    if spec.storage == "interval":
        if value is None and start_time is not None and end_time is not None:
            value = max(0.0, (end_time - start_time).total_seconds())
        if start_time is None or end_time is None or value is None:
            return None
        return HighVolumeRecord(
            data_type=data_type,
            metric=spec.metric,
            start_time=start_time,
            end_time=end_time,
            civil_date=civil_date or start_time.date(),
            value=_normalize_interval_value(spec, payload, value),
            unit=spec.unit,
            source_platform=source.get("platform"),
            source_device=device.get("displayName"),
        )

    return None


def _bulk_upsert_normalized_rows(
    session: Session,
    spec: DataTypeSpec,
    rows: list[dict[str, Any]],
) -> None:
    if spec.storage == "interval":
        interval_insert = pg_insert(MetricInterval).values(rows)
        session.execute(
            interval_insert.on_conflict_do_update(
                constraint="uq_metric_interval",
                set_={
                    "civil_date": interval_insert.excluded.civil_date,
                    "value": interval_insert.excluded.value,
                    "unit": interval_insert.excluded.unit,
                    "source_platform": interval_insert.excluded.source_platform,
                    "source_device": interval_insert.excluded.source_device,
                },
                where=MetricInterval.value.is_distinct_from(interval_insert.excluded.value),
            )
        )
        return

    sample_insert = pg_insert(MetricSample).values(rows)
    session.execute(
        sample_insert.on_conflict_do_update(
            constraint="uq_metric_sample",
            set_={
                "civil_date": sample_insert.excluded.civil_date,
                "value": sample_insert.excluded.value,
                "unit": sample_insert.excluded.unit,
                "source_platform": sample_insert.excluded.source_platform,
                "source_device": sample_insert.excluded.source_device,
            },
            where=MetricSample.value.is_distinct_from(sample_insert.excluded.value),
        )
    )


# delete previously generated normalised rows for this record
def _replace_normalized(session: Session, raw_record_id: str, *, storage: str | None = None) -> None:
    _replace_normalized_many(session, [raw_record_id], storage=storage)


def _replace_normalized_many(
    session: Session,
    raw_record_ids: list[str],
    *,
    storage: str | None = None,
) -> None:
    if not raw_record_ids:
        return
    if storage == "interval":
        models = (MetricInterval,)
    elif storage == "sample":
        models = (MetricSample,)
    elif storage == "sleep":
        models = (SleepSession,)
    elif storage == "workout":
        models = (Workout,)
    elif storage == "raw":
        models = ()
    else:
        models = (MetricInterval, MetricSample, SleepSession, Workout)
    for model in models:
        session.execute(delete(model).where(model.raw_record_id.in_(raw_record_ids)))


def _normalize_interval(
    session: Session,
    account: GoogleAccount,
    raw_record: RawHealthRecord,
    spec: DataTypeSpec,
    payload: dict[str, Any],
) -> None:
    start_time, end_time = _record_times(payload)
    value = _metric_numeric_value(spec, payload)
    if value is None and start_time is not None and end_time is not None:
        value = max(0.0, (end_time - start_time).total_seconds())
    if start_time is None or end_time is None or value is None:
        return
    value = _normalize_interval_value(spec, payload, value)
    session.add(
        MetricInterval(
            user_id=account.user_id,
            raw_record_id=raw_record.id,
            metric=spec.metric,
            start_time=start_time,
            end_time=end_time,
            civil_date=raw_record.civil_date,
            value=value,
            unit=spec.unit,
            source_platform=raw_record.source_platform,
            source_device=raw_record.source_device,
        )
    )


def _normalize_interval_value(spec: DataTypeSpec, payload: dict[str, Any], value: float) -> float:
    if spec.metric == "distance" and "millimeters" in payload and "meters" not in payload:
        return value / 1000
    return value


def _normalize_sample(
    session: Session,
    account: GoogleAccount,
    raw_record: RawHealthRecord,
    spec: DataTypeSpec,
    payload: dict[str, Any],
) -> None:
    observed_at = _sample_time(payload)
    value = _metric_numeric_value(spec, payload)
    if observed_at is None or value is None:
        return
    value = _normalize_sample_value(spec, payload, value)
    session.add(
        MetricSample(
            user_id=account.user_id,
            raw_record_id=raw_record.id,
            metric=spec.metric,
            observed_at=observed_at,
            civil_date=raw_record.civil_date,
            value=value,
            unit=spec.unit,
            source_platform=raw_record.source_platform,
            source_device=raw_record.source_device,
        )
    )


def _normalize_sample_value(spec: DataTypeSpec, payload: dict[str, Any], value: float) -> float:
    if spec.metric == "height" and "heightMillimeters" in payload and "meters" not in payload:
        return value / 1000
    if spec.metric == "weight" and "weightGrams" in payload and "weightKilograms" not in payload:
        return value / 1000
    return value


def _metric_numeric_value(spec: DataTypeSpec, payload: dict[str, Any]) -> float | None:
    if spec.metric == "skin_temperature_variation":
        nightly = _to_float(payload.get("nightlyTemperatureCelsius"))
        baseline = _to_float(payload.get("baselineTemperatureCelsius"))
        if nightly is None or baseline is None:
            return None
        return nightly - baseline
    return _extract_numeric_value(payload)


def _normalize_sleep(
    session: Session,
    account: GoogleAccount,
    raw_record: RawHealthRecord,
    payload: dict[str, Any],
) -> None:
    start_time, end_time = _record_times(payload)
    if start_time is None or end_time is None:
        return
    summary = payload.get("summary") or {}
    metadata = payload.get("metadata") or {}
    session.add(
        SleepSession(
            user_id=account.user_id,
            raw_record_id=raw_record.id,
            start_time=start_time,
            end_time=end_time,
            civil_date=raw_record.civil_date or end_time.date(),
            minutes_asleep=_to_int(summary.get("minutesAsleep")),
            minutes_awake=_to_int(summary.get("minutesAwake")),
            minutes_in_sleep_period=_to_int(summary.get("minutesInSleepPeriod")),
            stages_summary=summary.get("stagesSummary") or [],
            stages=payload.get("stages") or [],
            is_main_sleep=bool(metadata.get("main")),
        )
    )


def _normalize_workout(
    session: Session,
    account: GoogleAccount,
    raw_record: RawHealthRecord,
    payload: dict[str, Any],
) -> None:
    start_time, end_time = _record_times(payload)
    if start_time is None or end_time is None:
        return
    session.add(
        Workout(
            user_id=account.user_id,
            raw_record_id=raw_record.id,
            workout_type=payload.get("exerciseType") or payload.get("activityType") or payload.get("type"),
            start_time=start_time,
            end_time=end_time,
            civil_date=raw_record.civil_date or start_time.date(),
            duration_seconds=int((end_time - start_time).total_seconds()),
            raw_summary=payload,
        )
    )


# create the hash which acts as a fingerprint for the record
def _content_hash(payload: dict[str, Any]) -> str:
    encoded = json.dumps(payload, sort_keys=True, separators=(",", ":")).encode("utf-8")
    return hashlib.sha256(encoded).hexdigest()


def _record_times(payload: dict[str, Any]) -> tuple[datetime | None, datetime | None]:
    interval = payload.get("interval") or {}
    start_time = _parse_datetime(interval.get("startTime"))
    end_time = _parse_datetime(interval.get("endTime"))
    if start_time is None:
        start_time = _parse_civil_datetime(interval.get("civilStartTime"))
    if end_time is None:
        end_time = _parse_civil_datetime(interval.get("civilEndTime"))
    return start_time, end_time


def _sample_time(payload: dict[str, Any]) -> datetime | None:
    sample_time = payload.get("sampleTime") or payload.get("time") or {}
    if isinstance(sample_time, str):
        return _parse_datetime(sample_time)
    parsed = _parse_datetime(sample_time.get("physicalTime") or sample_time.get("time"))
    if parsed is not None:
        return parsed
    return _parse_civil_datetime(payload.get("civilTime") or payload.get("date"))


def _record_civil_date(payload: dict[str, Any]) -> date | None:
    interval = payload.get("interval") or {}
    for key in ("civilStartTime", "civilEndTime", "civilTime", "date"):
        value = interval.get(key) or payload.get(key)
        parsed = _parse_civil_date(value)
        if parsed:
            return parsed
    sample = payload.get("sampleTime") or {}
    if isinstance(sample, dict):
        return _parse_civil_date(sample.get("civilTime"))
    return None


def _parse_datetime(value: str | None) -> datetime | None:
    if not value:
        return None
    cleaned = value.replace("Z", "+00:00")
    return datetime.fromisoformat(cleaned)


def _parse_civil_date(value: dict[str, Any] | None) -> date | None:
    if not isinstance(value, dict):
        return None
    date_value = value.get("date") or value
    try:
        return date(int(date_value["year"]), int(date_value["month"]), int(date_value["day"]))
    except (KeyError, TypeError, ValueError):
        return None


def _parse_civil_datetime(value: dict[str, Any] | None) -> datetime | None:
    if not isinstance(value, dict):
        return None
    parsed_date = _parse_civil_date(value)
    if parsed_date is None:
        return None
    time_value = value.get("time") or {}
    if not isinstance(time_value, dict):
        time_value = {}
    try:
        return datetime(
            parsed_date.year,
            parsed_date.month,
            parsed_date.day,
            int(time_value.get("hours") or 0),
            int(time_value.get("minutes") or 0),
            int(time_value.get("seconds") or 0),
        )
    except (TypeError, ValueError):
        return datetime(parsed_date.year, parsed_date.month, parsed_date.day)


def _extract_numeric_value(payload: dict[str, Any]) -> float | None:
    priority_keys = (
        "count",
        "countSum",
        "value",
        "bpm",
        "beatsPerMinute",
        "percentage",
        "rate",
        "mean",
        "average",
        "avg",
        "milliseconds",
        "duration",
        "durationSeconds",
        "seconds",
        "calories",
        "kilocalories",
        "meters",
        "heightMeters",
        "distanceMeters",
        "beatsPerMinute",
        "breathsPerMinute",
        "heightMillimeters",
        "weightKilograms",
        "weightGrams",
        "vo2MillilitersPerMinuteKilogram",
        "millilitersPerMinuteKilogram",
        "bloodGlucoseMilligramsPerDeciliter",
        "minBeatsPerMinute",
        "maxBeatsPerMinute",
        "lowerBound",
        "upperBound",
    )
    for key in priority_keys:
        if key in payload:
            value = _to_float(payload[key])
            if value is not None:
                return value
    for key, value in payload.items():
        if key.lower().endswith(("time", "date")) or key in {"interval", "sampleTime", "metadata"}:
            continue
        if isinstance(value, (int, float, str)):
            parsed = _to_float(value)
            if parsed is not None:
                return parsed
        if isinstance(value, dict):
            parsed = _extract_numeric_value(value)
            if parsed is not None:
                return parsed
    return None


def _to_float(value: Any) -> float | None:
    if value is None or isinstance(value, bool):
        return None
    try:
        return float(value)
    except (TypeError, ValueError):
        return None


def _to_int(value: Any) -> int | None:
    parsed = _to_float(value)
    return int(parsed) if parsed is not None else None
