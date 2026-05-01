"""
Shared utility functions for the ZeroChat server.
"""

from typing import Optional

TOOL_ROLE_PREFIX = "1000000000"


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
