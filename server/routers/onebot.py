"""OneBot V11 接入层：HTTP POST 事件与反向 WebSocket。

本模块只负责传输与鉴权；解析、放行、指令、聚合、AI 调用、出站与 App 同步
都在 ``services/onebot/`` 中。URL 与鉴权方式保持不变：

* ``POST /api/onebot/{role_id}/event``
* ``WS   /onebot/ws/{role_id}``（main.py 注册）
"""
import asyncio
import json
import logging
from typing import Any, Dict, Optional

from fastapi import APIRouter, HTTPException, Request, WebSocket, WebSocketDisconnect

from services.onebot import auth
from services.onebot import config as cfg_mod
from services.onebot.models import OneBotEvent
from services.onebot.paths import role_dir as _role_dir  # noqa: F401  (兼容旧导入名)
from services.onebot.pipeline import pipeline
from services.onebot.sender import build_server_url
from transport.onebot_ws import manager as ws_manager

logger = logging.getLogger(__name__)

router = APIRouter()

__all__ = ["router", "onebot_ws_endpoint", "OneBotEvent", "handle_onebot_event"]


async def _reject_ws(websocket: WebSocket, code: int, reason: str) -> None:
    await websocket.accept()
    await websocket.close(code=code, reason=reason)


async def _handle_ws_frame(conn, role_id: str, config: Dict[str, Any], data: Dict[str, Any], server_url: str) -> None:
    try:
        event = OneBotEvent(**data)
    except Exception:  # noqa: BLE001 - 非法帧直接忽略
        return
    await pipeline.ingest(role_id, config, event, conn, server_url=server_url)


async def onebot_ws_endpoint(websocket: WebSocket, role_id: str):
    """反向 WebSocket 端点：NapCat 连接到此。"""
    from main import CONFIG

    if not CONFIG.get("onebot_enabled", True):
        logger.warning("OneBot WS 拒绝: 全局开关关闭")
        await _reject_ws(websocket, 1008, "OneBot interface disabled")
        return

    try:
        profile = cfg_mod.load_role_profile(role_id)
    except cfg_mod.InvalidRoleId:
        await _reject_ws(websocket, 1008, "Invalid role_id")
        return
    except cfg_mod.ProfileUnreadable:
        await _reject_ws(websocket, 1011, "读取角色配置失败")
        return
    if profile is None:
        logger.warning("OneBot WS 拒绝: 角色 %s 不存在", role_id)
        await _reject_ws(websocket, 1008, f"角色 {role_id} 不存在")
        return

    config = profile.get("onebot_config") or {}
    if not config.get("enabled", False):
        logger.warning("OneBot WS 拒绝: 角色 %s 未启用 OneBot", role_id)
        await _reject_ws(websocket, 1008, f"角色 {role_id} 未启用 OneBot 接口")
        return

    expected_secret = auth.configured_secret(config)
    if not expected_secret:
        logger.warning("OneBot WS 拒绝：角色 %s 已启用 OneBot 但未配置 secret", role_id)
        await _reject_ws(websocket, 1008, "OneBot secret not configured")
        return

    first_data: Optional[Dict] = None
    auth_ok = auth.ws_header_or_query_ok(websocket.headers, websocket.query_params, expected_secret)
    if not auth_ok:  # 首条消息 token 字段
        try:
            first_text = await asyncio.wait_for(websocket.receive_text(), timeout=10.0)
            first_data = json.loads(first_text)
            auth_ok = auth.secrets_match(auth.body_token(first_data), expected_secret)
        except Exception:  # noqa: BLE001
            auth_ok = False
    if not auth_ok:
        logger.warning("OneBot WS 鉴权失败: role=%s", role_id)
        await _reject_ws(websocket, 1008, "Invalid token")
        return

    await websocket.accept()
    self_id = None
    try:
        self_id = int(config.get("self_id") or config.get("selfId") or 0)
    except (TypeError, ValueError):
        self_id = 0
    conn = await ws_manager.connect(websocket, role_id, self_id=self_id)
    server_url = build_server_url(websocket)
    conn.server_url = config.get("server_url") or server_url
    logger.info("OneBot WS 连接建立: role=%s, self_id=%s, server_url=%s", role_id, self_id, server_url)

    try:
        if first_data is not None:
            try:
                await _handle_ws_frame(conn, role_id, config, first_data, server_url)
            except Exception as exc:  # noqa: BLE001
                logger.error("OneBot WS 首条消息处理失败: %s", exc)

        while True:
            text = await websocket.receive_text()
            try:
                data = json.loads(text)
            except json.JSONDecodeError:
                continue
            if not isinstance(data, dict):
                continue

            # 处理 echo 响应（NapCat 对 API 调用的回复）
            if "echo" in data and "retcode" in data:
                conn.resolve_echo(data["echo"], data)
                continue

            # 每条事件重新加载配置（支持热更新）
            fresh = cfg_mod.load_config(role_id)
            if fresh:
                config = fresh
                conn.server_url = config.get("server_url") or server_url
            try:
                await _handle_ws_frame(conn, role_id, config, data, server_url)
            except Exception as exc:  # noqa: BLE001 - 单个事件失败不应断开连接
                logger.error("OneBot 事件处理失败: role=%s error=%s", role_id, exc, exc_info=True)
    except WebSocketDisconnect:
        pass
    except Exception as exc:  # noqa: BLE001
        logger.error("OneBot WS 异常: role=%s, error=%s", role_id, exc)
    finally:
        ws_manager.disconnect(role_id, conn)


