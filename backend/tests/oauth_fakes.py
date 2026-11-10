from __future__ import annotations

from urllib.parse import parse_qs, urlparse

from app.core.config import get_settings


class FakeGoogleClient:
    def __init__(
        self,
        *,
        subject: str = "google-sub",
        email: str | None = "person@example.com",
        email_verified: object = "true",
        audience: str | None = None,
        id_token: str | None = "id-token",
        health_user_id: str = "google-health-id",
        legacy_user_id: str = "fitbit-legacy-id",
        refresh_token: str | None = "refresh-token",
    ) -> None:
        self.settings = get_settings()
        self.subject = subject
        self.email = email
        self.email_verified = email_verified
        self.audience = audience or self.settings.google_health_client_id
        self.id_token = id_token
        self.health_user_id = health_user_id
        self.legacy_user_id = legacy_user_id
        self.refresh_token = refresh_token
        self.revoked: list[str] = []

    async def exchange_code_for_tokens(self, code: str) -> dict[str, object]:
        payload: dict[str, object] = {
            "access_token": "access-token",
            "expires_in": 3600,
            "scope": "scope-a scope-b",
        }
        if self.refresh_token:
            payload["refresh_token"] = self.refresh_token
        if self.id_token:
            payload["id_token"] = self.id_token
        return payload

    async def verify_id_token(self, id_token: str) -> dict[str, object]:
        assert id_token == self.id_token
        return {
            "iss": "https://accounts.google.com",
            "aud": self.audience,
            "sub": self.subject,
            "email": self.email,
            "email_verified": self.email_verified,
        }

    async def get_identity(self, access_token: str) -> dict[str, str]:
        assert access_token == "access-token"
        return {"healthUserId": self.health_user_id, "legacyUserId": self.legacy_user_id}

    async def revoke_token(self, token: str) -> None:
        self.revoked.append(token)


def state_from(url: str) -> str:
    return parse_qs(urlparse(url).query)["state"][0]
