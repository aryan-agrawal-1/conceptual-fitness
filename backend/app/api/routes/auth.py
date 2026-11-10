from __future__ import annotations

from datetime import datetime
import logging
from typing import Literal
from urllib.parse import urlencode

from fastapi import APIRouter, Body, HTTPException, Query, Request, Response
from fastapi.responses import RedirectResponse
from pydantic import BaseModel, Field
from sqlalchemy import select

from app.api.deps import CurrentUser, DbSession, bearer_token_from_request
from app.apple.client import AppleAuthError
from app.core.config import get_settings, missing_or_placeholder_keys
from app.core.security import decrypt_secret, utcnow
from app.google_health.client import GoogleHealthAPIError
from app.models import ConnectionStatus, HealthConnection, SignInIdentity, User
from app.services.apple_sign_in import (
    complete_apple_sign_in,
    create_apple_nonce,
    handle_apple_notification,
)
from app.services.health_dates import get_or_create_profile
from app.services.app_auth import (
    AppAuthError,
    TokenPair,
    authenticate_access_token_with_session,
    create_app_auth_code,
    exchange_auth_code,
    refresh_tokens,
    revoke_with_access_token,
    revoke_with_refresh_token,
)
from app.services.device_keys import DeviceKeyError
from app.services.oauth import (
    CONNECT_HEALTH,
    SIGN_IN,
    GoogleAccountInUseError,
    HealthAccountInUseError,
    OAuthConfigurationError,
    OAuthStateError,
    complete_google_oauth,
    create_authorization_url,
    latest_health_connection,
)
from app.services.rate_limit import (
    AUTH_EXCHANGE_LIMIT,
    AUTH_LOGOUT_LIMIT,
    AUTH_REFRESH_LIMIT,
    AUTH_START_LIMIT,
    CONNECTION_MUTATION_LIMIT,
    client_ip,
    enforce_rate_limit,
)
from app.services.sensitive_actions import (
    SensitiveActionError,
    authorize_sensitive_action_challenge,
    create_sensitive_action_challenge,
)
from app.tasks.sync import enqueue_initial_backfill


router = APIRouter(prefix="/auth", tags=["auth"])
logger = logging.getLogger(__name__)


def sensitive_oauth_failure_reason(exc: Exception) -> str:
    if isinstance(exc, (GoogleHealthAPIError, AppleAuthError)):
        return f"provider_http_{exc.status_code}" if exc.status_code else "provider_request_failed"
    return {
        "Apple configuration is incomplete": "apple_not_configured",
        "Apple identity token nonce does not match": "nonce_mismatch",
        "Apple did not return tokens": "missing_apple_tokens",
        "Apple identity evidence does not match": "identity_mismatch",
        "OAuth state is bound to another device": "device_mismatch",
        "Google did not return authentication evidence": "missing_id_token",
        "Google did not confirm recent authentication": "missing_auth_time",
        "Google authentication evidence is invalid": "invalid_id_token_claims",
        "Google authentication evidence is stale": "stale_auth_time",
        "Google identity evidence does not match": "identity_mismatch",
        "Sensitive action requires an existing account": "account_not_found",
        "Authenticated account does not match the app session": "account_mismatch",
        "Pending-deletion accounts cannot authenticate": "account_pending_deletion",
        "Account is not pending deletion": "account_not_pending_deletion",
        "Account was not found": "account_not_found",
        "Health account is connected to another user": "health_account_in_use",
        "Google account is another account's data source": "google_account_in_use",
        "Google account signs in to another account": "google_account_in_use",
    }.get(str(exc).split(":")[0], "oauth_state_or_configuration")


class OAuthDiagnostics(BaseModel):
    configured: bool
    missing_or_placeholder_keys: list[str] = Field(default_factory=list)
    redirect_uri: str | None = None
    app_base_url: str | None = None
    client_id_present: bool
    client_secret_present: bool
    scopes: list[str] = Field(default_factory=list)


class TokenExchangeRequest(BaseModel):
    code: str
    device_id: str
    signature: str | None = Field(default=None, max_length=256)


