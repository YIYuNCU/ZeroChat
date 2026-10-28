"""QQ 出站：把 ReplyPlan 按 App 的节奏逐条发出。

* 私聊从不引用；群聊仅「第一条文字」引用原消息并 @ 发送者，后续分条两者都不带。
* 同一会话通道的出站串行，主动消息与普通回复不会交错。
* 单条发送失败只记日志并继续下一条，不中断整轮。
"""
from __future__ import annotations

import asyncio
import base64
import logging
from pathlib import Path
from typing import Any, Awaitable, Callable, Dict, List, Optional, Tuple

from core.utils import ensure_direct_child_path, ensure_simple_path_segment
from services.onebot.models import Target
from services.onebot.paths import ROLES_DIR, emoji_root
from services.onebot.reply_plan import OutItem, ReplyPlan

logger = logging.getLogger(__name__)

SERVER_URL_FALLBACK = "http://127.0.0.1:8000"

#: QQ 语音单条上限（base64 内联发送，过大的文件跳过）。
VOICE_MAX_BYTES = 4 * 1024 * 1024

Sleep = Callable[[float], Awaitable[None]]

_send_locks: Dict[Tuple[str, str], asyncio.Lock] = {}


def _send_lock(role_id: str, lane: str) -> asyncio.Lock:
    key = (role_id, lane)
    lock = _send_locks.get(key)
    if lock is None:
        lock = _send_locks[key] = asyncio.Lock()
    return lock


def onebot_ok(response: Any) -> bool:
    if not isinstance(response, dict):
        return False
    return response.get("status") == "ok" or response.get("retcode") == 0


def build_server_url(websocket=None) -> str:
    """从 WebSocket 连接或 CONFIG 构建服务器 URL（OneBot 通过 HTTP 取表情图片）。"""
    from main import CONFIG

    if websocket is not None:
        scheme = "https" if websocket.url.scheme == "wss" else "http"
        return f"{scheme}://{websocket.url.hostname}:{websocket.url.port}"
    host = CONFIG.get("host", "0.0.0.0")
    port = CONFIG.get("port", 8000)
    if not host or host in ("0.0.0.0", "::"):
        host = "127.0.0.1"
    return f"http://{host}:{port}"


def resolve_sticker(emotion: Any, role_id: str) -> Optional[Path]:
    """emojis_called 的一个元素 → 表情图片路径。

    元素可为：str 情绪名（本地情绪目录随机抽取）；
    dict {"category", "filename"}（精确定位某张缓存图片，如云端表情）。
    """
    from services.ai_tools import _pick_emoji_file

    if isinstance(emotion, dict):
        category = str(emotion.get("category") or "").strip()
        filename = str(emotion.get("filename") or "").strip()
        if not category or not filename:
            return None
        try:
            safe_cat = ensure_simple_path_segment(category, "category")
            safe_name = ensure_simple_path_segment(filename, "filename")
            category_dir = ensure_direct_child_path(emoji_root(role_id), safe_cat, "category")
            path = ensure_direct_child_path(category_dir, safe_name, "filename")
        except ValueError:
            return None
        return path if path.is_file() else None
    name = str(emotion or "").strip().lower()
    return _pick_emoji_file(role_id, name) if name else None


def sticker_url(path: Path, server_url: str) -> str:
    # path = {ROLES_DIR}/{role_id}/emojis/{category}/{filename}
    parts = path.relative_to(ROLES_DIR).parts
    return f"{server_url.rstrip('/')}/files/public/emojis/{parts[0]}/{parts[2]}/{parts[3]}"


async def _send(conn, target: Target, segments: List[Dict[str, Any]]) -> Any:
    if target.is_group:
        return await conn.send_action(
            "send_group_msg", {"group_id": target.group_id, "message": segments}
        )
    return await conn.send_action("send_private_msg", {"user_id": target.user_id, "message": segments})


def _text_segments(
    text: str, target: Target, quote_id: Optional[int], first: bool
) -> List[Dict[str, Any]]:
    """群聊首条：reply + @ + 文本；其余（含私聊）只有文本。"""
    if not (first and target.is_group):
        return [{"type": "text", "data": {"text": text}}]
    segments: List[Dict[str, Any]] = []
    if quote_id is not None:
        segments.append({"type": "reply", "data": {"id": quote_id}})
    segments.append({"type": "at", "data": {"qq": target.user_id}})
    segments.append({"type": "text", "data": {"text": f" {text}"}})
    return segments


