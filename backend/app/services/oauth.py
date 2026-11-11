from __future__ import annotations

from datetime import timedelta
from dataclasses import dataclass
import logging
from urllib.parse import urlencode

from sqlalchemy import select
from sqlalchemy.orm import Session

from app.core.config import get_settings, missing_or_placeholder_keys
from app.core.security import (
    decrypt_secret,
    encrypt_secret,
    expires_in,
    generate_state_token,
    state_digest,
    utcnow,
    verify_state_digest,
)
from app.google_health.client import GoogleHealthAPIError, GoogleHealthClient
from app.google_health.data_types import GOOGLE_OAUTH_AUTHORIZE_URL
from app.models import ConnectionStatus, HealthConnection, OAuthState, SignInIdentity, User
from app.services.app_auth import device_id_digest
from app.services.device_keys import DeviceKeyError, normalize_public_key

logger = logging.getLogger(__name__)

SIGN_IN_SCOPES = ("openid", "email", "profile")
GOOGLE_ISSUERS = {"accounts.google.com", "https://accounts.google.com"}
GOOGLE_SIGN_IN_PROVIDER = "google"
APPLE_SIGN_IN_PROVIDER = "apple"
GOOGLE_HEALTH_PROVIDER = "google_health"
SIGN_IN = "sign_in"
CONNECT_HEALTH = "connect_health"
SENSITIVE_PURPOSES = {"enroll_device", "recover_deletion"}


class OAuthConfigurationError(RuntimeError):
    pass


class OAuthStateError(RuntimeError):
    pass


class HealthAccountInUseError(OAuthConfigurationError):
    pass


class GoogleAccountInUseError(OAuthConfigurationError):
    pass


@dataclass(frozen=True)
class SignInCompletion:
    user_id: str
    purpose: str
    device_id_hash: str
    device_public_key: str | None
    source_session_id: str | None
    connection_id: str | None = None


def create_authorization_url(
    session: Session,
    *,
    device_id: str,
    purpose: str = SIGN_IN,
    redirect_after: str | None = None,
    user_id: str | None = None,
    device_public_key: str | None = None,
    source_session_id: str | None = None,
) -> str:
    settings = get_settings()
    missing = missing_or_placeholder_keys(settings)
    if missing:
        raise OAuthConfigurationError(f"OAuth configuration is incomplete: {', '.join(missing)}")
    if purpose == CONNECT_HEALTH and user_id is None:
        raise OAuthConfigurationError("Connecting health data requires a signed-in user")

    state = generate_state_token()
    scopes = settings.google_health_scopes if purpose == CONNECT_HEALTH else SIGN_IN_SCOPES
    normalized_public_key = normalize_public_key(device_public_key) if device_public_key else None
    if purpose in SENSITIVE_PURPOSES and not normalized_public_key:
        raise DeviceKeyError("Device public key is required")
    oauth_state = OAuthState(
        state_hash=state_digest(state),
        user_id=user_id,
        device_id_hash=device_id_digest(device_id),
        redirect_after=redirect_after,
        purpose=purpose,
        device_public_key=normalized_public_key,
        source_session_id=source_session_id,
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
        "prompt": "consent" if purpose == CONNECT_HEALTH else "select_account",
        "state": state,
    }
    if purpose == CONNECT_HEALTH:
        params["access_type"] = "offline"
        params["include_granted_scopes"] = "true"
    return f"{GOOGLE_OAUTH_AUTHORIZE_URL}?{urlencode(params)}"


def consume_oauth_state(
    session: Session, raw_state: str, *, provider: str = GOOGLE_SIGN_IN_PROVIDER
) -> OAuthState:
    oauth_state = session.scalar(select(OAuthState).where(OAuthState.state_hash == state_digest(raw_state)))
    if oauth_state is None or oauth_state.provider != provider:
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


async def complete_google_oauth(
    session: Session,
    *,
    code: str,
    state: str,
    client: GoogleHealthClient | None = None,
) -> SignInCompletion:
    oauth_state = consume_oauth_state(session, state)
    google_client = client or GoogleHealthClient(get_settings())
    token_payload = await google_client.exchange_code_for_tokens(code)
    if oauth_state.purpose == CONNECT_HEALTH:
        return await complete_health_connection(session, oauth_state, token_payload, google_client)
    return await complete_google_sign_in(session, oauth_state, token_payload, google_client)