class TokenRefreshRequest(BaseModel):
    refresh_token: str
    device_id: str


class LogoutRequest(BaseModel):
    refresh_token: str | None = None
    device_id: str | None = None


class TokenResponse(BaseModel):
    access_token: str
    refresh_token: str
    token_type: str
    expires_in: int


class DeviceChallengeRequest(BaseModel):
    purpose: Literal["export", "delete_account"]


class DeviceChallengeResponse(BaseModel):
    challenge: str
    expires_in: int
    session_id: str


class DeviceAuthorizeRequest(DeviceChallengeRequest):
    challenge: str = Field(min_length=1, max_length=128)
    signature: str = Field(min_length=1, max_length=256)


class DeviceAuthorizeResponse(BaseModel):
    sensitive_action_grant: str


class UserPayload(BaseModel):
    id: str
    sign_in_provider: str | None
    email: str | None
    first_name: str | None
    last_name: str | None
    created_at: datetime


class UserUpdate(BaseModel):
    first_name: str = Field(min_length=1, max_length=80)
    last_name: str | None = Field(default=None, max_length=80)


class HealthConnectionStatus(BaseModel):
    provider: str | None
    status: str
    connected_at: datetime | None
    last_sync_at: datetime | None
    last_error: str | None


class MeProfileStatus(BaseModel):
    onboarding_completed_at: datetime | None
    weather_enabled: bool


class MeResponse(BaseModel):
    user: UserPayload
    health_connection: HealthConnectionStatus
    profile: MeProfileStatus


class DisconnectRequest(BaseModel):
    revoke: bool = True


class AppleNonceResponse(BaseModel):
    nonce: str


class AppleCompletionRequest(BaseModel):
    nonce: str = Field(min_length=1, max_length=128)
    identity_token: str = Field(min_length=1, max_length=8192)
    authorization_code: str = Field(min_length=1, max_length=1024)
    device_id: str = Field(min_length=16)
    first_name: str | None = Field(default=None, max_length=200)
    last_name: str | None = Field(default=None, max_length=200)


class AppleCompletionResponse(BaseModel):
    status: Literal["signed_in", "authorized"]
    code: str | None = None
    grant: str | None = None
    purpose: str | None = None


class AppleNotificationRequest(BaseModel):
    payload: str = Field(min_length=1, max_length=16384)


@router.get("/google/diagnostics", response_model=OAuthDiagnostics)
def diagnostics() -> OAuthDiagnostics:
    settings = get_settings()
    missing = missing_or_placeholder_keys(settings)
    if settings.app_env == "production":
        return OAuthDiagnostics(
            configured=not missing,
            client_id_present=bool(settings.google_health_client_id),
            client_secret_present=bool(settings.google_health_client_secret),
        )
    return OAuthDiagnostics(
        configured=not missing,
        missing_or_placeholder_keys=missing,
        redirect_uri=settings.google_health_redirect_uri,
        app_base_url=settings.app_base_url,
        client_id_present=bool(settings.google_health_client_id),
        client_secret_present=bool(settings.google_health_client_secret),
        scopes=list(settings.google_health_scopes),
    )


@router.get("/google/start")
def start_google_oauth(
    request: Request,
    session: DbSession,
    device_id: str = Query(..., min_length=16),
    redirect_after: str | None = Query(default=None),
    device_public_key: str | None = Query(default=None, max_length=128),
) -> RedirectResponse:
    enforce_rate_limit(request, AUTH_START_LIMIT, client_ip(request), device_id)
    try:
        url = create_authorization_url(
            session,
            device_id=device_id,
            redirect_after=redirect_after,
            device_public_key=device_public_key,
        )
    except (OAuthConfigurationError, DeviceKeyError) as exc:
        raise HTTPException(status_code=500, detail="OAuth configuration is incomplete") from exc
    return RedirectResponse(url)


