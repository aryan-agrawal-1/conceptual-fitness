from __future__ import annotations

import hashlib
import json
import logging
from dataclasses import dataclass, field
from datetime import date, datetime

from sqlalchemy import delete, select
from sqlalchemy.orm import Session

from app.core.security import token_digest, utcnow
from app.models import (
    ConnectionStatus,
    DeletedDeviceRecord,
    DeviceSyncProgress,
    HealthConnection,
    RawHealthRecord,
    SyncStatus,
    User,
)
from app.services.health_dates import get_or_create_profile, local_date_for_profile
from app.services.normalization import remove_normalized_records
from app.services.oauth import disconnect_other_connections, revoke_replaced_tokens

logger = logging.getLogger(__name__)

APPLE_HEALTH_PROVIDER = "apple_health"
APPLE_HEALTH_PLATFORM = "APPLE_HEALTH"
SLEEP_ANALYSIS = "HKCategoryTypeIdentifierSleepAnalysis"
WORKOUT = "HKWorkoutTypeIdentifier"
APPLE_HEALTH_DATA_TYPES = frozenset(
    {
        "HKQuantityTypeIdentifierHeartRate",
        "HKQuantityTypeIdentifierRestingHeartRate",
        "HKQuantityTypeIdentifierHeartRateVariabilitySDNN",
        "HKQuantityTypeIdentifierRespiratoryRate",
        "HKQuantityTypeIdentifierOxygenSaturation",
        "HKQuantityTypeIdentifierAppleSleepingWristTemperature",
        "HKQuantityTypeIdentifierStepCount",
        "HKQuantityTypeIdentifierDistanceWalkingRunning",
        "HKQuantityTypeIdentifierActiveEnergyBurned",
        "HKQuantityTypeIdentifierBasalEnergyBurned",
        "HKQuantityTypeIdentifierVO2Max",
        "HKQuantityTypeIdentifierBodyMass",
        "HKQuantityTypeIdentifierHeight",
        SLEEP_ANALYSIS,
        WORKOUT,
    }
)
PHASES = frozenset({"current", "historical"})


class DeviceIngestionError(RuntimeError):
    pass


@dataclass(frozen=True)
class DeviceBatch:
    data_type: str
    phase: str
    range_start: date
    range_end: date
    samples: list[dict] = field(default_factory=list)
    deleted_ids: list[str] = field(default_factory=list)
    anchor: str | None = None
    final: bool = False


@dataclass(frozen=True)
class DeviceBatchResult:
    stored: int
    unchanged: int
    ignored: int
    deleted: int
    progress: DeviceSyncProgress
    rebuild_range: tuple[date, date] | None


def active_apple_health_connection(session: Session, user_id: str) -> HealthConnection | None:
    return session.scalar(
        select(HealthConnection).where(
            HealthConnection.user_id == user_id,
            HealthConnection.provider == APPLE_HEALTH_PROVIDER,
            HealthConnection.status != ConnectionStatus.disconnected,
        )
    )


async def connect_apple_health(session: Session, user: User) -> HealthConnection:
    session.execute(select(User.id).where(User.id == user.id).with_for_update())
    connection = session.scalar(
        select(HealthConnection).where(
            HealthConnection.user_id == user.id,
            HealthConnection.provider == APPLE_HEALTH_PROVIDER,
        )
    )
    replaced_tokens = disconnect_other_connections(session, user.id, keep=connection)
    if connection is None:
        connection = HealthConnection(user_id=user.id, provider=APPLE_HEALTH_PROVIDER)
    elif connection.status == ConnectionStatus.disconnected:
        connection.connected_at = utcnow()
    connection.status = ConnectionStatus.connected
    connection.disconnected_at = None
    connection.last_error = None
    session.add(connection)
    session.commit()
    session.refresh(connection)
    if replaced_tokens:
        from app.google_health.client import GoogleHealthClient

        await revoke_replaced_tokens(GoogleHealthClient(), replaced_tokens)
    return connection


