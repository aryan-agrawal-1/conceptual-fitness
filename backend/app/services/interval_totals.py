from __future__ import annotations

from collections import defaultdict
from datetime import date

from sqlalchemy import select
from sqlalchemy.orm import Session

from app.models import MetricInterval, RawHealthRecord


FITBIT_PREFERRED_ACTIVITY_METRICS = {"steps", "distance", "active_calories"}


def interval_totals_by_date(
    session: Session,
    *,
    user_id: str,
    metrics: set[str],
    start: date,
    end: date,
) -> dict[date, dict[str, float]]:
    if not metrics:
        return {}

    rows = session.execute(
        select(MetricInterval, RawHealthRecord)
        .outerjoin(RawHealthRecord, MetricInterval.raw_record_id == RawHealthRecord.id)
        .where(
            MetricInterval.user_id == user_id,
            MetricInterval.metric.in_(metrics),
            MetricInterval.civil_date >= start,
            MetricInterval.civil_date <= end,
        )
    ).all()
    all_totals: dict[date, dict[str, float]] = defaultdict(lambda: defaultdict(float))
    fitbit_totals: dict[date, dict[str, float]] = defaultdict(lambda: defaultdict(float))

    for interval, raw_record in rows:
        if interval.civil_date is None:
            continue
        all_totals[interval.civil_date][interval.metric] += interval.value
        if (
            interval.metric in FITBIT_PREFERRED_ACTIVITY_METRICS
            and _source_platform(interval, raw_record) == "FITBIT"
        ):
            fitbit_totals[interval.civil_date][interval.metric] += interval.value

    totals: dict[date, dict[str, float]] = defaultdict(dict)
    for day, metric_totals in all_totals.items():
        for metric, total in metric_totals.items():
            fitbit_total = fitbit_totals.get(day, {}).get(metric)
            totals[day][metric] = fitbit_total if fitbit_total is not None else total
    return totals


def _source_platform(interval: MetricInterval, raw_record: RawHealthRecord | None) -> str | None:
    if interval.source_platform:
        return interval.source_platform
    if raw_record is None:
        return None
    if raw_record.source_platform:
        return raw_record.source_platform
    data_source = (raw_record.raw_json or {}).get("dataSource") or {}
    if not isinstance(data_source, dict):
        return None
    platform = data_source.get("platform")
    return str(platform) if platform is not None else None
