from __future__ import annotations

import logging

from sqlalchemy import select

from app.db.session import SessionLocal
from app.models import JournalState, User
from app.services.behaviour_analysis import needs_run, run_analysis
from app.services.health_dates import get_or_create_profile, local_date_for_profile
from app.tasks.celery_app import celery_app


logger = logging.getLogger(__name__)


def enqueue_behaviour_analysis(user_id: str, trigger: str) -> bool:
    try:
        run_behaviour_analysis.delay(user_id, trigger)
        return True
    except Exception:
        logger.warning("Behaviour analysis enqueue failed trigger=%s", trigger)
        return False


@celery_app.task(name="app.tasks.behaviour_analysis.run_behaviour_analysis")
def run_behaviour_analysis(user_id: str, trigger: str) -> str | None:
    with SessionLocal() as session:
        account = session.get(User, user_id)
        if account is None or account.deletion_scheduled_for is not None:
            return None
        return run_analysis(session, user_id, trigger=trigger).id


@celery_app.task(name="app.tasks.behaviour_analysis.refresh_due_analyses")
def refresh_due_analyses() -> int:
    queued = 0
    with SessionLocal() as session:
        user_ids = session.scalars(select(JournalState.user_id).join(
            User, User.id == JournalState.user_id,
        ).where(User.deletion_scheduled_for.is_(None))).all()
        for user_id in user_ids:
            today = local_date_for_profile(get_or_create_profile(session, user_id))
            trigger = needs_run(session, user_id, today)
            if trigger and enqueue_behaviour_analysis(user_id, trigger):
                queued += 1
    return queued
