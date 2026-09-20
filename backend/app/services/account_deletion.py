from __future__ import annotations

import logging
from datetime import datetime, timedelta

from sqlalchemy import select
from sqlalchemy.orm import Session

from app.core.security import decrypt_secret, token_digest, utcnow
from app.google_health.client import GoogleHealthClient
from app.models import AppSession, ConnectionStatus, GoogleAccount, User
from app.services.app_auth import revoke_session


logger = logging.getLogger(__name__)

DELETION_GRACE_PERIOD = timedelta(days=14)


def schedule_account_deletion(
    session: Session,
    user: User,
    *,
    now: datetime | None = None,
) -> User:
    requested_at = now or utcnow()
    user = session.scalar(select(User).where(User.id == user.id).with_for_update()) or user
    if user.deletion_scheduled_for is None:
        user.deletion_requested_at = requested_at
        user.deletion_scheduled_for = requested_at + DELETION_GRACE_PERIOD

    for app_session in session.scalars(
        select(AppSession).where(AppSession.user_id == user.id)
    ):
        revoke_session(session, app_session)

    for account in session.scalars(
        select(GoogleAccount).where(GoogleAccount.user_id == user.id)
    ):
        account.status = ConnectionStatus.disconnected
        account.disconnected_at = requested_at
        account.sync_started_at = None
        session.add(account)

    session.add(user)
    session.commit()
    session.refresh(user)
    return user


async def purge_due_accounts(
    session: Session,
    *,
    now: datetime | None = None,
    google_client: GoogleHealthClient | None = None,
) -> dict[str, int]:
    cutoff = now or utcnow()
    user_ids = session.scalars(
        select(User.id).where(
            User.deletion_scheduled_for.is_not(None),
            User.deletion_scheduled_for <= cutoff,
        )
    ).all()
    client = google_client or GoogleHealthClient()
    purged = 0
    failed = 0
    revocation_failed = 0

    for user_id in user_ids:
        try:
            user = session.scalar(select(User).where(User.id == user_id).with_for_update())
            if (
                user is None
                or user.deletion_scheduled_for is None
                or aware(user.deletion_scheduled_for) > cutoff
            ):
                session.rollback()
                continue
            accounts = session.scalars(
                select(GoogleAccount).where(GoogleAccount.user_id == user.id)
            ).all()
            for account in accounts:
                if account.encrypted_refresh_token:
                    try:
                        await client.revoke_token(decrypt_secret(account.encrypted_refresh_token))
                    except Exception as exc:
                        revocation_failed += 1
                        logger.warning(
                            "Provider credential revocation failed before account purge user=%s (%s)",
                            token_digest(user.id)[:12],
                            type(exc).__name__,
                        )
            session.delete(user)
            session.commit()
            purged += 1
        except Exception as exc:
            session.rollback()
            failed += 1
            logger.error(
                "Scheduled account purge failed for user %s (%s)",
                token_digest(user_id)[:12],
                type(exc).__name__,
            )

    return {"purged": purged, "failed": failed, "revocation_failed": revocation_failed}


def aware(value: datetime) -> datetime:
    if value.tzinfo is None:
        return value.replace(tzinfo=utcnow().tzinfo)
    return value
