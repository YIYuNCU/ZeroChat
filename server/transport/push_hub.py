from datetime import datetime
import asyncio
from typing import Any

from fastapi import WebSocket

from services.security_service import DEFAULT_ENCRYPTION_SECRET, encrypt_payload


_clients: set[WebSocket] = set()
_clients_lock = asyncio.Lock()
_encryption_secret = DEFAULT_ENCRYPTION_SECRET
_logger = None


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
