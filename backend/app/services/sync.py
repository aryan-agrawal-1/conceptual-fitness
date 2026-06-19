from __future__ import annotations

from dataclasses import dataclass
from datetime import date, timedelta

from sqlalchemy import select
from sqlalchemy.orm import Session

from app.core.security import decrypt_secret, utcnow
from app.google_health.client import GoogleHealthClient
from app.google_health.data_types import DATA_TYPE_SPECS, MVP_SYNC_DATA_TYPES
from app.models import ConnectionStatus, GoogleAccount, SyncCursor, SyncStatus
from app.services.normalization import (
    _record_civil_date,
    upsert_heart_rate_points_fast,
    upsert_raw_and_normalized,
)
from app.services.scores import rebuild_derived_scores
from app.services.summaries import rebuild_daily_summaries


INITIAL_BACKFILL_DAYS = 14


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
        resume_running = cursor.status == SyncStatus.running
        cursor.status = SyncStatus.running
        cursor.last_error = None
        session.add(cursor)
        session.commit()
        try:
            seen, stored = await _sync_data_type(
                session,
                account=account,
                client=google_client,
                access_token=access_token,
                data_type=data_type,
                start=start,
                end=end,
                cursor=cursor,
                resume_running=resume_running,
            )
            records_seen += seen
            records_stored += stored
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
            if spec.fail_sync_on_error:
                account.status = ConnectionStatus.errored
                account.last_error = str(exc)
                session.add(account)
            session.add(cursor)
            session.commit()
            if spec.fail_sync_on_error:
                raise

    rebuild_daily_summaries(session, user_id=account.user_id, start=start, end=end)
    affected_end = min(date.today(), end + timedelta(days=7))
    rebuild_derived_scores(session, user_id=account.user_id, start=start, end=affected_end)
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
        start=today - timedelta(days=INITIAL_BACKFILL_DAYS - 1),
        end=today,
        client=client,
    )


async def _sync_data_type(
    session: Session,
    *,
    account: GoogleAccount,
    client: GoogleHealthClient,
    access_token: str,
    data_type: str,
    start: date,
    end: date,
    cursor: SyncCursor,
    resume_running: bool,
) -> tuple[int, int]:
    spec = DATA_TYPE_SPECS[data_type]
    records_seen = 0
    records_stored = 0

    if spec.prefer_daily_rollup:
        for chunk_start, chunk_end in _rollup_chunks(start, end):
            payload = await client.daily_rollup(
                data_type,
                access_token,
                start=chunk_start,
                end=chunk_end,
            )
            points = _rollup_data_points(data_type, spec.payload_key, payload)
            records_seen += len(points)
            records_stored += _store_points(
                session,
                account,
                data_type,
                points,
                start=chunk_start,
                end=chunk_end,
            )
            cursor.last_successful_start = start
            cursor.last_successful_end = chunk_end
            cursor.last_page_token = None
            session.add(cursor)
            session.commit()
        return records_seen, records_stored

    for chunk_start, chunk_end in _list_chunks(start, end, chunk_days=spec.chunk_days):
        if _should_skip_chunk_for_resume(
            cursor,
            range_start=start,
            chunk_start=chunk_start,
            chunk_end=chunk_end,
            resume_running=resume_running,
        ):
            continue
        filter_expr = (
            _filter_for_range(spec.filter_time_path, chunk_start, chunk_end)
            if spec.supports_filter
            else None
        )
        page_token = _resume_page_token(
            cursor,
            chunk_start,
            chunk_end,
            allow_resume=spec.resume_page_tokens,
            resume_running=resume_running,
        )
        async for points, next_page_token in client.iter_data_point_pages_with_tokens(
            data_type,
            access_token,
            filter_expr=filter_expr,
            prefer_reconcile=spec.prefer_reconcile,
            page_size=spec.page_size,
            page_token=page_token,
        ):
            records_seen += len(points)
            records_stored += _store_points(
                session,
                account,
                data_type,
                points,
                start=chunk_start,
                end=chunk_end,
            )
            cursor.last_successful_start = chunk_start
            cursor.last_successful_end = chunk_end
            cursor.last_page_token = next_page_token
            session.add(cursor)
            session.commit()
            page_token = None
        cursor.last_successful_start = start
        cursor.last_successful_end = chunk_end
        cursor.last_page_token = None
        session.add(cursor)
        session.commit()

    return records_seen, records_stored


