from __future__ import annotations

from datetime import date, timedelta

from fastapi import APIRouter, HTTPException, Query
from sqlalchemy import select

from app.api.deps import DbSession
from app.google_health.data_types import MVP_SYNC_DATA_TYPES
from app.models import GoogleAccount, SyncCursor
from app.services.sync import sync_google_account_range


router = APIRouter(prefix="/sync", tags=["sync"])


# having a manual sync option feels smart
@router.post("/manual")
async def manual_sync(
    session: DbSession,
    account_id: str = Query(...),
    start: date | None = Query(default=None),
    end: date | None = Query(default=None),
    data_type: list[str] | None = Query(default=None),
) -> dict[str, object]:
    account = session.get(GoogleAccount, account_id)
    if account is None:
        raise HTTPException(status_code=404, detail="Google account not found")
    today = date.today()
    start_date = start or today - timedelta(days=1)
    end_date = end or today
    requested_types = tuple(data_type or MVP_SYNC_DATA_TYPES)
    try:
        result = await sync_google_account_range(
            session,
            account=account,
            start=start_date,
            end=end_date,
            data_types=requested_types,
        )
    except Exception as exc:
        raise HTTPException(status_code=502, detail=str(exc)) from exc
    return {
        "google_account_id": result.google_account_id,
        "start": result.start,
        "end": result.end,
        "records_seen": result.records_seen,
        "records_stored": result.records_stored,
        "data_types": result.data_types,
    }


# Info about the last sync
@router.get("/status")
def sync_status(session: DbSession, account_id: str | None = Query(default=None)) -> list[dict[str, object]]:
    statement = select(SyncCursor)
    if account_id:
        statement = statement.where(SyncCursor.google_account_id == account_id)
    cursors = session.scalars(statement.order_by(SyncCursor.updated_at.desc())).all()
    return [
        {
            "google_account_id": cursor.google_account_id,
            "data_type": cursor.data_type,
            "status": cursor.status.value,
            "last_successful_start": cursor.last_successful_start,
            "last_successful_end": cursor.last_successful_end,
            "last_error": cursor.last_error,
            "updated_at": cursor.updated_at,
        }
        for cursor in cursors
    ]

