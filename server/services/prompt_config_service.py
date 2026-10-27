"""Configurable system-prompt registry.

Every system-prompt block that is sent to a model is registered here. The shipped text
lives in ``server/prompts/**/*.md`` (see :mod:`services.prompt_store`); this module adds
the user override layers on top and resolves the effective text for a request.

Each registry entry carries:

* ``builtin``  – the shipped default text, used whenever no override is configured;
* ``origin``   – ``"zerochat"`` / ``"onebot"`` for phase-specific blocks, ``"shared"``
                 for blocks that are identical in every phase;
* ``applies_to`` – which consumers may use the entry (``chat`` / ``summary``);
* ``version``  – bumped whenever the shipped text changes, so stored overrides can be
                 flagged as "based on an older builtin".

Resolution order per prompt id: **builtin → global override → model-profile override →
role metadata override**. Overrides live in ``config/settings.json``::

    "prompt_overrides": {"chat.no_reply": {"__builtin__": "…", "__base_version__": "2"}},
    "model_prompt_overrides": {"https://host/v1|model": {"chat.no_reply": {"__append__": "…"}}}

The inner map only uses reserved keys:

* ``__builtin__``     – replace the whole template;
* ``__append__``      – append text after the effective template (keeps receiving builtin
                        updates, unlike a forked copy);
* ``__base_version__`` – builtin version a replacement was written against.

Legacy phase keys (``zerochat`` / ``onebot`` / ``default`` / ``cloud_emoji``) are still
read for robustness and are folded into ``__builtin__`` by :func:`sanitize_overrides` /
:func:`migrate_stored_overrides`.

Templates may reference ``{NO_REPLY_DIRECTIVE}``, ``{STATS_LAYOUT_RULE}`` and the other
placeholders in :data:`services.prompt_store.KNOWN_PLACEHOLDERS`; :func:`resolve`
substitutes them from the caller-provided render variables so those protocol-critical
tokens stay under code control.
"""
from __future__ import annotations

import logging
import shutil
from typing import Any, Dict, List, Optional, Sequence, Tuple

from services import settings_service
from services.prompt_store import PromptDefinition, load_all

logger = logging.getLogger(__name__)

MAX_PROMPT_OVERRIDE_CHARS = 20000

ORIGIN_PHASES = ("zerochat", "onebot")
VARIANT_KEYS = ("default", "cloud_emoji")

#: Reserved key inside an override map that replaces a prompt's whole template.
BUILTIN_OVERRIDE_KEY = "__builtin__"
#: Reserved key whose text is appended after the effective template.
APPEND_OVERRIDE_KEY = "__append__"
#: Reserved key recording the builtin ``version`` a replacement was written against.
BASE_VERSION_KEY = "__base_version__"
RESERVED_OVERRIDE_KEYS = (BUILTIN_OVERRIDE_KEY, APPEND_OVERRIDE_KEY, BASE_VERSION_KEY)
#: Pre-v2 override keys, still understood on read and folded away on save/migration.
LEGACY_PHASE_KEYS = ("zerochat", "onebot", "default", "cloud_emoji")
#: Version assigned to overrides that predate versioning.
LEGACY_BASE_VERSION = 1

#: Placeholder key inside ``chat.tool_rules`` that carries the emoji-tool branch.
EMOJI_TOOL_RULE_PLACEHOLDER = "EMOJI_TOOL_RULE"

PROMPT_REGISTRY: Dict[str, PromptDefinition] = load_all()

CHAT_INSTRUCTION_PRIORITY_ID = "chat.instruction_priority"
CHAT_FORMAT_PROTOCOL_ID = "chat.format_protocol"
CHAT_STATS_BLOCK_ID = "chat.stats_block"
CHAT_SOUND_DEDUP_ID = "chat.sound_dedup"
CHAT_TOOL_RULES_ID = "chat.tool_rules"
CHAT_TOOL_POLICY_CONSERVATIVE_ID = "chat.tool_policy_conservative"
CHAT_STATS_LAYOUT_GROK_ID = "chat.stats_layout_grok"
CHAT_STATS_LAYOUT_DEFAULT_ID = "chat.stats_layout_default"
CHAT_STATS_BULLET_GROK_ID = "chat.stats_bullet_grok"
CHAT_STATS_BULLET_DEFAULT_ID = "chat.stats_bullet_default"
CHAT_EMOJI_RULE_DEFAULT_ID = "chat.emoji_rule_default"
CHAT_EMOJI_RULE_CLOUD_ID = "chat.emoji_rule_cloud_emoji"
CHAT_USER_MESSAGE_JSON_HINT_ID = "chat.user_message_json_hint"
CHAT_REPLY_FORMAT_HINT_ID = "chat.reply_format_hint"
CHAT_NO_REPLY_ID = "chat.no_reply"
ONEBOT_SYSTEM_DIRECTIVE_ID = "onebot.system_directive"
SUMMARY_CONTEXT_EVENTS_ID = "summary.context_events"
SUMMARY_CORE_MEMORY_ID = "summary.core_memory"

