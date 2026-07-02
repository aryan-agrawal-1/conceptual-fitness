from __future__ import annotations

from dataclasses import dataclass
from datetime import date, datetime, timedelta
from typing import Literal

from sqlalchemy import delete, select
from sqlalchemy.orm import Session

from app.core.security import utcnow
from app.models import (
    DailyBaseline,
    GoogleAccount,
    MetricDailyRollup,
    MetricHourlyRollup,
    MetricInterval,
    MetricMinuteRollup,
    MetricSample,
    RawHealthRecord,
)


HIGH_VOLUME_DATA_TYPES = {
    "heart-rate",
    "time-in-heart-rate-zone",
    "active-energy-burned",
    "oxygen-saturation",
    "steps",
    "distance",
}
HIGH_VOLUME_METRICS = {
    "heart_rate",
    "time_in_heart_rate_zone",
    "active_calories",
    "oxygen_saturation",
    "steps",
    "distance",
}
MINUTE_ROLLUP_METRICS = {"heart_rate"}
HOURLY_ROLLUP_METRICS = {"steps"}
SUM_METRICS = {"time_in_heart_rate_zone", "active_calories", "steps", "distance"}
SOURCE_PLATFORM_PRIORITY = {
    "FITBIT": 0,
    "HEALTH_KIT": 1,
}
EPHEMERAL_RAW_DATA_TYPES = HIGH_VOLUME_DATA_TYPES | {
    "active-zone-minutes",
    "heart-rate-variability",
}
EPHEMERAL_INTERVAL_METRICS = HIGH_VOLUME_METRICS | {"active_zone_minutes"}
RAW_RECORD_RETENTION_DAYS = 2
HEART_RATE_MINUTE_RETENTION_DAYS = 14
STEP_HOURLY_RETENTION_DAYS = 90
BASELINE_RETENTION_DAYS = 180


@dataclass(frozen=True)
class HighVolumeRecord:
    data_type: str
    metric: str
    value: float
    unit: str
    source_platform: str | None
    source_device: str | None
    civil_date: date | None
    observed_at: datetime | None = None
    start_time: datetime | None = None
    end_time: datetime | None = None


@dataclass(frozen=True)
class RollupPoint:
    observed_at: datetime
    civil_date: date | None
    value: float
    unit: str
    source_platform: str | None = None
    source_device: str | None = None


@dataclass
class _Aggregate:
    user_id: str
    metric: str
    civil_date: date
    unit: str
    source_platform: str | None
    source_device: str | None
    sum_value: float = 0.0
    sample_count: int = 0
    min_value: float | None = None
    max_value: float | None = None

    @property
    def avg_value(self) -> float | None:
        if self.sample_count <= 0:
            return None
        return self.sum_value / self.sample_count

    def add(self, value: float, *, count: int = 1) -> None:
        self.sum_value += value
        self.sample_count += count
        self.min_value = value if self.min_value is None else min(self.min_value, value)
        self.max_value = value if self.max_value is None else max(self.max_value, value)


def replace_high_volume_rollups(
    session: Session,
    *,
    account: GoogleAccount,
    metric: str,
    records: list[HighVolumeRecord],
    range_start: datetime,
    range_end: datetime,
) -> int:
    bucket_start = _truncate_minute(range_start)
    bucket_end = _ceil_minute(range_end)
    affected_dates = _dates_in_range(bucket_start, bucket_end)
    affected_dates.update(record.civil_date for record in records if record.civil_date is not None)

    _delete_count(
        session,
        delete(MetricMinuteRollup).where(
            MetricMinuteRollup.user_id == account.user_id,
            MetricMinuteRollup.metric == metric,
            MetricMinuteRollup.bucket_start >= bucket_start,
            MetricMinuteRollup.bucket_start < bucket_end,
        ),
    )
    if metric not in MINUTE_ROLLUP_METRICS:
        if metric in HOURLY_ROLLUP_METRICS:
            _delete_count(
                session,
                delete(MetricHourlyRollup).where(
                    MetricHourlyRollup.user_id == account.user_id,
                    MetricHourlyRollup.metric == metric,
                    MetricHourlyRollup.bucket_start >= _truncate_hour(range_start),
                    MetricHourlyRollup.bucket_start < _ceil_hour(range_end),
                ),
            )
            hourly_aggregates = _build_hourly_aggregates(account.user_id, records)
            _insert_hourly_aggregates(session, hourly_aggregates)
            session.flush()
            _rebuild_daily_rollups_from_hourly(
                session,
                user_id=account.user_id,
                metrics={metric},
                dates=affected_dates,
            )
            return len(records)
        daily_aggregates = _build_daily_aggregates(account.user_id, records)
        _replace_daily_aggregates(
            session,
            user_id=account.user_id,
            metrics={metric},
            dates=affected_dates,
            aggregates=daily_aggregates,
        )
        return len(records)

    minute_aggregates = _build_minute_aggregates(account.user_id, records)
    _insert_minute_aggregates(session, minute_aggregates)
    session.flush()
    _rebuild_daily_rollups(
        session,
        user_id=account.user_id,
        metrics={metric},
        dates=affected_dates,
    )
    return len(records)


