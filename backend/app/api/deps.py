from __future__ import annotations

from typing import Annotated

from fastapi import Depends, HTTPException, Request
from sqlalchemy.orm import Session

from app.core.config import get_settings
from app.db.session import get_db
from app.models import User
from app.services.app_auth import AppAuthError, authenticate_access_token


DbSession = Annotated[Session, Depends(get_db)]


def require_https_for_auth(request: Request) -> None:
    settings = get_settings()
    if settings.app_env != "production":
        return
    scheme = request.url.scheme
    if settings.trust_proxy_headers:
        scheme = request.headers.get("x-forwarded-proto", scheme).split(",")[0].strip()
    if scheme != "https":
        raise HTTPException(status_code=403, detail="HTTPS is required")


def bearer_token_from_request(request: Request) -> str:
    authorization = request.headers.get("authorization", "")
    scheme, _, token = authorization.partition(" ")
    if scheme.lower() != "bearer" or not token:
        raise HTTPException(status_code=401, detail="Invalid or expired token")
    return token


def get_current_user(request: Request, session: DbSession) -> User:
    require_https_for_auth(request)
    token = bearer_token_from_request(request)
    try:
        return authenticate_access_token(session, token)
    except AppAuthError as exc:
        raise HTTPException(status_code=401, detail="Invalid or expired token") from exc


CurrentUser = Annotated[User, Depends(get_current_user)]