_REQUIRED_IDS = (
    CHAT_INSTRUCTION_PRIORITY_ID, CHAT_FORMAT_PROTOCOL_ID, CHAT_STATS_BLOCK_ID,
    CHAT_SOUND_DEDUP_ID, CHAT_TOOL_RULES_ID, CHAT_TOOL_POLICY_CONSERVATIVE_ID,
    CHAT_STATS_LAYOUT_GROK_ID, CHAT_STATS_LAYOUT_DEFAULT_ID, CHAT_STATS_BULLET_GROK_ID,
    CHAT_STATS_BULLET_DEFAULT_ID, CHAT_EMOJI_RULE_DEFAULT_ID, CHAT_EMOJI_RULE_CLOUD_ID,
    CHAT_USER_MESSAGE_JSON_HINT_ID, CHAT_REPLY_FORMAT_HINT_ID, CHAT_NO_REPLY_ID,
    ONEBOT_SYSTEM_DIRECTIVE_ID, SUMMARY_CONTEXT_EVENTS_ID, SUMMARY_CORE_MEMORY_ID,
)
_missing_ids = [prompt_id for prompt_id in _REQUIRED_IDS if prompt_id not in PROMPT_REGISTRY]
if _missing_ids:
    raise RuntimeError(f"server/prompts 缺少必需的提示词: {', '.join(_missing_ids)}")

#: Consumer groups that may resolve a given prompt id.
APPLIES_TO_HINTS = {
    "chat": "chat",
    "summary": "summary",
}


def registry_snapshot(applies_to: Optional[str] = None) -> Dict[str, Dict[str, Any]]:
    """Return the editable prompt registry (builtin text included) for the frontend.

    Non-editable prompts (the tool-calling rules, instruction hierarchy, …) are kept out
    entirely so the frontend cannot offer an override that the resolver would ignore.
    """
    result: Dict[str, Dict[str, Any]] = {}
    for prompt_id, definition in PROMPT_REGISTRY.items():
        if not definition.editable:
            continue
        if applies_to and applies_to not in definition.applies_to:
            continue
        result[prompt_id] = {
            "title": definition.title,
            "group": definition.group,
            "origin": definition.origin,
            "applies_to": list(definition.applies_to),
            "builtin": definition.builtin,
            "version": definition.version,
        }
    return result


def reserved_keys_payload() -> Dict[str, Any]:
    """Reserved override keys advertised to the prompt editor UI."""
    return {
        "builtin": BUILTIN_OVERRIDE_KEY,
        "append": APPEND_OVERRIDE_KEY,
        "base_version": BASE_VERSION_KEY,
        "phases": list(ORIGIN_PHASES),
        "variants": list(VARIANT_KEYS),
    }


# ---------------------------------------------------------------------------
# Override normalisation
# ---------------------------------------------------------------------------

def _text_or_none(value: Any) -> Optional[str]:
    if isinstance(value, str) and value.strip():
        return value
    return None


def _replacement_text(
    definition: PromptDefinition, block: Any, variant: str = "default",
) -> Tuple[Optional[str], bool]:
    """Return ``(replacement text, came_from_legacy_phase_key)`` for one override block."""
    if not isinstance(block, dict):
        return None, False
    explicit = _text_or_none(block.get(BUILTIN_OVERRIDE_KEY))
    if explicit is not None:
        return explicit, False
    for key in _phase_keys(definition, variant):
        legacy = _text_or_none(block.get(key))
        if legacy is not None:
            return legacy, True
    return None, False


def _append_text(block: Any) -> Optional[str]:
    if not isinstance(block, dict):
        return None
    text = _text_or_none(block.get(APPEND_OVERRIDE_KEY))
    return text.strip("\n") if text is not None else None


def _parse_base_version(value: Any) -> Optional[int]:
    try:
        number = int(str(value).strip())
    except (TypeError, ValueError):
        return None
    return number if number >= 1 else None


