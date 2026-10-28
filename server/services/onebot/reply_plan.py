"""把 AI 原始回复解析为 QQ 出站计划，行为对齐 App 客户端。

对应客户端：
* ``core/message_parts.dart``：标签归一化与解析（只有 ``<对话>`` 与标签外裸文本送达对方）。
* ``core/segment_sender.dart``：按 ``$`` 分条，无对话的段并入相邻对话段。
* ``core/chat_controller.dart::_sendSegmentsQueued``：文字 → 语音 → 表情的发送顺序与随机延迟。
"""
from __future__ import annotations

import random
import re
from dataclasses import dataclass, field
from typing import Any, Dict, List, Optional

from services.message_format import NO_REPLY_DIRECTIVE, normalize_tags, strip_to_plain

_STRAY_TAG_RE = re.compile(r"</?(?:对话|动作|声音|心理|事实|数值)>")

#: 客户端分条延迟（毫秒）：段前 500–1500，非末段后再 100–299；语音段前 500–1500；表情 300–799。
SEGMENT_GAP_MS = (500, 1500)
SEGMENT_TAIL_MS = (100, 299)
VOICE_GAP_MS = (500, 1500)
STICKER_GAP_MS = (300, 799)


@dataclass
class OutItem:
    kind: str  # "text" | "voice" | "sticker"
    delay_ms: int = 0
    text: str = ""
    raw: str = ""  # 文字段的原始内容（含 <动作> 等标签），仅用于同步进 App 聊天记录
    carries_meta: bool = False  # 同步到 App 时挂 request_id / 工具调用 / 思考链的那一条
    voice: Optional[Dict[str, Any]] = None
    sticker: Any = None


@dataclass
class ReplyPlan:
    items: List[OutItem] = field(default_factory=list)
    no_reply: bool = False

    @property
    def empty(self) -> bool:
        return not self.items

    def text(self) -> str:
        """所有文字段以换行连接（HTTP 同步响应使用）。"""
        return "\n".join(i.text for i in self.items if i.kind == "text")


def is_no_reply(content: str) -> bool:
    return normalize_tags(content or "").strip() == NO_REPLY_DIRECTIVE


def dialogue_of(segment: str) -> str:
    """只保留 <对话> 正文与标签外裸文本，并清理残留的孤立标签。"""
    plain = strip_to_plain(segment or "")
    return _STRAY_TAG_RE.sub("", plain).strip()


def _has_dialogue(segment: str) -> bool:
    return bool(dialogue_of(segment))


def split_segments(content: str) -> List[str]:
    """按 ``$`` 拆成多条消息（移植自 SegmentSender.splitMessage）。"""
    if not (content or "").strip():
        return []
    segments = [s.strip() for s in content.split("$")]
    segments = [s for s in segments if s]
    if not segments:
        return [content.strip()]
    return _merge_without_dialogue(segments)


def _merge_without_dialogue(segments: List[str]) -> List[str]:
    merged: List[str] = []
    leading: List[str] = []
    for segment in segments:
        if not _has_dialogue(segment):
            if merged and _has_dialogue(merged[-1]):
                merged[-1] += segment
            else:
                leading.append(segment)
            continue
        if leading:
            merged.append("".join(leading) + segment)
            leading = []
        else:
            merged.append(segment)
    if leading:
        merged.append("".join(leading))
    return merged


def build_plan(
    content: str,
    metadata: Optional[Dict[str, Any]] = None,
    *,
    rng: Optional[random.Random] = None,
) -> ReplyPlan:
    """生成出站计划；无回复指令或没有可送达内容时返回空计划。"""
    r = rng or random
    meta = metadata or {}
    voices = [v for v in (meta.get("voice_messages") or []) if isinstance(v, dict)]
    emotions = list(meta.get("emojis_called") or [])

    raw = content or ""
    no_reply = is_no_reply(raw)
    if no_reply and not voices:
        return ReplyPlan(no_reply=True)

    texts: List[tuple] = []
    if not no_reply:
        for segment in split_segments(raw):
            text = dialogue_of(segment)
            if text:
                texts.append((text, segment))

    plan = ReplyPlan(no_reply=no_reply and not texts and not voices)
    for i, (text, segment) in enumerate(texts):
        delay = 0
        if i > 0:
            delay = r.randint(*SEGMENT_GAP_MS) + r.randint(*SEGMENT_TAIL_MS)
        plan.items.append(OutItem("text", delay_ms=delay, text=text, raw=segment))

    for v, voice in enumerate(voices):
        delay = r.randint(*VOICE_GAP_MS) if (texts or v > 0) else 0
        plan.items.append(OutItem("voice", delay_ms=delay, voice=voice))

    # 与客户端一致：元数据挂在最后一条文字上；正文全部转语音时挂在最后一条语音上
    carriers = [i for i in plan.items if i.kind == "text"] or [i for i in plan.items if i.kind == "voice"]
    if carriers:
        carriers[-1].carries_meta = True

    if not no_reply:
        for emotion in emotions:
            plan.items.append(
                OutItem("sticker", delay_ms=r.randint(*STICKER_GAP_MS), sticker=emotion)
            )
    return plan