def rollup_points_for_metric(
    session: Session,
    *,
    user_id: str,
    metric: str,
    start: date,
    end: date,
) -> list[RollupPoint]:
    rows = session.scalars(
        select(MetricMinuteRollup)
        .where(
            MetricMinuteRollup.user_id == user_id,
            MetricMinuteRollup.metric == metric,
            MetricMinuteRollup.civil_date >= start,
            MetricMinuteRollup.civil_date <= end,
        )
        .order_by(MetricMinuteRollup.bucket_start)
    ).all()
    return [_point_from_minute_rollup(row) for row in rows if row.avg_value is not None]


def hourly_rollup_points_for_metric(
    session: Session,
    *,
    user_id: str,
    metric: str,
    start: date,
    end: date,
) -> list[RollupPoint]:
    rows = session.scalars(
        select(MetricHourlyRollup)
        .where(
            MetricHourlyRollup.user_id == user_id,
            MetricHourlyRollup.metric == metric,
            MetricHourlyRollup.civil_date >= start,
            MetricHourlyRollup.civil_date <= end,
        )
        .order_by(MetricHourlyRollup.bucket_start)
    ).all()
    return [_point_from_hourly_rollup(row) for row in rows if row.sum_value is not None]


def daily_rollup_values(
    session: Session,
    *,
    user_id: str,
    metric: str,
    start: date,
    end: date,
    value_kind: Literal["avg", "sum", "min", "max"] = "avg",
) -> dict[date, float]:
    rows = session.scalars(
        select(MetricDailyRollup).where(
            MetricDailyRollup.user_id == user_id,
            MetricDailyRollup.metric == metric,
            MetricDailyRollup.civil_date >= start,
            MetricDailyRollup.civil_date <= end,
        )
    ).all()
    values: dict[date, float] = {}
    for row in rows:
        value = _daily_value(row, value_kind)
        if value is not None:
            values[row.civil_date] = value
    return values


def cleanup_high_volume_storage(
    session: Session,
    *,
    today: date,
) -> dict[str, int]:
    raw_cutoff = today - timedelta(days=RAW_RECORD_RETENTION_DAYS)
    heart_rate_minute_cutoff = today - timedelta(days=HEART_RATE_MINUTE_RETENTION_DAYS)
    step_hourly_cutoff = today - timedelta(days=STEP_HOURLY_RETENTION_DAYS)
    baseline_cutoff = today - timedelta(days=BASELINE_RETENTION_DAYS)
    counts: dict[str, int] = {}
    counts["metric_samples"] = _delete_count(
        session,
        delete(MetricSample).where(
            MetricSample.metric.in_(HIGH_VOLUME_METRICS),
            MetricSample.civil_date < raw_cutoff,
        ),
    )
    counts["intraday_hrv_samples"] = _delete_count(
        session,
        delete(MetricSample).where(
            MetricSample.raw_record_id.in_(
                select(RawHealthRecord.id).where(
                    RawHealthRecord.data_type == "heart-rate-variability",
                    RawHealthRecord.civil_date < raw_cutoff,
                )
            )
        ),
    )
    counts["metric_intervals"] = _delete_count(
        session,
        delete(MetricInterval).where(
            MetricInterval.metric.in_(EPHEMERAL_INTERVAL_METRICS),
            MetricInterval.civil_date < raw_cutoff,
        ),
    )
    counts["raw_health_records"] = _delete_count(
        session,
        delete(RawHealthRecord).where(
            RawHealthRecord.data_type.in_(EPHEMERAL_RAW_DATA_TYPES),
            RawHealthRecord.civil_date < raw_cutoff,
        ),
    )
    counts["metric_minute_rollups"] = _delete_count(
        session,
        delete(MetricMinuteRollup).where(
            (MetricMinuteRollup.metric.not_in(MINUTE_ROLLUP_METRICS))
            | (MetricMinuteRollup.civil_date < heart_rate_minute_cutoff)
        ),
    )
    counts["metric_hourly_rollups"] = _delete_count(
        session,
        delete(MetricHourlyRollup).where(
            (MetricHourlyRollup.metric.not_in(HOURLY_ROLLUP_METRICS))
            | (MetricHourlyRollup.civil_date < step_hourly_cutoff)
        ),
    )
    counts["daily_baselines"] = _delete_count(
        session,
        delete(DailyBaseline).where(DailyBaseline.baseline_date < baseline_cutoff),
    )
    return counts