async def complete_google_sign_in(
    session: Session,
    oauth_state: OAuthState,
    token_payload: dict,
    google_client: GoogleHealthClient,
) -> SignInCompletion:
    subject, email = await verified_google_identity(token_payload, google_client)
    if oauth_state.purpose == SIGN_IN and sign_in_identity(session, GOOGLE_SIGN_IN_PROVIDER, subject) is None:
        if google_account_is_data_source(session, subject):
            raise GoogleAccountInUseError("Google account is another account's data source")
    return complete_sign_in(
        session,
        oauth_state,
        provider=GOOGLE_SIGN_IN_PROVIDER,
        subject=subject,
        email=email,
    )


def complete_sign_in(
    session: Session,
    oauth_state: OAuthState,
    *,
    provider: str,
    subject: str,
    email: str | None,
    first_name: str | None = None,
    last_name: str | None = None,
    refresh_token: str | None = None,
) -> SignInCompletion:
    purpose = oauth_state.purpose
    identity = sign_in_identity(session, provider, subject)
    if purpose in SENSITIVE_PURPOSES and identity is None:
        raise OAuthConfigurationError("Sensitive action requires an existing account")
    if oauth_state.user_id and identity and identity.user_id != oauth_state.user_id:
        raise OAuthConfigurationError("Authenticated account does not match the app session")
    user = session.get(User, identity.user_id, with_for_update=True) if identity else None
    if user and user.deletion_scheduled_for and purpose != "recover_deletion":
        raise OAuthConfigurationError("Pending-deletion accounts cannot authenticate")
    if purpose == "recover_deletion" and (user is None or user.deletion_scheduled_for is None):
        raise OAuthConfigurationError("Account is not pending deletion")

    if identity is None:
        user = User(email=email)
        session.add(user)
        session.flush()
        identity = SignInIdentity(user_id=user.id, provider=provider, subject=subject)
    if first_name and not user.first_name:
        user.first_name = first_name
        user.last_name = last_name
    if email:
        identity.email = email
        if purpose == SIGN_IN:
            user.email = email
    if refresh_token:
        identity.encrypted_refresh_token = encrypt_secret(refresh_token)
    identity.last_signed_in_at = utcnow()
    session.add_all([user, identity])
    session.commit()
    return SignInCompletion(
        user_id=user.id,
        purpose=purpose,
        device_id_hash=device_hash_for_state(oauth_state),
        device_public_key=oauth_state.device_public_key,
        source_session_id=oauth_state.source_session_id,
    )


def sign_in_identity(session: Session, provider: str, subject: str) -> SignInIdentity | None:
    return session.scalar(
        select(SignInIdentity).where(
            SignInIdentity.provider == provider,
            SignInIdentity.subject == subject,
        )
    )


def google_account_is_data_source(session: Session, subject: str) -> bool:
    return session.scalar(
        select(HealthConnection.id).where(
            HealthConnection.provider == GOOGLE_HEALTH_PROVIDER,
            HealthConnection.account_subject == subject,
        )
    ) is not None


async def verified_google_identity(
    token_payload: dict, google_client: GoogleHealthClient
) -> tuple[str, str | None]:
    id_token = token_payload.get("id_token")
    if not id_token:
        raise OAuthConfigurationError("Google did not return authentication evidence")
    claims = await google_client.verify_id_token(id_token)
    if (
        claims.get("aud") != google_client.settings.google_health_client_id
        or claims.get("iss") not in GOOGLE_ISSUERS
        or not claims.get("sub")
    ):
        raise OAuthConfigurationError("Google authentication evidence is invalid")
    email_verified = str(claims.get("email_verified", "")).lower() == "true"
    email = claims.get("email") if email_verified else None
    return str(claims["sub"]), email


