from __future__ import annotations

import base64
import binascii
import struct

from cryptography.exceptions import InvalidSignature
from cryptography.hazmat.primitives import hashes
from cryptography.hazmat.primitives.asymmetric import ec


TRANSCRIPT_DOMAIN = "conceptual-fitness/device-proof/v1"


class DeviceKeyError(RuntimeError):
    pass


def normalize_public_key(value: str) -> str:
    raw = decode_base64(value, "device public key")
    if len(raw) != 65 or raw[0] != 4:
        raise DeviceKeyError("Device public key must be an uncompressed P-256 X9.63 key")
    try:
        ec.EllipticCurvePublicKey.from_encoded_point(ec.SECP256R1(), raw)
    except ValueError as exc:
        raise DeviceKeyError("Device public key is invalid") from exc
    return base64.b64encode(raw).decode("ascii")


def verify_signature(public_key: str, signature: str, transcript: bytes) -> None:
    key_bytes = decode_base64(public_key, "device public key")
    signature_bytes = decode_base64(signature, "device signature")
    try:
        key = ec.EllipticCurvePublicKey.from_encoded_point(ec.SECP256R1(), key_bytes)
        key.verify(signature_bytes, transcript, ec.ECDSA(hashes.SHA256()))
    except (ValueError, InvalidSignature) as exc:
        raise DeviceKeyError("Device signature is invalid") from exc


def auth_code_transcript(code: str, device_id: str) -> bytes:
    return encode_transcript(TRANSCRIPT_DOMAIN, "auth-code-exchange", code, device_id)


def sensitive_action_transcript(
    purpose: str,
    session_id: str,
    challenge: str,
) -> bytes:
    return encode_transcript(
        TRANSCRIPT_DOMAIN,
        "sensitive-action",
        purpose,
        session_id,
        challenge,
    )


def recovery_transcript(challenge: str, device_id: str) -> bytes:
    return encode_transcript(
        TRANSCRIPT_DOMAIN,
        "account-recovery",
        challenge,
        device_id,
    )


def encode_transcript(*fields: str) -> bytes:
    encoded = bytearray()
    for field in fields:
        value = field.encode("utf-8")
        encoded.extend(struct.pack(">I", len(value)))
        encoded.extend(value)
    return bytes(encoded)


def decode_base64(value: str, label: str) -> bytes:
    try:
        return base64.b64decode(value, validate=True)
    except (binascii.Error, ValueError) as exc:
        raise DeviceKeyError(f"Invalid base64 {label}") from exc
