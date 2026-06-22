from __future__ import annotations

from dataclasses import dataclass
from functools import lru_cache
import os
from pathlib import Path
from typing import Iterable

from dotenv import dotenv_values


BACKEND_DIR = Path(__file__).resolve().parents[2]
ENV_FILE = BACKEND_DIR / ".env"


GOOGLE_HEALTH_SCOPES: tuple[str, ...] = (
    "openid",
    "email",
    "profile",
    "https://www.googleapis.com/auth/googlehealth.activity_and_fitness.readonly",
    "https://www.googleapis.com/auth/googlehealth.health_metrics_and_measurements.readonly",
    "https://www.googleapis.com/auth/googlehealth.sleep.readonly",
    "https://www.googleapis.com/auth/googlehealth.profile.readonly",
)


@dataclass(frozen=True)
class Settings:
    app_env: str
    app_base_url: str
    ios_deep_link_redirect: str
    database_url: str
    redis_url: str
    google_health_api_timeout_seconds: float
    google_health_page_size: int
    google_health_client_id: str
    google_health_client_secret: str
    google_health_redirect_uri: str
    token_encryption_key: str
    session_secret_key: str
    access_token_ttl_minutes: int
    refresh_token_ttl_days: int
    app_auth_code_ttl_minutes: int
    allowed_cors_origins: tuple[str, ...]
    trust_proxy_headers: bool
    celery_timezone: str
    celery_sync_hour: str
    celery_sync_minute: str
    google_health_scopes: tuple[str, ...] = GOOGLE_HEALTH_SCOPES

    @property
    def is_configured_for_google(self) -> bool:
        values = (
            self.google_health_client_id,
            self.google_health_client_secret,
            self.google_health_redirect_uri,
        )
        return all(value and not value.lower().startswith("your-") for value in values)


def _read_env() -> dict[str, str]:
    file_values = dotenv_values(ENV_FILE) if ENV_FILE.exists() else {}
    values = {key: str(value) for key, value in file_values.items() if value is not None}
    values.update({key: value for key, value in os.environ.items() if value is not None})
    return values


def _get(env: dict[str, str], key: str, default: str | None = None) -> str:
    value = env.get(key, default)
    if value is None or value == "":
        raise RuntimeError(f"Missing required environment variable: {key}")
    return value


def _get_int(env: dict[str, str], key: str, default: int) -> int:
    value = _get(env, key, str(default))
    try:
        return int(value)
    except ValueError as exc:
        raise RuntimeError(f"Environment variable {key} must be an integer") from exc


def _get_float(env: dict[str, str], key: str, default: float) -> float:
    value = _get(env, key, str(default))
    try:
        return float(value)
    except ValueError as exc:
        raise RuntimeError(f"Environment variable {key} must be a number") from exc


def _get_bool(env: dict[str, str], key: str, default: bool) -> bool:
    value = env.get(key)
    if value is None or value == "":
        return default
    return value.strip().lower() in {"1", "true", "yes", "on"}


def _parse_csv(value: str | None) -> tuple[str, ...]:
    if not value:
        return ()
    return tuple(item.strip() for item in value.split(",") if item.strip())


def _parse_scopes(value: str | None) -> tuple[str, ...]:
    if not value:
        return GOOGLE_HEALTH_SCOPES
    return tuple(scope.strip() for scope in value.replace(",", " ").split() if scope.strip())


@lru_cache(maxsize=1)
def get_settings() -> Settings:
    env = _read_env()
    return Settings(
        app_env=_get(env, "APP_ENV", "local"),
        app_base_url=_get(env, "APP_BASE_URL", "http://localhost:8000").rstrip("/"),
        ios_deep_link_redirect=_get(env, "IOS_DEEP_LINK_REDIRECT", "healthapp://auth/callback"),
        database_url=_get(env, "DATABASE_URL", "sqlite:///./health.sqlite3"),
        redis_url=_get(env, "REDIS_URL", "redis://localhost:6379/0"),
        google_health_api_timeout_seconds=_get_float(env, "GOOGLE_HEALTH_API_TIMEOUT_SECONDS", 30.0),
        google_health_page_size=_get_int(env, "GOOGLE_HEALTH_PAGE_SIZE", 500),
        google_health_client_id=_get(env, "GOOGLE_HEALTH_CLIENT_ID"),
        google_health_client_secret=_get(env, "GOOGLE_HEALTH_CLIENT_SECRET"),
        google_health_redirect_uri=_get(env, "GOOGLE_HEALTH_REDIRECT_URI"),
        token_encryption_key=_get(env, "TOKEN_ENCRYPTION_KEY"),
        session_secret_key=_get(env, "SESSION_SECRET_KEY"),
        access_token_ttl_minutes=_get_int(env, "ACCESS_TOKEN_TTL_MINUTES", 15),
        refresh_token_ttl_days=_get_int(env, "REFRESH_TOKEN_TTL_DAYS", 30),
        app_auth_code_ttl_minutes=_get_int(env, "APP_AUTH_CODE_TTL_MINUTES", 5),
        allowed_cors_origins=_parse_csv(env.get("ALLOWED_CORS_ORIGINS")),
        trust_proxy_headers=_get_bool(env, "TRUST_PROXY_HEADERS", False),
        celery_timezone=_get(env, "CELERY_TIMEZONE", "UTC"),
        celery_sync_hour=_get(env, "CELERY_SYNC_HOUR", "*"),
        celery_sync_minute=_get(env, "CELERY_SYNC_MINUTE", "0"),
        google_health_scopes=_parse_scopes(env.get("GOOGLE_HEALTH_SCOPES")),
    )


def missing_or_placeholder_keys(settings: Settings) -> list[str]:
    keys: Iterable[tuple[str, str]] = (
        ("GOOGLE_HEALTH_CLIENT_ID", settings.google_health_client_id),
        ("GOOGLE_HEALTH_CLIENT_SECRET", settings.google_health_client_secret),
        ("GOOGLE_HEALTH_REDIRECT_URI", settings.google_health_redirect_uri),
        ("TOKEN_ENCRYPTION_KEY", settings.token_encryption_key),
        ("SESSION_SECRET_KEY", settings.session_secret_key),
    )
    return [
        key
        for key, value in keys
        if not value or value.lower().startswith("your-") or value.lower() == "generate-this"
    ]


def validate_production_settings(settings: Settings) -> None:
    if settings.app_env != "production":
        return
    missing = missing_or_placeholder_keys(settings)
    if missing:
        raise RuntimeError(f"Production configuration is incomplete: {', '.join(missing)}")
    if not settings.app_base_url.startswith("https://"):
        raise RuntimeError("APP_BASE_URL must use https:// in production")
    if not settings.google_health_redirect_uri.startswith("https://"):
        raise RuntimeError("GOOGLE_HEALTH_REDIRECT_URI must use https:// in production")
