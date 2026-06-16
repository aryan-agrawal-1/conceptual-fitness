from __future__ import annotations

from dataclasses import dataclass
from datetime import date, timedelta

from sqlalchemy import select
from sqlalchemy.orm import Session

from app.core.security import decrypt_secret, utcnow
from app.google_health.client import GoogleHealthClient
from app.google_health.data_types import DATA_TYPE_SPECS, MVP_SYNC_DATA_TYPES
from app.models import ConnectionStatus, GoogleAccount, SyncCursor, SyncStatus
from app.services.normalization import upsert_raw_and_normalized
from app.services.summaries import rebuild_daily_summaries


@dataclass
class SyncResult:
    google_account_id: str
    start: date
    end: date
    records_seen: int
    records_stored: int
    data_types: list[str]


async def sync_google_account_range(
    session: Session,
    *,
    account: GoogleAccount,
    start: date,
    end: date,
    data_types: tuple[str, ...] = MVP_SYNC_DATA_TYPES,
    client: GoogleHealthClient | None = None,
) -> SyncResult:
    if account.encrypted_refresh_token is None:
        raise RuntimeError("Google account does not have a refresh token")
    if account.status != ConnectionStatus.connected:
        raise RuntimeError("Google account is not connected")

    google_client = client or GoogleHealthClient()
    token_payload = await google_client.refresh_access_token(decrypt_secret(account.encrypted_refresh_token))
    access_token = token_payload["access_token"]
    account.last_token_refresh_at = utcnow()
    account.last_error = None
    session.add(account)
    session.commit()

    records_seen = 0
    records_stored = 0
    successful_types: list[str] = []

    for data_type in data_types:
        spec = DATA_TYPE_SPECS[data_type]
        cursor = _get_or_create_cursor(session, account.id, data_type)
        cursor.status = SyncStatus.running
        cursor.last_error = None
        session.add(cursor)
        session.commit()
        try:
            filter_expr = _filter_for_range(spec.filter_time_path, start, end)
            points = await google_client.iter_data_points(
                data_type,
                access_token,
                filter_expr=filter_expr,
                prefer_reconcile=spec.prefer_reconcile,
            )
            records_seen += len(points)
            for point in points:
                upsert_raw_and_normalized(
                    session,
                    account=account,
                    data_type=data_type,
                    data_point=point,
                )
                records_stored += 1
            cursor.status = SyncStatus.succeeded
            cursor.last_successful_start = start
            cursor.last_successful_end = end
            cursor.last_page_token = None
            successful_types.append(data_type)
            session.add(cursor)
            session.commit()
        except Exception as exc:
            session.rollback()
            cursor = _get_or_create_cursor(session, account.id, data_type)
            cursor.status = SyncStatus.failed
            cursor.last_error = str(exc)
            account.status = ConnectionStatus.errored
            account.last_error = str(exc)
            session.add_all([cursor, account])
            session.commit()
            raise

    rebuild_daily_summaries(session, user_id=account.user_id, start=start, end=end)
    account.last_sync_at = utcnow()
    account.status = ConnectionStatus.connected
    account.last_error = None
    session.add(account)
    session.commit()
    return SyncResult(
        google_account_id=account.id,
        start=start,
        end=end,
        records_seen=records_seen,
        records_stored=records_stored,
        data_types=successful_types,
    )


async def run_initial_backfill(
    session: Session,
    *,
    account: GoogleAccount,
    client: GoogleHealthClient | None = None,
) -> SyncResult:
    today = date.today()
    return await sync_google_account_range(
        session,
        account=account,
        start=today - timedelta(days=13),
        end=today,
        client=client,
    )


def _get_or_create_cursor(session: Session, google_account_id: str, data_type: str) -> SyncCursor:
    cursor = session.scalar(
        select(SyncCursor).where(
            SyncCursor.google_account_id == google_account_id,
            SyncCursor.data_type == data_type,
        )
    )
    if cursor:
        return cursor
    cursor = SyncCursor(google_account_id=google_account_id, data_type=data_type)
    session.add(cursor)
    session.flush()
    return cursor


def _filter_for_range(filter_time_path: str, start: date, end: date) -> str:
    if filter_time_path.endswith("physical_time"):
        start_value = f"{start.isoformat()}T00:00:00Z"
        end_value = f"{(end + timedelta(days=1)).isoformat()}T00:00:00Z"
    else:
        start_value = f"{start.isoformat()}T00:00:00"
        end_value = f"{(end + timedelta(days=1)).isoformat()}T00:00:00"
    return f'{filter_time_path} >= "{start_value}" AND {filter_time_path} < "{end_value}"'