def _delete_count(session: Session, statement) -> int:
    result = session.execute(statement)
    return int(result.rowcount or 0)


def _build_minute_aggregates(
    user_id: str,
    records: list[HighVolumeRecord],
) -> dict[tuple[str, datetime], _Aggregate]:
    minute_aggregates: dict[tuple[str, datetime], _Aggregate] = {}
    for record in records:
        for bucket_start, value in _minute_values(record):
            civil_date = record.civil_date or bucket_start.date()
            minute = minute_aggregates.setdefault(
                (record.metric, bucket_start),
                _Aggregate(
                    user_id=user_id,
                    metric=record.metric,
                    civil_date=civil_date,
                    unit=record.unit,
                    source_platform=record.source_platform,
                    source_device=record.source_device,
                ),
            )
            minute.add(value)
    return minute_aggregates


def _build_hourly_aggregates(
    user_id: str,
    records: list[HighVolumeRecord],
) -> dict[tuple[str, datetime], _Aggregate]:
    source_aggregates: dict[tuple[str, datetime, str | None], _Aggregate] = {}
    for record in records:
        for bucket_start, value in _hour_values(record):
            civil_date = record.civil_date or bucket_start.date()
            aggregate = source_aggregates.setdefault(
                (record.metric, bucket_start, record.source_platform),
                _Aggregate(
                    user_id=user_id,
                    metric=record.metric,
                    civil_date=civil_date,
                    unit=record.unit,
                    source_platform=record.source_platform,
                    source_device=record.source_device,
                ),
            )
            aggregate.add(value)

    hourly_aggregates: dict[tuple[str, datetime], _Aggregate] = {}
    for (_metric, bucket_start, _source), aggregate in source_aggregates.items():
        hourly_key = (aggregate.metric, bucket_start)
        current = hourly_aggregates.get(hourly_key)
        if current is None or _source_sort_key(aggregate) < _source_sort_key(current):
            hourly_aggregates[hourly_key] = aggregate
    return hourly_aggregates


def _build_daily_aggregates(
    user_id: str,
    records: list[HighVolumeRecord],
) -> dict[tuple[str, date], _Aggregate]:
    source_aggregates: dict[tuple[str, date, str | None], _Aggregate] = {}
    for record in records:
        civil_date = record.civil_date or _record_date(record)
        if civil_date is None:
            continue
        aggregate = source_aggregates.setdefault(
            (record.metric, civil_date, record.source_platform),
            _Aggregate(
                user_id=user_id,
                metric=record.metric,
                civil_date=civil_date,
                unit=record.unit,
                source_platform=record.source_platform,
                source_device=record.source_device,
            ),
        )
        aggregate.add(record.value)
    daily_aggregates: dict[tuple[str, date], _Aggregate] = {}
    for aggregate in source_aggregates.values():
        key = (aggregate.metric, aggregate.civil_date)
        current = daily_aggregates.get(key)
        if current is None or _source_sort_key(aggregate) < _source_sort_key(current):
            daily_aggregates[key] = aggregate
    return daily_aggregates


def _source_sort_key(aggregate: _Aggregate) -> tuple[int, int, float, str]:
    priority = SOURCE_PLATFORM_PRIORITY.get(aggregate.source_platform or "", 100)
    return (
        priority,
        -aggregate.sample_count,
        -(aggregate.sum_value or 0.0),
        aggregate.source_platform or "",
    )


def _record_date(record: HighVolumeRecord) -> date | None:
    if record.observed_at is not None:
        return record.observed_at.date()
    if record.start_time is not None:
        return record.start_time.date()
    return None


