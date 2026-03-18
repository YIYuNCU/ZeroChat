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

        try:
            while True:
                raw = await websocket.receive_text()
                request_id = ""
                try:
                    message_obj = json.loads(raw)
                    if not isinstance(message_obj, dict):
                        raise ValueError("invalid websocket frame")

                    request_id = str(message_obj.get("request_id") or "")
                    event = str(message_obj.get("event") or "")

                    if event == "heartbeat":
                        await websocket.send_json(
                            {
                                "event": "heartbeat_ack",
                                "timestamp": datetime.now().isoformat(),
                            }
                        )
                        continue

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
                    await websocket.send_json(
                        {
                            "request_id": request_id,
                            "ok": True,
                            "data": encrypted_result,
                        }
                    )
                except Exception as e:
                    logger.warning(f"WebSocket request error: {e}")
                    encrypted_error = encrypt_payload(
                        {
                            "error": "request_failed",
                        },
                        encryption_secret,
                    )
                    await websocket.send_json(
                        {
                            "request_id": request_id,
                            "ok": False,
                            "data": encrypted_error,
                        }
                    )
        except WebSocketDisconnect:
            logger.info("Secure WebSocket disconnected")
        except Exception as e:
            logger.warning(f"Secure WebSocket runtime error: {e}")
        finally:
            await unregister_client(websocket)

    return secure_websocket_endpoint
