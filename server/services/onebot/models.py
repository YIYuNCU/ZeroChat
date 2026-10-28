"""OneBot 事件模型与归一化后的入站消息。"""
from __future__ import annotations

from dataclasses import dataclass, field
from typing import Any, Dict, List, Optional

from pydantic import BaseModel

from services.chat_envelope import ORIGIN_ONEBOT_GROUP, ORIGIN_ONEBOT_PRIVATE

OWNER_SENDER = "user"


class OneBotEvent(BaseModel):
    post_type: Optional[str] = None
    message_type: Optional[str] = None
    sub_type: Optional[str] = None
    message_id: Optional[int] = None
    user_id: Optional[int] = None
    group_id: Optional[int] = None
    message: Any = None
    raw_message: Optional[str] = None
    sender: Optional[Dict[str, Any]] = None
    group_name: Optional[str] = None  # NapCat 等实现会在群消息事件里附带群名，缺省则不输出
    time: Optional[int] = None
    self_id: Optional[int] = None
    font: Optional[int] = None


@dataclass(frozen=True)
class Target:
    """出站目标：群聊（group_id 非空）或私聊。user_id 在群聊里是被 @ 的人。"""

    user_id: int
    group_id: Optional[int] = None

    @property
    def is_group(self) -> bool:
        return bool(self.group_id)

    @property
    def lane(self) -> str:
        return f"group:{self.group_id}" if self.group_id else f"private:{self.user_id}"


@dataclass
class Inbound:
    """一条归一化后的 QQ 入站消息（取代旧实现里的 dict）。"""

    role_id: str
    origin: str
    content: str
    sender: str
    user_id: int
    group_id: Optional[int] = None
    sender_name: str = ""
    chat_name: str = ""
    message_id: Optional[int] = None
    image_urls: List[str] = field(default_factory=list)
    server_url: str = ""
    at_bot: bool = True  # 群聊里是否 @ 了机器人（私聊恒为 True）

    @property
    def is_group(self) -> bool:
        return self.origin == ORIGIN_ONEBOT_GROUP

    @property
    def is_private(self) -> bool:
        return self.origin == ORIGIN_ONEBOT_PRIVATE

    @property
    def is_owner(self) -> bool:
        return self.sender == OWNER_SENDER

    @property
    def conv_key(self) -> str:
        """指令 / 屏蔽 / 随机回复使用的会话键（与既有 profile 数据兼容）。"""
        return f"group:{self.group_id}" if self.is_group else f"private:{self.user_id}"

    @property
    def lane(self) -> str:
        """出站串行与处理排队的会话通道。"""
        return self.conv_key

    @property
    def target(self) -> Target:
        return Target(self.user_id, self.group_id if self.is_group else None)