def _minute_values(record: HighVolumeRecord) -> list[tuple[datetime, float]]:
    if record.observed_at is not None:
        return [(_truncate_minute(record.observed_at), record.value)]
    if record.start_time is None or record.end_time is None or record.end_time <= record.start_time:
        return []
    duration = (record.end_time - record.start_time).total_seconds()
    cursor = _truncate_minute(record.start_time)
    values: list[tuple[datetime, float]] = []
    while cursor < record.end_time:
        next_minute = cursor + timedelta(minutes=1)
        overlap = max(
            0.0,
            (min(record.end_time, next_minute) - max(record.start_time, cursor)).total_seconds(),
        )
        if overlap > 0:
            values.append((cursor, record.value * overlap / duration))
        cursor = next_minute
    return values


def _hour_values(record: HighVolumeRecord) -> list[tuple[datetime, float]]:
    if record.observed_at is not None:
        return [(_truncate_hour(record.observed_at), record.value)]
    if record.start_time is None or record.end_time is None or record.end_time <= record.start_time:
        return []
    duration = (record.end_time - record.start_time).total_seconds()
    cursor = _truncate_hour(record.start_time)
    values: list[tuple[datetime, float]] = []
    while cursor < record.end_time:
        next_hour = cursor + timedelta(hours=1)
        overlap = max(
            0.0,
            (min(record.end_time, next_hour) - max(record.start_time, cursor)).total_seconds(),
        )
        if overlap > 0:
            values.append((cursor, record.value * overlap / duration))
        cursor = next_hour
    return values


def _insert_minute_aggregates(
    session: Session,
    aggregates: dict[tuple[str, datetime], _Aggregate],
) -> None:
    now = utcnow()
    for (_metric, bucket_start), aggregate in aggregates.items():
        session.add(
            MetricMinuteRollup(
                user_id=aggregate.user_id,
                metric=aggregate.metric,
                bucket_start=bucket_start,
                civil_date=aggregate.civil_date,
                avg_value=aggregate.avg_value,
                min_value=aggregate.min_value,
                max_value=aggregate.max_value,
                sum_value=aggregate.sum_value,
                sample_count=aggregate.sample_count,
                unit=aggregate.unit,
                source_platform=aggregate.source_platform,
                source_device=aggregate.source_device,
                created_at=now,
                updated_at=now,
            )
        )


def _insert_hourly_aggregates(
    session: Session,
    aggregates: dict[tuple[str, datetime], _Aggregate],
) -> None:
    now = utcnow()
    for (_metric, bucket_start), aggregate in aggregates.items():
        session.add(
            MetricHourlyRollup(
                user_id=aggregate.user_id,
                metric=aggregate.metric,
                bucket_start=bucket_start,
                civil_date=aggregate.civil_date,
                avg_value=aggregate.avg_value,
                min_value=aggregate.min_value,
                max_value=aggregate.max_value,
                sum_value=aggregate.sum_value,
                sample_count=aggregate.sample_count,
                unit=aggregate.unit,
                source_platform=aggregate.source_platform,
                source_device=aggregate.source_device,
                created_at=now,
                updated_at=now,
            )
        )


def _rebuild_daily_rollups(
    session: Session,
    *,
    user_id: str,
    metrics: set[str],
    dates: set[date],
) -> None:
    if not metrics or not dates:
        return
    rows = session.scalars(
        select(MetricMinuteRollup).where(
            MetricMinuteRollup.user_id == user_id,
            MetricMinuteRollup.metric.in_(metrics),
            MetricMinuteRollup.civil_date.in_(dates),
        )
    ).all()
    aggregates: dict[tuple[str, date], _Aggregate] = {}
    for row in rows:
        aggregate = aggregates.setdefault(
            (row.metric, row.civil_date),
            _Aggregate(
                user_id=user_id,
                metric=row.metric,
                civil_date=row.civil_date,
                unit=row.unit,
                source_platform=row.source_platform,
                source_device=row.source_device,
            ),
        )
        aggregate.sum_value += row.sum_value or 0.0
        aggregate.sample_count += row.sample_count or 0
        aggregate.min_value = _merge_min(aggregate.min_value, row.min_value)
        aggregate.max_value = _merge_max(aggregate.max_value, row.max_value)
    _replace_daily_aggregates(
        session,
        user_id=user_id,
        metrics=metrics,
        dates=dates,
        aggregates=aggregates,
    )


