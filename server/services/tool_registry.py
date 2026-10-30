"""Function-calling tool definitions whose text lives in ``server/prompts/tools/*.md``.

The schema skeleton (parameter names, types, enums) stays in code because it is coupled
to the executors. Everything the model reads – the tool description and each parameter
description – is stored in one prompt file per tool, ``id: tool.<name>``:

    <tool description>

    # 参数
    ## <parameter name>
    <parameter description>

Tool prompts are ``editable: false``: they are shipped with the code, never overridden by
settings, and never shown in the prompt editor. A tool whose file is missing, or whose
parameter sections do not match the code skeleton, fails at import time instead of being
sent to the model with a blank or stale description.
"""
from __future__ import annotations

import re
from functools import lru_cache
from typing import Any, Dict, List, Mapping, Tuple

from services import prompt_config_service

TOOL_PROMPT_PREFIX = "tool."
PARAMS_HEADING = "# 参数"
_PARAM_HEADING_RE = re.compile(r"^## (\S+)\s*$")


class ToolPromptError(RuntimeError):
    """Raised when a tool prompt file is missing, malformed or out of sync with the code."""


def tool_prompt_id(name: str) -> str:
    return f"{TOOL_PROMPT_PREFIX}{name}"


def parse_tool_text(body: str, source: str = "<memory>") -> Tuple[str, Dict[str, str]]:
    """Split a tool prompt body into ``(description, {parameter: description})``."""
    lines = body.replace("\r\n", "\n").split("\n")
    heading_at = next(
        (index for index, line in enumerate(lines) if line.strip() == PARAMS_HEADING), None
    )
    description_lines = lines if heading_at is None else lines[:heading_at]
    description = "\n".join(description_lines).strip()
    if not description:
        raise ToolPromptError(f"{source}: 工具描述为空")

    params: Dict[str, str] = {}
    if heading_at is not None:
        current = None
        buffer: List[str] = []

        def flush() -> None:
            if current is None:
                return
            text = "\n".join(buffer).strip()
            if not text:
                raise ToolPromptError(f"{source}: 参数 {current} 的描述为空")
            params[current] = text

        for line in lines[heading_at + 1:]:
            match = _PARAM_HEADING_RE.match(line)
            if match:
                flush()
                current = match.group(1)
                if current in params:
                    raise ToolPromptError(f"{source}: 参数 {current} 重复")
                buffer = []
            elif current is None:
                if line.strip():
                    raise ToolPromptError(f"{source}: '{PARAMS_HEADING}' 下的内容必须位于 '## 参数名' 之后")
            else:
                buffer.append(line)
        flush()
    return description, params


@lru_cache(maxsize=None)
def load_tool_text(name: str) -> Tuple[str, Dict[str, str]]:
    prompt_id = tool_prompt_id(name)
    definition = prompt_config_service.PROMPT_REGISTRY.get(prompt_id)
    if definition is None:
        raise ToolPromptError(f"缺少工具提示词 server/prompts/tools/{name}.md（id: {prompt_id}）")
    if definition.editable:
        raise ToolPromptError(f"{prompt_id}: 工具提示词必须声明 editable: false")
    return parse_tool_text(definition.builtin, source=prompt_id)


def build_tool(name: str, properties: Mapping[str, Mapping[str, Any]]) -> List[Dict[str, Any]]:
    """Build one strict function-calling tool.

    ``properties`` maps each parameter to its schema without the ``description``; the
    description is filled in from the tool's prompt file. All parameters are required, as
    strict mode demands.
    """
    description, texts = load_tool_text(name)
    missing = [key for key in properties if key not in texts]
    extra = [key for key in texts if key not in properties]
    if missing or extra:
        raise ToolPromptError(
            f"{tool_prompt_id(name)}: 参数与代码不一致"
            + (f"，提示词缺少 {', '.join(missing)}" if missing else "")
            + (f"，提示词多出 {', '.join(extra)}" if extra else "")
        )
    built: Dict[str, Dict[str, Any]] = {}
    for key, spec in properties.items():
        if "description" in spec:
            raise ToolPromptError(f"{tool_prompt_id(name)}: 参数 {key} 的描述应写在提示词文件里")
        built[key] = {**spec, "description": texts[key]}
    return [{
        "type": "function",
        "function": {
            "name": name,
            "description": description,
            "strict": True,
            "parameters": {
                "type": "object",
                "properties": built,
                "required": list(built),
                "additionalProperties": False,
            },
        },
    }]
