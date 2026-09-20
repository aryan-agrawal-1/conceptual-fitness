from __future__ import annotations

from datetime import timedelta
from dataclasses import dataclass
import json
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
    sensitive_action: str | None


# authorisation for google
def create_authorization_url(
    session: Session,
    *,
    device_id: str,
    redirect_after: str | None = None,
    user_id: str | None = None,
    sensitive_action: str | None = None,
) -> str:
    settings = get_settings()
    missing = missing_or_placeholder_keys(settings)
    if missing:
        raise OAuthConfigurationError(f"OAuth configuration is incomplete: {', '.join(missing)}")

    state = generate_state_token()
    scopes = (
        (
            "openid",
            "email",
            "profile",
            "https://www.googleapis.com/auth/googlehealth.profile.readonly",
        )
        if sensitive_action in {"export", "delete_account"}
        else settings.google_health_scopes
    )
    oauth_state = OAuthState(
        state_hash=state_digest(state),
        user_id=user_id,
        device_id_hash=device_id_digest(device_id),
        redirect_after=redirect_after,
        sensitive_action=sensitive_action,
        scopes=list(scopes),
        expires_at=expires_in(15),
    )
    session.add(oauth_state)
    session.commit()

    params = {
        "client_id": settings.google_health_client_id,
        "redirect_uri": settings.google_health_redirect_uri,
        "response_type": "code",
        "scope": " ".join(scopes),
        "prompt": "select_account" if sensitive_action in {"export", "delete_account"} else "consent",
        "state": state,
    }
    if sensitive_action not in {"export", "delete_account"}:
        params["access_type"] = "offline"
        params["include_granted_scopes"] = "true"
    if sensitive_action:
        params["max_age"] = "0"
        params["claims"] = json.dumps({"id_token": {"auth_time": {"essential": True}}})
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

    if oauth_state.sensitive_action:
        id_token = token_payload.get("id_token")
        if not id_token:
            raise OAuthConfigurationError("Google did not return authentication evidence")
        claims = await google_client.verify_id_token(str(id_token))
        try:
            auth_time = int(claims["auth_time"])
            expires_at = int(claims["exp"])
        except (KeyError, TypeError, ValueError) as exc:
            raise OAuthConfigurationError("Google did not confirm recent authentication") from exc
        now = int(utcnow().timestamp())
        if (
            claims.get("aud") != settings.google_health_client_id
            or claims.get("iss") not in {"https://accounts.google.com", "accounts.google.com"}
            or not claims.get("sub")
            or expires_at <= now
        ):
            raise OAuthConfigurationError("Google authentication evidence is invalid")
        if not (now - 300 <= auth_time <= now + 60):
            raise OAuthConfigurationError("Google authentication evidence is stale")

    identity = await google_client.get_identity(access_token)
    health_user_id = identity.get("healthUserId")
    legacy_user_id = identity.get("legacyUserId")
    try:
        userinfo = await google_client.get_userinfo(access_token)
    except Exception:
        userinfo = {}
    if oauth_state.sensitive_action and userinfo.get("sub") != claims.get("sub"):
        raise OAuthConfigurationError("Google identity evidence does not match")
    email = userinfo.get("email") if userinfo.get("email_verified", True) else None

    account = _find_existing_google_account(session, health_user_id, legacy_user_id)
    if oauth_state.sensitive_action and account is None:
        raise OAuthConfigurationError("Sensitive action requires an existing account")
    if oauth_state.user_id and account and account.user_id != oauth_state.user_id:
        raise OAuthConfigurationError("Authenticated Google account does not match the app session")
    locked_user = session.get(User, account.user_id, with_for_update=True) if account else None
    if locked_user and locked_user.deletion_scheduled_for and oauth_state.sensitive_action != "recover_deletion":
        raise OAuthConfigurationError("Pending-deletion accounts cannot authenticate")
    if oauth_state.sensitive_action == "recover_deletion":
        if locked_user is None or locked_user.deletion_scheduled_for is None:
            raise OAuthConfigurationError("Account is not pending deletion")
        if refresh_token:
            account.encrypted_refresh_token = encrypt_secret(refresh_token)
        account.granted_scopes = granted_scopes
        account.access_token_expires_at = utcnow() + timedelta(seconds=max(0, expires_in_seconds - 60))
        session.add(account)
        session.commit()
        return GoogleOAuthCompletion(
            account=account,
            device_id_hash=device_hash_for_state(oauth_state),
            sensitive_action=oauth_state.sensitive_action,
        )
    if oauth_state.sensitive_action:
        return GoogleOAuthCompletion(
            account=account,
            device_id_hash=device_hash_for_state(oauth_state),
            sensitive_action=oauth_state.sensitive_action,
        )
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
    return GoogleOAuthCompletion(
        account=account,
        device_id_hash=device_hash_for_state(oauth_state),
        sensitive_action=oauth_state.sensitive_action,
    )


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
