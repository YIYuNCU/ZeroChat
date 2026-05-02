"""
OneBot V11 反向 WebSocket 连接管理器
管理 NapCat 等框架的 WebSocket 连接，支持发送 API 调用并等待响应
"""
import asyncio
import json
import logging
import uuid
from typing import Any, Dict, Optional

from fastapi import WebSocket

logger = logging.getLogger(__name__)


class OneBotConnection:
    """单个 OneBot WebSocket 连接"""

    def __init__(self, websocket: WebSocket, role_id: str, self_id: Optional[int] = None):
        self.websocket = websocket
        self.role_id = role_id
        self.self_id = self_id
        self._pending_echoes: Dict[str, asyncio.Future] = {}
        self._heartbeat_task: Optional[asyncio.Task] = None

    async def send_action(self, action: str, params: Dict[str, Any]) -> Dict[str, Any]:
        """发送 API 调用并等待 echo 响应"""
        echo = uuid.uuid4().hex[:12]
        future: asyncio.Future = asyncio.get_event_loop().create_future()
        self._pending_echoes[echo] = future

        frame = {
            "action": action,
            "params": params,
            "echo": echo,
        }
        try:
            await self.websocket.send_text(json.dumps(frame, ensure_ascii=False))
        except Exception as e:
            self._pending_echoes.pop(echo, None)
            raise e

        try:
            return await asyncio.wait_for(future, timeout=30.0)
        except asyncio.TimeoutError:
            self._pending_echoes.pop(echo, None)
            return {"status": "failed", "retcode": -1, "error": "timeout"}

    def resolve_echo(self, echo: str, data: Any):
        """由消息循环调用，解析 echo 响应"""
        future = self._pending_echoes.pop(echo, None)
        if future and not future.done():
            future.set_result(data)

    async def start_heartbeat(self, interval: float = 20.0):
        """启动心跳任务"""
        if self._heartbeat_task and not self._heartbeat_task.done():
            return
        self._heartbeat_task = asyncio.ensure_future(self._heartbeat_loop(interval))

    async def stop_heartbeat(self):
        """停止心跳任务"""
        if self._heartbeat_task and not self._heartbeat_task.done():
            self._heartbeat_task.cancel()
            try:
                await self._heartbeat_task
            except (asyncio.CancelledError, Exception):
                pass
        self._heartbeat_task = None

    async def _heartbeat_loop(self, interval: float):
        """连接保活循环，定期发送 WebSocket ping 帧"""
        from starlette.websockets import WebSocketState
        while True:
            try:
                await asyncio.sleep(interval)
                if self.websocket.client_state != WebSocketState.CONNECTED:
                    break
                await self.websocket.send_text(json.dumps({"type": "ping"}))
                logger.debug(f"OneBot WS 保活 ping: role={self.role_id}")
            except asyncio.CancelledError:
                break
            except Exception as e:
                logger.warning(f"OneBot WS 保活失败: role={self.role_id}, error={e}")
                break


class OneBotConnectionManager:
    """管理所有 OneBot WebSocket 连接"""

    def __init__(self):
        self._connections: Dict[str, OneBotConnection] = {}  # role_id -> connection

    async def connect(self, websocket: WebSocket, role_id: str, self_id: Optional[int] = None):
        """注册新连接（替换同角色的旧连接）"""
        old = self._connections.pop(role_id, None)
        if old:
            await old.stop_heartbeat()
            try:
                await old.websocket.close()
            except Exception:
                pass
        conn = OneBotConnection(websocket, role_id, self_id)
        self._connections[role_id] = conn
        await conn.start_heartbeat(interval=20.0)
        logger.info(f"OneBot WS 连接建立: role={role_id}, self_id={self_id}")
        return conn

    def disconnect(self, role_id: str):
        """移除连接（心跳随连接生命周期自动停止）"""
        conn = self._connections.pop(role_id, None)
        if conn:
            asyncio.ensure_future(conn.stop_heartbeat())
        logger.info(f"OneBot WS 连接断开: role={role_id}")

    def get_connection(self, role_id: str) -> Optional[OneBotConnection]:
        """获取某角色的连接"""
        return self._connections.get(role_id)

    def is_connected(self, role_id: str) -> bool:
        return role_id in self._connections


# 全局单例
manager = OneBotConnectionManager()
