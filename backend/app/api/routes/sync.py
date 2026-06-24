from __future__ import annotations

from datetime import date, timedelta

from fastapi import APIRouter, HTTPException, Query
from sqlalchemy import select

from app.api.deps import CurrentUser, DbSession
from app.google_health.data_types import MVP_SYNC_DATA_TYPES
from app.models import ConnectionStatus, GoogleAccount, SyncCursor
from app.services.sync import (
    account_has_running_sync,
    is_account_sync_fresh,
    sync_google_account_range,
    sync_window_from_cursors,
)


router = APIRouter(prefix="/sync", tags=["sync"])


@router.get("/current/status")
def current_sync_status(session: DbSession, user: CurrentUser) -> dict[str, object]:
    account = _current_connected_account(session, user.id)
    if account is None:
        raise HTTPException(status_code=404, detail="Connected Google Health account not found")
    cursors = _account_cursors(session, account.id)
    return _current_status_payload(account, cursors)


@router.post("/current")
async def current_sync(session: DbSession, user: CurrentUser) -> dict[str, object]:
    account = _current_connected_account(session, user.id)
    if account is None:
        raise HTTPException(status_code=404, detail="Connected Google Health account not found")
    cursors = _account_cursors(session, account.id)
    if is_account_sync_fresh(account):
        return {
            **_current_status_payload(account, cursors),
            "status": "skipped_fresh",
        }
    if any(cursor.status.value == "running" for cursor in cursors) or account_has_running_sync(
        session,
        account,
    ):
        return {
            **_current_status_payload(account, cursors),
            "status": "already_running",
        }

    today = date.today()
    window = sync_window_from_cursors(session, account=account, today=today)
    try:
        result = await sync_google_account_range(
            session,
            account=account,
            start=window.start,
            end=window.end,
        )
    except Exception as exc:
        raise HTTPException(status_code=502, detail=str(exc)) from exc
    session.refresh(account)
    return {
        **_current_status_payload(account, _account_cursors(session, account.id)),
        "status": "synced",
        "start": result.start,
        "end": result.end,
        "records_seen": result.records_seen,
        "records_stored": result.records_stored,
        "data_types": result.data_types,
    }


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
    requested_types = tuple(data_type or MVP_SYNC_DATA_TYPES)
    if start is None and end is None:
        window = sync_window_from_cursors(
            session,
            account=account,
            data_types=requested_types,
            today=today,
        )
        start_date = window.start
        end_date = window.end
    else:
        start_date = start or today - timedelta(days=1)
        end_date = end or today
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


def _current_connected_account(session: DbSession, user_id: str) -> GoogleAccount | None:
    return session.scalar(
        select(GoogleAccount)
        .where(
            GoogleAccount.user_id == user_id,
            GoogleAccount.status == ConnectionStatus.connected,
        )
        .order_by(GoogleAccount.connected_at.desc())
    )


def _account_cursors(session: DbSession, account_id: str) -> list[SyncCursor]:
    return session.scalars(
        select(SyncCursor)
        .where(SyncCursor.google_account_id == account_id)
        .order_by(SyncCursor.updated_at.desc())
    ).all()


def _current_status_payload(account: GoogleAccount, cursors: list[SyncCursor]) -> dict[str, object]:
    return {
        "account_id": account.id,
        "is_running": any(cursor.status.value == "running" for cursor in cursors),
        "is_fresh": is_account_sync_fresh(account),
        "last_sync_at": account.last_sync_at,
        "cursors": [
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
        ],
    }
