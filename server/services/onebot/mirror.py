"""把主用户的 QQ 私聊同步进 App 聊天记录（messages.json）并推送刷新。

消息 id 使用 ``qq_`` 前缀，不含 ``_proactive/_task_/_followup``：App 不会把它们当作
未读 / 通知（用户本来就是在 QQ 里看到的）。内容格式与 App 自己落库的一致。
"""
from __future__ import annotations

import itertools
import json
import logging
import time
from datetime import datetime
from pathlib import Path
from typing import Any, Dict, Optional
from urllib.parse import quote

from services.onebot.models import Inbound
from services.onebot.paths import ROLES_DIR
from services.onebot.reply_plan import OutItem

logger = logging.getLogger(__name__)

_counter = itertools.count()


def should_mirror(inbound: Inbound) -> bool:
    """只同步主用户的 QQ 私聊；群聊与路人私聊不进 App。"""
    return inbound.is_private and inbound.is_owner


def _new_id(kind: str) -> str:
    return f"qq_{int(time.time() * 1000)}_{next(_counter)}_{kind}"


async def _save_and_push(role_id: str, message_kwargs: Dict[str, Any]) -> None:
    from routers.roles import ChatMessage, save_chat_message

    try:
        await save_chat_message(
            role_id,
            ChatMessage(
                timestamp=datetime.now().isoformat(),
                **message_kwargs,
            ),
        )
    except Exception as exc:  # noqa: BLE001 - 同步失败不能影响 QQ 回复
        logger.warning("OneBot 同步到 App 失败: role=%s %s", role_id, exc)
        return
    try:
        from transport.push_hub import publish_server_push

        await publish_server_push(
            "chat_message",
            {"role_id": role_id, "chat_id": role_id, "message_id": message_kwargs["id"]},
        )
    except Exception:  # noqa: BLE001 - 未配置推送（如测试环境）或无在线客户端
        logger.debug("OneBot 同步推送失败", exc_info=True)


async def mirror_user(role_id: str, text: str) -> None:
    if not (text or "").strip():
        return
    await _save_and_push(
        role_id,
        {"id": _new_id("u"), "content": text, "sender_id": "me", "type": "text"},
    )


def sticker_content(role_id: str, path: Path) -> Optional[str]:
    """表情 → ``[STICKER:<category>:ws-emoji://role/<role>/<category>/<file>]``。"""
    try:
        parts = path.relative_to(ROLES_DIR).parts  # (role_id, "emojis", category, filename)
        category, filename = parts[2], parts[3]
    except (ValueError, IndexError):
        return None
    ref = (
        f"ws-emoji://role/{quote(role_id, safe='')}/{quote(category, safe='')}/{quote(filename, safe='')}"
    )
    return f"[STICKER:{category}:{ref}]"


async def mirror_item(
    role_id: str,
    item: OutItem,
    path: Optional[Path],
    metadata: Optional[Dict[str, Any]] = None,
) -> None:
    """同步一条已送达的 AI 消息。metadata 仅挂在 ``carries_meta`` 的那一条上。"""
    meta = metadata if item.carries_meta else {}
    extra = {
        "request_id": (meta or {}).get("request_id"),
        "has_tool_calls": bool((meta or {}).get("has_tool_calls")),
        "reasoning_content": (meta or {}).get("reasoning_content"),
    }
    if item.kind == "text":
        payload = {"id": _new_id("a"), "content": item.raw or item.text, "type": "text"}
    elif item.kind == "voice" and item.voice:
        voice = item.voice
        content = json.dumps(
            {
                "kind": "voice",
                "text": str(voice.get("text") or ""),
                "ref": str(voice.get("ref") or ""),
                "duration_ms": voice.get("duration_ms"),
            },
            ensure_ascii=False,
        )
        payload = {"id": _new_id("v"), "content": content, "type": "voice"}
    elif item.kind == "sticker" and path is not None:
        content = sticker_content(role_id, path)
        if not content:
            return
        payload = {"id": _new_id("s"), "content": content, "type": "sticker"}
    else:
        return
    await _save_and_push(role_id, {**payload, "sender_id": role_id, **extra})
