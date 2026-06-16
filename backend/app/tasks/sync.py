from __future__ import annotations

import asyncio
from datetime import date, timedelta

from sqlalchemy import select

from app.db.session import SessionLocal
from app.models import ConnectionStatus, GoogleAccount
from app.services.sync import run_initial_backfill, sync_google_account_range
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
        return {
            "status": "ok",
            "account_id": account_id,
            "records_seen": result.records_seen,
            "records_stored": result.records_stored,
        }


@celery_app.task(name="app.tasks.sync.sync_all_connected_accounts")
def sync_all_connected_accounts() -> dict[str, object]:
    today = date.today()
    start = today - timedelta(days=2)
    synced: list[str] = []
    failed: dict[str, str] = {}
    with SessionLocal() as session:
        accounts = session.scalars(
            select(GoogleAccount).where(GoogleAccount.status == ConnectionStatus.connected)
        ).all()
        for account in accounts:
            try:
                asyncio.run(
                    sync_google_account_range(
                        session,
                        account=account,
                        start=start,
                        end=today,
                    )
                )
                synced.append(account.id)
            except Exception as exc:
                failed[account.id] = str(exc)
    return {"synced": synced, "failed": failed}

