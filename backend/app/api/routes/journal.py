from __future__ import annotations

import logging

from fastapi import APIRouter, HTTPException, Query, Request
from fastapi.exceptions import RequestValidationError
from fastapi.routing import APIRoute
from sqlalchemy import select

from app.api.deps import CurrentUser, DbSession
from app.journal import JournalCatalogue
from app.models import JournalEntry
from app.services.journal_catalogue import CATALOGUES
from app.services.journal_storage import (
    CLOCK_AHEAD, JournalAccountUnavailable, JournalSync, apply_sync, changes, entry_payload,
)


logger = logging.getLogger(__name__)
class JournalRoute(APIRoute):
    def get_route_handler(self):
        handler = super().get_route_handler()

        async def safe_handler(request: Request):
            try:
                return await handler(request)
            except RequestValidationError as exc:
                if any(error["type"] == CLOCK_AHEAD for error in exc.errors()):
                    logger.warning("Journal request rejected reason=clock_ahead")
                    raise HTTPException(422, {
                        "code": CLOCK_AHEAD,
                        "message": "This device's clock is ahead. Set the date and time automatically, then retry.",
                    }) from exc
                logger.warning("Journal request rejected reason=invalid_schema")
                # FastAPI's default validation response echoes rejected health values.
                raise HTTPException(422, "Invalid journal request") from exc
            except JournalAccountUnavailable:
                raise HTTPException(401, "Account is unavailable") from None

        return safe_handler


router = APIRouter(prefix="/journal", tags=["journal"], route_class=JournalRoute)


@router.get("/catalogue", response_model=JournalCatalogue)
def get_catalogue(user: CurrentUser, version: int = Query(default=1, ge=1)) -> JournalCatalogue:
    catalogue = CATALOGUES.get(version)
    if catalogue is None:
        logger.warning("Journal catalogue unavailable reason=unsupported_version")
        raise HTTPException(status_code=404, detail="Journal catalogue version is unavailable")
    return catalogue


@router.post("/sync")
def synchronize(payload: JournalSync, session: DbSession, user: CurrentUser) -> dict:
    try:
        return apply_sync(session, user.id, payload)
    except JournalAccountUnavailable:
        session.rollback()
        raise
    except ValueError as exc:
        session.rollback()
        logger.warning("Journal sync rejected reason=invalid_contract")
        raise HTTPException(422, "Journal changes could not be accepted. Check category access and answers.") from exc
    except Exception:
        session.rollback()
        logger.error("Journal sync failed reason=storage_failure")
        raise HTTPException(503, "Journal sync is unavailable. Retry your saved changes.") from None


@router.get("/changes")
def get_changes(session: DbSession, user: CurrentUser, after: int = Query(0, ge=0),
                limit: int = Query(200, ge=1, le=500)) -> dict:
    return changes(session, user.id, after, limit)


@router.get("/entries")
def get_entries(session: DbSession, user: CurrentUser,
                start: str = Query(...), end: str = Query(...)) -> list[dict]:
    from datetime import date

    try:
        first, last = date.fromisoformat(start), date.fromisoformat(end)
        if first > last or (last - first).days > 366:
            raise ValueError
    except ValueError:
        raise HTTPException(422, "Use an ordered date range of at most 367 days") from None
    rows = session.scalars(select(JournalEntry).where(
        JournalEntry.user_id == user.id, JournalEntry.journal_date.between(first, last),
        JournalEntry.deleted.is_(False),
    ).order_by(JournalEntry.journal_date, JournalEntry.behaviour_id))
    return [entry_payload(row) for row in rows]
