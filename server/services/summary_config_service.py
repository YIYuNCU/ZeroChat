"""Independent configuration for the two memory summaries.

Context (event) summaries and core-memory summaries used to borrow their API settings
from the built-in tool roles ``1000000000002`` / ``1000000000000``. They are now driven
by their own settings entries so the features no longer depend on any role:

* ``context_summary_config``      – 事件/上下文总结（写入 short_term 的 memory_summary）
* ``core_memory_summary_config``  – 核心记忆总结（写入 memory_meta.core_memory）

Missing values fall back to the global chat API. A one-time migration copies the legacy
tool-role profiles into settings so existing installations keep working, after which the
roles are never read again.
"""
from __future__ import annotations

import logging
from typing import Any, Dict, Optional

from services import prompt_config_service, settings_service

logger = logging.getLogger(__name__)

CONTEXT_SUMMARY = "context_summary"
CORE_MEMORY_SUMMARY = "core_memory_summary"

SUMMARY_KINDS = (CONTEXT_SUMMARY, CORE_MEMORY_SUMMARY)

CONFIG_KEYS = {
    CONTEXT_SUMMARY: "context_summary_config",
    CORE_MEMORY_SUMMARY: "core_memory_summary_config",
}

PROMPT_IDS = {
    CONTEXT_SUMMARY: prompt_config_service.SUMMARY_CONTEXT_EVENTS_ID,
    CORE_MEMORY_SUMMARY: prompt_config_service.SUMMARY_CORE_MEMORY_ID,
}

#: Legacy tool-role profiles used only to seed the first migration.
LEGACY_WORKER_IDS = {
    CONTEXT_SUMMARY: "1000000000002",
    CORE_MEMORY_SUMMARY: "1000000000000",
}

MIGRATION_FLAG_KEY = "summary_config_migrated"

DEFAULT_TEMPERATURE = 0.1
DEFAULT_TIMEOUT_SECONDS = 60


def default_summary_config() -> Dict[str, Any]:
    """Return the shipped defaults for one summary configuration entry."""
    return settings_service.default_summary_config()


def _normalize_api_format(value: Any) -> str:
    """Return a supported stored format, or ``""`` when unset.

    An empty result means "inherit the global chat API format", matching the
    ``api_url`` / ``api_key`` / ``model`` fallback behaviour.
    """
    text = str(value or "").strip().lower()
    return text if text in {
        "auto", "gemini_native", "openai_compatible", "zhipu_compatible",
    } else ""


def _stored_api_format(stored: Dict[str, Any]) -> str:
    """Return an explicitly chosen stored format.

    An independent endpoint must detect its own protocol. Only the default config
    with no endpoint inherits the global provider's protocol.
    """
    normalized = _normalize_api_format(stored.get("api_format"))
    if normalized == "auto" and not str(stored.get("api_url") or "").strip():
        return ""
    return normalized


def _normalize_temperature(value: Any) -> float:
    try:
        return min(2.0, max(0.0, float(value)))
    except (TypeError, ValueError):
        return DEFAULT_TEMPERATURE


def _normalize_timeout(value: Any) -> int:
    try:
        return max(1, min(3600, int(value)))
    except (TypeError, ValueError):
        return DEFAULT_TIMEOUT_SECONDS


def sanitize_summary_config(value: Any) -> Dict[str, Any]:
    """Normalize a partial summary configuration into the stored shape."""
    base = default_summary_config()
    if not isinstance(value, dict):
        return base
    for key in ("api_url", "api_key", "model", "reasoning_effort", "system_prompt"):
        if key in value and value[key] is not None:
            base[key] = str(value[key]).strip()[: prompt_config_service.MAX_PROMPT_OVERRIDE_CHARS]
    if "enabled" in value and value["enabled"] is not None:
        base["enabled"] = bool(value["enabled"])
    if "api_format" in value and value["api_format"] is not None:
        base["api_format"] = _normalize_api_format(value["api_format"])
    if "temperature" in value and value["temperature"] is not None:
        base["temperature"] = _normalize_temperature(value["temperature"])
    if "timeout_seconds" in value and value["timeout_seconds"] is not None:
        base["timeout_seconds"] = _normalize_timeout(value["timeout_seconds"])
    if "thinking_enabled" in value and value["thinking_enabled"] is not None:
        base["thinking_enabled"] = bool(value["thinking_enabled"])
    if "thinking_budget" in value and value["thinking_budget"] is not None:
        try:
            budget = int(value["thinking_budget"])
        except (TypeError, ValueError):
            budget = 0
        base["thinking_budget"] = budget if budget > 0 else None
    return base


def _legacy_role_config(kind: str) -> Optional[Dict[str, Any]]:
    """Read the legacy tool-role profile once, for migration only."""
    worker_id = LEGACY_WORKER_IDS.get(kind)
    if not worker_id:
        return None
    try:
        from routers.roles import load_role

        profile = load_role(worker_id)
    except Exception:
        logger.warning("读取旧总结助手档案失败: %s", worker_id, exc_info=True)
        return None
    if not isinstance(profile, dict):
        return None
    metadata = profile.get("metadata") or {}
    if not isinstance(metadata, dict):
        metadata = {}

    def thinking_value(key: str) -> Any:
        value = profile.get(key)
        return metadata.get(key) if value is None else value

    return {
        "api_url": profile.get("ai_api_url"),
        "api_key": profile.get("ai_api_key"),
        "model": profile.get("ai_model"),
        "api_format": profile.get("ai_api_format"),
        "temperature": profile.get("ai_temperature"),
        "timeout_seconds": profile.get("ai_timeout_seconds"),
        "reasoning_effort": thinking_value("ai_reasoning_effort"),
        "thinking_enabled": thinking_value("ai_thinking_enabled"),
        "thinking_budget": thinking_value("ai_thinking_budget"),
    }


