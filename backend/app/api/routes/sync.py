from __future__ import annotations

import asyncio

from datetime import UTC, date, timedelta

from fastapi import APIRouter, HTTPException, Query
from sqlalchemy import select

from app.api.deps import CurrentUser, DbSession
from app.core.security import utcnow
from app.google_health.data_types import DATA_TYPE_SPECS, MVP_SYNC_DATA_TYPES
from app.models import ConnectionStatus, GoogleAccount, HistoricalBackfill, SyncCursor
from app.services.sync import (
    SYNC_LEASE,
    SyncAlreadyRunningError,
    account_has_running_sync,
    is_account_sync_fresh,
    sync_google_account_range,
    sync_window_from_cursors,
)
from app.tasks.sync import enqueue_historical_backfill


router = APIRouter(prefix="/sync", tags=["sync"])


@router.get("/current/status")
def current_sync_status(session: DbSession, user: CurrentUser) -> dict[str, object]:
    account = _current_connected_account(session, user.id)
    if account is None:
        raise HTTPException(status_code=404, detail="Connected Google Health account not found")
    cursors = _account_cursors(session, account.id)
    return _current_status_payload(session, account, cursors)


@router.post("/current")
def current_sync(session: DbSession, user: CurrentUser) -> dict[str, object]:
    account = _current_connected_account(session, user.id)
    if account is None:
        raise HTTPException(status_code=404, detail="Connected Google Health account not found")
    cursors = _account_cursors(session, account.id)
    failed_types = tuple(
        cursor.data_type for cursor in cursors
        if cursor.status.value == "failed"
        and cursor.data_type in DATA_TYPE_SPECS
        and DATA_TYPE_SPECS[cursor.data_type].fail_sync_on_error
    )
    fresh = is_account_sync_fresh(account, session=session)
    if account_has_running_sync(
        session,
        account,
    ):
        return {
            **_current_status_payload(session, account, cursors),
            "status": "already_running",
        }
    if fresh and not failed_types:
        return {
            **_current_status_payload(session, account, cursors),
            "status": "skipped_fresh",
        }

    today = date.today()
    requested_types = failed_types if fresh and failed_types else MVP_SYNC_DATA_TYPES
    window = sync_window_from_cursors(
        session,
        account=account,
        data_types=requested_types,
        today=today,
    )
    try:
        result = asyncio.run(sync_google_account_range(
            session,
            account=account,
            start=window.start,
            end=window.end,
            data_types=requested_types,
        ))
    except SyncAlreadyRunningError:
        session.refresh(account)
        return {**_current_status_payload(session, account, cursors), "status": "already_running"}
    except Exception as exc:
        raise HTTPException(status_code=502, detail="Health data refresh failed") from exc
    session.refresh(account)
    if result.data_types and not _historical_backfills(session, account.id):
        enqueue_historical_backfill(account.id)
    return {
        **_current_status_payload(session, account, _account_cursors(session, account.id)),
        "status": "synced",
        "start": result.start,
        "end": result.end,
        "records_seen": result.records_seen,
        "records_stored": result.records_stored,
        "data_types": result.data_types,
    }


@router.post("/current/historical-backfill/retry")
def retry_current_historical_backfill(
    session: DbSession,
    user: CurrentUser,
) -> dict[str, object]:
    account = _current_connected_account(session, user.id)
    if account is None:
        raise HTTPException(status_code=404, detail="Connected Google Health account not found")
    progress = _historical_backfill_payload(_historical_backfills(session, account.id))
    if progress is not None and progress["status"] in {"running", "complete"}:
        return {"status": progress["status"], "account_id": account.id}
    if not enqueue_historical_backfill(account.id):
        raise HTTPException(status_code=503, detail="Historical backfill could not be queued")
    return {"status": "queued", "account_id": account.id}


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


def _current_status_payload(
    session: DbSession,
    account: GoogleAccount,
    cursors: list[SyncCursor],
) -> dict[str, object]:
    backfills = _historical_backfills(session, account.id)
    historical_backfill = _historical_backfill_payload(backfills)
    return {
        "account_id": account.id,
        "is_running": account_has_running_sync(session, account),
        "is_fresh": is_account_sync_fresh(account, session=session),
        "has_failure": account.last_error is not None or any(
            cursor.status.value == "failed"
            and cursor.data_type in DATA_TYPE_SPECS
            and DATA_TYPE_SPECS[cursor.data_type].fail_sync_on_error
            for cursor in cursors
        ),
        "last_sync_at": account.last_sync_at,
        "historical_backfill": historical_backfill,
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


def _historical_backfills(session: DbSession, account_id: str) -> list[HistoricalBackfill]:
    return session.scalars(
        select(HistoricalBackfill)
        .where(HistoricalBackfill.google_account_id == account_id)
        .order_by(HistoricalBackfill.range_end.desc(), HistoricalBackfill.data_type)
    ).all()


def _historical_backfill_payload(rows: list[HistoricalBackfill]) -> dict[str, object] | None:
    if not rows:
        return None
    latest_end = rows[0].range_end
    latest = [row for row in rows if row.range_end == latest_end]
    source_statuses = {
        row.id: "failed" if row.status.value in {"pending", "running"}
        and row.updated_at.replace(tzinfo=row.updated_at.tzinfo or UTC) < utcnow() - SYNC_LEASE
        else row.status.value
        for row in latest
    }
    completed = sum(status == "succeeded" for status in source_statuses.values())
    failed = sum(status == "failed" for status in source_statuses.values())
    running = any(status in {"pending", "running"} for status in source_statuses.values())
    return {
        "range_start": min(row.range_start for row in latest),
        "range_end": latest_end,
        "completed_sources": completed,
        "total_sources": len(latest),
        "status": "running" if running else "failed" if failed else "complete",
        "sources": [
            {
                "data_type": row.data_type,
                "status": source_statuses[row.id],
                "last_error": row.last_error,
            }
            for row in latest
        ],
    }
