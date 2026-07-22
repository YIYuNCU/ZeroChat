import asyncio
from datetime import datetime
from typing import Any

from fastapi import WebSocket

from services.security_service import encrypt_payload


_clients: set[WebSocket] = set()
_clients_lock = asyncio.Lock()
_encryption_secret: str | None = None
_logger = None

# Recent push cache for missed-push recovery.
# Covers chat_response (keyed by task_id) plus proactive/task messages
# (keyed by message_id) so clients that were offline/backgrounded can recover
# pushes that arrived while disconnected.
_CHAT_PUSH_CACHE: dict[str, tuple[datetime, dict]] = {}
_CHAT_PUSH_CACHE_TTL = 1800  # seconds — cover longer offline/background windows
_CHAT_PUSH_CACHE_MAX = 500

# Event types whose payload carries a message_id and should be cached for recovery
_MESSAGE_PUSH_EVENTS = ("task_message", "proactive_message")


def configure_push_hub(*, encryption_secret: str | None = None, logger=None):
    global _encryption_secret, _logger
    secret = (encryption_secret or "").strip()
    if secret:
        _encryption_secret = secret
    _logger = logger


async def register_client(websocket: WebSocket):
    async with _clients_lock:
        _clients.add(websocket)


async def unregister_client(websocket: WebSocket):
    async with _clients_lock:
        if websocket in _clients:
            _clients.remove(websocket)


def _prune_chat_push_cache():
    now = datetime.now()
    expired = [
        tid for tid, (ts, _) in _CHAT_PUSH_CACHE.items()
        if (now - ts).total_seconds() > _CHAT_PUSH_CACHE_TTL
    ]
    for tid in expired:
        _CHAT_PUSH_CACHE.pop(tid, None)

    if len(_CHAT_PUSH_CACHE) > _CHAT_PUSH_CACHE_MAX:
        sorted_items = sorted(
            _CHAT_PUSH_CACHE.items(),
            key=lambda item: item[1][0],
        )
        overflow = len(_CHAT_PUSH_CACHE) - _CHAT_PUSH_CACHE_MAX
        for tid, _ in sorted_items[:overflow]:
            _CHAT_PUSH_CACHE.pop(tid, None)


async def publish_server_push(event_type: str, payload: dict[str, Any] | None = None):
    if _encryption_secret is None:
        raise RuntimeError("push hub encryption is not configured")

    data = {
        "event_type": event_type,
        "payload": payload or {},
        "timestamp": datetime.now().isoformat(),
    }
    encrypted = encrypt_payload(data, _encryption_secret)

    frame = {
        "event": "server_push",
        "type": event_type,
        "data": encrypted,
    }

    # Cache pushes for missed-push recovery.
    cache_key = None
    if event_type == "chat_response" and payload and payload.get("task_id"):
        cache_key = str(payload["task_id"])
    elif event_type in _MESSAGE_PUSH_EVENTS and payload and payload.get("message_id"):
        cache_key = str(payload["message_id"])
    if cache_key:
        _prune_chat_push_cache()
        _CHAT_PUSH_CACHE[cache_key] = (datetime.now(), data)

    async with _clients_lock:
        clients = list(_clients)

    stale: list[WebSocket] = []
    for ws in clients:
        try:
            await ws.send_json(frame)
        except Exception:
            stale.append(ws)

    if stale:
        async with _clients_lock:
            for ws in stale:
                _clients.discard(ws)

    if _logger is not None and clients:
        try:
            _logger.info(f"WS push published: {event_type}, clients={len(clients)}")
        except Exception:
            pass


def get_missed_chat_pushes(task_ids: list[str]) -> list[dict]:
    """Return cached chat_response pushes for the given task_ids.

    Used by clients to recover pushes that arrived while they were disconnected.
    """
    if not task_ids:
        return []

    _prune_chat_push_cache()
    now = datetime.now()
    recovered: list[dict] = []
    for tid in task_ids:
        entry = _CHAT_PUSH_CACHE.get(tid)
        if entry is None:
            continue
        ts, push_data = entry
        # Double-check TTL
        if (now - ts).total_seconds() > _CHAT_PUSH_CACHE_TTL:
            _CHAT_PUSH_CACHE.pop(tid, None)
            continue
        recovered.append(
            {
                "task_id": tid,
                "payload": push_data.get("payload", {}),
            }
        )
    return recovered


def get_missed_message_pushes(message_ids: list[str]) -> list[dict]:
    """Return cached proactive/task message pushes for the given message_ids.

    Mirror of get_missed_chat_pushes but for task_message/proactive_message
    events, which are cached keyed by message_id (see _MESSAGE_PUSH_EVENTS).
    Lets clients recover proactive/task pushes that arrived while disconnected.
    """
    if not message_ids:
        return []

    _prune_chat_push_cache()
    now = datetime.now()
    recovered: list[dict] = []
    for mid in message_ids:
        entry = _CHAT_PUSH_CACHE.get(mid)
        if entry is None:
            continue
        ts, push_data = entry
        if (now - ts).total_seconds() > _CHAT_PUSH_CACHE_TTL:
            _CHAT_PUSH_CACHE.pop(mid, None)
            continue
        recovered.append(
            {
                "message_id": mid,
                "event_type": push_data.get("event_type"),
                "payload": push_data.get("payload", {}),
            }
        )
    return recovered
