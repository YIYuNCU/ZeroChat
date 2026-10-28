"""OneBot 通道鉴权。

OneBot 通道豁免全局 X-Auth-Token 与加密，安全完全依赖 per-role secret。
启用但未配置 secret 视为配置错误，一律拒绝，绝不把空 secret 当作“关闭鉴权”。
"""
from __future__ import annotations

import hashlib
import hmac
from typing import Any, Mapping, Optional


def configured_secret(config: Mapping[str, Any]) -> str:
    return str(config.get("secret") or "").strip()


def secrets_match(candidate: str, secret: str) -> bool:
    """常量时间比较（按 UTF-8 字节，避免非 ASCII 触发 TypeError）。"""
    return hmac.compare_digest(str(candidate or "").encode("utf-8"), secret.encode("utf-8"))


_eq = secrets_match


def verify_signature(raw_body: bytes, secret: str, signature_header: str) -> bool:
    """验证 OneBot V11 HMAC-SHA1 签名。空 secret 不放行。"""
    if not secret or not signature_header or not signature_header.startswith("sha1="):
        return False
    expected = "sha1=" + hmac.new(secret.encode("utf-8"), raw_body, hashlib.sha1).hexdigest()
    return hmac.compare_digest(expected, signature_header)


def body_token(body: Any) -> str:
    if not isinstance(body, dict):
        return ""
    return str(body.get("token") or body.get("access_token") or body.get("secret") or "").strip()


def ws_header_or_query_ok(headers: Mapping[str, str], query: Mapping[str, str], secret: str) -> bool:
    """WS 握手阶段的三种凭据：Bearer、X-OneBot-Secret、access_token。"""
    auth_header = headers.get("authorization", "")
    if auth_header.lower().startswith("bearer ") and _eq(auth_header[7:].strip(), secret):
        return True
    if _eq(headers.get("x-onebot-secret", ""), secret):
        return True
    return _eq(query.get("access_token", ""), secret)


def http_ok(
    raw_body: bytes,
    headers: Mapping[str, str],
    query: Mapping[str, str],
    body: Any,
    secret: str,
) -> bool:
    signature = headers.get("x-signature", "")
    if signature and verify_signature(raw_body, secret, signature):
        return True
    for name in ("x-onebot-secret", "authorization", "x-auth-token"):
        value = headers.get(name, "").strip()
        if value:
            if name == "authorization" and value.lower().startswith("bearer "):
                value = value[7:].strip()
            if _eq(value, secret):
                return True
            break
    if _eq(query.get("access_token", ""), secret):
        return True
    return _eq(body_token(body), secret)
