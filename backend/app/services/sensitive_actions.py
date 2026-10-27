from __future__ import annotations

from datetime import timedelta

from sqlalchemy import select, update
from sqlalchemy.orm import Session

from app.core.security import generate_app_token, token_digest, utcnow, verify_token_digest
from app.models import SensitiveActionGrant
from app.services.device_keys import (
    DeviceKeyError,
    recovery_transcript,
    sensitive_action_transcript,
    verify_signature,
)


SENSITIVE_ACTION_PURPOSES = {"export", "delete_account", "recover_deletion"}


class SensitiveActionError(RuntimeError):
    pass


def create_sensitive_action_challenge(
    session: Session,
    *,
    user_id: str,
    device_id_hash: str,
    purpose: str,
    device_public_key: str,
    session_id: str | None = None,
) -> str:
    if purpose not in SENSITIVE_ACTION_PURPOSES:
        raise SensitiveActionError("Unsupported sensitive action")
    token = generate_app_token()
    session.add(
        SensitiveActionGrant(
            user_id=user_id,
            device_id_hash=device_id_hash,
            session_id=session_id,
            device_public_key=device_public_key,
            purpose=purpose,
            token_hash=token_digest(token),
            expires_at=utcnow() + timedelta(minutes=5),
        )
    )
    session.commit()
    return token


def authorize_sensitive_action_challenge(
    session: Session,
    *,
    challenge: str,
    signature: str,
    purpose: str,
    user_id: str,
    session_id: str,
) -> None:
    grant = get_valid_challenge(session, challenge, purpose)
    if grant.user_id != user_id or grant.session_id != session_id or not grant.device_public_key:
        raise SensitiveActionError("Invalid or expired sensitive action challenge")
    try:
        verify_signature(
            grant.device_public_key,
            signature,
            sensitive_action_transcript(purpose, session_id, challenge),
        )
    except DeviceKeyError as exc:
        raise SensitiveActionError("Invalid device signature") from exc
    verified = session.execute(
        update(SensitiveActionGrant)
        .where(
            SensitiveActionGrant.id == grant.id,
            SensitiveActionGrant.verified_at.is_(None),
            SensitiveActionGrant.consumed_at.is_(None),
        )
        .values(verified_at=utcnow())
    )
    if verified.rowcount != 1:
        session.rollback()
        raise SensitiveActionError("Invalid or expired sensitive action challenge")
    session.commit()


def consume_recovery_challenge(
    session: Session,
    *,
    challenge: str,
    signature: str,
    device_id: str,
) -> SensitiveActionGrant:
    grant = get_valid_challenge(session, challenge, "recover_deletion")
    if (
        grant.session_id is not None
        or not grant.device_public_key
        or not verify_token_digest(device_id, grant.device_id_hash)
    ):
        raise SensitiveActionError("Invalid or expired sensitive action challenge")
    try:
        verify_signature(
            grant.device_public_key,
            signature,
            recovery_transcript(challenge, device_id),
        )
    except DeviceKeyError as exc:
        raise SensitiveActionError("Invalid device signature") from exc
    now = utcnow()
    consumed = session.execute(
        update(SensitiveActionGrant)
        .where(
            SensitiveActionGrant.id == grant.id,
            SensitiveActionGrant.verified_at.is_(None),
            SensitiveActionGrant.consumed_at.is_(None),
        )
        .values(verified_at=now, consumed_at=now)
    )
    if consumed.rowcount != 1:
        session.rollback()
        raise SensitiveActionError("Invalid or expired sensitive action challenge")
    session.commit()
    session.refresh(grant)
    return grant


def consume_sensitive_action_grant(
    session: Session,
    *,
    token: str,
    purpose: str,
    user_id: str | None = None,
    device_id: str | None = None,
    session_id: str | None = None,
) -> SensitiveActionGrant:
    grant = session.scalar(
        select(SensitiveActionGrant).where(SensitiveActionGrant.token_hash == token_digest(token))
    )
    now = utcnow()
    invalid = (
        grant is None
        or grant.purpose != purpose
        or grant.consumed_at is not None
        or grant.verified_at is None
        or aware(grant.expires_at) < now
        or (user_id is not None and grant.user_id != user_id)
        or (device_id is not None and not verify_token_digest(device_id, grant.device_id_hash))
        or (session_id is not None and grant.session_id != session_id)
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


def get_valid_challenge(
    session: Session,
    challenge: str,
    purpose: str,
) -> SensitiveActionGrant:
    grant = session.scalar(
        select(SensitiveActionGrant).where(
            SensitiveActionGrant.token_hash == token_digest(challenge)
        )
    )
    if (
        grant is None
        or grant.purpose != purpose
        or grant.verified_at is not None
        or grant.consumed_at is not None
        or aware(grant.expires_at) < utcnow()
    ):
        raise SensitiveActionError("Invalid or expired sensitive action challenge")
    return grant


def aware(value):
    if value.tzinfo is None:
        return value.replace(tzinfo=utcnow().tzinfo)
    return value
