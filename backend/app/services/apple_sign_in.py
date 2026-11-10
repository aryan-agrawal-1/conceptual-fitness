from __future__ import annotations

import hashlib
import hmac
import logging

from sqlalchemy import select
from sqlalchemy.orm import Session

from app.apple.client import AppleClient
from app.core.config import get_settings, missing_apple_keys
from app.core.security import (
    expires_in,
    generate_state_token,
    state_digest,
    token_digest,
    verify_token_digest,
)
from app.models import AppSession, OAuthState, User
from app.services.account_deletion import schedule_account_deletion
from app.services.app_auth import device_id_digest, revoke_session
from app.services.device_keys import DeviceKeyError, normalize_public_key
from app.services.oauth import (
    APPLE_SIGN_IN_PROVIDER,
    SENSITIVE_PURPOSES,
    SIGN_IN,
    OAuthConfigurationError,
    OAuthStateError,
    SignInCompletion,
    complete_sign_in,
    consume_oauth_state,
    sign_in_identity,
)

logger = logging.getLogger(__name__)

APPLE_SCOPES = ["name", "email"]
NONCE_LIFETIME_MINUTES = 10
CONSENT_REVOKED = "consent-revoked"
ACCOUNT_DELETED = "account-delete"


def create_apple_nonce(
    session: Session,
    *,
    device_id: str,
    purpose: str = SIGN_IN,
    user_id: str | None = None,
    device_public_key: str | None = None,
    source_session_id: str | None = None,
) -> str:
    missing = missing_apple_keys(get_settings())
    if missing:
        raise OAuthConfigurationError(f"Apple configuration is incomplete: {', '.join(missing)}")
    normalized_public_key = normalize_public_key(device_public_key) if device_public_key else None
    if purpose in SENSITIVE_PURPOSES and not normalized_public_key:
        raise DeviceKeyError("Device public key is required")
    nonce = generate_state_token()
    session.add(
        OAuthState(
            provider=APPLE_SIGN_IN_PROVIDER,
            state_hash=state_digest(nonce),
            user_id=user_id,
            device_id_hash=device_id_digest(device_id),
            purpose=purpose,
            device_public_key=normalized_public_key,
            source_session_id=source_session_id,
            scopes=APPLE_SCOPES,
            expires_at=expires_in(NONCE_LIFETIME_MINUTES),
        )
    )
    session.commit()
    return nonce


def hashed_nonce(nonce: str) -> str:
    return hashlib.sha256(nonce.encode()).hexdigest()


async def complete_apple_sign_in(
    session: Session,
    *,
    nonce: str,
    identity_token: str,
    authorization_code: str,
    device_id: str,
    first_name: str | None = None,
    last_name: str | None = None,
    client: AppleClient | None = None,
) -> SignInCompletion:
    oauth_state = consume_oauth_state(session, nonce, provider=APPLE_SIGN_IN_PROVIDER)
    if not oauth_state.device_id_hash or not verify_token_digest(device_id, oauth_state.device_id_hash):
        raise OAuthStateError("OAuth state is bound to another device")
    apple = client or AppleClient()
    claims = await apple.verify_identity_token(identity_token)
    if not hmac.compare_digest(str(claims.get("nonce", "")), hashed_nonce(nonce)):
        raise OAuthConfigurationError("Apple identity token nonce does not match")
    subject = str(claims["sub"])

    tokens = await apple.exchange_code(authorization_code)
    refresh_token = tokens.get("refresh_token")
    exchanged_token = tokens.get("id_token")
    if not refresh_token or not exchanged_token:
        raise OAuthConfigurationError("Apple did not return tokens")
    exchanged_claims = await apple.verify_identity_token(exchanged_token)
    if exchanged_claims.get("sub") != subject:
        raise OAuthConfigurationError("Apple identity evidence does not match")

    return complete_sign_in(
        session,
        oauth_state,
        provider=APPLE_SIGN_IN_PROVIDER,
        subject=subject,
        email=verified_email(claims),
        first_name=clean_name(first_name),
        last_name=clean_name(last_name),
        refresh_token=refresh_token,
    )


def verified_email(claims: dict) -> str | None:
    if str(claims.get("email_verified", "")).lower() != "true":
        return None
    return claims.get("email") or None


def clean_name(value: str | None) -> str | None:
    if value is None:
        return None
    return value.strip()[:80] or None


async def handle_apple_notification(session: Session, signed_payload: str, client: AppleClient | None = None) -> str:
    events = await (client or AppleClient()).verify_notification(signed_payload)
    event_type = str(events["type"])
    identity = sign_in_identity(session, APPLE_SIGN_IN_PROVIDER, str(events["sub"]))
    if identity is None:
        return "unknown_account"
    if event_type not in {CONSENT_REVOKED, ACCOUNT_DELETED}:
        return "ignored"

    identity.encrypted_refresh_token = None
    session.add(identity)
    user = session.get(User, identity.user_id)
    if event_type == ACCOUNT_DELETED:
        schedule_account_deletion(session, user)
    else:
        for app_session in session.scalars(
            select(AppSession).where(AppSession.user_id == user.id, AppSession.revoked_at.is_(None))
        ):
            revoke_session(session, app_session)
        session.commit()
    logger.info(
        "Apple notification handled type=%s user=%s", event_type, token_digest(user.id)[:12]
    )
    return event_type

