from __future__ import annotations

from datetime import timedelta
from dataclasses import dataclass
from urllib.parse import urlencode

from sqlalchemy import select
from sqlalchemy.orm import Session

from app.core.config import get_settings, missing_or_placeholder_keys
from app.core.security import (
    encrypt_secret,
    expires_in,
    generate_state_token,
    state_digest,
    utcnow,
    verify_state_digest,
)
from app.google_health.client import GoogleHealthClient
from app.google_health.data_types import GOOGLE_OAUTH_AUTHORIZE_URL
from app.models import ConnectionStatus, GoogleAccount, OAuthState, User
from app.services.app_auth import device_id_digest


class OAuthConfigurationError(RuntimeError):
    pass


class OAuthStateError(RuntimeError):
    pass


@dataclass(frozen=True)
class GoogleOAuthCompletion:
    account: GoogleAccount
    device_id_hash: str


# authorisation for google
def create_authorization_url(
    session: Session,
    *,
    device_id: str,
    redirect_after: str | None = None,
) -> str:
    settings = get_settings()
    missing = missing_or_placeholder_keys(settings)
    if missing:
        raise OAuthConfigurationError(f"OAuth configuration is incomplete: {', '.join(missing)}")

    state = generate_state_token()
    oauth_state = OAuthState(
        state_hash=state_digest(state),
        device_id_hash=device_id_digest(device_id),
        redirect_after=redirect_after,
        scopes=list(settings.google_health_scopes),
        expires_at=expires_in(15),
    )
    session.add(oauth_state)
    session.commit()

    params = {
        "client_id": settings.google_health_client_id,
        "redirect_uri": settings.google_health_redirect_uri,
        "response_type": "code",
        "scope": " ".join(settings.google_health_scopes),
        "access_type": "offline",
        "include_granted_scopes": "true",
        "prompt": "consent",
        "state": state,
    }
    return f"{GOOGLE_OAUTH_AUTHORIZE_URL}?{urlencode(params)}"


def consume_oauth_state(session: Session, raw_state: str) -> OAuthState:
    oauth_state = session.scalar(select(OAuthState).where(OAuthState.state_hash == state_digest(raw_state)))
    if oauth_state is None:
        raise OAuthStateError("OAuth state was not found")
    if oauth_state.consumed_at is not None:
        raise OAuthStateError("OAuth state has already been used")
    expires_at = oauth_state.expires_at
    if expires_at.tzinfo is None:
        expires_at = expires_at.replace(tzinfo=utcnow().tzinfo)
    if expires_at < utcnow():
        raise OAuthStateError("OAuth state has expired")
    if not verify_state_digest(raw_state, oauth_state.state_hash):
        raise OAuthStateError("OAuth state failed validation")
    oauth_state.consumed_at = utcnow()
    session.add(oauth_state)
    session.commit()
    session.refresh(oauth_state)
    return oauth_state


# time to get the tokens
async def complete_google_health_oauth(
    session: Session,
    *,
    code: str,
    state: str,
    client: GoogleHealthClient | None = None,
) -> GoogleOAuthCompletion:
    settings = get_settings()
    oauth_state = consume_oauth_state(session, state)
    google_client = client or GoogleHealthClient(settings)

    token_payload = await google_client.exchange_code_for_tokens(code)
    access_token = token_payload["access_token"]
    refresh_token = token_payload.get("refresh_token")
    expires_in_seconds = int(token_payload.get("expires_in", 3600))
    granted_scopes = token_payload.get("scope", " ".join(oauth_state.scopes)).split()

    identity = await google_client.get_identity(access_token)
    health_user_id = identity.get("healthUserId")
    legacy_user_id = identity.get("legacyUserId")
    try:
        userinfo = await google_client.get_userinfo(access_token)
    except Exception:
        userinfo = {}
    email = userinfo.get("email") if userinfo.get("email_verified", True) else None

    account = _find_existing_google_account(session, health_user_id, legacy_user_id)
    if account is None:
        user = _get_or_create_user(session)
        account = GoogleAccount(user_id=user.id)
    elif account.status == ConnectionStatus.disconnected:
        account.connected_at = utcnow()
        user = account.user
    else:
        user = account.user

    if email and user.email != email:
        user.email = str(email)
        session.add(user)

    account.health_user_id = health_user_id
    account.legacy_user_id = legacy_user_id
    account.granted_scopes = granted_scopes
    if refresh_token:
        account.encrypted_refresh_token = encrypt_secret(refresh_token)
    elif account.encrypted_refresh_token is None:
        raise OAuthConfigurationError(
            "Google did not return a refresh token. Revoke test access and retry with prompt=consent."
        )
    account.access_token_expires_at = utcnow() + timedelta(seconds=max(0, expires_in_seconds - 60))
    account.status = ConnectionStatus.connected
    account.disconnected_at = None
    account.last_error = None
    session.add(account)
    session.commit()
    session.refresh(account)
    return GoogleOAuthCompletion(account=account, device_id_hash=device_hash_for_state(oauth_state))


def device_hash_for_state(oauth_state: OAuthState) -> str:
    if not oauth_state.device_id_hash:
        raise OAuthStateError("OAuth state is missing device binding")
    return oauth_state.device_id_hash


def _find_existing_google_account(
    session: Session,
    health_user_id: str | None,
    legacy_user_id: str | None,
) -> GoogleAccount | None:
    if health_user_id:
        account = session.scalar(
            select(GoogleAccount).where(GoogleAccount.health_user_id == health_user_id)
        )
        if account:
            return account
    if legacy_user_id:
        return session.scalar(select(GoogleAccount).where(GoogleAccount.legacy_user_id == legacy_user_id))
    return None


def _get_or_create_user(session: Session) -> User:
    user = User()
    session.add(user)
    session.flush()
    return user
