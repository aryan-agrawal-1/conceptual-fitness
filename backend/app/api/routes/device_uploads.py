from __future__ import annotations

import logging
import math
from datetime import date
from typing import Annotated, Any, Literal

from fastapi import APIRouter, HTTPException, Request
from fastapi.exceptions import RequestValidationError
from fastapi.routing import APIRoute
from pydantic import AwareDatetime, BaseModel, Field, StringConstraints, field_validator, model_validator

from app.api.deps import CurrentUser, DbSession
from app.core.security import utcnow
from app.models import ConnectionStatus, DeviceSyncProgress, HealthConnection
from app.services.device_ingestion import (
    DeviceBatch,
    DeviceIngestionError,
    active_apple_health_connection,
    connect_apple_health,
    device_progress,
    ingest_device_batch,
    mark_rebuild_queued,
)
from app.services.rate_limit import CONNECTION_MUTATION_LIMIT, DEVICE_UPLOAD_LIMIT, enforce_rate_limit
from app.tasks.sync import enqueue_score_rebuild

logger = logging.getLogger(__name__)


class DeviceUploadRoute(APIRoute):
    def get_route_handler(self):
        handler = super().get_route_handler()

        async def handler_without_echoed_values(request: Request):
            try:
                return await handler(request)
            except RequestValidationError as exc:
                fields = sorted({".".join(str(part) for part in error["loc"][1:]) for error in exc.errors()})
                logger.warning("Device upload rejected reason=invalid_schema fields=%s", ",".join(fields[:10]))
                raise HTTPException(422, {"code": "invalid_batch", "fields": fields[:20]}) from exc

        return handler_without_echoed_values


connections_router = APIRouter(prefix="/connections/apple-health", tags=["connections"])
router = APIRouter(prefix="/ingest/apple-health", tags=["ingest"], route_class=DeviceUploadRoute)

RecordId = Annotated[str, StringConstraints(min_length=1, max_length=64)]
ShortText = Annotated[str, StringConstraints(max_length=255)]


class DeviceSampleSource(BaseModel):
    bundle_id: ShortText | None = None
    name: ShortText | None = None
    device_name: ShortText | None = None
    device_model: ShortText | None = None
    product_type: ShortText | None = None


class DeviceSample(BaseModel):
    id: RecordId
    start: AwareDatetime
    end: AwareDatetime
    value: float | None = Field(default=None, allow_inf_nan=False)
    unit: Annotated[str, StringConstraints(max_length=32)] | None = None
    category_value: int | None = None
    source: DeviceSampleSource | None = None
    metadata: dict[ShortText, str | float | int | bool] = Field(default_factory=dict, max_length=50)
    workout: dict[ShortText, str | float | int | bool | None] | None = Field(default=None, max_length=50)

    @model_validator(mode="after")
    def ends_after_start(self) -> DeviceSample:
        if self.end < self.start:
            raise ValueError("end must not be before start")
        return self

    @field_validator("metadata", "workout")
    @classmethod
    def finite_numbers(cls, values: dict[str, Any] | None) -> dict[str, Any] | None:
        if values and any(isinstance(value, float) and not math.isfinite(value) for value in values.values()):
            raise ValueError("numbers must be finite")
        return values


class DeviceBatchRequest(BaseModel):
    data_type: Annotated[str, StringConstraints(max_length=80)]
    phase: Literal["current", "historical"]
    range_start: date
    range_end: date
    samples: list[DeviceSample] = Field(default_factory=list, max_length=1000)
    deleted_ids: list[RecordId] = Field(default_factory=list, max_length=1000)
    anchor: Annotated[str, StringConstraints(max_length=8192)] | None = None
    final: bool = False


@connections_router.post("")
async def connect(request: Request, session: DbSession, user: CurrentUser) -> dict[str, object]:
    enforce_rate_limit(request, CONNECTION_MUTATION_LIMIT, user.id)
    return connection_payload(await connect_apple_health(session, user))


@connections_router.post("/disconnect")
def disconnect(request: Request, session: DbSession, user: CurrentUser) -> dict[str, object]:
    enforce_rate_limit(request, CONNECTION_MUTATION_LIMIT, user.id)
    connection = active_apple_health_connection(session, user.id)
    if connection is None:
        raise HTTPException(status_code=404, detail="Apple Health connection not found")
    connection.status = ConnectionStatus.disconnected
    connection.disconnected_at = utcnow()
    session.add(connection)
    session.commit()
    return connection_payload(connection)


@router.post("/batches")
def upload_batch(
    request: Request,
    payload: DeviceBatchRequest,
    session: DbSession,
    user: CurrentUser,
) -> dict[str, object]:
    enforce_rate_limit(request, DEVICE_UPLOAD_LIMIT, user.id)
    connection = active_apple_health_connection(session, user.id)
    if connection is None:
        raise HTTPException(status_code=409, detail={"code": "apple_health_not_connected"})
    try:
        result = ingest_device_batch(
            session,
            connection,
            DeviceBatch(
                data_type=payload.data_type,
                phase=payload.phase,
                range_start=payload.range_start,
                range_end=payload.range_end,
                samples=[sample.model_dump(mode="json", exclude_none=True) for sample in payload.samples],
                deleted_ids=payload.deleted_ids,
                anchor=payload.anchor,
                final=payload.final,
            ),
        )
    except DeviceIngestionError as exc:
        raise HTTPException(status_code=422, detail={"code": "unsupported_batch"}) from exc
    rebuild_queued = False
    if result.rebuild_range is not None:
        rebuild_queued = enqueue_score_rebuild(user.id, *result.rebuild_range)
        if rebuild_queued:
            mark_rebuild_queued(session, result.progress)
    return {
        "stored": result.stored,
        "unchanged": result.unchanged,
        "ignored": result.ignored,
        "deleted": result.deleted,
        "rebuild_queued": rebuild_queued,
        "progress": progress_payload(result.progress),
    }


@router.get("/progress")
def progress(session: DbSession, user: CurrentUser) -> dict[str, object]:
    connection = active_apple_health_connection(session, user.id)
    if connection is None:
        raise HTTPException(status_code=409, detail={"code": "apple_health_not_connected"})
    return {
        "connection": connection_payload(connection),
        "types": [progress_payload(row) for row in device_progress(session, connection)],
    }


def connection_payload(connection: HealthConnection) -> dict[str, object]:
    return {
        "account_id": connection.id,
        "provider": connection.provider,
        "status": connection.status.value,
        "connected_at": connection.connected_at,
        "last_sync_at": connection.last_sync_at,
    }


def progress_payload(row: DeviceSyncProgress) -> dict[str, object]:
    return {
        "data_type": row.data_type,
        "phase": row.phase,
        "status": row.status.value,
        "range_start": row.range_start,
        "range_end": row.range_end,
        "anchor": row.anchor,
        "samples_received": row.samples_received,
        "deletions_received": row.deletions_received,
        "rebuild_pending": row.pending_rebuild_start is not None,
        "completed_at": row.completed_at,
        "updated_at": row.updated_at,
    }
