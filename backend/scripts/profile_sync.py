from __future__ import annotations

import argparse
import asyncio
import json
from datetime import date
from time import perf_counter

from sqlalchemy import select

from app.db.session import SessionLocal
from app.google_health.data_types import MVP_SYNC_DATA_TYPES
from app.models import ConnectionStatus, GoogleAccount
from app.services.sync import SyncProfile, sync_google_account_range, sync_window_from_cursors


def _parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(description="Run a Google Health sync and print timing details.")
    parser.add_argument("--account-id", help="GoogleAccount id to sync. Defaults to first connected account.")
    parser.add_argument("--data-type", action="append", dest="data_types", help="Data type to sync. Repeatable.")
    parser.add_argument("--start", type=date.fromisoformat, help="Inclusive start date, YYYY-MM-DD.")
    parser.add_argument("--end", type=date.fromisoformat, help="Inclusive end date, YYYY-MM-DD.")
    return parser.parse_args()


def _find_account(account_id: str | None) -> GoogleAccount:
    with SessionLocal() as session:
        if account_id:
            account = session.get(GoogleAccount, account_id)
        else:
            account = session.scalar(
                select(GoogleAccount)
                .where(GoogleAccount.status == ConnectionStatus.connected)
                .order_by(GoogleAccount.created_at.desc())
            )
        if account is None:
            raise SystemExit("No matching connected Google account found.")
        session.expunge(account)
        return account


async def _run() -> dict[str, object]:
    args = _parse_args()
    data_types = tuple(args.data_types or MVP_SYNC_DATA_TYPES)
    profile = SyncProfile()
    started = perf_counter()

    with SessionLocal() as session:
        account = session.merge(_find_account(args.account_id))
        if args.start is None and args.end is None:
            window = sync_window_from_cursors(
                session,
                account=account,
                data_types=data_types,
                today=date.today(),
            )
            start = window.start
            end = window.end
            is_cursor_window = True
        else:
            today = date.today()
            start = args.start or today
            end = args.end or today
            is_cursor_window = False

        result = await sync_google_account_range(
            session,
            account=account,
            start=start,
            end=end,
            data_types=data_types,
            profile=profile,
        )

    return {
        "account_id": result.google_account_id,
        "window": {
            "start": result.start.isoformat(),
            "end": result.end.isoformat(),
            "from_cursors": is_cursor_window,
        },
        "total_seconds": round(perf_counter() - started, 3),
        "records_seen": result.records_seen,
        "records_stored": result.records_stored,
        "successful_data_types": result.data_types,
        "profile": profile.as_dict(),
    }


def main() -> None:
    print(json.dumps(asyncio.run(_run()), indent=2, sort_keys=True))


if __name__ == "__main__":
    main()
