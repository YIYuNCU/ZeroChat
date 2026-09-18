"""Content-addressed response parts shared by encrypted WS resource reads.

Each response is built from one snapshot. The manifest is authoritative only for
the exact query, so deleting a part never means deleting an unrelated resource.
"""
import hashlib
import json

READ_ACTIONS = frozenset({
    "settings_get", "settings_prompts_get", "settings_summary_get",
    "roles_list", "roles_detail", "roles_memory_get", "vector_memory_list", "usage_stats_get",
    "chat_snapshot", "moments_list", "tasks_list", "user_emojis_list",
    "role_emoji_categories_list", "role_emojis_list", "user_emoji_categories_list",
})


def invalidated_actions(action):
    if action in READ_ACTIONS or action.endswith(("_get", "_hash", "_list")):
        return []
    if action == "settings_update":
        return ["settings_get", "settings_prompts_get", "settings_summary_get"]
    if action.startswith(("short_term_", "vector_memory_")) or action == "roles_memory_update":
        return ["roles_memory_get", "vector_memory_list"]
    if "emoji" in action and action.endswith(("_upload", "_delete", "_create")):
        return ["role_emoji_categories_list", "role_emojis_list", "user_emoji_categories_list", "user_emojis_list"]
    if action.startswith("roles_"):
        return ["roles_list", "roles_detail", "roles_memory_get", "chat_snapshot"]
    return []


def digest(value):
    return hashlib.sha256(json.dumps(value, ensure_ascii=False, sort_keys=True,
                                    separators=(",", ":")).encode()).hexdigest()


def pack_response(action, response, known):
    parts = {}

    def part(path, value):
        key = json.dumps(path, ensure_ascii=False, separators=(",", ":"))
        parts[key] = value
        return {"part": key}

    def split(path, value):
        if isinstance(value, dict) and (not path or path == ["settings"] or path == ["chats"]):
            return {"map": {key: split(path + [key], item) for key, item in value.items()}}
        if isinstance(value, list):
            size = 200 if action in {"chat_snapshot", "roles_memory_get"} else 1
            ids = [str(item.get("id")) for item in value if isinstance(item, dict) and item.get("id") is not None]
            keyed = size == 1 and len(ids) == len(value) and len(set(ids)) == len(ids)
            return {"list": [part(path + [ids[index] if keyed else index // size], value[index:index + size])
                             for index in range(0, len(value), size)]}
        return part(path, value)

    layout = split([], response)
    hashes = {key: digest(value) for key, value in parts.items()}
    root = digest({"layout": layout, "hashes": hashes})
    if known.get("hash") == root:
        return {"_sync": {"version": 1, "hash": root, "not_modified": True}}
    previous = known.get("hashes")
    previous = previous if isinstance(previous, dict) else {}
    return {"_sync": {"version": 1, "hash": root, "hashes": hashes, "layout": layout},
            "parts": {key: value for key, value in parts.items() if previous.get(key) != hashes[key]}}