@router.post("/onebot/{role_id}/event")
async def handle_onebot_event(role_id: str, request: Request):
    """接收 OneBot V11 HTTP POST 事件（备用接口，同步返回回复文本）。"""
    from main import CONFIG

    if not CONFIG.get("onebot_enabled", True):
        raise HTTPException(status_code=403, detail="OneBot interface disabled")

    try:
        profile = cfg_mod.load_role_profile(role_id)
    except cfg_mod.InvalidRoleId as exc:
        raise HTTPException(status_code=400, detail="Invalid role_id") from exc
    except cfg_mod.ProfileUnreadable as exc:
        raise HTTPException(status_code=500, detail="读取角色配置失败") from exc
    if profile is None:
        raise HTTPException(status_code=404, detail=f"角色 {role_id} 不存在")

    config = profile.get("onebot_config") or {}
    if not config.get("enabled", False):
        raise HTTPException(status_code=403, detail=f"角色 {role_id} 未启用 OneBot 接口")

    try:
        raw_body = await request.body()
        body = json.loads(raw_body.decode("utf-8")) if raw_body else {}
    except Exception:
        raise HTTPException(status_code=400, detail="Invalid JSON body")

    expected_secret = auth.configured_secret(config)
    if not expected_secret:
        logger.warning("OneBot HTTP 拒绝：角色 %s 已启用 OneBot 但未配置 secret", role_id)
        raise HTTPException(status_code=401, detail="OneBot secret not configured")
    if not auth.http_ok(raw_body, request.headers, request.query_params, body, expected_secret):
        raise HTTPException(status_code=401, detail="Invalid OneBot secret")

    if not isinstance(body, dict):
        return {"status": "ignored", "reason": "not a message event or empty content"}
    event = OneBotEvent(**body)

    conn = ws_manager.get_connection(role_id)
    try:
        result = await pipeline.ingest(
            role_id, config, event, conn,
            server_url=str(request.base_url).rstrip("/"), sync=True,
        )
    except Exception as exc:  # noqa: BLE001
        logger.error("OneBot AI 处理失败: %s", exc, exc_info=True)
        raise HTTPException(status_code=500, detail="内部处理错误")

    if result.status == "ignored":
        return {"status": "ignored", "reason": result.reason}
    return {"status": "ok", "reply": result.reply, "success": True}
