"""
Shared utility functions for the ZeroChat server.
"""

import ipaddress
import json
import os
import secrets
import socket
import tempfile
from pathlib import Path
from typing import Any, Optional, Union
from urllib.parse import urlparse

TOOL_ROLE_PREFIX = "1000000000"
MIN_SECRET_LENGTH = 16


def atomic_write_json(
    path: Union[str, Path],
    data: Any,
    *,
    ensure_ascii: bool = False,
    indent: Optional[int] = 2,
) -> None:
    """原子写 JSON：写入同目录临时文件后 os.replace 覆盖目标。

    避免进程崩溃 / 并发读取到半截写入的文件（write-temp-then-rename）。
    临时文件与目标同目录以保证 rename 在同一文件系统内为原子操作。
    """
    target = Path(path)
    target.parent.mkdir(parents=True, exist_ok=True)
    fd, tmp_name = tempfile.mkstemp(
        prefix=f".{target.name}.", suffix=".tmp", dir=str(target.parent)
    )
    try:
        with os.fdopen(fd, "w", encoding="utf-8") as f:
            json.dump(data, f, ensure_ascii=ensure_ascii, indent=indent)
            f.flush()
            os.fsync(f.fileno())
        os.replace(tmp_name, target)
    except BaseException:
        try:
            os.unlink(tmp_name)
        except OSError:
            pass
        raise


def ensure_simple_path_segment(value: Optional[str], field_name: str = "path") -> str:
    """Validate a single untrusted path segment."""
    normalized = str(value or "").strip()
    if not normalized:
        raise ValueError(f"{field_name} cannot be empty")
    if normalized in {".", ".."}:
        raise ValueError(f"{field_name} is invalid")
    if any(ch in normalized for ch in ("/", "\\", "\x00")):
        raise ValueError(f"{field_name} is invalid")
    return normalized


def ensure_path_within_root(path: Path, root: Path) -> Path:
    """Resolve a path and ensure it stays inside the expected root."""
    resolved_root = root.resolve()
    resolved_path = path.resolve()
    try:
        resolved_path.relative_to(resolved_root)
    except ValueError as exc:
        raise ValueError("resolved path escapes allowed root") from exc
    return resolved_path


def ensure_direct_child_path(
    root: Path, value: Optional[str], field_name: str = "path"
) -> Path:
    """Resolve one untrusted child segment without following directory aliases."""
    safe_value = ensure_simple_path_segment(value, field_name)
    resolved_root = root.resolve()
    expected_path = resolved_root / safe_value
    resolved_path = expected_path.resolve()
    if resolved_path != expected_path:
        raise ValueError(f"{field_name} resolves through a symbolic link")
    return ensure_path_within_root(resolved_path, resolved_root)


def is_secure_secret(secret: Optional[str], legacy_default: Optional[str] = None) -> bool:
    """Check whether a configured shared secret is acceptable for production use."""
    value = str(secret or "").strip()
    if len(value) < MIN_SECRET_LENGTH:
        return False
    if legacy_default and secrets.compare_digest(value, legacy_default):
        return False
    return True


def _is_disallowed_ip(ip: "ipaddress._BaseAddress") -> bool:
    """判断 IP 是否落在需要拒绝的内网/环回/链路本地/元数据等敏感段。"""
    return (
        ip.is_private
        or ip.is_loopback
        or ip.is_link_local
        or ip.is_reserved
        or ip.is_multicast
        or ip.is_unspecified
        # 云元数据地址 169.254.169.254 已被 link_local 覆盖；IPv4-mapped IPv6 额外处理
        or (isinstance(ip, ipaddress.IPv6Address) and ip.ipv4_mapped is not None
            and _is_disallowed_ip(ip.ipv4_mapped))
    )


def is_safe_external_url(
    url: Optional[str],
    allowed_hosts: Optional[set] = None,
    allowed_schemes: tuple = ("http", "https"),
) -> bool:
    """
    校验一个用于服务端出站下载的 URL 是否安全，防止 SSRF。

    - 仅允许 allowed_schemes 中的协议（默认 http/https；QQ CDN 图片常为 http）。
    - 解析主机名到 IP（含所有 A/AAAA 记录），拒绝私有/环回/链路本地/元数据等敏感段。
    - 若提供 allowed_hosts，则主机名必须在白名单内（精确匹配或子域）。
    """
    value = str(url or "").strip()
    if not value:
        return False

    try:
        parsed = urlparse(value)
    except Exception:
        return False

    if parsed.scheme.lower() not in allowed_schemes:
        return False

    host = parsed.hostname
    if not host:
        return False

    if allowed_hosts:
        host_lower = host.lower()
        if not any(
            host_lower == h or host_lower.endswith("." + h)
            for h in (a.lower() for a in allowed_hosts)
        ):
            return False

    # 解析主机名到所有 IP，任一落入敏感段即拒绝（防 DNS rebinding 的基础校验）
    default_port = 443 if parsed.scheme.lower() == "https" else 80
    try:
        infos = socket.getaddrinfo(host, parsed.port or default_port, proto=socket.IPPROTO_TCP)
    except (socket.gaierror, UnicodeError, ValueError):
        return False

    if not infos:
        return False

    for info in infos:
        sockaddr = info[4]
        ip_str = sockaddr[0]
        try:
            ip = ipaddress.ip_address(ip_str)
        except ValueError:
            return False
        if _is_disallowed_ip(ip):
            return False

    return True


def load_moments_posts(moments_file: Union[str, Path]) -> list:
    """读取朋友圈 posts.json，返回 dict 列表（容错：文件缺失/损坏时返回空列表）。

    ai_behavior 与 scheduler_service 共用，避免两份重复实现漂移。
    """
    path = Path(moments_file)
    if not path.exists():
        return []
    try:
        with open(path, "r", encoding="utf-8") as f:
            data = json.load(f)
        if isinstance(data, list):
            return [item for item in data if isinstance(item, dict)]
    except Exception:
        return []
    return []


def is_tool_role_id(role_id: Optional[str]) -> bool:
    """Check if a role ID belongs to a system/tool role."""
    return str(role_id or "").startswith(TOOL_ROLE_PREFIX)


def mask_api_key(api_key: Optional[str]) -> Optional[str]:
    """Mask an API key, showing first 8 and last 4 characters."""
    if not api_key or api_key == "***":
        return None
    if len(api_key) > 12:
        return f"{api_key[:8]}...{api_key[-4:]}"
    return "***"