@router.get("/google/start-url")
def start_google_oauth_url(
    request: Request,
    session: DbSession,
    device_id: str = Query(..., min_length=16),
    redirect_after: str | None = Query(default=None),
    device_public_key: str | None = Query(default=None, max_length=128),
) -> dict[str, str]:
    enforce_rate_limit(request, AUTH_START_LIMIT, client_ip(request), device_id)
    try:
        return {
            "authorization_url": create_authorization_url(
                session,
                device_id=device_id,
                redirect_after=redirect_after,
                device_public_key=device_public_key,
            )
        }
    except (OAuthConfigurationError, DeviceKeyError) as exc:
        raise HTTPException(status_code=500, detail="OAuth configuration is incomplete") from exc


@router.get("/google/sensitive-start-url")
def start_sensitive_google_oauth_url(
    request: Request,
    session: DbSession,
    device_id: str = Query(..., min_length=16),
    purpose: Literal["enroll_device", "recover_deletion"] = Query(...),
    device_public_key: str = Query(..., max_length=128),
) -> dict[str, str]:
    enforce_rate_limit(request, AUTH_START_LIMIT, client_ip(request), device_id)
    user_id, source_session_id = enrolling_session(request, session, purpose)
    try:
        return {
            "authorization_url": create_authorization_url(
                session,
                device_id=device_id,
                user_id=user_id,
                purpose=purpose,
                device_public_key=device_public_key,
                source_session_id=source_session_id,
            )
        }
    except (OAuthConfigurationError, DeviceKeyError) as exc:
        raise HTTPException(status_code=500, detail="OAuth configuration is incomplete") from exc


@router.get("/google/callback")
async def google_oauth_callback(
    session: DbSession,
    code: str | None = Query(default=None),
    state: str | None = Query(default=None),
    error: str | None = Query(default=None),
) -> RedirectResponse:
    if error:
        return _deep_link_redirect(status="error", reason="oauth_error")
    if not code or not state:
        raise HTTPException(status_code=400, detail="Missing OAuth code or state")
    try:
        completion = await complete_google_oauth(session, code=code, state=state)
        if completion.purpose == CONNECT_HEALTH:
            queued = enqueue_initial_backfill(completion.connection_id)
            return _deep_link_redirect(status="health_connected_queued" if queued else "health_connected")
        if completion.purpose == "recover_deletion":
            if not completion.device_public_key:
                raise OAuthStateError("OAuth state is missing device key binding")
            grant = create_sensitive_action_challenge(
                session,
                user_id=completion.user_id,
                device_id_hash=completion.device_id_hash,
                purpose=completion.purpose,
                device_public_key=completion.device_public_key,
            )
            return _deep_link_redirect(
                status="authorized",
                grant=grant,
                purpose=completion.purpose,
            )
        app_code = create_app_auth_code(
            session,
            user_id=completion.user_id,
            device_id_hash=completion.device_id_hash,
            device_public_key=completion.device_public_key,
            source_session_id=completion.source_session_id,
        )
    except HealthAccountInUseError:
        logger.warning("Google OAuth failed reason=health_account_in_use")
        return _deep_link_redirect(status="error", reason="health_account_in_use")
    except GoogleAccountInUseError:
        logger.warning("Google OAuth failed reason=google_account_in_use")
        return _deep_link_redirect(status="error", reason="google_account_in_use")
    except (OAuthConfigurationError, OAuthStateError, GoogleHealthAPIError) as exc:
        reason = sensitive_oauth_failure_reason(exc)
        logger.warning("Google OAuth failed reason=%s", reason)
        return _deep_link_redirect(status="error", reason="oauth_failed")

    return _deep_link_redirect(status="signed_in", code=app_code)


@router.get("/apple/start", response_model=AppleNonceResponse)
def start_apple_sign_in(
    request: Request,
    session: DbSession,
    device_id: str = Query(..., min_length=16),
    purpose: Literal["sign_in", "enroll_device", "recover_deletion"] = Query(default=SIGN_IN),
    device_public_key: str | None = Query(default=None, max_length=128),
) -> AppleNonceResponse:
    enforce_rate_limit(request, AUTH_START_LIMIT, client_ip(request), device_id)
    user_id, source_session_id = enrolling_session(request, session, purpose)
    try:
        nonce = create_apple_nonce(
            session,
            device_id=device_id,
            purpose=purpose,
            user_id=user_id,
            device_public_key=device_public_key,
            source_session_id=source_session_id,
        )
    except (OAuthConfigurationError, DeviceKeyError) as exc:
        logger.warning("Apple sign-in start failed reason=%s", sensitive_oauth_failure_reason(exc))
        raise HTTPException(status_code=500, detail="Apple sign-in configuration is incomplete") from exc
    return AppleNonceResponse(nonce=nonce)


