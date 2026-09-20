from __future__ import annotations

from datetime import datetime

from sqlalchemy import select
from sqlalchemy.orm import Session

from app.core.security import utcnow
from app.models import ConnectionStatus, GoogleAccount, User


class AccountRecoveryError(RuntimeError):
    pass


def recover_account(session: Session, user: User, *, now: datetime | None = None) -> User:
    if user.deletion_scheduled_for is None:
        raise AccountRecoveryError("Account is not scheduled for deletion")
    if aware(user.deletion_scheduled_for) <= (now or utcnow()):
        raise AccountRecoveryError("Account recovery period has ended")

    recovered_at = now or utcnow()
    user.deletion_requested_at = None
    user.deletion_scheduled_for = None
    for account in session.scalars(
        select(GoogleAccount).where(GoogleAccount.user_id == user.id)
    ):
        if account.encrypted_refresh_token:
            account.status = ConnectionStatus.connected
            account.connected_at = recovered_at
            account.disconnected_at = None
            account.last_error = None
            session.add(account)
    session.add(user)
    session.commit()
    session.refresh(user)
    return user


def aware(value: datetime) -> datetime:
    if value.tzinfo is None:
        return value.replace(tzinfo=utcnow().tzinfo)
    return value
