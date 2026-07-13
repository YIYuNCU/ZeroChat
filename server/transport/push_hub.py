import asyncio
from datetime import datetime
from typing import Any

from fastapi import WebSocket

from services.security_service import DEFAULT_ENCRYPTION_SECRET, encrypt_payload


_clients: set[WebSocket] = set()
_clients_lock = asyncio.Lock()
_encryption_secret = DEFAULT_ENCRYPTION_SECRET
_logger = None

# Recent chat_response push cache for missed-push recovery
_CHAT_PUSH_CACHE: dict[str, tuple[datetime, dict]] = {}
_CHAT_PUSH_CACHE_TTL = 120  # seconds
_CHAT_PUSH_CACHE_MAX = 100


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

    # Cache chat_response pushes for missed-push recovery
    if event_type == "chat_response" and payload and payload.get("task_id"):
        task_id = payload["task_id"]
        _prune_chat_push_cache()
        _CHAT_PUSH_CACHE[task_id] = (datetime.now(), data)

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
