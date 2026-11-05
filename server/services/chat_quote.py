"""App 引用消息的服务端解析。

客户端发消息时只会带上被引用消息的 id 和界面里的预览文字（预览会被截成 50 字）。
这里按 id 到服务端已同步的聊天记录（``chats/messages.json``）里还原被引用的消息：

* 记录里找得到：用记录里的完整内容和发送人（图片 / 表情 / 语音折算成文字占位），
  不再信任界面预览；
* 找不到（群聊、尚未同步、已删除）：退回客户端带来的内容与发送人。

结果写入 ``context["quote"]``（``[{"sender", "content"}]``），由 ``build_envelope``
归一为对话信封，随用户消息 JSON 发给模型并写入短期记忆。
"""
from __future__ import annotations

import json
import logging
from pathlib import Path
from typing import Any, Dict, List, Mapping, Optional, Sequence, Tuple

from core.utils import ensure_direct_child_path
from services.chat_envelope import (
    MAX_QUOTES,
    QUOTE_OWNER,
    QUOTE_SELF,
    build_envelope,
    clean_text,
    is_onebot_origin,
)

logger = logging.getLogger(__name__)

#: 客户端上送的待解析引用（``[{"id", "content", "sender_id"}]``）所在的 context 键。
QUOTED_MESSAGES_KEY = "quoted_messages"

ROLES_DIR = Path(__file__).resolve().parent.parent / "data" / "roles"

_OWNER_SENDER_IDS = ("me", "user")


def find_stored_message(role_id: str, message_id: str) -> Optional[Dict[str, Any]]:
    """按 id 从角色已同步的聊天记录里找一条消息；找不到或读取失败返回 None。"""
    from services.chat_io_service import role_lock

    try:
        role_dir = ensure_direct_child_path(ROLES_DIR, role_id, "role_id")
        messages_file = ensure_direct_child_path(role_dir / "chats", "messages.json", "chat file")
    except ValueError:
        return None
    try:
        with role_lock(role_id):
            if not messages_file.is_file():
                return None
            with open(messages_file, "r", encoding="utf-8") as handle:
                messages = json.load(handle).get("messages", [])
    except (OSError, ValueError, AttributeError):
        logger.debug("读取聊天记录失败，引用退回客户端预览: role=%s", role_id, exc_info=True)
        return None
    if not isinstance(messages, list):
        return None
    for message in reversed(messages):  # 被引用的多是较新的消息
        if isinstance(message, dict) and str(message.get("id", "")) == message_id:
            return message
    return None


def describe_message(message: Mapping[str, Any]) -> str:
    """一条聊天记录对模型可读的文字：图片 / 表情用占位符，语音取其转写，AI 消息去掉动作等标签。"""
    from services.message_format import strip_to_plain

    kind = str(message.get("type") or "text").strip().lower()
    content = str(message.get("content") or "")
    if kind == "image":
        return "[图片]"
    if kind == "sticker" or content.startswith("[STICKER"):
        return "[表情]"
    if kind == "voice":
        try:
            spoken = str(json.loads(content).get("text") or "").strip()
        except (ValueError, AttributeError):
            spoken = ""
        return spoken or "[语音]"
    if str(message.get("sender_id") or "") in _OWNER_SENDER_IDS:
        return content
    return strip_to_plain(content) or content


def sender_label(sender_id: Any, role_id: str, members: Sequence[Tuple[str, str]] = ()) -> str:
    """被引用消息的发送人标记：亲密对象 ``user``、角色自己 ``self``，群里其他角色带名字。"""
    sid = str(sender_id or "").strip()
    if not sid:
        return ""
    if sid in _OWNER_SENDER_IDS:
        return QUOTE_OWNER
    if sid in ("ai", role_id):
        return QUOTE_SELF
    name = dict(members).get(sid, "")
    return f"{sid}(角色:{name})" if name else clean_text(sid)


def _resolve_one(role_id: str, raw: Mapping[str, Any], members) -> Optional[Dict[str, str]]:
    message_id = str(raw.get("id") or "").strip()
    stored = find_stored_message(role_id, message_id) if message_id else None
    if stored is not None:
        content = describe_message(stored)
        sender = sender_label(stored.get("sender_id"), role_id, members)
    else:
        content = str(raw.get("content") or "")
        sender = sender_label(raw.get("sender_id"), role_id, members)
    if not content.strip():
        return None
    return {"sender": sender, "content": content}


def resolve_app_quotes(
    role_id: str, raw: Any, members: Sequence[Tuple[str, str]] = ()
) -> List[Dict[str, str]]:
    """把客户端上送的引用解析成 ``[{"sender", "content"}]``（最多 ``MAX_QUOTES`` 条）。"""
    if isinstance(raw, Mapping):
        raw = [raw]
    if not isinstance(raw, (list, tuple)):
        return []
    resolved: List[Dict[str, str]] = []
    for item in raw:
        if len(resolved) >= MAX_QUOTES:
            break
        if isinstance(item, Mapping):
            quote = _resolve_one(role_id, item, members)
            if quote is not None:
                resolved.append(quote)
    return resolved


async def attach_app_quotes(role_id: str, context: Optional[Mapping[str, Any]]) -> Dict[str, Any]:
    """返回补上 ``quote`` 的 context 副本；QQ 来源（已由服务端解析）和无引用的请求原样返回。"""
    ctx: Dict[str, Any] = dict(context or {})
    raw = ctx.pop(QUOTED_MESSAGES_KEY, None)
    if not raw or is_onebot_origin(ctx.get("origin")):
        return ctx
    from services.chat_io_service import run_file_io

    members = build_envelope(ctx).members
    quotes = await run_file_io(resolve_app_quotes, role_id, raw, members)
    if quotes:
        ctx["quote"] = quotes
    return ctx
