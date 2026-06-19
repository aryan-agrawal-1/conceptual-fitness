from __future__ import annotations

from datetime import date as date_type, datetime
from typing import Any

from fastapi import APIRouter, HTTPException, Query, status
from pydantic import BaseModel, Field
from sqlalchemy import select

from app.api.deps import CurrentUser, DbSession
from app.models import DailyContext


router = APIRouter(prefix="/tags", tags=["tags"])

DEFAULT_TAG_TYPES = {
    "alcohol",
    "caffeine",
    "illness",
    "soreness",
    "stress",
    "travel",
    "poor_sleep",
    "late_meal",
    "unusual_workout",
}


class TagPayload(BaseModel):
    id: str
    date: date_type
    type: str
    source: str
    severity: str | None
    value: dict[str, Any]
    created_at: datetime


class TagCreate(BaseModel):
    date: date_type
    type: str = Field(..., min_length=1, max_length=80)
    severity: str | None = Field(default=None, max_length=32)
    value: dict[str, Any] = Field(default_factory=dict)


class TagUpdate(BaseModel):
    date: date_type | None = None
    type: str | None = Field(default=None, min_length=1, max_length=80)
    severity: str | None = Field(default=None, max_length=32)
    value: dict[str, Any] | None = None

# get all the tag types
@router.get("/types")
def tag_types() -> dict[str, list[str]]:
    return {"types": sorted(DEFAULT_TAG_TYPES)}

# retrieved logged user tags
@router.get("", response_model=list[TagPayload])
def list_tags(
    session: DbSession,
    user: CurrentUser,
    start: date_type | None = Query(default=None),
    end: date_type | None = Query(default=None),
    type: str | None = Query(default=None),
) -> list[TagPayload]:
    statement = select(DailyContext).where(DailyContext.user_id == user.id)
    if start is not None:
        statement = statement.where(DailyContext.context_date >= start)
    if end is not None:
        statement = statement.where(DailyContext.context_date <= end)
    if type is not None:
        statement = statement.where(DailyContext.context_type == _clean_string(type))
    tags = session.scalars(
        statement.order_by(DailyContext.context_date.desc(), DailyContext.created_at.desc())
    ).all()
    return [_tag_payload(tag) for tag in tags]


@router.post("", response_model=TagPayload, status_code=status.HTTP_201_CREATED)
def create_tag(payload: TagCreate, session: DbSession, user: CurrentUser) -> TagPayload:
    tag = DailyContext(
        user_id=user.id,
        context_date=payload.date,
        context_type=_clean_string(payload.type),
        source="manual",
        severity=_clean_optional_string(payload.severity),
        value=payload.value,
    )
    session.add(tag)
    session.commit()
    session.refresh(tag)
    return _tag_payload(tag)


@router.patch("/{tag_id}", response_model=TagPayload)
def update_tag(
    tag_id: str,
    payload: TagUpdate,
    session: DbSession,
    user: CurrentUser,
) -> TagPayload:
    tag = _get_user_tag(session, user.id, tag_id)
    updates = payload.model_dump(exclude_unset=True)
    if "date" in updates:
        tag.context_date = updates["date"]
    if "type" in updates:
        tag.context_type = _clean_string(updates["type"])
    if "severity" in updates:
        tag.severity = _clean_optional_string(updates["severity"])
    if "value" in updates:
        tag.value = updates["value"] or {}
    session.add(tag)
    session.commit()
    session.refresh(tag)
    return _tag_payload(tag)


@router.delete("/{tag_id}", status_code=status.HTTP_204_NO_CONTENT)
def delete_tag(tag_id: str, session: DbSession, user: CurrentUser) -> None:
    tag = _get_user_tag(session, user.id, tag_id)
    session.delete(tag)
    session.commit()


def _get_user_tag(session: DbSession, user_id: str, tag_id: str) -> DailyContext:
    tag = session.get(DailyContext, tag_id)
    if tag is None or tag.user_id != user_id:
        raise HTTPException(status_code=404, detail="Tag not found")
    return tag


def _tag_payload(tag: DailyContext) -> TagPayload:
    return TagPayload(
        id=tag.id,
        date=tag.context_date,
        type=tag.context_type,
        source=tag.source,
        severity=tag.severity,
        value=tag.value,
        created_at=tag.created_at,
    )


def _clean_string(value: str) -> str:
    cleaned = value.strip()
    if not cleaned:
        raise HTTPException(status_code=422, detail="String fields cannot be blank")
    return cleaned


def _clean_optional_string(value: str | None) -> str | None:
    if value is None:
        return None
    return _clean_string(value)
