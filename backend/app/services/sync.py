from __future__ import annotations

from dataclasses import dataclass, field
from datetime import UTC, date, datetime, time, timedelta
from time import perf_counter
from zoneinfo import ZoneInfo

from sqlalchemy import select
from sqlalchemy.orm import Session

from app.core.security import decrypt_secret, utcnow
from app.google_health.client import GoogleHealthClient
from app.google_health.data_types import DATA_TYPE_SPECS, MVP_SYNC_DATA_TYPES
from app.models import ConnectionStatus, GoogleAccount, SyncCursor, SyncStatus, UserProfile
from app.services.health_dates import timezone_for_profile
from app.services.normalization import (
    _record_civil_date,
    high_volume_records_for_points,
    upsert_measurement_points_fast,
    upsert_raw_and_normalized,
)
from app.services.metric_rollups import (
    HIGH_VOLUME_DATA_TYPES,
    MINUTE_ROLLUP_METRICS,
    replace_high_volume_rollups,
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


@dataclass
class SyncProfileEntry:
    data_type: str
    endpoint: str
    seconds: float = 0.0
    store_seconds: float = 0.0
    records_seen: int = 0
    records_stored: int = 0
    chunks: int = 0
    pages: int = 0
    status: str = "running"
    error: str | None = None

    @property
    def fetch_seconds(self) -> float:
        return max(0.0, self.seconds - self.store_seconds)


@dataclass
class SyncProfile:
    entries: dict[str, SyncProfileEntry] = field(default_factory=dict)
    summary_rebuild_seconds: float = 0.0
    score_rebuild_seconds: float = 0.0

    def start_type(self, data_type: str, endpoint: str) -> None:
        self.entries[data_type] = SyncProfileEntry(data_type=data_type, endpoint=endpoint)

    def record_chunk(self, data_type: str) -> None:
        self.entries[data_type].chunks += 1

    def record_page(self, data_type: str) -> None:
        self.entries[data_type].pages += 1

    def record_store(self, data_type: str, *, seconds: float, seen: int, stored: int) -> None:
        entry = self.entries[data_type]
        entry.store_seconds += seconds
        entry.records_seen += seen
        entry.records_stored += stored

    def finish_type(
        self,
        data_type: str,
        *,
        seconds: float,
        status: str,
        error: str | None = None,
    ) -> None:
        entry = self.entries[data_type]
        entry.seconds = seconds
        entry.status = status
        entry.error = error

    def as_dict(self) -> dict[str, object]:
        return {
            "data_types": [
                {
                    "data_type": entry.data_type,
                    "endpoint": entry.endpoint,
                    "seconds": round(entry.seconds, 3),
                    "fetch_seconds": round(entry.fetch_seconds, 3),
                    "store_seconds": round(entry.store_seconds, 3),
                    "records_seen": entry.records_seen,
                    "records_stored": entry.records_stored,
                    "chunks": entry.chunks,
                    "pages": entry.pages,
                    "status": entry.status,
                    "error": entry.error,
                }
                for entry in sorted(
                    self.entries.values(),
                    key=lambda item: item.seconds,
                    reverse=True,
                )
            ],
            "summary_rebuild_seconds": round(self.summary_rebuild_seconds, 3),
            "score_rebuild_seconds": round(self.score_rebuild_seconds, 3),
        }


@dataclass(frozen=True)
class SyncWindow:
    start: date
    end: date
    is_initial_backfill: bool


@dataclass(frozen=True)
class TypeSyncBounds:
    start: date
    end: date
    start_at: datetime | None = None
    end_at: datetime | None = None

    @property
    def uses_timestamp(self) -> bool:
        return self.start_at is not None and self.end_at is not None


def sync_window_from_cursors(
    session: Session,
    *,
    account: GoogleAccount,
    data_types: tuple[str, ...] = MVP_SYNC_DATA_TYPES,
    today: date | None = None,
    overlap_days: int = 1,
) -> SyncWindow:
    if not data_types:
        raise ValueError("At least one data type is required to choose a sync window")

    end = today or date.today()
    initial_start = end - timedelta(days=INITIAL_BACKFILL_DAYS - 1)
    cursors = session.scalars(
        select(SyncCursor).where(
            SyncCursor.google_account_id == account.id,
            SyncCursor.data_type.in_(data_types),
        )
    ).all()
    cursor_by_type = {cursor.data_type: cursor for cursor in cursors}
    last_successful_by_type = {
        cursor.data_type: cursor.last_successful_end
        for cursor in cursors
        if cursor.last_successful_end is not None
    }
    if not last_successful_by_type:
        return SyncWindow(start=initial_start, end=end, is_initial_backfill=True)

    start_candidates = [
        cursor_end - timedelta(days=overlap_days)
        for cursor_end in last_successful_by_type.values()
    ]
    missing_data_type = any(data_type not in cursor_by_type for data_type in data_types)
    if missing_data_type:
        start_candidates.append(initial_start)

    return SyncWindow(
        start=min(start_candidates),
        end=end,
        is_initial_backfill=missing_data_type,
    )


async def sync_google_account_range(
    session: Session,
    *,
    account: GoogleAccount,
    start: date,
    end: date,
    data_types: tuple[str, ...] = MVP_SYNC_DATA_TYPES,
    client: GoogleHealthClient | None = None,
    profile: SyncProfile | None = None,
    now: datetime | None = None,
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
    sync_now = now or utcnow()

    for data_type in data_types:
        spec = DATA_TYPE_SPECS[data_type]
        endpoint = "daily_rollup" if spec.prefer_daily_rollup else "reconcile" if spec.prefer_reconcile else "list"
        if profile:
            profile.start_type(data_type, endpoint)
        type_started = perf_counter()
        cursor = _get_or_create_cursor(session, account.id, data_type)
        resume_running = cursor.status == SyncStatus.running
        bounds = _bounds_for_data_type(
            session,
            account=account,
            cursor=cursor,
            data_type=data_type,
            start=start,
            end=end,
            now=sync_now,
        )
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
                bounds=bounds,
                cursor=cursor,
                resume_running=resume_running,
                profile=profile,
            )
            records_seen += seen
            records_stored += stored
            if profile:
                profile.finish_type(
                    data_type,
                    seconds=perf_counter() - type_started,
                    status="succeeded",
                )
            cursor.status = SyncStatus.succeeded
            _set_cursor_success(cursor, bounds)
            cursor.last_page_token = None
            successful_types.append(data_type)
            session.add(cursor)
            session.commit()
        except Exception as exc:
            session.rollback()
            cursor = _get_or_create_cursor(session, account.id, data_type)
            if profile:
                profile.finish_type(
                    data_type,
                    seconds=perf_counter() - type_started,
                    status="failed",
                    error=str(exc),
                )
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

    rebuild_started = perf_counter()
    rebuild_daily_summaries(session, user_id=account.user_id, start=start, end=end)
    if profile:
        profile.summary_rebuild_seconds = perf_counter() - rebuild_started
    affected_end = min(date.today(), end + timedelta(days=7))
    rebuild_started = perf_counter()
    rebuild_derived_scores(session, user_id=account.user_id, start=start, end=affected_end)
    if profile:
        profile.score_rebuild_seconds = perf_counter() - rebuild_started
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
    window = sync_window_from_cursors(session, account=account)
    return await sync_google_account_range(
        session,
        account=account,
        start=window.start,
        end=window.end,
        client=client,
    )


async def _sync_data_type(
    session: Session,
    *,
    account: GoogleAccount,
    client: GoogleHealthClient,
    access_token: str,
    data_type: str,
    bounds: TypeSyncBounds,
    cursor: SyncCursor,
    resume_running: bool,
    profile: SyncProfile | None = None,
) -> tuple[int, int]:
    spec = DATA_TYPE_SPECS[data_type]
    records_seen = 0
    records_stored = 0

    if spec.prefer_daily_rollup:
        for chunk_start, chunk_end in _rollup_chunks(bounds.start, bounds.end):
            if profile:
                profile.record_chunk(data_type)
            payload = await client.daily_rollup(
                data_type,
                access_token,
                start=chunk_start,
                end=chunk_end,
            )
            points = _rollup_data_points(data_type, spec.payload_key, payload)
            records_seen += len(points)
            store_started = perf_counter()
            stored = _store_points(
                session,
                account,
                data_type,
                points,
                start=chunk_start,
                end=chunk_end,
            )
            records_stored += stored
            if profile:
                profile.record_store(
                    data_type,
                    seconds=perf_counter() - store_started,
                    seen=len(points),
                    stored=stored,
                )
            cursor.last_successful_start = bounds.start
            cursor.last_successful_end = chunk_end
            cursor.last_page_token = None
            session.add(cursor)
            session.commit()
        return records_seen, records_stored

    chunks = (
        _timestamp_chunks(bounds.start_at, bounds.end_at, chunk_days=spec.chunk_days)
        if bounds.uses_timestamp
        else _list_chunks(bounds.start, bounds.end, chunk_days=spec.chunk_days)
    )
    for chunk_start, chunk_end in chunks:
        if profile:
            profile.record_chunk(data_type)
        if _should_skip_chunk_for_resume(
            cursor,
            range_start=bounds.start_at if bounds.uses_timestamp else bounds.start,
            chunk_start=chunk_start,
            chunk_end=chunk_end,
            resume_running=resume_running,
            use_timestamp=bounds.uses_timestamp,
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
            use_timestamp=bounds.uses_timestamp,
        )
        chunk_points: list[dict[str, object]] = []
        async for points, next_page_token in client.iter_data_point_pages_with_tokens(
            data_type,
            access_token,
            filter_expr=filter_expr,
            prefer_reconcile=spec.prefer_reconcile,
            page_size=spec.page_size,
            page_token=page_token,
        ):
            if profile:
                profile.record_page(data_type)
            records_seen += len(points)
            if data_type in HIGH_VOLUME_DATA_TYPES:
                chunk_points.extend(points)
                cursor.last_page_token = next_page_token
                page_token = None
                continue
            store_started = perf_counter()
            stored = _store_points(
                session,
                account,
                data_type,
                points,
                start=_bound_date(chunk_start),
                end=_bound_date(chunk_end),
            )
            records_stored += stored
            if profile:
                profile.record_store(
                    data_type,
                    seconds=perf_counter() - store_started,
                    seen=len(points),
                    stored=stored,
                )
            _set_cursor_chunk_progress(cursor, bounds, chunk_start, chunk_end)
            cursor.last_page_token = next_page_token
            session.add(cursor)
            session.commit()
            page_token = None
        if data_type in HIGH_VOLUME_DATA_TYPES:
            store_started = perf_counter()
            filtered_points = _points_in_range(
                data_type,
                chunk_points,
                start=_bound_date(chunk_start),
                end=_bound_date(chunk_end),
            )
            records = high_volume_records_for_points(
                data_type=data_type,
                points=filtered_points,
            )
            stored = replace_high_volume_rollups(
                session,
                account=account,
                metric=spec.metric,
                records=records,
                range_start=_range_start_datetime(session, account, spec.filter_time_path, chunk_start),
                range_end=_range_end_datetime(session, account, spec.filter_time_path, chunk_end),
            )
            records_stored += stored
            if profile:
                profile.record_store(
                    data_type,
                    seconds=perf_counter() - store_started,
                    seen=len(filtered_points),
                    stored=stored,
                )
        _set_cursor_chunk_complete(cursor, bounds, chunk_end)
        cursor.last_page_token = None
        session.add(cursor)
        session.commit()

    return records_seen, records_stored


def _bounds_for_data_type(
    session: Session,
    *,
    account: GoogleAccount,
    cursor: SyncCursor,
    data_type: str,
    start: date,
    end: date,
    now: datetime,
) -> TypeSyncBounds:
    spec = DATA_TYPE_SPECS[data_type]
    if data_type in HIGH_VOLUME_DATA_TYPES and spec.metric not in MINUTE_ROLLUP_METRICS:
        return TypeSyncBounds(start=start, end=end)
    if not spec.use_timestamp_cursor:
        return TypeSyncBounds(start=start, end=end)

    end_at = _timestamp_end_for_filter(session, account, spec.filter_time_path, end, now)
    if (
        cursor.status == SyncStatus.running
        and cursor.last_page_token
        and cursor.last_successful_start_at is not None
        and cursor.last_successful_end_at is not None
    ):
        start_at = _normalize_timestamp_for_filter(
            session,
            account,
            spec.filter_time_path,
            cursor.last_successful_start_at,
        )
        saved_end_at = _normalize_timestamp_for_filter(
            session,
            account,
            spec.filter_time_path,
            cursor.last_successful_end_at,
        )
        return TypeSyncBounds(
            start=_bound_date(start_at),
            end=_bound_date(max(saved_end_at, end_at)),
            start_at=start_at,
            end_at=max(saved_end_at, end_at),
        )
    start_at = _timestamp_start_for_filter(
        session,
        account=account,
        cursor=cursor,
        filter_time_path=spec.filter_time_path,
        start=start,
        end=end,
        end_at=end_at,
        overlap=timedelta(minutes=spec.timestamp_overlap_minutes),
    )
    if start_at >= end_at:
        start_at = end_at - timedelta(minutes=spec.timestamp_overlap_minutes)
    return TypeSyncBounds(
        start=_bound_date(start_at),
        end=_bound_date(end_at),
        start_at=start_at,
        end_at=end_at,
    )


def _timestamp_end_for_filter(
    session: Session,
    account: GoogleAccount,
    filter_time_path: str,
    end: date,
    now: datetime,
) -> datetime:
    if filter_time_path.endswith("physical_time"):
        current = _ensure_aware(now, UTC).astimezone(UTC)
        range_end = datetime.combine(end + timedelta(days=1), time.min, tzinfo=UTC)
        return min(current, range_end)
    tz = _account_timezone(session, account)
    current = _ensure_aware(now, UTC).astimezone(tz)
    range_end = datetime.combine(end + timedelta(days=1), time.min, tzinfo=tz)
    return min(current, range_end)


def _timestamp_start_for_filter(
    session: Session,
    *,
    account: GoogleAccount,
    cursor: SyncCursor,
    filter_time_path: str,
    start: date,
    end: date,
    end_at: datetime,
    overlap: timedelta,
) -> datetime:
    if cursor.last_successful_end_at is not None:
        base = _normalize_timestamp_for_filter(
            session,
            account,
            filter_time_path,
            cursor.last_successful_end_at,
        )
        return min(base, end_at) - overlap

    if cursor.last_successful_end is not None:
        if cursor.last_successful_end >= end:
            return end_at - overlap
        legacy_end = _date_start_for_filter(
            session,
            account,
            filter_time_path,
            cursor.last_successful_end + timedelta(days=1),
        )
        return min(legacy_end, end_at) - overlap

    return _date_start_for_filter(session, account, filter_time_path, start)


def _date_start_for_filter(
    session: Session,
    account: GoogleAccount,
    filter_time_path: str,
    value: date,
) -> datetime:
    if filter_time_path.endswith("physical_time"):
        return datetime.combine(value, time.min, tzinfo=UTC)
    return datetime.combine(value, time.min, tzinfo=_account_timezone(session, account))


def _range_start_datetime(
    session: Session,
    account: GoogleAccount,
    filter_time_path: str,
    value: date | datetime,
) -> datetime:
    if isinstance(value, datetime):
        return _normalize_timestamp_for_filter(session, account, filter_time_path, value)
    return _date_start_for_filter(session, account, filter_time_path, value)


def _range_end_datetime(
    session: Session,
    account: GoogleAccount,
    filter_time_path: str,
    value: date | datetime,
) -> datetime:
    if isinstance(value, datetime):
        return _normalize_timestamp_for_filter(session, account, filter_time_path, value)
    return _date_start_for_filter(session, account, filter_time_path, value + timedelta(days=1))


def _normalize_timestamp_for_filter(
    session: Session,
    account: GoogleAccount,
    filter_time_path: str,
    value: datetime,
) -> datetime:
    if filter_time_path.endswith("physical_time"):
        return _ensure_aware(value, UTC).astimezone(UTC)
    tz = _account_timezone(session, account)
    return _ensure_aware(value, tz).astimezone(tz)


def _account_timezone(session: Session, account: GoogleAccount) -> ZoneInfo:
    profile = session.scalar(select(UserProfile).where(UserProfile.user_id == account.user_id))
    if profile is None:
        return ZoneInfo("UTC")
    return timezone_for_profile(profile)


def _ensure_aware(value: datetime, default_tz: ZoneInfo) -> datetime:
    if value.tzinfo is None:
        return value.replace(tzinfo=default_tz)
    return value


def _bound_date(value: date | datetime) -> date:
    if isinstance(value, datetime):
        return value.date()
    return value


def _set_cursor_success(cursor: SyncCursor, bounds: TypeSyncBounds) -> None:
    cursor.last_successful_start = bounds.start
    cursor.last_successful_end = bounds.end
    if bounds.uses_timestamp:
        cursor.last_successful_start_at = bounds.start_at
        cursor.last_successful_end_at = bounds.end_at


def _set_cursor_chunk_progress(
    cursor: SyncCursor,
    bounds: TypeSyncBounds,
    chunk_start: date | datetime,
    chunk_end: date | datetime,
) -> None:
    if bounds.uses_timestamp:
        cursor.last_successful_start = bounds.start
        cursor.last_successful_end = _bound_date(chunk_end)
        cursor.last_successful_start_at = chunk_start if isinstance(chunk_start, datetime) else None
        cursor.last_successful_end_at = chunk_end if isinstance(chunk_end, datetime) else None
        return
    cursor.last_successful_start = _bound_date(chunk_start)
    cursor.last_successful_end = _bound_date(chunk_end)


def _set_cursor_chunk_complete(
    cursor: SyncCursor,
    bounds: TypeSyncBounds,
    chunk_end: date | datetime,
) -> None:
    cursor.last_successful_start = bounds.start
    cursor.last_successful_end = _bound_date(chunk_end)
    if bounds.uses_timestamp:
        cursor.last_successful_start_at = bounds.start_at
        cursor.last_successful_end_at = chunk_end if isinstance(chunk_end, datetime) else None


def _store_points(
    session: Session,
    account: GoogleAccount,
    data_type: str,
    points: list[dict[str, object]],
    *,
    start: date,
    end: date,
) -> int:
    spec = DATA_TYPE_SPECS[data_type]
    points = _points_in_range(data_type, points, start=start, end=end)
    if spec.storage in {"interval", "sample"}:
        return upsert_measurement_points_fast(
            session,
            account=account,
            data_type=data_type,
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
    chunk_start: date | datetime,
    chunk_end: date | datetime,
    *,
    allow_resume: bool,
    resume_running: bool,
    use_timestamp: bool,
) -> str | None:
    if not allow_resume or not resume_running:
        return None
    if use_timestamp:
        if (
            cursor.last_page_token
            and cursor.last_successful_start_at == chunk_start
            and cursor.last_successful_end_at == chunk_end
        ):
            return cursor.last_page_token
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
    range_start: date | datetime,
    chunk_start: date | datetime,
    chunk_end: date | datetime,
    resume_running: bool,
    use_timestamp: bool,
) -> bool:
    if not resume_running:
        return False
    if use_timestamp:
        successful_start = cursor.last_successful_start_at
        successful_end = cursor.last_successful_end_at
    else:
        successful_start = cursor.last_successful_start
        successful_end = cursor.last_successful_end
    if successful_start is None or successful_end is None:
        return False
    if cursor.last_page_token and chunk_end < successful_start:
        return True
    if (
        cursor.last_page_token is None
        and successful_start == range_start
        and chunk_end <= successful_end
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


def _filter_for_range(filter_time_path: str, start: date | datetime, end: date | datetime) -> str:
    if isinstance(start, datetime) and isinstance(end, datetime):
        if filter_time_path.endswith("physical_time"):
            start_value = _format_physical_datetime(start)
            end_value = _format_physical_datetime(end)
        elif filter_time_path.endswith(".date"):
            start_value = start.date().isoformat()
            end_value = end.date().isoformat()
        else:
            start_value = _format_civil_datetime(start)
            end_value = _format_civil_datetime(end)
    elif isinstance(start, date) and isinstance(end, date):
        if filter_time_path.endswith("physical_time"):
            start_value = f"{start.isoformat()}T00:00:00Z"
            end_value = f"{(end + timedelta(days=1)).isoformat()}T00:00:00Z"
        elif filter_time_path.endswith(".date"):
            start_value = start.isoformat()
            end_value = (end + timedelta(days=1)).isoformat()
        else:
            start_value = f"{start.isoformat()}T00:00:00"
            end_value = f"{(end + timedelta(days=1)).isoformat()}T00:00:00"
    else:
        raise TypeError("Sync range bounds must both be dates or both be datetimes")
    return f'{filter_time_path} >= "{start_value}" AND {filter_time_path} < "{end_value}"'


def _format_physical_datetime(value: datetime) -> str:
    return _ensure_aware(value, UTC).astimezone(UTC).isoformat(timespec="seconds").replace(
        "+00:00",
        "Z",
    )


def _format_civil_datetime(value: datetime) -> str:
    if value.tzinfo is not None:
        value = value.replace(tzinfo=None)
    return value.isoformat(timespec="seconds")


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


def _timestamp_chunks(
    start: datetime | None,
    end: datetime | None,
    *,
    chunk_days: int | None,
) -> list[tuple[datetime, datetime]]:
    if start is None or end is None:
        return []
    if start >= end:
        return []
    if chunk_days is None:
        return [(start, end)]
    chunks: list[tuple[datetime, datetime]] = []
    current = start
    while current < end:
        chunk_end = min(end, current + timedelta(days=chunk_days))
        chunks.append((current, chunk_end))
        current = chunk_end
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
