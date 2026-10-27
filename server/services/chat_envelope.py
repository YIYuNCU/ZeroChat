"""统一对话信封（ChatEnvelope）。

各入口（App 单聊 / App 群聊 / OneBot 私聊 / OneBot 群聊 / 将来的客户端）先把原始
context 归一成同一个信封，再进入 AI 管道。信封回答三个问题：

* 来源（origin）：消息从哪个客户端、哪种会话进来。
* 会话（chat_type / chat_id / chat_name）：私聊还是群聊，群号与群名。
* 发送人（sender / sender_id / sender_name / sender_kind）：谁说的。

兼容约定：

* ``sender == "user"`` 仍是唯一信任锚点（亲密对象 / 主用户），只能由服务端按入口规则授予。
* ``sender_kind`` 完全由服务端推导，忽略客户端传值。
* 新字段只在非普通 App 单聊时输出，普通单聊的请求字节与旧版一致（前缀缓存稳定）。
"""
from __future__ import annotations

import re
from dataclasses import dataclass
from typing import Any, Dict, List, Mapping, Optional, Tuple

ORIGIN_ZEROCHAT = "zerochat"
ORIGIN_ZEROCHAT_GROUP = "zerochat_group"
ORIGIN_ONEBOT_PRIVATE = "onebot_private"
ORIGIN_ONEBOT_GROUP = "onebot_group"

#: 视为“群聊”的来源。记忆查询、摘要作用域、会话键都应引用它，而不是写死 onebot_group。
GROUP_ORIGINS: Tuple[str, ...] = (ORIGIN_ONEBOT_GROUP, ORIGIN_ZEROCHAT_GROUP)

CHAT_TYPE_PRIVATE = "private"
CHAT_TYPE_GROUP = "group"

KIND_OWNER = "owner"
KIND_MEMBER = "member"
KIND_AI_ROLE = "ai_role"
KIND_SYSTEM = "system"

#: 会随用户消息发给 AI、并写入短期记忆 JSON 的可选字段（按此顺序输出）。
EXTRA_FIELDS: Tuple[str, ...] = (
    "chat_type",
    "chat_id",
    "chat_name",
    "sender_id",
    "sender_name",
    "sender_kind",
)

MAX_ID_LENGTH = 64
MAX_NAME_LENGTH = 64
MAX_SENDER_LENGTH = 128
MAX_MEMBERS = 20

_CONTROL_CHARS = re.compile(r"[\x00-\x1f\x7f\u2028\u2029]+")


def clean_text(value: Any, max_length: int = MAX_NAME_LENGTH) -> str:
    """净化来自外部的展示文本：去控制字符 / 换行、折叠空白、截断。

    QQ 昵称、群名、角色名都可能被对方控制，不能原样信任。
    """
    if value is None:
        return ""
    text = _CONTROL_CHARS.sub(" ", str(value))
    text = " ".join(text.split())
    return text[:max_length].strip()


def is_group_origin(origin: Optional[str]) -> bool:
    return str(origin or "") in GROUP_ORIGINS


def is_onebot_origin(origin: Optional[str]) -> bool:
    return str(origin or "").startswith("onebot")


@dataclass(frozen=True)
class ChatEnvelope:
    origin: str = ORIGIN_ZEROCHAT
    sender: str = "user"
    chat_type: str = ""
    chat_id: str = ""
    chat_name: str = ""
    sender_id: str = ""
    sender_name: str = ""
    sender_kind: str = ""
    members: Tuple[Tuple[str, str], ...] = ()

    @property
    def is_group(self) -> bool:
        return is_group_origin(self.origin)

    @property
    def is_onebot(self) -> bool:
        return is_onebot_origin(self.origin)

    @property
    def is_owner(self) -> bool:
        return self.sender == "user"

    @property
    def group_id(self) -> str:
        """群聊来源的群 id；非群聊为空串（写入 short_term.group_id 列）。"""
        return self.chat_id if self.is_group else ""

    def payload_fields(self) -> Dict[str, str]:
        """需要附加到用户消息 JSON 的可选字段。

        普通 App 单聊（origin == zerochat）以及 proactive / system 事件不输出任何
        额外字段，保持与旧版请求字节一致。
        """
        if self.origin == ORIGIN_ZEROCHAT:
            return {}
        fields: Dict[str, str] = {}
        for key in EXTRA_FIELDS:
            value = getattr(self, key)
            if value:
                fields[key] = value
        return fields


def derive_sender_kind(sender: str, speaker_is_role: bool = False) -> str:
    if speaker_is_role:
        return KIND_AI_ROLE
    if sender == "user":
        return KIND_OWNER
    if sender in ("system", "memory_summary"):
        return KIND_SYSTEM
    return KIND_MEMBER


def _clean_members(raw: Any) -> Tuple[Tuple[str, str], ...]:
    if not isinstance(raw, (list, tuple)):
        return ()
    members: List[Tuple[str, str]] = []
    for item in raw:
        if len(members) >= MAX_MEMBERS:
            break
        if isinstance(item, Mapping):
            member_id = clean_text(item.get("id"), MAX_ID_LENGTH)
            name = clean_text(item.get("name"), MAX_NAME_LENGTH)
        else:
            member_id, name = clean_text(item, MAX_ID_LENGTH), ""
        if member_id:
            members.append((member_id, name))
    return tuple(members)


