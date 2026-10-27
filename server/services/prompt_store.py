"""File-backed store for the built-in system prompts.

Each prompt lives in ``server/prompts/**/*.md`` as a small front-matter block followed
by the template body (see ``server/prompts/README.md``). The store parses and validates
the files once and hands :class:`PromptDefinition` objects to
:mod:`services.prompt_config_service`. Any malformed file raises
:class:`PromptStoreError` – a broken prompt must never silently degrade to an empty string.
"""
from __future__ import annotations

import json
import re
from dataclasses import dataclass
from pathlib import Path
from typing import Any, Dict, Optional, Sequence, Tuple

PROMPTS_DIR = Path(__file__).resolve().parent.parent / "prompts"

#: Placeholders that the code is allowed to substitute at render time.
KNOWN_PLACEHOLDERS = frozenset(
    {
        "NO_REPLY_DIRECTIVE",
        "STATS_LAYOUT_RULE",
        "MAIN_QQ_HINT",
        "TOOL_POLICY_CONSERVATIVE",
        "EMOJI_TOOL_RULE",
    }
)

_REQUIRED_KEYS = ("id", "title", "group", "origin", "applies_to")
_OPTIONAL_KEYS = ("editable", "version", "placeholders")
_ALLOWED_KEYS = frozenset(_REQUIRED_KEYS + _OPTIONAL_KEYS)
_VALID_ORIGINS = ("zerochat", "onebot", "shared")
_VALID_APPLIES = ("chat", "summary")
_PLACEHOLDER_RE = re.compile(r"\{([A-Z][A-Z0-9_]*)\}")


class PromptStoreError(RuntimeError):
    """Raised when a prompt file is missing, malformed or inconsistent."""


@dataclass(frozen=True)
class PromptDefinition:
    """One prompt block.

    ``builtin`` is the complete default template. ``editable`` decides whether the
    frontend may override it at all: code-owned prompts are coupled to the tools actually
    registered for the active model/plugin and to the ``{...}`` placeholders the code
    substitutes at render time. ``version`` is bumped whenever the shipped text changes so
    stored overrides can be flagged as based on an older builtin.
    """

    id: str
    title: str
    group: str
    builtin: str
    origin: str = "shared"
    applies_to: Sequence[str] = ("chat",)
    editable: bool = True
    version: int = 1
    placeholders: Tuple[str, ...] = ()


def _parse_value(raw: str) -> Any:
    text = raw.strip()
    try:
        return json.loads(text)
    except ValueError:
        pass
    # Unquoted scalar: drop an inline " # comment".
    return re.split(r"\s+#", text, maxsplit=1)[0].strip()


def parse_prompt_text(text: str, source: str = "<memory>") -> PromptDefinition:
    """Parse one prompt file's content."""
    normalized = text.lstrip("\ufeff").replace("\r\n", "\n").replace("\r", "\n")
    lines = normalized.split("\n")
    if not lines or lines[0].strip() != "---":
        raise PromptStoreError(f"{source}: 缺少 front-matter 起始行 '---'")
    try:
        end = next(i for i in range(1, len(lines)) if lines[i].strip() == "---")
    except StopIteration:
        raise PromptStoreError(f"{source}: front-matter 未以 '---' 结束") from None

    meta: Dict[str, Any] = {}
    for lineno, line in enumerate(lines[1:end], start=2):
        if not line.strip() or line.lstrip().startswith("#"):
            continue
        key, sep, value = line.partition(":")
        key = key.strip()
        if not sep or not key:
            raise PromptStoreError(f"{source}:{lineno}: 无法解析 front-matter 行 {line!r}")
        if key not in _ALLOWED_KEYS:
            raise PromptStoreError(f"{source}:{lineno}: 未知的 front-matter 键 {key!r}")
        if key in meta:
            raise PromptStoreError(f"{source}:{lineno}: front-matter 键重复 {key!r}")
        meta[key] = _parse_value(value)

    missing = [key for key in _REQUIRED_KEYS if key not in meta]
    if missing:
        raise PromptStoreError(f"{source}: 缺少必填键 {', '.join(missing)}")

    prompt_id = meta["id"]
    if not isinstance(prompt_id, str) or not prompt_id.strip():
        raise PromptStoreError(f"{source}: id 必须是非空字符串")
    for key in ("title", "group"):
        if not isinstance(meta[key], str) or not meta[key].strip():
            raise PromptStoreError(f"{source}: {key} 必须是非空字符串")
    if meta["origin"] not in _VALID_ORIGINS:
        raise PromptStoreError(f"{source}: origin 必须是 {_VALID_ORIGINS}")
    applies = meta["applies_to"]
    if (
        not isinstance(applies, list)
        or not applies
        or any(item not in _VALID_APPLIES for item in applies)
    ):
        raise PromptStoreError(f"{source}: applies_to 必须是 {_VALID_APPLIES} 的非空数组")
    editable = meta.get("editable", True)
    if not isinstance(editable, bool):
        raise PromptStoreError(f"{source}: editable 必须是 true/false")
    version = meta.get("version", 1)
    if not isinstance(version, int) or isinstance(version, bool) or version < 1:
        raise PromptStoreError(f"{source}: version 必须是 >= 1 的整数")
    declared = meta.get("placeholders", [])
    if not isinstance(declared, list) or any(not isinstance(item, str) for item in declared):
        raise PromptStoreError(f"{source}: placeholders 必须是字符串数组")
    unknown = sorted(set(declared) - KNOWN_PLACEHOLDERS)
    if unknown:
        raise PromptStoreError(f"{source}: 未登记的占位符 {', '.join(unknown)}")

    body = "\n".join(lines[end + 1:]).strip("\n")
    if not body.strip():
        raise PromptStoreError(f"{source}: 正文为空")
    used = set(_PLACEHOLDER_RE.findall(body))
    undeclared = sorted(used - set(declared))
    if undeclared:
        raise PromptStoreError(f"{source}: 正文使用了未声明的占位符 {', '.join(undeclared)}")
    unused = sorted(set(declared) - used)
    if unused:
        raise PromptStoreError(f"{source}: 声明了但正文未使用的占位符 {', '.join(unused)}")

    return PromptDefinition(
        id=prompt_id.strip(),
        title=meta["title"].strip(),
        group=meta["group"].strip(),
        builtin=body,
        origin=meta["origin"],
        applies_to=tuple(applies),
        editable=editable,
        version=version,
        placeholders=tuple(declared),
    )


def load_all(prompts_dir: Optional[Path] = None) -> Dict[str, PromptDefinition]:
    """Load every ``*.md`` prompt under ``prompts_dir`` (``README.md`` is skipped)."""
    root = Path(prompts_dir) if prompts_dir is not None else PROMPTS_DIR
    if not root.is_dir():
        raise PromptStoreError(f"提示词目录不存在: {root}")
    files = sorted(
        path for path in root.rglob("*.md") if path.name.lower() != "readme.md"
    )
    if not files:
        raise PromptStoreError(f"提示词目录中没有任何 .md 文件: {root}")
    definitions: Dict[str, PromptDefinition] = {}
    sources: Dict[str, Path] = {}
    for path in files:
        try:
            text = path.read_text(encoding="utf-8")
        except (OSError, UnicodeDecodeError) as exc:
            raise PromptStoreError(f"{path}: 读取失败: {exc}") from exc
        definition = parse_prompt_text(text, source=str(path))
        if definition.id in definitions:
            raise PromptStoreError(
                f"提示词 id 重复: {definition.id}（{sources[definition.id]} 与 {path}）"
            )
        definitions[definition.id] = definition
        sources[definition.id] = path
    return definitions
