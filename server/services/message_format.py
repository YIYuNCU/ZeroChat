"""消息格式归一化与剥离工具。

AI 偶尔会把规范的中文结构标签写成英文或近义词（如 ``<message>``、``<action>``），
或中英混用。这些别名标签不被客户端解析器识别，会连同字面量一起渲染。此模块提供：

- :func:`normalize_tags` —— 把别名/混用标签改写回中文规范标签。
- :func:`strip_to_plain` —— 归一化后仅保留对话正文，丢弃动作/心理/数值等块，
  供朋友圈等纯文本场景使用。

与客户端 ``client/lib/core/message_parts.dart`` 的映射保持同步。
"""
import re
from typing import Dict, List, Tuple

NO_REPLY_DIRECTIVE = "<无回复/>"

# 别名标签 → 中文规范标签。需与客户端 _tagAliases 同步。
_TAG_ALIASES: Dict[str, List[str]] = {
    "对话": ["message", "dialogue", "dialog", "talk", "speech", "say"],
    "动作": ["action", "act", "move", "motion"],
    "心理": ["thought", "psychology", "psych", "mind", "inner", "think", "feeling"],
    "事实": ["fact", "facts"],
    "数值": ["stats", "stat", "value", "values", "status"],
}

_NO_REPLY_ALIASES: List[str] = [
    "no_reply",
    "noreply",
    "no-reply",
    "noresponse",
    "no_response",
]


def _build_rules() -> List[Tuple[re.Pattern, str]]:
    rules: List[Tuple[re.Pattern, str]] = []
    # 无回复别名（自闭合或成对写法）统一为规范指令。
    for alias in _NO_REPLY_ALIASES:
        e = re.escape(alias)
        rules.append((
            re.compile(rf"<\s*{e}\s*/?\s*>(?:\s*</\s*{e}\s*>)?", re.IGNORECASE),
            NO_REPLY_DIRECTIVE,
        ))
    # 成对别名标签：开/闭标签分别改写为对应中文标签。
    for zh, aliases in _TAG_ALIASES.items():
        for alias in aliases:
            e = re.escape(alias)
            rules.append((re.compile(rf"<\s*{e}\s*>", re.IGNORECASE), f"<{zh}>"))
            rules.append((re.compile(rf"<\s*/\s*{e}\s*>", re.IGNORECASE), f"</{zh}>"))
    return rules


_NORMALIZE_RULES = _build_rules()

# 归一化后用于按类型抽取正文的正则（与客户端 _partRe 对齐）。
_PART_RE = re.compile(r"<(对话|动作|心理|事实|数值)>(.*?)</\1>", re.DOTALL)


def normalize_tags(text: str) -> str:
    """把英文/别名/混用标签归一化为中文规范标签。"""
    if not text or "<" not in text:
        return text
    result = text
    for pattern, repl in _NORMALIZE_RULES:
        result = pattern.sub(repl, result)
    return result


def strip_to_plain(text: str) -> str:
    """归一化后仅保留对话正文，丢弃动作/心理/数值等结构块。

    - ``<对话>`` 块保留其正文，按原文顺序拼接。
    - ``<动作>/<心理>/<数值>/<事实>`` 块整体丢弃。
    - 标签外的裸文本视为对话保留。
    - 若整条是无回复指令，返回空串。
    """
    if not text:
        return text
    normalized = normalize_tags(text)
    if normalized.strip() == NO_REPLY_DIRECTIVE:
        return ""

    pieces: List[str] = []
    cursor = 0
    for match in _PART_RE.finditer(normalized):
        # 标签之间/之前的裸文本按对话保留。
        outside = normalized[cursor:match.start()].strip()
        if outside:
            pieces.append(outside)
        tag = match.group(1)
        body = (match.group(2) or "").strip()
        if tag == "对话" and body:
            pieces.append(body)
        cursor = match.end()
    tail = normalized[cursor:].strip()
    if tail:
        pieces.append(tail)

    return "\n".join(pieces).strip()