@router.post("/apple/complete", response_model=AppleCompletionResponse)
async def complete_apple(
    request: Request,
    payload: AppleCompletionRequest,
    session: DbSession,
) -> AppleCompletionResponse:
    enforce_rate_limit(request, AUTH_EXCHANGE_LIMIT, client_ip(request), payload.device_id)
    try:
        completion = await complete_apple_sign_in(
            session,
            nonce=payload.nonce,
            identity_token=payload.identity_token,
            authorization_code=payload.authorization_code,
            device_id=payload.device_id,
            first_name=payload.first_name,
            last_name=payload.last_name,
        )
        if completion.purpose == "recover_deletion":
            grant = create_sensitive_action_challenge(
                session,
                user_id=completion.user_id,
                device_id_hash=completion.device_id_hash,
                purpose=completion.purpose,
                device_public_key=completion.device_public_key,
            )
            return AppleCompletionResponse(status="authorized", grant=grant, purpose=completion.purpose)
        app_code = create_app_auth_code(
            session,
            user_id=completion.user_id,
            device_id_hash=completion.device_id_hash,
            device_public_key=completion.device_public_key,
            source_session_id=completion.source_session_id,
        )
    except (OAuthConfigurationError, OAuthStateError, AppleAuthError) as exc:
        reason = sensitive_oauth_failure_reason(exc)
        logger.warning("Apple sign-in failed reason=%s", reason)
        raise HTTPException(status_code=403, detail={"code": public_failure_code(reason)}) from exc
    return AppleCompletionResponse(status="signed_in", code=app_code)


@router.post("/apple/notifications", status_code=204)
async def apple_notification(payload: AppleNotificationRequest, session: DbSession) -> Response:
    try:
        await handle_apple_notification(session, payload.payload)
    except AppleAuthError as exc:
        logger.warning("Apple notification rejected reason=%s", sensitive_oauth_failure_reason(exc))
        raise HTTPException(status_code=400, detail="Invalid notification") from exc
    return Response(status_code=204)


@router.post("/exchange", response_model=TokenResponse)
def exchange_token(
    request: Request,
    payload: TokenExchangeRequest,
    session: DbSession,
) -> TokenResponse:
    enforce_rate_limit(request, AUTH_EXCHANGE_LIMIT, client_ip(request), payload.device_id)
    try:
        token_pair = exchange_auth_code(
            session,
            code=payload.code,
            device_id=payload.device_id,
            signature=payload.signature,
            user_agent=request.headers.get("user-agent"),
        )
    except AppAuthError as exc:
        raise HTTPException(status_code=401, detail="Invalid or expired token") from exc
    return _token_response(token_pair)


@router.post("/device/challenge", response_model=DeviceChallengeResponse)
def device_challenge(
    request: Request,
    payload: DeviceChallengeRequest,
    session: DbSession,
) -> DeviceChallengeResponse:
    try:
        user, app_session = authenticate_access_token_with_session(
            session, bearer_token_from_request(request)
        )
    except AppAuthError as exc:
        raise HTTPException(status_code=401, detail="Invalid or expired token") from exc
    enforce_rate_limit(request, CONNECTION_MUTATION_LIMIT, user.id, app_session.id)
    if not app_session.device_public_key:
        raise HTTPException(
            status_code=409,
            detail={"code": "device_key_enrollment_required"},
        )
    challenge = create_sensitive_action_challenge(
        session,
        user_id=user.id,
        device_id_hash=app_session.device_id_hash,
        purpose=payload.purpose,
        device_public_key=app_session.device_public_key,
        session_id=app_session.id,
    )
    return DeviceChallengeResponse(challenge=challenge, expires_in=300, session_id=app_session.id)


