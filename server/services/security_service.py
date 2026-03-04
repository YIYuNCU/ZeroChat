"""
安全服务
提供固定 Token 鉴权与传输内容加解密能力
"""
from __future__ import annotations

import base64
import hashlib
import hmac
import json
import secrets
from typing import Any, Dict


DEFAULT_AUTH_TOKEN = "ZEROCHAT_FIXED_TOKEN_2026"
DEFAULT_ENCRYPTION_SECRET = "ZEROCHAT_TRANSFER_SECRET_2026"


def _build_keystream(secret_bytes: bytes, nonce: bytes, length: int) -> bytes:
    stream = bytearray()
    counter = 0
    while len(stream) < length:
        counter_bytes = counter.to_bytes(4, "big", signed=False)
        digest = hashlib.sha256(secret_bytes + nonce + counter_bytes).digest()
        stream.extend(digest)
        counter += 1
    return bytes(stream[:length])


def _xor_bytes(data: bytes, key_stream: bytes) -> bytes:
    return bytes(a ^ b for a, b in zip(data, key_stream))


def encrypt_payload(data: Any, secret: str) -> Dict[str, str]:
    plain = json.dumps(data, ensure_ascii=False, separators=(",", ":")).encode("utf-8")
    nonce = secrets.token_bytes(16)
    secret_bytes = secret.encode("utf-8")
    key_stream = _build_keystream(secret_bytes, nonce, len(plain))
    cipher = _xor_bytes(plain, key_stream)

    sign = hmac.new(secret_bytes, nonce + cipher, hashlib.sha256).hexdigest()
    return {
        "nonce": base64.b64encode(nonce).decode("ascii"),
        "ciphertext": base64.b64encode(cipher).decode("ascii"),
        "hmac": sign,
    }


def decrypt_payload(encrypted: Dict[str, str], secret: str) -> Any:
    if not isinstance(encrypted, dict):
        raise ValueError("invalid encrypted payload")

    nonce_b64 = encrypted.get("nonce")
    cipher_b64 = encrypted.get("ciphertext")
    sign = encrypted.get("hmac")
    if not nonce_b64 or not cipher_b64 or not sign:
        raise ValueError("encrypted payload missing fields")

    nonce = base64.b64decode(nonce_b64)
    cipher = base64.b64decode(cipher_b64)
    secret_bytes = secret.encode("utf-8")

    expected_sign = hmac.new(secret_bytes, nonce + cipher, hashlib.sha256).hexdigest()
    if not hmac.compare_digest(sign, expected_sign):
        raise ValueError("payload hmac verify failed")

    key_stream = _build_keystream(secret_bytes, nonce, len(cipher))
    plain = _xor_bytes(cipher, key_stream)
    return json.loads(plain.decode("utf-8"))
