from cryptography.fernet import Fernet, InvalidToken, MultiFernet
from sqlalchemy import JSON
from sqlalchemy.types import TypeDecorator

from app.core.config import get_settings


class JournalTextUnavailable(RuntimeError):
    pass


def note_cipher():
    keys = [key.strip() for key in get_settings().journal_encryption_key.split(",") if key.strip()]
    try:
        return MultiFernet([Fernet(key.encode("utf-8")) for key in keys])
    except ValueError:
        raise JournalTextUnavailable("Journal encryption key is missing or invalid") from None


def seal_text(node):
    if isinstance(node, list):
        return [seal_text(item) for item in node]
    if not isinstance(node, dict):
        return node
    if node.get("type") == "text" and isinstance(node.get("value"), str):
        token = note_cipher().encrypt(node["value"].encode("utf-8")).decode("utf-8")
        return {"type": "text", "ciphertext": token}
    return {key: seal_text(value) for key, value in node.items()}


def open_text(node):
    if isinstance(node, list):
        return [open_text(item) for item in node]
    if not isinstance(node, dict):
        return node
    if node.get("type") == "text" and isinstance(node.get("ciphertext"), str):
        try:
            value = note_cipher().decrypt(node["ciphertext"].encode("utf-8")).decode("utf-8")
        except InvalidToken:
            raise JournalTextUnavailable("Stored journal text could not be decrypted") from None
        return {"type": "text", "value": value}
    return {key: open_text(value) for key, value in node.items()}


class SealedJSON(TypeDecorator):
    impl = JSON
    cache_ok = True

    def process_bind_param(self, value, dialect):
        return seal_text(value)

    def process_result_value(self, value, dialect):
        return open_text(value)
