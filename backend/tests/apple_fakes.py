from __future__ import annotations

import json
import time

import jwt
from cryptography.hazmat.primitives.asymmetric import rsa

from app.apple.client import APPLE_ISSUER, APPLE_REVOKE_URL, APPLE_TOKEN_URL, AppleClient
from app.services.apple_sign_in import hashed_nonce

KEY_ID = "test-apple-key"
SIGNING_KEY = rsa.generate_private_key(public_exponent=65537, key_size=2048)


class FakeAppleClient(AppleClient):
    def __init__(
        self,
        *,
        subject: str = "apple-sub",
        email: str | None = "relay123@privaterelay.appleid.com",
        exchanged_subject: str | None = None,
        refresh_token: str | None = "apple-refresh-token",
    ) -> None:
        super().__init__()
        self.subject = subject
        self.email = email
        self.exchanged_subject = exchanged_subject or subject
        self.refresh_token = refresh_token
        self.requests: list[tuple[str, dict[str, str] | None]] = []

    async def public_keys(self, *, force_refresh: bool) -> dict:
        return {KEY_ID: SIGNING_KEY.public_key()}

    async def request(self, method: str, url: str, data: dict[str, str] | None = None) -> dict:
        self.requests.append((url, data))
        if url == APPLE_TOKEN_URL:
            payload = {"id_token": self.token({"sub": self.exchanged_subject})}
            if self.refresh_token:
                payload["refresh_token"] = self.refresh_token
            return payload
        return {}

    def identity_token(self, raw_nonce: str, **overrides) -> str:
        claims = {"nonce": hashed_nonce(raw_nonce), "sub": self.subject, "is_private_email": "true"}
        if self.email:
            claims |= {"email": self.email, "email_verified": "true"}
        return self.token(claims | overrides)

    def notification(self, event_type: str, subject: str | None = None) -> str:
        events = {"type": event_type, "sub": subject or self.subject, "event_time": int(time.time())}
        return self.token({"events": json.dumps(events), "jti": "notification-id"})

    def token(self, claims: dict, *, key=SIGNING_KEY, key_id: str = KEY_ID) -> str:
        now = int(time.time())
        payload = {
            "iss": APPLE_ISSUER,
            "aud": self.settings.apple_client_id,
            "iat": now,
            "exp": now + 600,
        } | claims
        return jwt.encode(
            {name: value for name, value in payload.items() if value is not None},
            key,
            algorithm="RS256",
            headers={"kid": key_id},
        )

    @property
    def revoked(self) -> list[str]:
        return [data["token"] for url, data in self.requests if url == APPLE_REVOKE_URL]
