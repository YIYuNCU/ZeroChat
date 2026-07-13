"""
Shared utility functions for the ZeroChat server.
"""

import secrets
from pathlib import Path
from typing import Optional

TOOL_ROLE_PREFIX = "1000000000"
MIN_SECRET_LENGTH = 16


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


def is_secure_secret(secret: Optional[str], legacy_default: Optional[str] = None) -> bool:
    """Check whether a configured shared secret is acceptable for production use."""
    value = str(secret or "").strip()
    if len(value) < MIN_SECRET_LENGTH:
        return False
    if legacy_default and secrets.compare_digest(value, legacy_default):
        return False
    return True


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
