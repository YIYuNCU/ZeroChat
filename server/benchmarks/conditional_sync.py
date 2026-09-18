"""Deterministic response-body benchmark; no network or user data required.

Run from server/: python -m benchmarks.conditional_sync
Numbers include manifests but exclude encryption, WebSocket and TLS overhead.
"""
import json

from services.conditional_sync import pack_response


def size(value):
    return len(json.dumps(value, ensure_ascii=False, separators=(",", ":")).encode())


def measure(name, full, optimized):
    before, after = size(full), size(optimized)
    return {"scenario": name, "full_bytes": before, "optimized_bytes": after,
            "reduction_percent": round((1 - after / before) * 100, 2)}


def main():
    settings = {"settings": {"ai_model": "model-a", "prompt_overrides": {"chat": "prompt " * 2000}}}
    first = pack_response("settings_get", settings, {})
    results = [measure("unchanged_settings", settings, pack_response("settings_get", settings, first["_sync"]))]
    settings["settings"]["ai_model"] = "model-b"
    results.append(measure("one_setting_changed", settings, pack_response("settings_get", settings, first["_sync"])))
    chats = {"chats": {"a": [{"id": str(i), "content": "message " * 40} for i in range(400)],
                       "b": [{"id": str(i), "content": "other " * 40} for i in range(400)]}}
    first = pack_response("chat_snapshot", chats, {})
    chats["chats"]["a"].append({"id": "400", "content": "new message"})
    results.append(measure("append_one_message", chats, pack_response("chat_snapshot", chats, first["_sync"])))
    memory = {"core_memory": ["fact one", "fact two"], "short_term": [
        {"id": i, "content": "memory " * 50} for i in range(2000)], "vector_count": 1000}
    results.append(measure("core_memory_only", memory,
                           pack_response("roles_memory_get", {"core_memory": memory["core_memory"], "vector_count": 1000}, {})))
    results.append(measure("first_memory_page", memory, pack_response("roles_memory_get", {
        "short_term": memory["short_term"][-200:], "version": "sample-version", "has_more": True, "next_cursor": 1800}, {})))
    print(json.dumps(results, indent=2))


if __name__ == "__main__":
    main()
