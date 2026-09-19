from __future__ import annotations

import logging
from collections.abc import Iterator
from datetime import datetime
from typing import Literal

from fastapi import APIRouter, HTTPException
from fastapi.responses import StreamingResponse
from pydantic import BaseModel, Field, model_validator

from app.api.deps import CurrentUser, DbSession
from app.services.account_export import EXPORT_CATEGORIES, build_account_export
from app.services.sensitive_actions import SensitiveActionError, consume_sensitive_action_grant


logger = logging.getLogger(__name__)
router = APIRouter(prefix="/account", tags=["account"])


class LocalInsight(BaseModel):
    date: str = Field(max_length=10)
    slot: str = Field(max_length=32)
    kind: str = Field(max_length=32)
    text: str = Field(max_length=1000)
    generated_at: datetime


class ExportRequest(BaseModel):
    categories: list[
        Literal["health_and_workouts", "journal", "derived_insights", "personalization"]
    ] = Field(min_length=1)
    sensitive_action_grant: str = Field(min_length=1)
    device_id: str = Field(min_length=16)
    local_insights: list[LocalInsight] = Field(default_factory=list, max_length=1000)

    @model_validator(mode="after")
    def unique_categories(self):
        if len(self.categories) != len(set(self.categories)):
            raise ValueError("Export categories must be unique")
        if not set(self.categories) <= EXPORT_CATEGORIES:
            raise ValueError("Unsupported export category")
        return self


@router.post("/export")
def export_account_data(payload: ExportRequest, session: DbSession, user: CurrentUser):
    try:
        consume_sensitive_action_grant(
            session,
            token=payload.sensitive_action_grant,
            purpose="export",
            user_id=user.id,
            device_id=payload.device_id,
        )
    except SensitiveActionError as exc:
        raise HTTPException(status_code=403, detail="Reauthentication is required") from exc

    try:
        archive = build_account_export(
            session,
            user_id=user.id,
            categories=set(payload.categories),
            local_insights=[item.model_dump(mode="json") for item in payload.local_insights],
        )
    except Exception as exc:
        logger.error("Account export generation failed (%s)", type(exc).__name__)
        raise HTTPException(status_code=500, detail="Account export could not be generated") from exc

    logger.info("Account export generated categories=%s", ",".join(sorted(payload.categories)))

    def chunks() -> Iterator[bytes]:
        try:
            while chunk := archive.read(64 * 1024):
                yield chunk
        finally:
            archive.close()

    filename = f"conceptual-fitness-export-{datetime.now().date().isoformat()}.zip"
    return StreamingResponse(
        chunks(),
        media_type="application/zip",
        headers={"Content-Disposition": f'attachment; filename="{filename}"'},
    )