def _migrate_legacy_settings(settings: Dict[str, Any]) -> Dict[str, Any]:
    """Seed both summary configs from the legacy tool roles exactly once."""
    if settings.get(MIGRATION_FLAG_KEY):
        return settings
    updates: Dict[str, Any] = {MIGRATION_FLAG_KEY: True}
    for kind in SUMMARY_KINDS:
        key = CONFIG_KEYS[kind]
        stored = settings.get(key)
        # ``load_settings`` overlays defaults, so an untouched installation has a
        # default-shaped entry here. Any deviation is an explicit new-style choice
        # (including disabling the feature) and must win over legacy data.
        if isinstance(stored, dict) and sanitize_summary_config(stored) != default_summary_config():
            continue
        legacy = _legacy_role_config(kind)
        if not legacy:
            continue
        merged = sanitize_summary_config({**default_summary_config(), **{
            field: value for field, value in legacy.items() if value is not None
        }})
        updates[key] = merged
        logger.info("已从旧总结助手档案迁移 %s 配置: %s", key, legacy.get("model"))
    settings_service.save_settings(updates)
    settings.update(updates)
    return settings


def load_settings_with_summary_configs() -> Dict[str, Any]:
    """Migrate before exposing settings to clients that sync the whole snapshot."""
    return _migrate_legacy_settings(dict(settings_service.load_settings()))


def load_summary_config(kind: str) -> Dict[str, Any]:
    """Return the normalized stored configuration for one summary kind."""
    if kind not in CONFIG_KEYS:
        raise ValueError(f"unknown summary kind: {kind}")
    settings = load_settings_with_summary_configs()
    return sanitize_summary_config(settings.get(CONFIG_KEYS[kind]))


def update_summary_config(kind: str, value: Any) -> bool:
    """Merge a partial summary update into the migrated stored configuration."""
    if kind not in CONFIG_KEYS:
        raise ValueError(f"unknown summary kind: {kind}")
    if not isinstance(value, dict):
        return False
    current = load_summary_config(kind)
    merged = {**current, **value}
    return settings_service.save_settings({
        CONFIG_KEYS[kind]: sanitize_summary_config(merged),
    })


def save_summary_config(kind: str, value: Any) -> bool:
    """Backward-compatible alias for partial summary configuration updates."""
    return update_summary_config(kind, value)


def resolve_summary_config(kind: str) -> Dict[str, Any]:
    """Resolve the effective summary call configuration.

    Empty ``api_url`` / ``api_key`` / ``model`` fall back to the global chat API, matching
    the embedding ``*_api_url`` fallback convention. ``system_prompt`` falls back to the
    prompt registry default. ``enabled`` is honored as-is.
    """
    stored = load_summary_config(kind)
    chat = settings_service.get_ai_config()
    thinking_defaults = settings_service.get_thinking_config("chat")
    resolved = {
        "enabled": bool(stored.get("enabled", True)),
        "api_url": str(stored.get("api_url") or "").strip() or chat.get("api_url", ""),
        "api_key": str(stored.get("api_key") or "").strip() or chat.get("api_key", ""),
        "model": str(stored.get("model") or "").strip() or chat.get("model", ""),
        "api_format": _stored_api_format(stored) or _normalize_api_format(chat.get("api_format")) or "auto",
        "temperature": _normalize_temperature(stored.get("temperature")),
        "timeout_seconds": _normalize_timeout(stored.get("timeout_seconds")),
        "reasoning_effort": (
            str(stored.get("reasoning_effort") or "").strip()
            or str(chat.get("reasoning_effort") or "").strip()
        ),
        "thinking_enabled": (
            stored.get("thinking_enabled")
            if stored.get("thinking_enabled") is not None
            else thinking_defaults.get("thinking_enabled")
        ),
        "thinking_budget": (
            stored.get("thinking_budget")
            if stored.get("thinking_budget") is not None
            else thinking_defaults.get("thinking_budget")
        ),
    }
    resolved["system_prompt"] = summary_system_prompt(
        kind,
        model=resolved["model"],
        api_url=resolved["api_url"],
        stored_prompt=stored.get("system_prompt"),
    )
    resolved["configured"] = bool(resolved["api_url"] and resolved["api_key"] and resolved["model"])
    return resolved


def summary_system_prompt(
    kind: str,
    *,
    model: Optional[str] = None,
    api_url: Optional[str] = None,
    stored_prompt: Optional[str] = None,
) -> str:
    """Resolve the system prompt for one summary kind.

    A non-empty ``system_prompt`` in the summary config wins; otherwise the model-profile
    prompt override for that summary applies, and finally the built-in registry default.
    """
    text = str(stored_prompt or "").strip()
    base = prompt_config_service.resolve(
        PROMPT_IDS[kind],
        api_url=api_url,
        model=model,
    )
    if not text:
        return base
    return f"{base}\n\n{text}" if base else text
