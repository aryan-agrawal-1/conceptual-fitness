from __future__ import annotations

from fastapi import APIRouter, HTTPException, Query
from fastapi.responses import RedirectResponse
from pydantic import BaseModel
from sqlalchemy import select

from app.api.deps import DbSession
from app.core.config import get_settings, missing_or_placeholder_keys
from app.core.security import decrypt_secret, utcnow
from app.google_health.client import GoogleHealthAPIError
from app.models import ConnectionStatus, GoogleAccount
from app.services.oauth import (
    OAuthConfigurationError,
    OAuthStateError,
    complete_google_health_oauth,
    create_authorization_url,
)
from app.tasks.sync import enqueue_initial_backfill


router = APIRouter(prefix="/auth/google-health", tags=["google-health-auth"])


class OAuthDiagnostics(BaseModel):
    configured: bool
    missing_or_placeholder_keys: list[str]
    redirect_uri: str
    app_base_url: str
    client_id_present: bool
    client_secret_present: bool
    scopes: list[str]


@router.get("/diagnostics", response_model=OAuthDiagnostics)
def diagnostics() -> OAuthDiagnostics:
    settings = get_settings()
    missing = missing_or_placeholder_keys(settings)
    return OAuthDiagnostics(
        configured=not missing,
        missing_or_placeholder_keys=missing,
        redirect_uri=settings.google_health_redirect_uri,
        app_base_url=settings.app_base_url,
        client_id_present=bool(settings.google_health_client_id),
        client_secret_present=bool(settings.google_health_client_secret),
        scopes=list(settings.google_health_scopes),
    )


# route to start auth process
@router.get("/start")
def start_google_health_oauth(
    session: DbSession,
    user_id: str | None = Query(default=None),
    redirect_after: str | None = Query(default=None),
) -> RedirectResponse:
    try:
        url = create_authorization_url(session, user_id=user_id, redirect_after=redirect_after)
    except OAuthConfigurationError as exc:
        raise HTTPException(status_code=500, detail=str(exc)) from exc
    return RedirectResponse(url)


@router.get("/start-url")
def start_google_health_oauth_url(
    session: DbSession,
    user_id: str | None = Query(default=None),
    redirect_after: str | None = Query(default=None),
) -> dict[str, str]:
    try:
        return {"authorization_url": create_authorization_url(session, user_id=user_id, redirect_after=redirect_after)}
    except OAuthConfigurationError as exc:
        raise HTTPException(status_code=500, detail=str(exc)) from exc


# callback url for the auth
@router.get("/callback")
async def google_health_oauth_callback(
    session: DbSession,
    code: str | None = Query(default=None),
    state: str | None = Query(default=None),
    error: str | None = Query(default=None),
) -> RedirectResponse:
    settings = get_settings()
    if error:
        return RedirectResponse(f"{settings.ios_deep_link_redirect}?status=error&reason={error}")
    if not code or not state:
        raise HTTPException(status_code=400, detail="Missing OAuth code or state")
    try:
        account = await complete_google_health_oauth(session, code=code, state=state)
    except (OAuthConfigurationError, OAuthStateError, GoogleHealthAPIError) as exc:
        raise HTTPException(status_code=400, detail=str(exc)) from exc

    queued = enqueue_initial_backfill(account.id)
    status = "connected_queued" if queued else "connected"
    return RedirectResponse(
        f"{settings.ios_deep_link_redirect}?status={status}&account_id={account.id}"
    )


# disconnect route
@router.post("/disconnect")
async def disconnect_google_health(
    session: DbSession,
    account_id: str = Query(...),
    revoke: bool = Query(default=True),
) -> dict[str, str]:
    from app.google_health.client import GoogleHealthClient

    account = session.get(GoogleAccount, account_id)
    if account is None:
        raise HTTPException(status_code=404, detail="Google account not found")
    if revoke and account.encrypted_refresh_token:
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


@router.get("/callback/debug")
def callback_debug() -> dict[str, str]:
    return {
        "message": "Use /auth/google-health/start in a browser. Google redirects back to /callback.",
    }


connections_router = APIRouter(prefix="/connections", tags=["connections"])


@connections_router.get("/google-health")
def google_health_connections(session: DbSession) -> list[dict[str, object]]:
    accounts = session.scalars(select(GoogleAccount).order_by(GoogleAccount.connected_at.desc())).all()
    return [
        {
            "account_id": account.id,
            "user_id": account.user_id,
            "status": account.status.value,
            "health_user_id_present": bool(account.health_user_id),
            "legacy_user_id_present": bool(account.legacy_user_id),
            "granted_scopes": account.granted_scopes,
            "connected_at": account.connected_at,
            "last_sync_at": account.last_sync_at,
            "last_error": account.last_error,
        }
        for account in accounts
    ]