@router.post("/device/authorize", response_model=DeviceAuthorizeResponse)
def authorize_device_challenge(
    request: Request,
    payload: DeviceAuthorizeRequest,
    session: DbSession,
) -> DeviceAuthorizeResponse:
    try:
        user, app_session = authenticate_access_token_with_session(
            session, bearer_token_from_request(request)
        )
    except AppAuthError as exc:
        raise HTTPException(status_code=401, detail="Invalid or expired token") from exc
    enforce_rate_limit(request, CONNECTION_MUTATION_LIMIT, user.id, app_session.id)
    try:
        authorize_sensitive_action_challenge(
            session,
            challenge=payload.challenge,
            signature=payload.signature,
            purpose=payload.purpose,
            user_id=user.id,
            session_id=app_session.id,
        )
    except SensitiveActionError as exc:
        raise HTTPException(status_code=403, detail="Device authorization failed") from exc
    return DeviceAuthorizeResponse(sensitive_action_grant=payload.challenge)


@router.post("/refresh", response_model=TokenResponse)
def refresh_token(
    request: Request,
    payload: TokenRefreshRequest,
    session: DbSession,
) -> TokenResponse:
    enforce_rate_limit(request, AUTH_REFRESH_LIMIT, client_ip(request), payload.device_id)
    try:
        token_pair = refresh_tokens(
            session,
            refresh_token=payload.refresh_token,
            device_id=payload.device_id,
        )
    except AppAuthError as exc:
        raise HTTPException(status_code=401, detail="Invalid or expired token") from exc
    return _token_response(token_pair)


@router.post("/logout", status_code=204)
def logout(
    request: Request,
    session: DbSession,
    payload: LogoutRequest | None = Body(default=None),
) -> Response:
    enforce_rate_limit(request, AUTH_LOGOUT_LIMIT, client_ip(request), payload.device_id if payload else None)
    try:
        access_token = bearer_token_from_request(request)
    except HTTPException:
        access_token = None
    if access_token:
        revoke_with_access_token(session, access_token=access_token)
    if payload and payload.refresh_token:
        revoke_with_refresh_token(
            session,
            refresh_token=payload.refresh_token,
            device_id=payload.device_id,
        )
    return Response(status_code=204)


@router.get("/me", response_model=MeResponse)
def me(session: DbSession, user: CurrentUser) -> MeResponse:
    return _me_response(session, user)


@router.patch("/me", response_model=MeResponse)
def update_me(payload: UserUpdate, session: DbSession, user: CurrentUser) -> MeResponse:
    user.first_name = _clean_string(payload.first_name)
    user.last_name = _clean_optional_string(payload.last_name)
    session.add(user)
    session.commit()
    session.refresh(user)
    return _me_response(session, user)


connections_router = APIRouter(prefix="/connections", tags=["connections"])


@connections_router.get("/google-health/start-url")
def start_google_health_connection_url(
    request: Request,
    session: DbSession,
    user: CurrentUser,
    device_id: str = Query(..., min_length=16),
) -> dict[str, str]:
    enforce_rate_limit(request, AUTH_START_LIMIT, client_ip(request), device_id)
    try:
        return {
            "authorization_url": create_authorization_url(
                session,
                device_id=device_id,
                purpose=CONNECT_HEALTH,
                user_id=user.id,
            )
        }
    except OAuthConfigurationError as exc:
        raise HTTPException(status_code=500, detail="OAuth configuration is incomplete") from exc


@connections_router.get("/google-health")
def google_health_connections(session: DbSession, user: CurrentUser) -> list[dict[str, object]]:
    connections = session.scalars(
        select(HealthConnection)
        .where(HealthConnection.user_id == user.id)
        .order_by(HealthConnection.connected_at.desc())
    ).all()
    return [_connection_payload(connection) for connection in connections]


