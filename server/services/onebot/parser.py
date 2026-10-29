"""OneBot 消息段解析：纯文本、图片 URL、@bot / 关键词唤醒判断、昵称。"""
from __future__ import annotations

import logging
from typing import Any, List, Optional, Tuple

from services.chat_envelope import (
    ORIGIN_ONEBOT_GROUP,
    ORIGIN_ONEBOT_PRIVATE,
    clean_text,
)
from services.onebot.models import OWNER_SENDER, Inbound, OneBotEvent

logger = logging.getLogger(__name__)

_PLACEHOLDERS = {
    "face": "[表情]",
    "record": "[语音]",
    "video": "[视频]",
    "reply": "[回复]",
    "forward": "[转发消息]",
    "json": "[JSON卡片]",
    "xml": "[XML消息]",
}


def _at_target(data: dict) -> Any:
    return data.get("qq") or data.get("target") or data.get("uin") or ""


def flatten_message(message: Any, self_id: Optional[int] = None) -> Tuple[str, List[str]]:
    """将 OneBot message 字段转换为纯文本和图片 URL 列表，去除开头的 @机器人。"""
    if isinstance(message, str):
        return message, []
    if not isinstance(message, list):
        return str(message or ""), []

    parts: List[str] = []
    image_urls: List[str] = []
    skip_leading_at = True  # 仅跳过消息开头的 @机器人
    for seg in message:
        if not isinstance(seg, dict):
            continue
        seg_type = seg.get("type", "")
        data = seg.get("data") or {}
        if seg_type == "at":
            qq = _at_target(data) or "all"
            at_qq = int(qq) if str(qq).isdigit() else qq
            if skip_leading_at and self_id and at_qq == self_id:
                continue
            parts.append(f"@{qq}")
            skip_leading_at = False
        elif seg_type == "text":
            text = str(data.get("text", ""))
            if skip_leading_at and text.lstrip():
                skip_leading_at = False
            parts.append(text)
        else:
            skip_leading_at = False
            if seg_type == "image":
                parts.append("[图片]")
                url = str(data.get("url", "")).strip()
                if url:
                    image_urls.append(url)
            else:
                parts.append(_PLACEHOLDERS.get(seg_type, f"[{seg_type}]"))
    return "".join(parts).strip(), image_urls


def is_at_bot(message: Any, self_id: Optional[int]) -> bool:
    """检查消息是否 @了机器人。未配置 self_id 时无法判断，按已 @ 处理。"""
    if not self_id:
        logger.warning("is_at_bot: self_id 为空，跳过检查")
        return True
    if isinstance(message, str):
        return f"@{self_id}" in message
    if isinstance(message, list):
        for seg in message:
            if isinstance(seg, dict) and seg.get("type") == "at":
                if str(_at_target(seg.get("data") or {})) == str(self_id):
                    return True
    return False


def normalize_wake_keywords(raw: Any) -> List[str]:
    """清洗配置里的唤醒关键词：去空白、去空串、忽略大小写去重，保持原有顺序。"""
    if isinstance(raw, str):
        raw = [raw]
    if not isinstance(raw, (list, tuple)):
        return []
    result: List[str] = []
    seen = set()
    for item in raw:
        word = str(item).strip()
        key = word.casefold()
        if word and key not in seen:
            seen.add(key)
            result.append(word)
    return result


def _plain_text(message: Any) -> str:
    """只取用户实际输入的文字（text 段），不含 @、图片、表情等占位符。"""
    if isinstance(message, str):
        return message
    if not isinstance(message, list):
        return ""
    return "".join(
        str((seg.get("data") or {}).get("text", ""))
        for seg in message
        if isinstance(seg, dict) and seg.get("type") == "text"
    )


def match_wake_keyword(message: Any, keywords: Any) -> Optional[str]:
    """消息文字里包含任一唤醒关键词（忽略大小写）时返回命中的关键词，否则返回 None。"""
    words = normalize_wake_keywords(keywords)
    if not words:
        return None
    text = _plain_text(message).casefold()
    if not text:
        return None
    for word in words:
        if word.casefold() in text:
            return word
    return None


def extract_sender_name(event: OneBotEvent) -> str:
    sender = event.sender or {}
    if event.message_type == "group":
        card = str(sender.get("card") or "").strip()
        if card:
            return card
    nickname = str(sender.get("nickname") or "").strip()
    if nickname:
        return nickname
    return str(event.user_id or "unknown")


def parse_int(value: Any) -> int:
    try:
        return int(value or 0)
    except (TypeError, ValueError):
        return 0


def effective_self_id(config: dict, event: Optional[OneBotEvent] = None) -> int:
    configured = parse_int(config.get("self_id") or config.get("selfId"))
    return configured or parse_int(getattr(event, "self_id", 0))


def transform_event(
    event: OneBotEvent,
    *,
    role_id: str,
    config: dict,
    server_url: str = "",
) -> Optional[Inbound]:
    """将 OneBot 事件转成 Inbound；非消息事件或空内容返回 None。

    主 QQ 号发来的消息 sender 记为 "user"（唯一信任锚点），其余带净化后的昵称。
    """
    if event.post_type != "message" or event.message_type not in ("private", "group"):
        return None

    content, image_urls = flatten_message(event.message, self_id=effective_self_id(config, event))
    if not content.strip() and not image_urls:
        return None

    # 昵称 / 群名由对方控制：先净化（去换行与控制字符、限长），再拼进 sender 字符串。
    sender_name = clean_text(extract_sender_name(event))
    user_id = event.user_id or 0
    sender = f"{user_id}(QQ名:{sender_name})"
    main_user_id = parse_int(config.get("main_user_id"))
    if main_user_id and event.user_id == main_user_id:
        sender = OWNER_SENDER

    if event.message_type == "group":
        origin, group_id, chat_name = ORIGIN_ONEBOT_GROUP, event.group_id or 0, clean_text(event.group_name)
    else:
        origin, group_id, chat_name = ORIGIN_ONEBOT_PRIVATE, None, ""

    at_bot = True  # 私聊恒为 True
    if event.message_type == "group":
        at_bot = is_at_bot(event.message, effective_self_id(config, event))
        if not at_bot:
            keyword = match_wake_keyword(event.message, config.get("wake_keywords"))
            if keyword:
                at_bot = True
                logger.info("关键词唤醒: role=%s, group=%s, keyword=%s", role_id, event.group_id, keyword)

    return Inbound(
        role_id=role_id,
        origin=origin,
        content=content,
        sender=sender,
        user_id=user_id,
        group_id=group_id,
        sender_name=sender_name,
        chat_name=chat_name,
        message_id=event.message_id,
        image_urls=image_urls,
        server_url=server_url,
        at_bot=at_bot,
    )
