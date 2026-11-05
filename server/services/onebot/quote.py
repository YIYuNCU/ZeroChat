"""OneBot 引用（reply 段）还原：把「回复了哪条消息」变成模型能读的 ``{sender, content}``。

QQ 的 reply 段只带被引用消息的 id。还原顺序：

1. 本地额外消息库（``message_log``）：保留 3 天，含机器人自己发出的回复，不需要网络；
2. 反向 WS 上的 ``get_msg`` 接口（NapCat 等实现提供），带短超时；HTTP 同步模式没有连接，跳过；
3. 都取不到时给一个明确的占位，让模型知道对方在回复某条看不到的消息，而不是装作没有引用。

发送人沿用整条链路的信任约定：主 QQ 号是 ``user``，机器人自己是 ``self``，其余是
``<QQ号>(QQ名:<昵称>)``；昵称与内容都由对方控制，已经净化并限长。
"""
from __future__ import annotations

import asyncio
import logging
import re
from typing import Any, Dict, List, Optional

from services.chat_envelope import (
    MAX_QUOTES,
    QUOTE_OWNER,
    QUOTE_SELF,
    clean_text,
)
from services.onebot import config as cfg_mod, message_log
from services.onebot.models import Inbound
from services.onebot.parser import effective_self_id, flatten_message, parse_int

logger = logging.getLogger(__name__)

#: ``get_msg`` 的等待上限（秒）。引用还原只是锦上添花，不能把回复拖慢太久。
GET_MSG_TIMEOUT = 5.0
UNAVAILABLE_TEXT = "[无法获取被引用的消息]"

_REPLY_MARK_RE = re.compile(r"^\[回复\]\s*")


def _label(user_id: Any, nickname: str, main_user_id: int, self_id: int) -> str:
    uid = parse_int(user_id)
    if main_user_id and uid == main_user_id:
        return QUOTE_OWNER
    if self_id and uid == self_id:
        return QUOTE_SELF
    name = clean_text(nickname)
    return f"{uid}(QQ名:{name})" if name else str(uid or "")


def _from_log(inbound: Inbound, message_id: int) -> Optional[Dict[str, str]]:
    chat_type, chat_id = message_log._chat_key(inbound)
    try:
        row = message_log.lookup_message(inbound.role_id, chat_type, chat_id, message_id)
    except Exception:  # noqa: BLE001 - 消息库读取失败只影响引用还原
        logger.warning("OneBot 消息库查询引用失败", exc_info=True)
        return None
    if row is None:
        return None
    content = _REPLY_MARK_RE.sub("", row["content"])
    sender = QUOTE_SELF if row["is_self"] else clean_text(row["sender"], 128)
    return {"sender": sender, "content": content}


async def _from_get_msg(
    conn, message_id: int, main_user_id: int, self_id: int
) -> Optional[Dict[str, str]]:
    try:
        response = await conn.send_action(
            "get_msg", {"message_id": message_id}, timeout=GET_MSG_TIMEOUT
        )
    except Exception:  # noqa: BLE001 - 连接已断等：退回占位
        logger.debug("OneBot get_msg 失败: id=%s", message_id, exc_info=True)
        return None
    data = response.get("data") if isinstance(response, dict) else None
    if not isinstance(data, dict) or response.get("retcode", 0) != 0:
        return None
    text, _ = flatten_message(data.get("message", data.get("raw_message")))
    if not text.strip():
        return None
    sender = data.get("sender") or {}
    nickname = str(sender.get("card") or sender.get("nickname") or "")
    return {
        "sender": _label(sender.get("user_id") or data.get("user_id"), nickname, main_user_id, self_id),
        "content": text,
    }


async def resolve_quotes(batch: List[Inbound], conn) -> List[Dict[str, str]]:
    """还原这一批消息引用的所有旧消息（按首次出现顺序，去重，最多 ``MAX_QUOTES`` 条）。"""
    config = cfg_mod.load_config(batch[0].role_id) if batch else {}
    main_user_id = cfg_mod.main_user_id(config)
    quotes: List[Dict[str, str]] = []
    seen = set()
    for inbound in batch:
        message_id = inbound.reply_to_id
        if message_id is None or message_id in seen:
            continue
        seen.add(message_id)
        if len(quotes) >= MAX_QUOTES:
            break
        quote = await asyncio.get_running_loop().run_in_executor(None, _from_log, inbound, message_id)
        if quote is None and conn is not None:
            self_id = effective_self_id(config) or parse_int(getattr(conn, "self_id", 0))
            quote = await _from_get_msg(conn, message_id, main_user_id, self_id)
        quotes.append(quote or {"sender": "", "content": UNAVAILABLE_TEXT})
    return quotes
