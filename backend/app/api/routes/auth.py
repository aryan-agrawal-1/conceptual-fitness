from __future__ import annotations

from datetime import datetime
from urllib.parse import urlencode

from fastapi import APIRouter, Body, HTTPException, Query, Request, Response
from fastapi.responses import RedirectResponse
from pydantic import BaseModel, Field
from sqlalchemy import select

from app.api.deps import CurrentUser, DbSession, bearer_token_from_request
from app.core.config import get_settings, missing_or_placeholder_keys
from app.core.security import decrypt_secret, utcnow
from app.google_health.client import GoogleHealthAPIError
from app.models import ConnectionStatus, GoogleAccount, User
from app.services.health_dates import get_or_create_profile
from app.services.app_auth import (
    AppAuthError,
    TokenPair,
    create_app_auth_code,
    exchange_auth_code,
    refresh_tokens,
    revoke_with_access_token,
    revoke_with_refresh_token,
)
from app.services.oauth import (
    OAuthConfigurationError,
    OAuthStateError,
    complete_google_health_oauth,
    create_authorization_url,
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
from app.tasks.sync import enqueue_initial_backfill


router = APIRouter(prefix="/auth", tags=["auth"])


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


class UserPayload(BaseModel):
    id: str
    email: str | None
    first_name: str | None
    last_name: str | None
    created_at: datetime


class UserUpdate(BaseModel):
    first_name: str = Field(min_length=1, max_length=80)
    last_name: str | None = Field(default=None, max_length=80)


class GoogleHealthStatus(BaseModel):
    status: str
    connected_at: datetime | None
    last_sync_at: datetime | None
    last_error: str | None


class MeProfileStatus(BaseModel):
    onboarding_completed_at: datetime | None
    weather_enabled: bool


class MeResponse(BaseModel):
    user: UserPayload
    google_health: GoogleHealthStatus
    profile: MeProfileStatus


class DisconnectRequest(BaseModel):
    revoke: bool = True


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
) -> RedirectResponse:
    enforce_rate_limit(request, AUTH_START_LIMIT, client_ip(request), device_id)
    try:
        url = create_authorization_url(
            session,
            device_id=device_id,
            redirect_after=redirect_after,
        )
    except OAuthConfigurationError as exc:
        raise HTTPException(status_code=500, detail="OAuth configuration is incomplete") from exc
    return RedirectResponse(url)


@router.get("/google/start-url")
def start_google_oauth_url(
    request: Request,
    session: DbSession,
    device_id: str = Query(..., min_length=16),
    redirect_after: str | None = Query(default=None),
) -> dict[str, str]:
    enforce_rate_limit(request, AUTH_START_LIMIT, client_ip(request), device_id)
    try:
        return {
            "authorization_url": create_authorization_url(
                session,
                device_id=device_id,
                redirect_after=redirect_after,
            )
        }
    except OAuthConfigurationError as exc:
        raise HTTPException(status_code=500, detail="OAuth configuration is incomplete") from exc


@router.get("/google/callback")
async def google_oauth_callback(
    session: DbSession,
    code: str | None = Query(default=None),
    state: str | None = Query(default=None),
    error: str | None = Query(default=None),
) -> RedirectResponse:
    settings = get_settings()
    if error:
        return _deep_link_redirect(status="error", reason="oauth_error")
    if not code or not state:
        raise HTTPException(status_code=400, detail="Missing OAuth code or state")
    try:
        completion = await complete_google_health_oauth(session, code=code, state=state)
        app_code = create_app_auth_code(
            session,
            user_id=completion.account.user_id,
            device_id_hash=completion.device_id_hash,
        )
    except (OAuthConfigurationError, OAuthStateError, GoogleHealthAPIError):
        return _deep_link_redirect(status="error", reason="oauth_failed")

    queued = enqueue_initial_backfill(completion.account.id)
    status = "connected_queued" if queued else "connected"
    return _deep_link_redirect(status=status, code=app_code)


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
            user_agent=request.headers.get("user-agent"),
        )
    except AppAuthError as exc:
        raise HTTPException(status_code=401, detail="Invalid or expired token") from exc
    return _token_response(token_pair)


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


@connections_router.get("/google-health")
def google_health_connections(session: DbSession, user: CurrentUser) -> list[dict[str, object]]:
    accounts = session.scalars(
        select(GoogleAccount)
        .where(GoogleAccount.user_id == user.id)
        .order_by(GoogleAccount.connected_at.desc())
    ).all()
    return [_connection_payload(account) for account in accounts]


@connections_router.post("/google-health/disconnect")
async def disconnect_google_health(
    request: Request,
    session: DbSession,
    user: CurrentUser,
    payload: DisconnectRequest | None = None,
) -> dict[str, str]:
    enforce_rate_limit(request, CONNECTION_MUTATION_LIMIT, user.id)
    account = session.scalar(
        select(GoogleAccount)
        .where(GoogleAccount.user_id == user.id)
        .order_by(GoogleAccount.connected_at.desc())
    )
    if account is None:
        raise HTTPException(status_code=404, detail="Google Health account not found")
    revoke = True if payload is None else payload.revoke
    if revoke and account.encrypted_refresh_token:
        from app.google_health.client import GoogleHealthClient

        try:
            await GoogleHealthClient().revoke_token(decrypt_secret(account.encrypted_refresh_token))
        except GoogleHealthAPIError:
            pass
    account.status = ConnectionStatus.disconnected
    account.disconnected_at = utcnow()
    account.encrypted_refresh_token = None
    session.add(account)
    session.commit()
    return {"status": "disconnected", "account_id": account.id}


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


def _user_payload(user: User) -> UserPayload:
    return UserPayload(
        id=user.id,
        email=user.email,
        first_name=user.first_name,
        last_name=user.last_name,
        created_at=user.created_at,
    )


def _me_response(session: DbSession, user: User) -> MeResponse:
    profile = get_or_create_profile(session, user.id)
    session.commit()
    return MeResponse(
        user=_user_payload(user),
        google_health=_google_health_status(session, user.id),
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


def _google_health_status(session: DbSession, user_id: str) -> GoogleHealthStatus:
    account = session.scalar(
        select(GoogleAccount)
        .where(GoogleAccount.user_id == user_id)
        .order_by(GoogleAccount.connected_at.desc())
    )
    if account is None:
        return GoogleHealthStatus(
            status="disconnected",
            connected_at=None,
            last_sync_at=None,
            last_error=None,
        )
    return GoogleHealthStatus(
        status=account.status.value,
        connected_at=account.connected_at,
        last_sync_at=account.last_sync_at,
        last_error=account.last_error,
    )


def _connection_payload(account: GoogleAccount) -> dict[str, object]:
    return {
        "account_id": account.id,
        "status": account.status.value,
        "health_user_id_present": bool(account.health_user_id),
        "legacy_user_id_present": bool(account.legacy_user_id),
        "granted_scopes": account.granted_scopes,
        "connected_at": account.connected_at,
        "last_sync_at": account.last_sync_at,
        "last_error": account.last_error,
    }