def _store_points(
    session: Session,
    account: GoogleAccount,
    data_type: str,
    points: list[dict[str, object]],
    *,
    start: date,
    end: date,
) -> int:
    points = _points_in_range(data_type, points, start=start, end=end)
    if data_type == "heart-rate":
        return upsert_heart_rate_points_fast(
            session,
            account=account,
            points=points,
        )
    for point in points:
        upsert_raw_and_normalized(
            session,
            account=account,
            data_type=data_type,
            data_point=point,
        )
    return len(points)


def _points_in_range(
    data_type: str,
    points: list[dict[str, object]],
    *,
    start: date,
    end: date,
) -> list[dict[str, object]]:
    spec = DATA_TYPE_SPECS[data_type]
    filtered: list[dict[str, object]] = []
    for point in points:
        payload = point.get(spec.payload_key)
        point_date = _record_civil_date(payload) if isinstance(payload, dict) else None
        if point_date is not None and not start <= point_date <= end:
            continue
        filtered.append(point)
    return filtered


def _resume_page_token(
    cursor: SyncCursor,
    chunk_start: date,
    chunk_end: date,
    *,
    allow_resume: bool,
    resume_running: bool,
) -> str | None:
    if not allow_resume or not resume_running:
        return None
    if (
        cursor.last_page_token
        and cursor.last_successful_start == chunk_start
        and cursor.last_successful_end == chunk_end
    ):
        return cursor.last_page_token
    return None


def _should_skip_chunk_for_resume(
    cursor: SyncCursor,
    *,
    range_start: date,
    chunk_start: date,
    chunk_end: date,
    resume_running: bool,
) -> bool:
    if not resume_running or cursor.last_successful_start is None or cursor.last_successful_end is None:
        return False
    if cursor.last_page_token and chunk_end < cursor.last_successful_start:
        return True
    if (
        cursor.last_page_token is None
        and cursor.last_successful_start == range_start
        and chunk_end <= cursor.last_successful_end
    ):
        return True
    return False


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
    elif filter_time_path.endswith(".date"):
        start_value = start.isoformat()
        end_value = (end + timedelta(days=1)).isoformat()
    else:
        start_value = f"{start.isoformat()}T00:00:00"
        end_value = f"{(end + timedelta(days=1)).isoformat()}T00:00:00"
    return f'{filter_time_path} >= "{start_value}" AND {filter_time_path} < "{end_value}"'


def _rollup_data_points(
    data_type: str,
    payload_key: str,
    payload: dict[str, object],
) -> list[dict[str, object]]:
    points: list[dict[str, object]] = []
    for index, item in enumerate(payload.get("rollupDataPoints", [])):
        if not isinstance(item, dict):
            continue
        value_payload = dict(item.get(payload_key) or {})
        value_payload["interval"] = {
            "civilStartTime": item.get("civilStartTime"),
            "civilEndTime": item.get("civilEndTime"),
        }
        start_date = _rollup_civil_date_token(item.get("civilStartTime"))
        source_id = f"users/me/dataTypes/{data_type}/dailyRollUp/{start_date or index}"
        points.append(
            {
                "name": source_id,
                "dataSource": {"platform": "GOOGLE_HEALTH_DAILY_ROLLUP"},
                payload_key: value_payload,
            }
        )
    return points


def _rollup_chunks(start: date, end: date) -> list[tuple[date, date]]:
    chunks: list[tuple[date, date]] = []
    current = start
    while current <= end:
        chunk_end = min(end, current + timedelta(days=13))
        chunks.append((current, chunk_end))
        current = chunk_end + timedelta(days=1)
    return chunks


def _list_chunks(start: date, end: date, *, chunk_days: int | None) -> list[tuple[date, date]]:
    if chunk_days is None:
        return [(start, end)]
    chunks: list[tuple[date, date]] = []
    current = start
    while current <= end:
        chunk_end = min(end, current + timedelta(days=chunk_days - 1))
        chunks.append((current, chunk_end))
        current = chunk_end + timedelta(days=1)
    return chunks


def _rollup_civil_date_token(value: object) -> str | None:
    if not isinstance(value, dict):
        return None
    date_value = value.get("date")
    if not isinstance(date_value, dict):
        return None
    try:
        return (
            f"{int(date_value['year']):04d}-"
            f"{int(date_value['month']):02d}-"
            f"{int(date_value['day']):02d}"
        )
    except (KeyError, TypeError, ValueError):
        return None