def build_envelope(
    context: Optional[Mapping[str, Any]],
    default_origin: str = ORIGIN_ZEROCHAT,
    default_sender: str = "user",
) -> ChatEnvelope:
    """把各入口的原始 context 归一成 :class:`ChatEnvelope`。

    兼容旧客户端：只发 ``is_group`` 与 ``chat_id`` 的 App 群聊会被推断为
    ``zerochat_group``；缺少 chat_id 时不提升为群聊，避免会话键落到“all”。
    """
    ctx: Mapping[str, Any] = context or {}
    origin = clean_text(ctx.get("origin"), MAX_ID_LENGTH) or default_origin
    group_hint = clean_text(ctx.get("onebot_group_id") or ctx.get("group_id"), MAX_ID_LENGTH)
    app_chat_id = clean_text(ctx.get("chat_id"), MAX_ID_LENGTH)

    if origin == ORIGIN_ZEROCHAT and ctx.get("is_group") is True and (group_hint or app_chat_id):
        origin = ORIGIN_ZEROCHAT_GROUP

    chat_type = ""
    chat_id = ""
    chat_name = ""
    members: Tuple[Tuple[str, str], ...] = ()
    if origin in GROUP_ORIGINS:
        chat_type = CHAT_TYPE_GROUP
        chat_id = group_hint or app_chat_id
        chat_name = clean_text(ctx.get("chat_name") or ctx.get("group_name"), MAX_NAME_LENGTH)
        if origin == ORIGIN_ZEROCHAT_GROUP:
            members = _clean_members(ctx.get("group_members"))
    elif origin == ORIGIN_ONEBOT_PRIVATE:
        chat_type = CHAT_TYPE_PRIVATE

    sender = clean_text(ctx.get("sender"), MAX_SENDER_LENGTH) or default_sender
    sender_id = clean_text(ctx.get("sender_id"), MAX_ID_LENGTH)
    sender_name = clean_text(ctx.get("sender_name"), MAX_NAME_LENGTH)
    speaker_is_role = False

    # App 群聊里另一个 AI 角色的发言：身份由服务端命名空间化，绝不会等于 "user"。
    speaker = ctx.get("speaker")
    if origin == ORIGIN_ZEROCHAT_GROUP and isinstance(speaker, Mapping) and speaker.get("type") == "role":
        role_id = clean_text(speaker.get("id"), MAX_ID_LENGTH)
        if role_id:
            role_name = clean_text(speaker.get("name"), MAX_NAME_LENGTH)
            sender = f"{role_id}(角色:{role_name})" if role_name else role_id
            sender_id, sender_name = role_id, role_name
            speaker_is_role = True

    return ChatEnvelope(
        origin=origin,
        sender=sender,
        chat_type=chat_type,
        chat_id=chat_id,
        chat_name=chat_name,
        sender_id=sender_id,
        sender_name=sender_name,
        sender_kind=derive_sender_kind(sender, speaker_is_role),
        members=members,
    )


def envelope_from_legacy(
    origin: str = ORIGIN_ZEROCHAT,
    sender: str = "user",
    sender_id: str = "",
    group_id: str = "",
) -> ChatEnvelope:
    """供仍使用 origin / sender kwargs 的调用方（proactive / task / followup 等）构造信封。"""
    ctx: Dict[str, Any] = {"origin": origin, "sender": sender, "sender_id": sender_id}
    if group_id:
        ctx["group_id"] = group_id
    return build_envelope(ctx, default_origin=origin or ORIGIN_ZEROCHAT, default_sender=sender or "user")


def conversation_key(envelope: ChatEnvelope, is_main_user: Optional[bool] = None) -> str:
    """记忆隔离键。既有分支行为不变，并为 zerochat_group 提供独立群记忆。

    * 主用户在 OneBot 私聊 / App 单聊：``default_user``（全渠道共享）。
    * 任何群聊（含主用户）：``group:{id}``，主用户另混入 10% 全渠道记忆（由调用方处理）。
    * OneBot 路人私聊：``private:{sender_id}``。
    * 其他未知来源：``all``。
    """
    main = envelope.is_owner if is_main_user is None else is_main_user
    origin = envelope.origin
    gid = envelope.group_id
    if main and envelope.is_onebot:
        return f"group:{gid}" if origin == ORIGIN_ONEBOT_GROUP and gid else "default_user"
    if envelope.is_group and gid:
        return f"group:{gid}"
    if origin == ORIGIN_ONEBOT_PRIVATE and envelope.sender_id:
        return f"private:{envelope.sender_id}"
    if origin == ORIGIN_ZEROCHAT:
        return "default_user"
    return "all"


def group_context_text(envelope: ChatEnvelope, self_role_id: str = "") -> str:
    """App 群聊的 [群聊信息] 额外上下文；每个群内容固定，利于前缀缓存。非 App 群聊返回空串。"""
    if envelope.origin != ORIGIN_ZEROCHAT_GROUP:
        return ""
    title = f"「{envelope.chat_name}」" if envelope.chat_name else ""
    lines = [f"[群聊信息]\n你正在 App 群聊{title}中，会话 id：{envelope.chat_id}。"]
    if envelope.members:
        shown = []
        for member_id, name in envelope.members:
            label = name or member_id
            shown.append(f"{label}（你自己）" if self_role_id and member_id == self_role_id else label)
        lines.append("群内 AI 角色：" + "、".join(shown) + "。")
    lines.append(
        "sender 为 \"user\" 的是你的亲密对象（真人）；sender_kind 为 ai_role 的是群内其他 AI 角色，"
        "不是你的亲密对象。你只代表你自己发言，回复时区分每条消息的发送人。"
    )
    return "\n".join(lines)
