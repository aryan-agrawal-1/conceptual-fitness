from __future__ import annotations

from dataclasses import dataclass

from fastapi import HTTPException, Request
from redis import Redis
from redis.exceptions import RedisError

from app.core.config import get_settings


@dataclass(frozen=True)
class RateLimit:
    name: str
    limit: int
    window_seconds: int


AUTH_START_LIMIT = RateLimit("auth_start", 10, 600)
AUTH_EXCHANGE_LIMIT = RateLimit("auth_exchange", 10, 600)
AUTH_REFRESH_LIMIT = RateLimit("auth_refresh", 30, 600)
AUTH_LOGOUT_LIMIT = RateLimit("auth_logout", 30, 600)
CONNECTION_MUTATION_LIMIT = RateLimit("connection_mutation", 10, 600)


def client_ip(request: Request) -> str:
    settings = get_settings()
    if settings.trust_proxy_headers:
        forwarded_for = request.headers.get("x-forwarded-for")
        if forwarded_for:
            return forwarded_for.split(",")[0].strip()
    return request.client.host if request.client else "unknown"


def enforce_rate_limit(request: Request, limit: RateLimit, *parts: str | None) -> None:
    settings = get_settings()
    key_parts = [part for part in parts if part]
    identity = ":".join(key_parts) if key_parts else client_ip(request)
    key = f"rate-limit:{limit.name}:{identity}"
    try:
        redis = Redis.from_url(settings.redis_url, decode_responses=True)
        count = redis.incr(key)
        if count == 1:
            redis.expire(key, limit.window_seconds)
        if count > limit.limit:
            raise HTTPException(status_code=429, detail="Too many requests")
    except HTTPException:
        raise
    except RedisError as exc:
        if settings.app_env == "production":
            raise HTTPException(status_code=503, detail="Rate limiting unavailable") from exc
