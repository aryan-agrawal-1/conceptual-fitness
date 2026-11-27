from __future__ import annotations

from datetime import datetime

from sqlalchemy import or_, select
from sqlalchemy.orm import Session

from app.core.security import utcnow
from app.models import ConnectionStatus, HealthConnection, User
from app.services.device_ingestion import APPLE_HEALTH_PROVIDER


class AccountRecoveryError(RuntimeError):
    pass


def recover_account(session: Session, user: User, *, now: datetime | None = None) -> User:
    if user.deletion_scheduled_for is None:
        raise AccountRecoveryError("Account is not scheduled for deletion")
    if aware(user.deletion_scheduled_for) <= (now or utcnow()):
        raise AccountRecoveryError("Account recovery period has ended")

    recovered_at = now or utcnow()
    deletion_requested_at = user.deletion_requested_at
    user.deletion_requested_at = None
    user.deletion_scheduled_for = None
    restorable = connection_closed_by_deletion(session, user.id, deletion_requested_at)
    if restorable is not None:
        restorable.status = ConnectionStatus.connected
        restorable.connected_at = recovered_at
        restorable.disconnected_at = None
        restorable.last_error = None
        session.add(restorable)
    session.add(user)
    session.commit()
    session.refresh(user)
    return user


def connection_closed_by_deletion(
    session: Session, user_id: str, deletion_requested_at: datetime | None
) -> HealthConnection | None:
    if deletion_requested_at is None:
        return None
    return session.scalar(
        select(HealthConnection)
        .where(
            HealthConnection.user_id == user_id,
            HealthConnection.status == ConnectionStatus.disconnected,
            HealthConnection.disconnected_at >= deletion_requested_at,
            or_(
                HealthConnection.provider == APPLE_HEALTH_PROVIDER,
                HealthConnection.encrypted_refresh_token.is_not(None),
            ),
        )
        .order_by(HealthConnection.connected_at.desc())
    )


def aware(value: datetime) -> datetime:
    if value.tzinfo is None:
        return value.replace(tzinfo=utcnow().tzinfo)
    return value
