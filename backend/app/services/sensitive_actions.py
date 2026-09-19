from __future__ import annotations

from datetime import timedelta

from sqlalchemy import select, update
from sqlalchemy.orm import Session

from app.core.security import generate_app_token, token_digest, utcnow, verify_token_digest
from app.models import SensitiveActionGrant


SENSITIVE_ACTION_PURPOSES = {"export", "delete_account", "recover_deletion"}


class SensitiveActionError(RuntimeError):
    pass


def create_sensitive_action_grant(
    session: Session,
    *,
    user_id: str,
    device_id_hash: str,
    purpose: str,
) -> str:
    if purpose not in SENSITIVE_ACTION_PURPOSES:
        raise SensitiveActionError("Unsupported sensitive action")
    token = generate_app_token()
    session.add(
        SensitiveActionGrant(
            user_id=user_id,
            device_id_hash=device_id_hash,
            purpose=purpose,
            token_hash=token_digest(token),
            expires_at=utcnow() + timedelta(minutes=5),
        )
    )
    session.commit()
    return token


def consume_sensitive_action_grant(
    session: Session,
    *,
    token: str,
    purpose: str,
    user_id: str | None = None,
    device_id: str | None = None,
) -> SensitiveActionGrant:
    grant = session.scalar(
        select(SensitiveActionGrant).where(SensitiveActionGrant.token_hash == token_digest(token))
    )
    now = utcnow()
    invalid = (
        grant is None
        or grant.purpose != purpose
        or grant.consumed_at is not None
        or aware(grant.expires_at) < now
        or (user_id is not None and grant.user_id != user_id)
        or (device_id is not None and not verify_token_digest(device_id, grant.device_id_hash))
    )
    if invalid:
        raise SensitiveActionError("Invalid or expired sensitive action grant")
    consumed = session.execute(
        update(SensitiveActionGrant)
        .where(
            SensitiveActionGrant.id == grant.id,
            SensitiveActionGrant.consumed_at.is_(None),
        )
        .values(consumed_at=now)
    )
    if consumed.rowcount != 1:
        session.rollback()
        raise SensitiveActionError("Invalid or expired sensitive action grant")
    session.commit()
    session.refresh(grant)
    return grant


def aware(value):
    if value.tzinfo is None:
        return value.replace(tzinfo=utcnow().tzinfo)
    return value
