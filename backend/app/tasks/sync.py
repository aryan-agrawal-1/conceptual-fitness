from __future__ import annotations

import asyncio
import logging
from datetime import UTC, date

from sqlalchemy import select

from app.core.security import utcnow
from app.db.session import SessionLocal
from app.models import ConnectionStatus, GoogleAccount, HistoricalBackfill, SyncStatus
from app.services.metric_rollups import cleanup_high_volume_storage
from app.services.sync import (
    SYNC_LEASE,
    account_has_running_sync,
    is_account_sync_fresh,
    prepare_historical_backfill,
    run_initial_backfill,
    run_historical_backfill,
    sync_google_account_range,
    sync_window_from_cursors,
)
from app.tasks.celery_app import celery_app

logger = logging.getLogger(__name__)

# hand work to celery to backfill data
def enqueue_initial_backfill(account_id: str) -> bool:
    try:
        initial_backfill.delay(account_id)
        return True
    except Exception:
        return False


def enqueue_historical_backfill(account_id: str) -> bool:
    with SessionLocal() as session:
        account = session.get(GoogleAccount, account_id)
        if account is None:
            return False
        existing = session.scalar(select(HistoricalBackfill.id).where(
            HistoricalBackfill.google_account_id == account_id,
        ).limit(1))
        rows = prepare_historical_backfill(session, account=account)
        if existing and any(
            row.status in {SyncStatus.pending, SyncStatus.running}
            and row.updated_at.replace(tzinfo=row.updated_at.tzinfo or UTC) > utcnow() - SYNC_LEASE
            for row in rows
        ):
            return True
        if all(row.status == SyncStatus.succeeded for row in rows):
            return True
        try:
            for row in rows:
                if row.status == SyncStatus.failed:
                    row.status = SyncStatus.pending
                    row.last_error = None
            session.commit()
            historical_backfill.delay(account_id)
            return True
        except Exception as exc:
            for row in rows:
                if row.status != SyncStatus.succeeded:
                    row.status = SyncStatus.failed
                    row.last_error = "QueueUnavailable"
            session.commit()
            logger.warning("Historical backfill could not be queued (%s)", type(exc).__name__)
            return False


@celery_app.task(name="app.tasks.sync.initial_backfill")
def initial_backfill(account_id: str) -> dict[str, object]:
    with SessionLocal() as session:
        account = session.get(GoogleAccount, account_id)
        if account is None:
            return {"status": "missing_account", "account_id": account_id}
        result = asyncio.run(run_initial_backfill(session, account=account))
        backfills = asyncio.run(run_historical_backfill(session, account=account))
        cleanup_counts = cleanup_high_volume_storage(session, today=date.today())
        session.commit()
        return {
            "status": "ok",
            "account_id": account_id,
            "records_seen": result.records_seen,
            "records_stored": result.records_stored,
            "historical_succeeded": sum(row.status.value == "succeeded" for row in backfills),
            "historical_failed": sum(row.status.value == "failed" for row in backfills),
            "cleanup": cleanup_counts,
        }


@celery_app.task(name="app.tasks.sync.historical_backfill")
def historical_backfill(account_id: str) -> dict[str, object]:
    with SessionLocal() as session:
        account = session.get(GoogleAccount, account_id)
        if account is None:
            return {"status": "missing_account", "account_id": account_id}
        rows = asyncio.run(run_historical_backfill(session, account=account))
        return {
            "status": "ok",
            "account_id": account_id,
            "succeeded": sum(row.status.value == "succeeded" for row in rows),
            "failed": sum(row.status.value == "failed" for row in rows),
        }


@celery_app.task(name="app.tasks.sync.sync_all_connected_accounts")
def sync_all_connected_accounts() -> dict[str, object]:
    synced: list[str] = []
    skipped: dict[str, str] = {}
    failed: dict[str, str] = {}
    ranges: dict[str, dict[str, object]] = {}
    with SessionLocal() as session:
        accounts = session.scalars(
            select(GoogleAccount).where(GoogleAccount.status == ConnectionStatus.connected)
        ).all()
        for account in accounts:
            try:
                if is_account_sync_fresh(account, session=session):
                    skipped[account.id] = "fresh"
                    enqueue_historical_backfill(account.id)
                    continue
                if account_has_running_sync(session, account):
                    skipped[account.id] = "already_running"
                    continue
                window = sync_window_from_cursors(session, account=account, today=date.today())
                asyncio.run(
                    sync_google_account_range(
                        session,
                        account=account,
                        start=window.start,
                        end=window.end,
                    )
                )
                enqueue_historical_backfill(account.id)
                synced.append(account.id)
                ranges[account.id] = {
                    "start": window.start.isoformat(),
                    "end": window.end.isoformat(),
                    "is_initial_backfill": window.is_initial_backfill,
                }
            except Exception as exc:
                logger.error("Google Health sync failed for account %s: %s", account.id, type(exc).__name__)
                failed[account.id] = str(exc)
        cleanup_counts = cleanup_high_volume_storage(session, today=date.today())
        session.commit()
    return {
        "synced": synced,
        "skipped": skipped,
        "failed": failed,
        "ranges": ranges,
        "cleanup": cleanup_counts,
    }
