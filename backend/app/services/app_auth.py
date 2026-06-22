from __future__ import annotations

from dataclasses import dataclass
from datetime import timedelta

from sqlalchemy import select, update
from sqlalchemy.orm import Session

from app.core.config import get_settings
from app.core.security import generate_app_token, token_digest, utcnow, verify_token_digest
from app.models import AppAccessToken, AppAuthCode, AppRefreshToken, AppSession, User


class AppAuthError(RuntimeError):
    pass


@dataclass(frozen=True)
class TokenPair:
    access_token: str
    refresh_token: str
    token_type: str
    expires_in: int
    session_id: str


def device_id_digest(device_id: str) -> str:
    return token_digest(device_id)


def create_app_auth_code(session: Session, *, user_id: str, device_id_hash: str) -> str:
    settings = get_settings()
    code = generate_app_token()
    app_code = AppAuthCode(
        user_id=user_id,
        code_hash=token_digest(code),
        device_id_hash=device_id_hash,
        expires_at=utcnow() + timedelta(minutes=settings.app_auth_code_ttl_minutes),
    )
    session.add(app_code)
    session.commit()
    return code


def exchange_auth_code(
    session: Session,
    *,
    code: str,
    device_id: str,
    user_agent: str | None = None,
) -> TokenPair:
    app_code = _get_auth_code(session, code)
    now = utcnow()
    if (
        app_code is None
        or app_code.consumed_at is not None
        or _aware(app_code.expires_at) < now
        or not verify_token_digest(device_id, app_code.device_id_hash)
    ):
        raise AppAuthError("Invalid or expired authorization code")

    app_code.consumed_at = now
    app_session = AppSession(
        user_id=app_code.user_id,
        device_id_hash=app_code.device_id_hash,
        expires_at=now + timedelta(days=get_settings().refresh_token_ttl_days),
        last_used_at=now,
        user_agent=(user_agent or "")[:256] or None,
    )
    session.add(app_code)
    session.add(app_session)
    session.flush()
    token_pair = _issue_token_pair(session, app_session)
    session.commit()
    return token_pair


def refresh_tokens(
    session: Session,
    *,
    refresh_token: str,
    device_id: str,
) -> TokenPair:
    token = _get_refresh_token(session, refresh_token)
    if token is None:
        raise AppAuthError("Invalid or expired token")

    app_session = session.get(AppSession, token.session_id)
    now = utcnow()
    compromised = (
        token.used_at is not None
        or token.revoked_at is not None
        or app_session is None
        or app_session.revoked_at is not None
        or _aware(token.expires_at) < now
        or (app_session is not None and _aware(app_session.expires_at) < now)
        or (app_session is not None and not verify_token_digest(device_id, app_session.device_id_hash))
    )
    if compromised:
        if app_session is not None:
            revoke_session(session, app_session)
            session.commit()
        raise AppAuthError("Invalid or expired token")

    token.used_at = now
    token.revoked_at = now
    app_session.last_used_at = now
    session.add(token)
    session.add(app_session)
    token_pair = _issue_token_pair(session, app_session)
    session.commit()
    return token_pair


def authenticate_access_token(session: Session, raw_token: str) -> User:
    token = session.scalar(
        select(AppAccessToken).where(AppAccessToken.token_hash == token_digest(raw_token))
    )
    now = utcnow()
    if token is None or token.revoked_at is not None or _aware(token.expires_at) < now:
        raise AppAuthError("Invalid or expired token")
    app_session = session.get(AppSession, token.session_id)
    if app_session is None or app_session.revoked_at is not None or _aware(app_session.expires_at) < now:
        raise AppAuthError("Invalid or expired token")
    user = session.get(User, token.user_id)
    if user is None:
        raise AppAuthError("Invalid or expired token")
    app_session.last_used_at = now
    session.add(app_session)
    session.commit()
    return user


def revoke_with_refresh_token(session: Session, *, refresh_token: str, device_id: str | None = None) -> None:
    token = _get_refresh_token(session, refresh_token)
    if token is None:
        return
    app_session = session.get(AppSession, token.session_id)
    if app_session is None:
        return
    if device_id and not verify_token_digest(device_id, app_session.device_id_hash):
        return
    revoke_session(session, app_session)
    session.commit()


def revoke_with_access_token(session: Session, *, access_token: str) -> None:
    token = session.scalar(
        select(AppAccessToken).where(AppAccessToken.token_hash == token_digest(access_token))
    )
    if token is None:
        return
    app_session = session.get(AppSession, token.session_id)
    if app_session is not None:
        revoke_session(session, app_session)
        session.commit()


def revoke_session(session: Session, app_session: AppSession) -> None:
    now = utcnow()
    app_session.revoked_at = app_session.revoked_at or now
    session.add(app_session)
    session.execute(
        update(AppAccessToken)
        .where(AppAccessToken.session_id == app_session.id, AppAccessToken.revoked_at.is_(None))
        .values(revoked_at=now)
    )
    session.execute(
        update(AppRefreshToken)
        .where(AppRefreshToken.session_id == app_session.id, AppRefreshToken.revoked_at.is_(None))
        .values(revoked_at=now)
    )


def _issue_token_pair(session: Session, app_session: AppSession) -> TokenPair:
    settings = get_settings()
    access_token = generate_app_token()
    refresh_token = generate_app_token()
    access_expires_at = utcnow() + timedelta(minutes=settings.access_token_ttl_minutes)
    refresh_expires_at = min(
        _aware(app_session.expires_at),
        utcnow() + timedelta(days=settings.refresh_token_ttl_days),
    )
    access = AppAccessToken(
        session_id=app_session.id,
        user_id=app_session.user_id,
        token_hash=token_digest(access_token),
        expires_at=access_expires_at,
    )
    refresh = AppRefreshToken(
        session_id=app_session.id,
        user_id=app_session.user_id,
        token_hash=token_digest(refresh_token),
        expires_at=refresh_expires_at,
    )
    session.add(access)
    session.add(refresh)
    session.flush()
    return TokenPair(
        access_token=access_token,
        refresh_token=refresh_token,
        token_type="bearer",
        expires_in=settings.access_token_ttl_minutes * 60,
        session_id=app_session.id,
    )


def _get_auth_code(session: Session, code: str) -> AppAuthCode | None:
    return session.scalar(select(AppAuthCode).where(AppAuthCode.code_hash == token_digest(code)))


def _get_refresh_token(session: Session, refresh_token: str) -> AppRefreshToken | None:
    return session.scalar(
        select(AppRefreshToken).where(AppRefreshToken.token_hash == token_digest(refresh_token))
    )


def _aware(value):
    if value.tzinfo is None:
        return value.replace(tzinfo=utcnow().tzinfo)
    return value
