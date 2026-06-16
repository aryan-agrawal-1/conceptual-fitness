from __future__ import annotations

import hashlib
import hmac
import secrets
from datetime import UTC, datetime, timedelta

from cryptography.fernet import Fernet, InvalidToken

from app.core.config import get_settings


def utcnow() -> datetime:
    return datetime.now(UTC)


def expires_in(minutes: int) -> datetime:
    return utcnow() + timedelta(minutes=minutes)


def generate_state_token() -> str:
    return secrets.token_urlsafe(48)


def state_digest(state: str) -> str:
    secret = get_settings().session_secret_key.encode("utf-8")
    return hmac.new(secret, state.encode("utf-8"), hashlib.sha256).hexdigest()


def verify_state_digest(state: str, expected_digest: str) -> bool:
    return hmac.compare_digest(state_digest(state), expected_digest)


def encrypt_secret(value: str) -> str:
    fernet = Fernet(get_settings().token_encryption_key.encode("utf-8"))
    return fernet.encrypt(value.encode("utf-8")).decode("utf-8")


def decrypt_secret(value: str) -> str:
    fernet = Fernet(get_settings().token_encryption_key.encode("utf-8"))
    try:
        return fernet.decrypt(value.encode("utf-8")).decode("utf-8")
    except InvalidToken as exc:
        raise RuntimeError("Stored token could not be decrypted") from exc

