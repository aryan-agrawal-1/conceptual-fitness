"""Repair sleep dates and rebuild strain from precise movement evidence.

Run with PYTHONPATH=. .venv/bin/python scripts/repair_score_inputs.py --account-id ID.
Existing heart-rate history bounds the rebuild; older scores are left untouched.
"""
from __future__ import annotations

import argparse
import asyncio
from datetime import timedelta

from sqlalchemy import func, select, update

from app.core.security import decrypt_secret, utcnow
from app.db.session import SessionLocal
from app.google_health.client import GoogleHealthClient
from app.models import ConnectionStatus, GoogleAccount, MetricMinuteRollup, RawHealthRecord
from app.services.normalization import upsert_raw_and_normalized
from app.services.scores import rebuild_derived_scores
from app.services.summaries import rebuild_daily_summaries
from app.services.sync import (
    TypeSyncBounds,
    _get_or_create_cursor,
    _sync_data_type,
    account_has_running_sync,
)


async def repair(account_id: str) -> None:
    with SessionLocal() as session:
        account = session.get(GoogleAccount, account_id)
        if account is None or account.status != ConnectionStatus.connected or not account.encrypted_refresh_token:
            raise ValueError("A connected account with a refresh token is required")
        if account_has_running_sync(session, account):
            raise RuntimeError("Wait for the account's current import to finish")
        start, end = session.execute(
            select(func.min(MetricMinuteRollup.civil_date), func.max(MetricMinuteRollup.civil_date))
            .where(MetricMinuteRollup.user_id == account.user_id, MetricMinuteRollup.metric == "heart_rate")
        ).one()
        if start is None or end is None:
            raise ValueError("No retained minute heart-rate history to rebuild")
        lease = utcnow()
        claimed = session.execute(update(GoogleAccount).where(
            GoogleAccount.id == account.id, GoogleAccount.sync_started_at.is_(None),
        ).values(sync_started_at=lease)).rowcount
        session.commit()
        if not claimed:
            raise RuntimeError("An import started before the repair could acquire its lease")
        try:
            print(f"Rebuilding {start} through {end}", flush=True)
            client = GoogleHealthClient()
            token = (await client.refresh_access_token(decrypt_secret(account.encrypted_refresh_token)))["access_token"]
            # These sources return original intervals, not hourly totals spread across minutes.
            for data_type in ("steps", "distance"):
                seen, _ = await _sync_data_type(
                    session, account=account, client=client, access_token=token,
                    data_type=data_type, bounds=TypeSyncBounds(start=start, end=end),
                    cursor=_get_or_create_cursor(session, account.id, data_type), resume_running=False,
                )
                print(f"Imported {data_type}: {seen} intervals", flush=True)
            changed = 0
            for raw in session.scalars(select(RawHealthRecord).where(
                RawHealthRecord.google_account_id == account.id, RawHealthRecord.data_type == "sleep",
            )).all():
                old_date = raw.civil_date
                upsert_raw_and_normalized(session, account=account, data_type="sleep", data_point=raw.raw_json)
                changed += old_date != raw.civil_date
            session.flush()
            rebuild_daily_summaries(session, user_id=account.user_id, start=start - timedelta(days=28), end=end)
            result = rebuild_derived_scores(session, user_id=account.user_id, start=start, end=end)
            session.commit()
            print(f"Corrected {changed} sleep dates; rebuilt {result.scores_rebuilt} scores and {result.targets_rebuilt} targets", flush=True)
        finally:
            session.rollback()
            session.execute(update(GoogleAccount).where(
                GoogleAccount.id == account_id, GoogleAccount.sync_started_at == lease,
            ).values(sync_started_at=None))
            session.commit()



if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--account-id", required=True)
    asyncio.run(repair(parser.parse_args().account_id))