def _rebuild_daily_rollups_from_hourly(
    session: Session,
    *,
    user_id: str,
    metrics: set[str],
    dates: set[date],
) -> None:
    if not metrics or not dates:
        return
    rows = session.scalars(
        select(MetricHourlyRollup).where(
            MetricHourlyRollup.user_id == user_id,
            MetricHourlyRollup.metric.in_(metrics),
            MetricHourlyRollup.civil_date.in_(dates),
        )
    ).all()
    aggregates: dict[tuple[str, date], _Aggregate] = {}
    for row in rows:
        aggregate = aggregates.setdefault(
            (row.metric, row.civil_date),
            _Aggregate(
                user_id=user_id,
                metric=row.metric,
                civil_date=row.civil_date,
                unit=row.unit,
                source_platform=row.source_platform,
                source_device=row.source_device,
            ),
        )
        aggregate.sum_value += row.sum_value or 0.0
        aggregate.sample_count += row.sample_count or 0
        aggregate.min_value = _merge_min(aggregate.min_value, row.min_value)
        aggregate.max_value = _merge_max(aggregate.max_value, row.max_value)
    _replace_daily_aggregates(
        session,
        user_id=user_id,
        metrics=metrics,
        dates=dates,
        aggregates=aggregates,
    )


def _replace_daily_aggregates(
    session: Session,
    *,
    user_id: str,
    metrics: set[str],
    dates: set[date],
    aggregates: dict[tuple[str, date], _Aggregate],
) -> None:
    if not metrics or not dates:
        return
    session.execute(
        delete(MetricDailyRollup).where(
            MetricDailyRollup.user_id == user_id,
            MetricDailyRollup.metric.in_(metrics),
            MetricDailyRollup.civil_date.in_(dates),
        )
    )
    now = utcnow()
    for aggregate in aggregates.values():
        session.add(
            MetricDailyRollup(
                user_id=user_id,
                metric=aggregate.metric,
                civil_date=aggregate.civil_date,
                avg_value=aggregate.avg_value,
                min_value=aggregate.min_value,
                max_value=aggregate.max_value,
                sum_value=aggregate.sum_value,
                sample_count=aggregate.sample_count,
                unit=aggregate.unit,
                metadata_json={},
                created_at=now,
                updated_at=now,
            )
        )


def _point_from_minute_rollup(row: MetricMinuteRollup) -> RollupPoint:
    value = row.sum_value if row.metric in SUM_METRICS else row.avg_value
    return RollupPoint(
        observed_at=row.bucket_start,
        civil_date=row.civil_date,
        value=float(value or 0.0),
        unit=row.unit,
        source_platform=row.source_platform,
        source_device=row.source_device,
    )


def _point_from_hourly_rollup(row: MetricHourlyRollup) -> RollupPoint:
    value = row.sum_value if row.metric in SUM_METRICS else row.avg_value
    return RollupPoint(
        observed_at=row.bucket_start,
        civil_date=row.civil_date,
        value=float(value or 0.0),
        unit=row.unit,
        source_platform=row.source_platform,
        source_device=row.source_device,
    )


def _daily_value(row: MetricDailyRollup, value_kind: str) -> float | None:
    if value_kind == "sum":
        return row.sum_value
    if value_kind == "min":
        return row.min_value
    if value_kind == "max":
        return row.max_value
    return row.avg_value


def _truncate_minute(value: datetime) -> datetime:
    return value.replace(second=0, microsecond=0)


def _truncate_hour(value: datetime) -> datetime:
    return value.replace(minute=0, second=0, microsecond=0)


def _ceil_minute(value: datetime) -> datetime:
    truncated = _truncate_minute(value)
    if truncated == value:
        return truncated
    return truncated + timedelta(minutes=1)


def _ceil_hour(value: datetime) -> datetime:
    truncated = _truncate_hour(value)
    if truncated == value:
        return truncated
    return truncated + timedelta(hours=1)


def _dates_in_range(start: datetime, end: datetime) -> set[date]:
    if end <= start:
        return {start.date()}
    dates: set[date] = set()
    current = start.date()
    final = (end - timedelta(microseconds=1)).date()
    while current <= final:
        dates.add(current)
        current = date.fromordinal(current.toordinal() + 1)
    return dates


def _merge_min(left: float | None, right: float | None) -> float | None:
    if left is None:
        return right
    if right is None:
        return left
    return min(left, right)


def _merge_max(left: float | None, right: float | None) -> float | None:
    if left is None:
        return right
    if right is None:
        return left
    return max(left, right)