def ingest_device_batch(session: Session, connection: HealthConnection, batch: DeviceBatch) -> DeviceBatchResult:
    if batch.data_type not in APPLE_HEALTH_DATA_TYPES:
        raise DeviceIngestionError("Unsupported data type")
    if batch.phase not in PHASES or batch.range_start > batch.range_end:
        raise DeviceIngestionError("Invalid sync window")

    profile = get_or_create_profile(session, connection.user_id)
    affected_dates: set[date] = set()
    sample_ids = [sample["id"] for sample in batch.samples]
    tombstoned = set(
        session.scalars(
            select(DeletedDeviceRecord.source_record_id).where(
                DeletedDeviceRecord.connection_id == connection.id,
                DeletedDeviceRecord.source_record_id.in_(sample_ids + batch.deleted_ids),
            )
        )
    )
    existing = {
        record.source_record_id: record
        for record in session.scalars(
            select(RawHealthRecord).where(
                RawHealthRecord.connection_id == connection.id,
                RawHealthRecord.data_type == batch.data_type,
                RawHealthRecord.source_record_id.in_(sample_ids),
            )
        )
    }

    stored = unchanged = ignored = 0
    for sample in batch.samples:
        if sample["id"] in tombstoned:
            ignored += 1
            continue
        content_hash = sample_hash(sample)
        record = existing.get(sample["id"])
        if record is not None and record.content_hash == content_hash:
            unchanged += 1
            continue
        if record is None:
            record = RawHealthRecord(
                user_id=connection.user_id,
                connection_id=connection.id,
                data_type=batch.data_type,
                source_record_id=sample["id"],
            )
            existing[sample["id"]] = record
        elif record.civil_date:
            affected_dates.add(record.civil_date)
        start_time, end_time = parse_instant(sample["start"]), parse_instant(sample["end"])
        source = sample.get("source") or {}
        record.raw_json = sample
        record.content_hash = content_hash
        record.source_platform = APPLE_HEALTH_PLATFORM
        record.source_device = source.get("device_name") or source.get("name")
        record.start_time = start_time
        record.end_time = end_time
        record.civil_date = local_date_for_profile(
            profile, end_time if batch.data_type == SLEEP_ANALYSIS else start_time
        )
        affected_dates.add(record.civil_date)
        session.add(record)
        stored += 1

    new_tombstones = [record_id for record_id in dict.fromkeys(batch.deleted_ids) if record_id not in tombstoned]
    deleted_records = session.scalars(
        select(RawHealthRecord).where(
            RawHealthRecord.connection_id == connection.id,
            RawHealthRecord.source_record_id.in_(batch.deleted_ids),
        )
    ).all() if batch.deleted_ids else []
    affected_dates.update(record.civil_date for record in deleted_records if record.civil_date)
    remove_normalized_records(session, [record.id for record in deleted_records])
    if deleted_records:
        session.execute(
            delete(RawHealthRecord).where(RawHealthRecord.id.in_([record.id for record in deleted_records]))
        )
    session.add_all(
        DeletedDeviceRecord(connection_id=connection.id, source_record_id=record_id)
        for record_id in new_tombstones
    )

    progress = progress_for(session, connection, batch)
    progress.samples_received += len(batch.samples)
    progress.deletions_received += len(batch.deleted_ids)
    progress.anchor = batch.anchor or progress.anchor
    if affected_dates:
        pending = affected_dates | {
            day for day in (progress.pending_rebuild_start, progress.pending_rebuild_end) if day
        }
        progress.pending_rebuild_start, progress.pending_rebuild_end = min(pending), max(pending)
    rebuild_range = None
    if batch.final:
        progress.status = SyncStatus.succeeded
        progress.completed_at = utcnow()
        if progress.pending_rebuild_start and progress.pending_rebuild_end:
            rebuild_range = (progress.pending_rebuild_start, progress.pending_rebuild_end)
        if batch.phase == "current":
            connection.last_sync_at = utcnow()
            session.add(connection)
    session.add(progress)
    session.commit()
    logger.info(
        "Device batch stored user=%s type=%s phase=%s stored=%d unchanged=%d ignored=%d deleted=%d final=%s",
        token_digest(connection.user_id)[:12],
        batch.data_type,
        batch.phase,
        stored,
        unchanged,
        ignored,
        len(deleted_records),
        batch.final,
    )
    return DeviceBatchResult(
        stored=stored,
        unchanged=unchanged,
        ignored=ignored,
        deleted=len(deleted_records),
        progress=progress,
        rebuild_range=rebuild_range,
    )


def mark_rebuild_queued(session: Session, progress: DeviceSyncProgress) -> None:
    progress.pending_rebuild_start = None
    progress.pending_rebuild_end = None
    session.add(progress)
    session.commit()


def progress_for(session: Session, connection: HealthConnection, batch: DeviceBatch) -> DeviceSyncProgress:
    progress = session.scalar(
        select(DeviceSyncProgress).where(
            DeviceSyncProgress.connection_id == connection.id,
            DeviceSyncProgress.data_type == batch.data_type,
            DeviceSyncProgress.phase == batch.phase,
        )
    )
    if progress is None:
        progress = DeviceSyncProgress(
            connection_id=connection.id,
            data_type=batch.data_type,
            phase=batch.phase,
            samples_received=0,
            deletions_received=0,
        )
    if (progress.range_start, progress.range_end) != (batch.range_start, batch.range_end):
        progress.range_start = batch.range_start
        progress.range_end = batch.range_end
        progress.completed_at = None
    progress.status = SyncStatus.running
    return progress


def device_progress(session: Session, connection: HealthConnection) -> list[DeviceSyncProgress]:
    return session.scalars(
        select(DeviceSyncProgress)
        .where(DeviceSyncProgress.connection_id == connection.id)
        .order_by(DeviceSyncProgress.phase, DeviceSyncProgress.data_type)
    ).all()


def sample_hash(sample: dict) -> str:
    return hashlib.sha256(json.dumps(sample, sort_keys=True, separators=(",", ":")).encode()).hexdigest()


def parse_instant(value: str | datetime) -> datetime:
    return value if isinstance(value, datetime) else datetime.fromisoformat(value)
