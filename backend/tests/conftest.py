from __future__ import annotations

import os
from collections.abc import Generator

import pytest


os.environ.update(
    {
        "APP_ENV": "test",
        "APP_BASE_URL": "http://localhost:8000",
        "IOS_DEEP_LINK_REDIRECT": "healthapp://auth/callback",
        "APP_HOST": "0.0.0.0",
        "APP_PORT": "8000",
        "API_PORT": "8000",
        "UVICORN_RELOAD_FLAG": "--reload",
        "POSTGRES_DB": "health",
        "POSTGRES_USER": "health",
        "POSTGRES_PASSWORD": "health",
        "POSTGRES_PORT": "5432",
        "DATABASE_URL": "sqlite:////tmp/personal_health_backend_test.sqlite3",
        "REDIS_URL": "redis://localhost:6379/15",
        "REDIS_PORT": "6379",
        "GOOGLE_HEALTH_CLIENT_ID": "test-client-id.apps.googleusercontent.com",
        "GOOGLE_HEALTH_CLIENT_SECRET": "test-client-secret",
        "GOOGLE_HEALTH_REDIRECT_URI": "http://localhost:8000/auth/google/callback",
        "GOOGLE_HEALTH_API_TIMEOUT_SECONDS": "30",
        "GOOGLE_HEALTH_PAGE_SIZE": "500",
        "TOKEN_ENCRYPTION_KEY": "YWFhYWFhYWFhYWFhYWFhYWFhYWFhYWFhYWFhYWFhYWE=",
        "SESSION_SECRET_KEY": "test-session-secret",
        "ACCESS_TOKEN_TTL_MINUTES": "15",
        "REFRESH_TOKEN_TTL_DAYS": "30",
        "APP_AUTH_CODE_TTL_MINUTES": "5",
        "CELERY_TIMEZONE": "UTC",
        "CELERY_SYNC_HOUR": "*",
        "CELERY_SYNC_MINUTE": "0",
        "GOOGLE_HEALTH_SYNC_FRESHNESS_MINUTES": "15",
    }
)

from app.db.session import Base, SessionLocal, engine  # noqa: E402
from app.services.app_auth import create_app_auth_code, device_id_digest, exchange_auth_code  # noqa: E402


@pytest.fixture(autouse=True)
def database() -> Generator[None, None, None]:
    Base.metadata.drop_all(bind=engine)
    Base.metadata.create_all(bind=engine)
    yield
    Base.metadata.drop_all(bind=engine)


@pytest.fixture
def session() -> Generator:
    with SessionLocal() as db:
        yield db


@pytest.fixture
def auth_headers(session):
    def _headers(user, *, device_id: str = "test-device-id-000000000000") -> dict[str, str]:
        code = create_app_auth_code(
            session,
            user_id=user.id,
            device_id_hash=device_id_digest(device_id),
        )
        token_pair = exchange_auth_code(session, code=code, device_id=device_id)
        return {"Authorization": f"Bearer {token_pair.access_token}"}

    return _headers