async def complete_health_connection(
    session: Session,
    oauth_state: OAuthState,
    token_payload: dict,
    google_client: GoogleHealthClient,
) -> SignInCompletion:
    if oauth_state.user_id is None:
        raise OAuthStateError("OAuth state is missing the connecting user")
    user = session.get(User, oauth_state.user_id, with_for_update=True)
    if user is None:
        raise OAuthConfigurationError("Account was not found")
    if user.deletion_scheduled_for:
        raise OAuthConfigurationError("Pending-deletion accounts cannot authenticate")

    account_subject, _ = await verified_google_identity(token_payload, google_client)
    signed_in_as = sign_in_identity(session, GOOGLE_SIGN_IN_PROVIDER, account_subject)
    if signed_in_as and signed_in_as.user_id != user.id:
        raise GoogleAccountInUseError("Google account signs in to another account")

    access_token = token_payload["access_token"]
    refresh_token = token_payload.get("refresh_token")
    expires_in_seconds = int(token_payload.get("expires_in", 3600))
    granted_scopes = token_payload.get("scope", " ".join(oauth_state.scopes)).split()
    identity = await google_client.get_identity(access_token)
    external_user_id = identity.get("healthUserId")
    external_legacy_user_id = identity.get("legacyUserId")

    connection = find_health_connection(session, external_user_id, external_legacy_user_id)
    if connection and connection.user_id != user.id:
        raise HealthAccountInUseError("Health account is connected to another user")
    if not refresh_token and (connection is None or connection.encrypted_refresh_token is None):
        raise OAuthConfigurationError(
            "Google did not return a refresh token. Revoke test access and retry with prompt=consent."
        )

    replaced_tokens = disconnect_other_connections(session, user.id, keep=connection)
    if connection is None:
        connection = HealthConnection(user_id=user.id, provider=GOOGLE_HEALTH_PROVIDER)
    elif connection.status == ConnectionStatus.disconnected:
        connection.connected_at = utcnow()
    connection.external_user_id = external_user_id
    connection.external_legacy_user_id = external_legacy_user_id
    connection.account_subject = account_subject
    connection.granted_scopes = granted_scopes
    if refresh_token:
        connection.encrypted_refresh_token = encrypt_secret(refresh_token)
    connection.access_token_expires_at = utcnow() + timedelta(seconds=max(0, expires_in_seconds - 60))
    connection.status = ConnectionStatus.connected
    connection.disconnected_at = None
    connection.last_error = None
    session.add(connection)
    session.commit()
    session.refresh(connection)
    await revoke_replaced_tokens(google_client, replaced_tokens)
    return SignInCompletion(
        user_id=user.id,
        purpose=CONNECT_HEALTH,
        device_id_hash=device_hash_for_state(oauth_state),
        device_public_key=oauth_state.device_public_key,
        source_session_id=oauth_state.source_session_id,
        connection_id=connection.id,
    )


def disconnect_other_connections(
    session: Session, user_id: str, *, keep: HealthConnection | None
) -> list[str]:
    replaced_tokens = []
    others = session.scalars(
        select(HealthConnection).where(
            HealthConnection.user_id == user_id,
            HealthConnection.status != ConnectionStatus.disconnected,
        )
    ).all()
    for other in others:
        if keep is not None and other.id == keep.id:
            continue
        if other.encrypted_refresh_token:
            replaced_tokens.append(other.encrypted_refresh_token)
        other.status = ConnectionStatus.disconnected
        other.disconnected_at = utcnow()
        other.encrypted_refresh_token = None
        other.sync_started_at = None
        session.add(other)
    session.flush()
    return replaced_tokens


async def revoke_replaced_tokens(google_client: GoogleHealthClient, encrypted_tokens: list[str]) -> None:
    for encrypted_token in encrypted_tokens:
        try:
            await google_client.revoke_token(decrypt_secret(encrypted_token))
        except GoogleHealthAPIError as exc:
            logger.warning("Replaced health connection revocation failed (%s)", exc.status_code)


def device_hash_for_state(oauth_state: OAuthState) -> str:
    if not oauth_state.device_id_hash:
        raise OAuthStateError("OAuth state is missing device binding")
    return oauth_state.device_id_hash


def find_health_connection(
    session: Session,
    external_user_id: str | None,
    external_legacy_user_id: str | None,
) -> HealthConnection | None:
    if external_user_id:
        connection = session.scalar(
            select(HealthConnection).where(
                HealthConnection.provider == GOOGLE_HEALTH_PROVIDER,
                HealthConnection.external_user_id == external_user_id,
            )
        )
        if connection:
            return connection
    if external_legacy_user_id:
        return session.scalar(
            select(HealthConnection).where(
                HealthConnection.provider == GOOGLE_HEALTH_PROVIDER,
                HealthConnection.external_legacy_user_id == external_legacy_user_id,
            )
        )
    return None


def active_health_connection(session: Session, user_id: str) -> HealthConnection | None:
    return session.scalar(
        select(HealthConnection)
        .where(
            HealthConnection.user_id == user_id,
            HealthConnection.status != ConnectionStatus.disconnected,
        )
        .order_by(HealthConnection.connected_at.desc())
    )


def latest_health_connection(session: Session, user_id: str) -> HealthConnection | None:
    return active_health_connection(session, user_id) or session.scalar(
        select(HealthConnection)
        .where(HealthConnection.user_id == user_id)
        .order_by(HealthConnection.connected_at.desc())
    )