def _normalize_block(
    definition: PromptDefinition, raw: Any, previous: Any = None,
) -> Dict[str, str]:
    """Fold a raw override block into ``{__builtin__, __append__, __base_version__}``."""
    if not isinstance(raw, dict):
        return {}
    cleaned: Dict[str, str] = {}
    replacement, from_legacy = _replacement_text(definition, raw)
    has_legacy = any(_text_or_none(raw.get(key)) is not None for key in LEGACY_PHASE_KEYS)
    if replacement is not None:
        cleaned[BUILTIN_OVERRIDE_KEY] = replacement[:MAX_PROMPT_OVERRIDE_CHARS]
        base = _parse_base_version(raw.get(BASE_VERSION_KEY))
        if base is None:
            if from_legacy or has_legacy:
                base = LEGACY_BASE_VERSION
            else:
                # A client that dropped the stamp: keep the stored one while the text is
                # unchanged, otherwise the text was (re)written against today's builtin.
                prev_text, _ = _replacement_text(definition, previous)
                prev_base = (
                    _parse_base_version(previous.get(BASE_VERSION_KEY))
                    if isinstance(previous, dict) else None
                )
                if prev_text == replacement and prev_base is not None:
                    base = prev_base
                else:
                    base = definition.version
        cleaned[BASE_VERSION_KEY] = str(base)
    appended = _append_text(raw)
    if appended is not None:
        cleaned[APPEND_OVERRIDE_KEY] = appended[:MAX_PROMPT_OVERRIDE_CHARS]
    return cleaned


def sanitize_overrides(raw: Any, previous: Any = None) -> Dict[str, Dict[str, str]]:
    """Whitelist editable prompt ids and keep only reserved-key override maps.

    ``previous`` is the currently stored mapping; it lets the server keep a replacement's
    ``__base_version__`` when a client round-trips the text without the stamp.
    """
    if not isinstance(raw, dict):
        return {}
    previous_map = previous if isinstance(previous, dict) else {}
    cleaned: Dict[str, Dict[str, str]] = {}
    for prompt_id, value in raw.items():
        key = str(prompt_id or "").strip()
        definition = PROMPT_REGISTRY.get(key)
        if definition is None:
            logger.warning("忽略未知的提示词覆盖项: %s", key)
            continue
        if not definition.editable:
            logger.warning("忽略不可编辑的提示词覆盖项: %s", key)
            continue
        block = _normalize_block(definition, value, previous_map.get(key))
        if block:
            cleaned[key] = block
    return cleaned


def sanitize_model_overrides(
    raw: Any, previous: Any = None,
) -> Dict[str, Dict[str, Dict[str, str]]]:
    """Whitelist model-profile prompt overrides keyed by ``api_url|model``."""
    if not isinstance(raw, dict):
        return {}
    previous_map = previous if isinstance(previous, dict) else {}
    cleaned: Dict[str, Dict[str, Dict[str, str]]] = {}
    for target, value in raw.items():
        target_key = str(target or "").strip().lower()
        if not target_key or "|" not in target_key:
            continue
        block = sanitize_overrides(value, previous_map.get(target_key))
        if block:
            cleaned[target_key] = block
    return cleaned


def migrate_stored_overrides() -> bool:
    """Fold legacy override shapes in ``settings.json`` into the v2 reserved-key shape.

    Idempotent. The first time anything changes, the original file is copied to
    ``settings.json.bak-prompts`` (never overwritten). Returns ``True`` when settings
    were rewritten.
    """
    try:
        settings = settings_service.load_settings()
        stored_global = settings.get("prompt_overrides") or {}
        stored_models = settings.get("model_prompt_overrides") or {}
        cleaned_global = sanitize_overrides(stored_global)
        cleaned_models = sanitize_model_overrides(stored_models)
        if cleaned_global == stored_global and cleaned_models == stored_models:
            return False
        backup = settings_service.get_settings_file().with_name("settings.json.bak-prompts")
        if not backup.exists():
            shutil.copyfile(settings_service.get_settings_file(), backup)
        saved = settings_service.save_settings(
            {"prompt_overrides": cleaned_global, "model_prompt_overrides": cleaned_models}
        )
        if saved:
            logger.info("提示词覆盖已迁移到 v2 结构")
        return bool(saved)
    except Exception:  # noqa: BLE001 - never block startup on a settings problem
        logger.exception("提示词覆盖迁移失败，保留原设置")
        return False


# ---------------------------------------------------------------------------
# Resolution
# ---------------------------------------------------------------------------

def _profile_block_for(
    definitions: Dict[str, Any],
    api_url: Any,
    model: Any,
) -> Dict[str, Any]:
    if not isinstance(definitions, dict):
        return {}
    api_url_text = str(api_url or "").strip().lower()
    model_text = str(model or "").strip().lower()
    if not api_url_text or not model_text:
        return {}
    block = definitions.get(f"{api_url_text}|{model_text}")
    if isinstance(block, dict):
        return block
    return {}


def model_target_key(api_url: Any, model: Any) -> str:
    api_url_text = str(api_url or "").strip().lower()
    model_text = str(model or "").strip().lower()
    if not api_url_text or not model_text:
        return ""
    return f"{api_url_text}|{model_text}"


