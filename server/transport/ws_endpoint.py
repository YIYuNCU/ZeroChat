import asyncio
import json
from datetime import datetime

from fastapi import WebSocket, WebSocketDisconnect

from services.security_service import (
    DEFAULT_AUTH_TOKEN,
    DEFAULT_ENCRYPTION_SECRET,
    decrypt_payload,
    encrypt_payload,
)
from transport.push_hub import register_client, unregister_client
from transport.ws_dispatcher import handle_ws_action


_DEDUPE_TTL_SECONDS = 180
_DEDUPE_MAX_ENTRIES = 600
_REQUEST_RESPONSE_CACHE: dict[str, tuple[datetime, dict]] = {}
_INFLIGHT_REQUESTS: dict[str, asyncio.Future] = {}
_REQUEST_CACHE_LOCK = asyncio.Lock()


def _prune_response_cache(cache: dict[str, tuple[datetime, dict]], now: datetime):
    if not cache:
        return

    expired_keys = [
        req_id
        for req_id, (created_at, _) in cache.items()
        if (now - created_at).total_seconds() > _DEDUPE_TTL_SECONDS
    ]
    for req_id in expired_keys:
        cache.pop(req_id, None)

    if len(cache) <= _DEDUPE_MAX_ENTRIES:
        return

    sorted_items = sorted(
        cache.items(),
        key=lambda item: item[1][0],
    )
    overflow = len(cache) - _DEDUPE_MAX_ENTRIES
    for req_id, _ in sorted_items[:overflow]:
        cache.pop(req_id, None)


def _is_closed_send_error(exc: Exception) -> bool:
    text = str(exc).lower()
    return "cannot call \"send\" once a close message has been sent" in text


def create_secure_websocket_endpoint(config: dict, logger):
    async def secure_websocket_endpoint(websocket: WebSocket):
        await websocket.accept()

        auth_token = config.get("auth_token") or DEFAULT_AUTH_TOKEN
        encryption_secret = config.get("encryption_secret") or DEFAULT_ENCRYPTION_SECRET

        token_from_header = websocket.headers.get("X-Auth-Token", "")
        incoming_token = token_from_header
        if incoming_token != auth_token:
            await websocket.close(code=1008, reason="Unauthorized")
            return

        await register_client(websocket)

        async def _send_json_or_stop(payload: dict) -> bool:
            try:
                await websocket.send_json(payload)
                return True
            except (WebSocketDisconnect, RuntimeError) as exc:
                if isinstance(exc, RuntimeError) and not _is_closed_send_error(exc):
                    raise
                logger.info("Secure WebSocket send skipped: connection already closed")
                return False

        async def _process_message(request_id: str, message_obj: dict) -> dict:
            event = str(message_obj.get("event") or "")

            if event == "heartbeat":
                return {
                    "event": "heartbeat_ack",
                    "timestamp": datetime.now().isoformat(),
                }

            action = str(message_obj.get("action") or "").strip()
            encrypted_payload = message_obj.get("payload")
            if not action or encrypted_payload is None:
                raise ValueError("action or payload missing")

            payload = decrypt_payload(encrypted_payload, encryption_secret)
            if not isinstance(payload, dict):
                raise ValueError("invalid decrypted payload")

            result = await handle_ws_action(action, payload, websocket, config)
            if result is None:
                result = {}
            if not isinstance(result, dict):
                result = {"result": result}

            encrypted_result = encrypt_payload(result, encryption_secret)
            return {
                "request_id": request_id,
                "ok": True,
                "data": encrypted_result,
            }

        try:
            while True:
                raw = await websocket.receive_text()
                received_at = datetime.now()
                request_id = ""
                action = "-"
                try:
                    message_obj = json.loads(raw)
                    if not isinstance(message_obj, dict):
                        raise ValueError("invalid websocket frame")

                    request_id = str(message_obj.get("request_id") or "")
                    action = str(message_obj.get("action") or "-").strip() or "-"

                    if not request_id:
                        response = await _process_message(request_id, message_obj)
                        sent = await _send_json_or_stop(response)
                        if not sent:
                            return
                        continue

                    # 1) completed-response cache hit
                    async with _REQUEST_CACHE_LOCK:
                        now = datetime.now()
                        _prune_response_cache(_REQUEST_RESPONSE_CACHE, now)
                        cached = _REQUEST_RESPONSE_CACHE.get(request_id)
                    if cached is not None:
                        _, cached_response = cached
                        sent = await _send_json_or_stop(cached_response)
                        if not sent:
                            return
                        continue

                    # 2) in-flight dedupe: followers await leader result
                    is_leader = False
                    inflight_future = None
                    async with _REQUEST_CACHE_LOCK:
                        inflight_future = _INFLIGHT_REQUESTS.get(request_id)
                        if inflight_future is None:
                            inflight_future = asyncio.get_running_loop().create_future()
                            _INFLIGHT_REQUESTS[request_id] = inflight_future
                            is_leader = True

                    if not is_leader:
                        response = await asyncio.shield(inflight_future)
                        sent = await _send_json_or_stop(response)
                        if not sent:
                            return
                        continue

                    leader_response = None
                    try:
                        leader_response = await _process_message(request_id, message_obj)
                    except Exception as e:
                        if _is_closed_send_error(e):
                            raise
                        logger.warning(f"WebSocket request error: {e}")
                        encrypted_error = encrypt_payload(
                            {
                                "error": "request_failed",
                            },
                            encryption_secret,
                        )
                        leader_response = {
                            "request_id": request_id,
                            "ok": False,
                            "data": encrypted_error,
                        }
                    finally:
                        async with _REQUEST_CACHE_LOCK:
                            current = _INFLIGHT_REQUESTS.pop(request_id, None)
                            if current is not None and not current.done() and leader_response is not None:
                                current.set_result(leader_response)

                    response = leader_response
                    sent = await _send_json_or_stop(response)
                    if not sent:
                        return

                    if response.get("event") != "heartbeat_ack":
                        async with _REQUEST_CACHE_LOCK:
                            _REQUEST_RESPONSE_CACHE[request_id] = (datetime.now(), response)
                except Exception as e:
                    if _is_closed_send_error(e):
                        logger.info("WebSocket request aborted: connection already closed")
                        return
                    logger.warning(f"WebSocket request error: {e}")
                    encrypted_error = encrypt_payload(
                        {
                            "error": "request_failed",
                        },
                        encryption_secret,
                    )
                    error_response = {
                        "request_id": request_id,
                        "ok": False,
                        "data": encrypted_error,
                    }
                    sent = await _send_json_or_stop(error_response)
                    if not sent:
                        return

                    if request_id:
                        async with _REQUEST_CACHE_LOCK:
                            _REQUEST_RESPONSE_CACHE[request_id] = (datetime.now(), error_response)

                    await asyncio.sleep(0)
        except WebSocketDisconnect:
            logger.info("Secure WebSocket disconnected")
        except Exception as e:
            if _is_closed_send_error(e):
                logger.info("Secure WebSocket closed during runtime")
                return
            logger.warning(f"Secure WebSocket runtime error: {e}")
        finally:
            await unregister_client(websocket)

    return secure_websocket_endpoint
