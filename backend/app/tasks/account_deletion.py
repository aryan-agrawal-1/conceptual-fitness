from __future__ import annotations

import asyncio

from app.db.session import SessionLocal
from app.services.account_deletion import purge_due_accounts
from app.tasks.celery_app import celery_app


@celery_app.task(name="app.tasks.account_deletion.purge_due_accounts")
def purge_due_accounts_task() -> dict[str, int]:
    with SessionLocal() as session:
        return asyncio.run(purge_due_accounts(session))