def _render(text: str, render: Dict[str, str]) -> str:
    if not text or "{" not in text:
        return text
    for key, value in render.items():
        text = text.replace("{" + key + "}", value)
    return text


def _phase_keys(definition: PromptDefinition, variant: str) -> List[str]:
    keys: List[str] = []
    if definition.origin in ORIGIN_PHASES:
        keys.append(definition.origin)
    if variant in VARIANT_KEYS:
        keys.append(variant)
    keys.append("default")
    return keys


def resolve(
    prompt_id: str,
    *,
    settings: Optional[Dict[str, Any]] = None,
    overrides: Optional[Dict[str, Any]] = None,
    model_overrides: Optional[Dict[str, Any]] = None,
    api_url: Optional[str] = None,
    model: Optional[str] = None,
    role_data: Optional[Dict[str, Any]] = None,
    variant: str = "default",
    render: Optional[Dict[str, str]] = None,
) -> str:
    """Resolve one prompt id following builtin → global → profile → role precedence.

    Each override layer may replace the template (``__builtin__``) and/or append text
    (``__append__``); layers are applied in order. ``variant`` selects the code-owned
    replacement for placeholders that depend on the model/plugin (today only
    ``EMOJI_TOOL_RULE``). ``render`` carries runtime protocol tokens such as
    ``NO_REPLY_DIRECTIVE``. Prompts flagged ``editable=False`` always return their
    builtin text.
    """
    definition = PROMPT_REGISTRY.get(prompt_id)
    if definition is None:
        logger.warning("未知的提示词 id: %s", prompt_id)
        return ""

    text = definition.builtin

    # Non-editable prompts (tool-calling rules, instruction hierarchy) are code-owned and
    # ignore all overrides; skip the settings lookup entirely for them.
    if definition.editable:
        data = settings if settings is not None else settings_service.load_settings()
        global_overrides = (
            overrides if overrides is not None else (data.get("prompt_overrides") or {})
        )
        profile_overrides = (
            model_overrides if model_overrides is not None
            else (data.get("model_prompt_overrides") or {})
        )
        blocks: List[Any] = []
        if isinstance(global_overrides, dict):
            blocks.append(global_overrides.get(prompt_id))
        profile_block = _profile_block_for(profile_overrides, api_url, model)
        if isinstance(profile_block, dict):
            blocks.append(profile_block.get(prompt_id))
        if role_data:
            metadata = role_data.get("metadata") or {}
            role_block = metadata.get("prompt_overrides") if isinstance(metadata, dict) else None
            if isinstance(role_block, dict):
                blocks.append(role_block.get(prompt_id))
        for block in blocks:
            replacement, _ = _replacement_text(definition, block, variant)
            if replacement is not None:
                text = replacement
            appended = _append_text(block)
            if appended is not None:
                text = text.rstrip("\n") + "\n\n" + appended

    variables = {
        "NO_REPLY_DIRECTIVE": "",
        "STATS_LAYOUT_RULE": PROMPT_REGISTRY[CHAT_STATS_LAYOUT_DEFAULT_ID].builtin,
        "MAIN_QQ_HINT": "",
        "TOOL_POLICY_CONSERVATIVE": "",
        # 表情分支由模型/插件决定（见 ai_service._prompt_variant），
        # 这里给出默认分支，保证单独 resolve 时也不会漏出占位符。
        EMOJI_TOOL_RULE_PLACEHOLDER: PROMPT_REGISTRY[
            CHAT_EMOJI_RULE_CLOUD_ID if variant == "cloud_emoji" else CHAT_EMOJI_RULE_DEFAULT_ID
        ].builtin,
    }
    if render:
        variables.update({key: str(value) for key, value in render.items()})
    return _render(text, variables)


def resolve_many(
    prompt_ids: Sequence[str],
    **kwargs: Any,
) -> Dict[str, str]:
    """Resolve several prompt ids with one settings lookup."""
    return {prompt_id: resolve(prompt_id, **kwargs) for prompt_id in prompt_ids}


def reset_override_entry(prompt_id: str, *, phase: Optional[str] = None) -> bool:
    """Remove one override (or a single key of it) from settings.json."""
    if prompt_id not in PROMPT_REGISTRY:
        return False
    settings = settings_service.load_settings()
    current = settings.get("prompt_overrides")
    if not isinstance(current, dict) or prompt_id not in current:
        return False
    block = current.get(prompt_id)
    if phase and isinstance(block, dict) and phase in block:
        block = {key: value for key, value in block.items() if key != phase}
    else:
        block = None
    updated = dict(current)
    if block:
        updated[prompt_id] = block
    else:
        updated.pop(prompt_id, None)
    return settings_service.save_settings({"prompt_overrides": updated})
