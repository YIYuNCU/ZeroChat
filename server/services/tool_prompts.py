"""Backward-compatible access to the built-in tool prompts.

The canonical prompt text now lives in :mod:`services.prompt_config_service` and is
configurable from the frontend (globally or per model profile). This module only maps the
legacy tool-role ids onto registry entries so older call sites keep working.
"""
from __future__ import annotations

from typing import Dict

from services import prompt_config_service

_WORKER_PROMPT_IDS: Dict[str, str] = {
    "1000000000000": prompt_config_service.SUMMARY_CORE_MEMORY_ID,
    "1000000000002": prompt_config_service.SUMMARY_CONTEXT_EVENTS_ID,
}

#: Legacy mapping of tool role id → default prompt text.
TOOL_ROLE_PROMPTS = {
    worker_id: prompt_config_service.PROMPT_REGISTRY[prompt_id].builtin
    for worker_id, prompt_id in _WORKER_PROMPT_IDS.items()
}


def prompt_id_for_worker(worker_id: str) -> str:
    """Return the registry prompt id backing a legacy tool role, or ``""``."""
    return _WORKER_PROMPT_IDS.get(str(worker_id), "")


def get_tool_prompt(role_id: str, fallback: str = "") -> str:
    """Return the effective prompt for a legacy tool role, or the fallback."""
    prompt_id = prompt_id_for_worker(role_id)
    if not prompt_id:
        return fallback
    return prompt_config_service.resolve(prompt_id)