async def _send_voice(conn, target: Target, role_id: str, voice: Dict[str, Any]) -> bool:
    """语音以 record 段（base64）单独发送；失败时降级为文字转写。"""
    from services import tts_service

    spoken = str(voice.get("text") or "").strip()
    delivered = False
    try:
        path = tts_service.voice_file_path(role_id, str(voice.get("filename") or ""))
        if path.is_file() and path.stat().st_size <= VOICE_MAX_BYTES:
            encoded = base64.b64encode(path.read_bytes()).decode("ascii")
            response = await _send(
                conn, target, [{"type": "record", "data": {"file": f"base64://{encoded}"}}]
            )
            delivered = onebot_ok(response)
    except Exception as exc:  # noqa: BLE001 - 语音失败不影响其余回复
        logger.warning("OneBot 语音发送失败: %s", type(exc).__name__)
    if not delivered and spoken:
        try:
            response = await _send(conn, target, [{"type": "text", "data": {"text": f"[语音] {spoken}"}}])
            delivered = onebot_ok(response)
        except Exception as exc:  # noqa: BLE001
            logger.warning("OneBot 语音降级文字失败: %s", type(exc).__name__)
    return delivered


async def deliver_plan(
    conn,
    role_id: str,
    target: Target,
    plan: ReplyPlan,
    *,
    quote_id: Optional[int] = None,
    server_url: str = "",
    sleep: Sleep = asyncio.sleep,
    on_delivered: Optional[Callable[[OutItem, Optional[Path]], Awaitable[None]]] = None,
) -> List[Tuple[OutItem, Optional[Path]]]:
    """按计划逐条发送；返回实际送达的条目（表情附带解析出的文件路径）。"""
    delivered: List[Tuple[OutItem, Optional[Path]]] = []
    if plan.empty:
        return delivered
    base_url = server_url or getattr(conn, "server_url", "") or SERVER_URL_FALLBACK
    quote_pending = True
    seen_stickers: set = set()

    async with _send_lock(role_id, target.lane):
        for item in plan.items:
            if item.delay_ms > 0:
                await sleep(item.delay_ms / 1000.0)
            try:
                if item.kind == "text":
                    # 引用 / @ 仅限第一条文字
                    segments = _text_segments(item.text, target, quote_id, quote_pending)
                    quote_pending = False
                    ok = onebot_ok(await _send(conn, target, segments))
                    path = None
                elif item.kind == "voice":
                    ok = await _send_voice(conn, target, role_id, item.voice or {})
                    path = None
                elif item.kind == "sticker":
                    path = resolve_sticker(item.sticker, role_id)
                    if path is None or str(path) in seen_stickers:
                        continue
                    seen_stickers.add(str(path))
                    segments = [{"type": "image", "data": {"file": sticker_url(path, base_url)}}]
                    ok = onebot_ok(await _send(conn, target, segments))
                else:
                    continue
            except asyncio.CancelledError:
                raise
            except Exception as exc:  # noqa: BLE001 - 单条失败继续下一条
                logger.warning("OneBot 发送失败 role=%s kind=%s: %s", role_id, item.kind, exc)
                continue
            if ok:
                delivered.append((item, path))
                if on_delivered is not None:
                    try:
                        await on_delivered(item, path)
                    except Exception:  # noqa: BLE001 - 回调（如同步到 App）失败不影响发送
                        logger.warning("OneBot 送达回调失败", exc_info=True)
            else:
                logger.warning("OneBot 发送未成功 role=%s kind=%s", role_id, item.kind)
    return delivered


async def send_plain(
    conn,
    role_id: str,
    target: Target,
    text: str,
    *,
    quote_id: Optional[int] = None,
) -> None:
    """发送一条不经协议解析的纯文本（指令回复等）。群聊同样仅首条引用并 @。"""
    text = (text or "").strip()
    if not text:
        return
    plan = ReplyPlan(items=[OutItem("text", text=text)])
    await deliver_plan(conn, role_id, target, plan, quote_id=quote_id)
