"""按需暴露的工具组。

低频且体积大的工具（朋友圈、历史回顾）不在每次请求里都带完整定义，而是折叠成「工具组」：

* 用户消息命中组的关键词时，整组直接加入本轮工具列表；
* 否则只下发一个很小的 ``load_tools`` 工具，其描述里用一行话列出每个未暴露的组，
  告诉模型这些能力存在；模型需要时调用 ``load_tools(group)``，该组工具随即并入工具列表，
  在工具循环的下一轮即可调用（见 ``ai_service._handle_tool_calls``）。

状态放在 ContextVar 中，按请求（asyncio 任务）隔离；工具列表由调用方持有并原地修改，
因此工具循环里重复使用同一个 list 就能看到新加载的工具。
"""
from __future__ import annotations

import copy
import logging
from contextvars import ContextVar
from dataclasses import dataclass, field
from typing import Any, Dict, List, Optional, Sequence, Set

from services.ai_tools import _LOAD_TOOLS_TOOL

logger = logging.getLogger(__name__)

LOAD_TOOLS_NAME = "load_tools"


@dataclass(frozen=True)
class ToolGroup:
    name: str
    #: 一行话说明这组工具能做什么，会写进 load_tools 的描述。
    summary: str
    tools: tuple
    #: 用户消息包含任一关键词时整组直接暴露。
    keywords: tuple = ()


@dataclass
class _State:
    pending: Dict[str, ToolGroup] = field(default_factory=dict)
    loaded: Set[str] = field(default_factory=set)


_state: ContextVar[Optional[_State]] = ContextVar("zerochat_tool_groups", default=None)

MOMENTS_KEYWORDS = ("朋友圈", "发圈", "点赞", "点个赞", "评论区")
RECALL_KEYWORDS = (
    "聊过", "说过", "聊了什么", "聊了啥", "说了什么", "说了啥", "还记得", "记不记得",
    "聊天记录", "回顾", "刚才大家", "刚刚大家", "上次",
)


def _tool_names(tools: Sequence[Dict[str, Any]]) -> List[str]:
    return [t["function"]["name"] for t in tools]


def moments_group() -> ToolGroup:
    from services.ai_tools import (
        _COMMENT_MOMENT_TOOL,
        _LIKE_MOMENT_TOOL,
        _POST_MOMENT_TOOL,
        _VIEW_MOMENT_COMMENTS_TOOL,
        _VIEW_MOMENTS_TOOL,
    )

    return ToolGroup(
        name="moments",
        summary="朋友圈：查看动态与评论点赞、发布朋友圈、评论或回复、点赞",
        tools=(
            *_VIEW_MOMENTS_TOOL, *_VIEW_MOMENT_COMMENTS_TOOL,
            *_POST_MOMENT_TOOL, *_COMMENT_MOMENT_TOOL, *_LIKE_MOMENT_TOOL,
        ),
        keywords=MOMENTS_KEYWORDS,
    )


def recall_group(recall_tools: Sequence[Dict[str, Any]]) -> Optional[ToolGroup]:
    """把当前场景可用的历史回顾工具折叠成一组；没有可用工具时返回 None。"""
    summaries = {
        "recall_chat_history": "按时间或事件回看与用户的历史聊天",
        "recall_onebot_messages": "回看当前 QQ 会话（群聊或私聊）最近的消息",
    }
    names = _tool_names(recall_tools)
    if not names:
        return None
    parts = [summaries[n] for n in names if n in summaries]
    return ToolGroup(
        name="recall",
        summary="历史回顾：" + "；".join(parts),
        tools=tuple(recall_tools),
        keywords=RECALL_KEYWORDS,
    )


def _build_loader(pending: Dict[str, ToolGroup]) -> Dict[str, Any]:
    tool = copy.deepcopy(_LOAD_TOOLS_TOOL[0])
    function = tool["function"]
    lines = "\n".join(f"- {group.name}：{group.summary}" for group in pending.values())
    function["description"] = f"{function['description']}\n{lines}"
    function["parameters"]["properties"]["group"]["enum"] = list(pending)
    return tool


def _sync_loader(tools: List[Dict[str, Any]], state: _State) -> None:
    """让 tools 里的 load_tools 与未加载的组保持一致；没有未加载的组时移除它。"""
    index = next(
        (i for i, t in enumerate(tools) if t["function"]["name"] == LOAD_TOOLS_NAME), None,
    )
    if not state.pending:
        if index is not None:
            del tools[index]
        return
    loader = _build_loader(state.pending)
    if index is None:
        tools.append(loader)
    else:
        tools[index] = loader


def offer_groups(
    tools: List[Dict[str, Any]], groups: Sequence[ToolGroup], user_message: str,
) -> None:
    """按用户消息决定每组是直接并入 tools，还是折叠到 load_tools 之后。"""
    state = _State()
    message = str(user_message or "")
    existing = set(_tool_names(tools))
    for group in groups:
        if any(word in message for word in group.keywords):
            tools.extend(t for t in group.tools if t["function"]["name"] not in existing)
            state.loaded.add(group.name)
        else:
            state.pending[group.name] = group
    _sync_loader(tools, state)
    _state.set(state)


def execute_load_tools(tools: Optional[List[Dict[str, Any]]], group: str) -> str:
    """加载一组工具并返回给模型的结果描述。永不抛出。"""
    state = _state.get()
    key = str(group or "").strip().lower()
    if tools is None or state is None:
        return "加载失败：当前没有可加载的工具组"
    if key in state.loaded:
        return f"「{key}」工具组已经可用，直接调用其中的工具即可"
    target = state.pending.get(key)
    if target is None:
        available = "、".join(state.pending) or "无"
        return f"加载失败：没有名为「{group}」的工具组。当前可加载：{available}"

    existing = set(_tool_names(tools))
    added = [t for t in target.tools if t["function"]["name"] not in existing]
    tools.extend(added)
    del state.pending[key]
    state.loaded.add(key)
    _sync_loader(tools, state)
    names = "、".join(_tool_names(target.tools))
    logger.info("按需加载工具组 %s: %s", key, names)
    return f"已加载「{key}」工具组，现在可以直接调用：{names}"
