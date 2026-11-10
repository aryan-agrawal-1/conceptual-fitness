from __future__ import annotations

import asyncio
import json
import time
from typing import Any

import httpx
import jwt

from app.core.config import Settings, get_settings

APPLE_ISSUER = "https://appleid.apple.com"
APPLE_KEYS_URL = f"{APPLE_ISSUER}/auth/keys"
APPLE_TOKEN_URL = f"{APPLE_ISSUER}/auth/token"
APPLE_REVOKE_URL = f"{APPLE_ISSUER}/auth/revoke"
KEYS_CACHE_SECONDS = 3600
CLIENT_SECRET_LIFETIME_SECONDS = 300
CLOCK_LEEWAY_SECONDS = 60

public_key_cache: dict[str, Any] = {"keys": {}, "fetched_at": 0.0}


class AppleAuthError(RuntimeError):
    def __init__(self, message: str, status_code: int | None = None) -> None:
        super().__init__(message)
        self.status_code = status_code


class AppleClient:
    def __init__(self, settings: Settings | None = None, timeout: float = 10.0) -> None:
        self.settings = settings or get_settings()
        self.timeout = timeout

    async def verify_identity_token(self, identity_token: str) -> dict[str, Any]:
        return await self.verified_claims(identity_token, required=("exp", "iat", "sub"))

    async def verify_notification(self, signed_payload: str) -> dict[str, Any]:
        claims = await self.verified_claims(signed_payload, required=("iat", "events"))
        events = claims["events"]
        if isinstance(events, str):
            try:
                events = json.loads(events)
            except json.JSONDecodeError as exc:
                raise AppleAuthError("Apple notification events are invalid") from exc
        if not isinstance(events, dict) or not events.get("type") or not events.get("sub"):
            raise AppleAuthError("Apple notification events are invalid")
        return events

    async def verified_claims(self, token: str, *, required: tuple[str, ...]) -> dict[str, Any]:
        try:
            key_id = jwt.get_unverified_header(token).get("kid")
        except jwt.PyJWTError as exc:
            raise AppleAuthError("Apple token is malformed") from exc
        key = await self.signing_key(key_id)
        try:
            return jwt.decode(
                token,
                key,
                algorithms=["RS256"],
                audience=self.settings.apple_client_id,
                issuer=APPLE_ISSUER,
                leeway=CLOCK_LEEWAY_SECONDS,
                options={"require": ["aud", "iss", *required]},
            )
        except jwt.PyJWTError as exc:
            raise AppleAuthError("Apple token failed verification") from exc

    async def signing_key(self, key_id: str | None) -> Any:
        if not key_id:
            raise AppleAuthError("Apple token has no key id")
        keys = await self.public_keys(force_refresh=False)
        if key_id not in keys:
            keys = await self.public_keys(force_refresh=True)
        if key_id not in keys:
            raise AppleAuthError("Apple token signing key is unknown")
        return keys[key_id]

    async def public_keys(self, *, force_refresh: bool) -> dict[str, Any]:
        cache_is_fresh = time.monotonic() - public_key_cache["fetched_at"] < KEYS_CACHE_SECONDS
        if public_key_cache["keys"] and cache_is_fresh and not force_refresh:
            return public_key_cache["keys"]
        payload = await self.request("GET", APPLE_KEYS_URL)
        keys = {}
        for entry in payload.get("keys", []):
            try:
                keys[entry["kid"]] = jwt.PyJWK(entry).key
            except (KeyError, jwt.PyJWTError):
                continue
        public_key_cache["keys"] = keys
        public_key_cache["fetched_at"] = time.monotonic()
        return keys

    def client_secret(self) -> str:
        issued_at = int(time.time())
        try:
            return self.signed_client_secret(issued_at)
        except (ValueError, TypeError, jwt.PyJWTError) as exc:
            raise AppleAuthError("Apple private key is invalid") from exc

    def signed_client_secret(self, issued_at: int) -> str:
        return jwt.encode(
            {
                "iss": self.settings.apple_team_id,
                "iat": issued_at,
                "exp": issued_at + CLIENT_SECRET_LIFETIME_SECONDS,
                "aud": APPLE_ISSUER,
                "sub": self.settings.apple_client_id,
            },
            self.settings.apple_private_key,
            algorithm="ES256",
            headers={"kid": self.settings.apple_key_id},
        )

    async def exchange_code(self, authorization_code: str) -> dict[str, Any]:
        return await self.request(
            "POST",
            APPLE_TOKEN_URL,
            data={
                "client_id": self.settings.apple_client_id,
                "client_secret": self.client_secret(),
                "code": authorization_code,
                "grant_type": "authorization_code",
            },
        )

    async def revoke_token(self, refresh_token: str) -> None:
        await self.request(
            "POST",
            APPLE_REVOKE_URL,
            data={
                "client_id": self.settings.apple_client_id,
                "client_secret": self.client_secret(),
                "token": refresh_token,
                "token_type_hint": "refresh_token",
            },
        )

    async def request(self, method: str, url: str, data: dict[str, str] | None = None) -> dict[str, Any]:
        try:
            async with httpx.AsyncClient(timeout=httpx.Timeout(self.timeout)) as client:
                response = await asyncio.wait_for(
                    client.request(method, url, data=data), timeout=self.timeout
                )
        except (asyncio.TimeoutError, httpx.TimeoutException) as exc:
            raise AppleAuthError("Apple request timed out") from exc
        except httpx.HTTPError as exc:
            raise AppleAuthError("Apple request failed") from exc
        if response.status_code >= 400:
            raise AppleAuthError("Apple rejected the request", response.status_code)
        if not response.content:
            return {}
        try:
            return response.json()
        except ValueError as exc:
            raise AppleAuthError("Apple returned an unreadable response", response.status_code) from exc
