from __future__ import annotations

import asyncio
from datetime import date

from sqlalchemy import select

from app.db.session import SessionLocal
from app.models import ConnectionStatus, GoogleAccount
from app.services.metric_rollups import cleanup_high_volume_storage
from app.services.sync import (
    account_has_running_sync,
    is_account_sync_fresh,
    run_initial_backfill,
    sync_google_account_range,
    sync_window_from_cursors,
)
from app.tasks.celery_app import celery_app

# hand work to celery to backfill data
def enqueue_initial_backfill(account_id: str) -> bool:
    try:
        initial_backfill.delay(account_id)
        return True
    except Exception:
        return False


@celery_app.task(name="app.tasks.sync.initial_backfill")
def initial_backfill(account_id: str) -> dict[str, object]:
    with SessionLocal() as session:
        account = session.get(GoogleAccount, account_id)
        if account is None:
            return {"status": "missing_account", "account_id": account_id}
        result = asyncio.run(run_initial_backfill(session, account=account))
        cleanup_counts = cleanup_high_volume_storage(session, today=date.today())
        session.commit()
        return {
            "status": "ok",
            "account_id": account_id,
            "records_seen": result.records_seen,
            "records_stored": result.records_stored,
            "cleanup": cleanup_counts,
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
                if is_account_sync_fresh(account):
                    skipped[account.id] = "fresh"
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
                synced.append(account.id)
                ranges[account.id] = {
                    "start": window.start.isoformat(),
                    "end": window.end.isoformat(),
                    "is_initial_backfill": window.is_initial_backfill,
                }
            except Exception as exc:
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
