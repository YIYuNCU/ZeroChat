"""Client-visible settings groups. Security/hosting configuration is never cached."""
GROUPS = {
    "chat": {"ai_api_url", "ai_api_key", "ai_model", "ai_api_format", "ai_timeout_seconds", "ai_reasoning_effort", "ai_stream"},
    "thinking": {"thinking_enabled", "ai_thinking_budget", "model_thinking_settings"},
    "intent": {"intent_enabled", "intent_api_url", "intent_api_key", "intent_model", "intent_api_format"},
    "vision": {"vision_enabled", "vision_api_url", "vision_api_key", "vision_model", "vision_mode", "vision_api_format"},
    "embedding": {"embedding_enabled", "embedding_api_url", "embedding_api_key", "embedding_model"},
    "context_summary": {"context_summary_config"},
    "core_summary": {"core_memory_summary_config"},
    "prompts": {"prompt_overrides", "model_prompt_overrides"},
    "quiet_rules": {"quiet_rules"},
    "profile": {"user_nickname", "user_avatar_url", "user_avatar_hash"},
}


def select_settings(settings, groups=None):
    selected = list(GROUPS) if groups is None else groups
    if not isinstance(selected, list) or any(group not in GROUPS for group in selected):
        raise ValueError("Unknown settings group")
    keys = set().union(*(GROUPS[group] for group in selected))
    return {key: value for key, value in settings.items() if key in keys}