@connections_router.post("/google-health/disconnect")
async def disconnect_google_health(
    request: Request,
    session: DbSession,
    user: CurrentUser,
    payload: DisconnectRequest | None = None,
) -> dict[str, str]:
    enforce_rate_limit(request, CONNECTION_MUTATION_LIMIT, user.id)
    connection = latest_health_connection(session, user.id)
    if connection is None:
        raise HTTPException(status_code=404, detail="Health connection not found")
    revoke = True if payload is None else payload.revoke
    if revoke and connection.encrypted_refresh_token:
        from app.google_health.client import GoogleHealthClient

        try:
            await GoogleHealthClient().revoke_token(decrypt_secret(connection.encrypted_refresh_token))
        except GoogleHealthAPIError:
            pass
    connection.status = ConnectionStatus.disconnected
    connection.disconnected_at = utcnow()
    connection.encrypted_refresh_token = None
    session.add(connection)
    session.commit()
    return {"status": "disconnected", "account_id": connection.id}


def enrolling_session(request: Request, session: DbSession, purpose: str) -> tuple[str | None, str | None]:
    if purpose != "enroll_device":
        return None, None
    try:
        user, app_session = authenticate_access_token_with_session(
            session, bearer_token_from_request(request)
        )
    except AppAuthError as exc:
        raise HTTPException(status_code=401, detail="Invalid or expired token") from exc
    if app_session.device_public_key is not None:
        raise HTTPException(status_code=409, detail={"code": "device_key_already_enrolled"})
    return user.id, app_session.id


def public_failure_code(reason: str) -> str:
    if reason in {"account_pending_deletion", "account_not_pending_deletion", "account_not_found"}:
        return reason
    return "sign_in_failed"


def _deep_link_redirect(**params: str) -> RedirectResponse:
    settings = get_settings()
    query = urlencode({key: value for key, value in params.items() if value})
    separator = "&" if "?" in settings.ios_deep_link_redirect else "?"
    return RedirectResponse(f"{settings.ios_deep_link_redirect}{separator}{query}")


def _token_response(token_pair: TokenPair) -> TokenResponse:
    return TokenResponse(
        access_token=token_pair.access_token,
        refresh_token=token_pair.refresh_token,
        token_type=token_pair.token_type,
        expires_in=token_pair.expires_in,
    )


def _user_payload(session: DbSession, user: User) -> UserPayload:
    return UserPayload(
        id=user.id,
        sign_in_provider=session.scalar(
            select(SignInIdentity.provider).where(SignInIdentity.user_id == user.id)
        ),
        email=user.email,
        first_name=user.first_name,
        last_name=user.last_name,
        created_at=user.created_at,
    )


def _me_response(session: DbSession, user: User) -> MeResponse:
    profile = get_or_create_profile(session, user.id)
    session.commit()
    return MeResponse(
        user=_user_payload(session, user),
        health_connection=_health_connection_status(session, user.id),
        profile=MeProfileStatus(
            onboarding_completed_at=profile.onboarding_completed_at,
            weather_enabled=profile.weather_enabled,
        ),
    )


def _clean_string(value: str) -> str:
    cleaned = value.strip()
    if not cleaned:
        raise HTTPException(status_code=422, detail="String fields cannot be blank")
    return cleaned


def _clean_optional_string(value: str | None) -> str | None:
    if value is None:
        return None
    cleaned = value.strip()
    return cleaned or None


def _health_connection_status(session: DbSession, user_id: str) -> HealthConnectionStatus:
    connection = latest_health_connection(session, user_id)
    if connection is None:
        return HealthConnectionStatus(
            provider=None,
            status="disconnected",
            connected_at=None,
            last_sync_at=None,
            last_error=None,
        )
    return HealthConnectionStatus(
        provider=connection.provider,
        status=connection.status.value,
        connected_at=connection.connected_at,
        last_sync_at=connection.last_sync_at,
        last_error=connection.last_error,
    )


def _connection_payload(connection: HealthConnection) -> dict[str, object]:
    return {
        "account_id": connection.id,
        "provider": connection.provider,
        "status": connection.status.value,
        "external_user_id_present": bool(connection.external_user_id),
        "external_legacy_user_id_present": bool(connection.external_legacy_user_id),
        "granted_scopes": connection.granted_scopes,
        "connected_at": connection.connected_at,
        "last_sync_at": connection.last_sync_at,
        "last_error": connection.last_error,
    }
