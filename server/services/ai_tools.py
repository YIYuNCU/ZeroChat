"""
AI 工具定义与执行器
管理 AI 可调用的 function-calling 工具（定时任务、用户屏蔽等）
"""
import json
import logging
import random
import uuid
from datetime import datetime
from pathlib import Path
from typing import Dict, List, Optional

from services import scheduler_service

logger = logging.getLogger(__name__)

DATA_DIR = Path(__file__).parent.parent / "data"
TASKS_FILE = DATA_DIR / "tasks" / "scheduled.json"

# ========== 工具定义 ==========

"""
定时任务工具：允许 AI 在对话中主动创建定时提醒。
对所有场景开放（ZeroChat + OneBot）。
"""
_SCHEDULE_TASK_TOOL = [{
    "type": "function",
    "function": {
        "name": "schedule_task",
        "description": "创建一个定时提醒任务。当用户明确要求提醒、或你主动承诺在未来某时间做某事时，调用此函数创建定时任务。触发时间使用 ISO 8601 格式（24小时制），可指定重复模式（none/daily/weekly）。",
        "strict": True,
        "parameters": {
            "type": "object",
            "properties": {
                "message": {
                    "type": "string",
                    "description": "提醒内容，例如「该喝水了」「记得吃药」「检查邮件」等"
                },
                "trigger_time": {
                    "type": "string",
                    "description": "触发时间，ISO 8601 格式（例如 2026-05-08T14:30:00），需要使用 24 小时制。如果不确定具体日期，基于当前时间推算。"
                },
                "repeat": {
                    "type": "string",
                    "enum": ["none", "daily", "weekly"],
                    "description": "重复模式：none（单次）、daily（每天）、weekly（每周）"
                }
            },
            "required": ["message", "trigger_time", "repeat"],
            "additionalProperties": False,
        }
    }
}]

"""
系统闹钟/日历工具：允许 AI 请求在用户设备上设置系统闹钟或写入日历事件。
与 schedule_task 不同：schedule_task 是应用内的定时消息提醒；set_alarm 会
落到用户手机的系统闹钟 App 或系统日历，由客户端执行。仅对有设备的 ZeroChat 场景开放。
"""
_SET_ALARM_TOOL = [{
    "type": "function",
    "function": {
        "name": "set_alarm",
        "description": "在用户的设备上设置系统闹钟或写入日历事件。当用户明确要求「定个闹钟」「加到日历」「提醒我到点响铃」等需要落到手机系统的场景时调用。与 schedule_task（应用内提醒消息）不同，此工具作用于系统闹钟/日历。触发时间使用 ISO 8601 格式（24 小时制）。注意：这是向设备发起请求，用户可能拒绝权限，不保证一定成功。",
        "strict": True,
        "parameters": {
            "type": "object",
            "properties": {
                "title": {
                    "type": "string",
                    "description": "闹钟或日历事件的标题，例如「吃药」「开会」「起床」"
                },
                "trigger_time": {
                    "type": "string",
                    "description": "触发时间，ISO 8601 格式（例如 2026-05-08T14:30:00），24 小时制。基于当前时间推算。"
                },
                "kind": {
                    "type": "string",
                    "enum": ["alarm", "calendar_event"],
                    "description": "类型：alarm（系统闹钟，到点响铃）、calendar_event（日历事件）"
                },
                "note": {
                    "type": "string",
                    "description": "备注/说明，可留空字符串"
                }
            },
            "required": ["title", "trigger_time", "kind", "note"],
            "additionalProperties": False,
        }
    }
}]

"""
无回复续写工具：允许 AI 在说完话后设置一个「若用户在指定时长内没有回复就继续说」的计时器。
用户一旦回复，续写会自动取消。支持链式续写，但受角色配置的最大续写次数限制。
仅对有设备的 ZeroChat 场景开放。
"""
_CONTINUE_IF_NO_REPLY_TOOL = [{
    "type": "function",
    "function": {
        "name": "continue_if_no_reply",
        "description": "设置一个「无回复续写」计时器：当你说完话，并且希望在用户一段时间内没有回复时主动继续说、追问或补充（例如没等到回应就补一句「在吗」「刚才那个你怎么看」），调用此函数。用户一旦回复，续写会自动取消。可以在续写触发后再次调用形成链式跟进，但有最大次数限制，达到上限时请自然收尾、不要再调用。",
        "strict": True,
        "parameters": {
            "type": "object",
            "properties": {
                "delay_minutes": {
                    "type": "integer",
                    "description": "等待用户回复的时长（分钟）。超过这个时长用户仍未回复，就会触发你的续写。例如 3 表示等 3 分钟。"
                },
                "prompt": {
                    "type": "string",
                    "description": "续写触发时给你自己的提示，说明你想继续说什么、以什么心情追问，例如「用户还没回，关心地追问一下刚才提到的考试结果」"
                }
            },
            "required": ["delay_minutes", "prompt"],
            "additionalProperties": False,
        }
    }
}]

"""
屏蔽用户工具：允许 AI 屏蔽第三方用户的骚扰消息。
仅对 OneBot 第三方用户消息场景开放。
"""
_BLOCK_USER_TOOL = [{
    "type": "function",
    "function": {
        "name": "block_user",
        "description": "屏蔽当前群聊/私聊中某个用户的消息。当你觉得某个用户的行为令人不适、骚扰、刷屏、恶意攻击或伪装亲密对象时，需要调用此函数屏蔽该用户。不要因为正常的聊天分歧而屏蔽用户。",
        "strict": True,
        "parameters": {
            "type": "object",
            "properties": {
                "user_id": {
                    "type": "string",
                    "description": "要屏蔽的用户 QQ 号"
                },
                "reason": {
                    "type": "string",
                    "description": "屏蔽原因（简短说明）"
                }
            },
            "required": ["user_id", "reason"],
            "additionalProperties": False,
        }
    }
}]


# ========== 工具执行器 ==========

async def execute_schedule_task(role_data: Dict, message: str, trigger_time: str, repeat: str = "none") -> str:
    """创建定时任务，返回结果描述"""
    role_id = role_data.get("id", "")
    role_name = role_data.get("name", role_id)

    # 解析并验证时间
    try:
        run_time = datetime.fromisoformat(trigger_time)
        if run_time < datetime.now():
            return f"创建失败：触发时间 {trigger_time} 已过期，请选择未来的时间"
    except ValueError as e:
        return f"创建失败：时间格式无效（{e}），请使用 ISO 8601 格式"

    task_record = {
        "id": str(uuid.uuid4()),
        "chat_id": role_id,
        "role_id": role_id,
        "message": message,
        "ai_prompt": "",
        "trigger_time": run_time.isoformat(),
        "repeat": repeat if repeat != "none" else None,
        "enabled": True,
        "created_at": datetime.now().isoformat(),
    }

    try:
        TASKS_FILE.parent.mkdir(parents=True, exist_ok=True)
        tasks = []
        if TASKS_FILE.exists():
            with open(TASKS_FILE, "r", encoding="utf-8") as f:
                tasks = json.load(f)

        tasks.append(task_record)
        with open(TASKS_FILE, "w", encoding="utf-8") as f:
            json.dump(tasks, f, indent=2, ensure_ascii=False)

        scheduler_service.schedule_task(task_record)

        # 通知在线客户端立即刷新任务列表，使 AI 自建任务在设置页可见
        try:
            from transport.push_hub import publish_server_push
            await publish_server_push(
                "task_created",
                {
                    "role_id": role_id,
                    "chat_id": task_record["chat_id"],
                    "task_id": task_record["id"],
                },
            )
        except Exception as e:
            logger.debug(f"task_created 推送失败（不影响任务创建）: {e}")

        repeat_hint = "" if repeat == "none" else f"（重复：{repeat}）"
        logger.info(f"AI创建定时任务: role={role_name}({role_id}), time={trigger_time}, msg={message}{repeat_hint}")
        return f"定时任务已创建：在 {trigger_time} 提醒「{message}」{repeat_hint}"
    except Exception as e:
        return f"创建失败：{e}"


async def execute_set_alarm(
    role_data: Dict,
    title: str,
    trigger_time: str,
    kind: str = "alarm",
    note: str = "",
) -> str:
    """请求在用户设备上设置系统闹钟/日历事件，通过推送信令交由客户端执行。"""
    role_id = role_data.get("id", "")
    role_name = role_data.get("name", role_id)

    title = (title or "").strip()
    if not title:
        return "设置失败：标题为空"

    kind = (kind or "alarm").strip().lower()
    if kind not in ("alarm", "calendar_event"):
        kind = "alarm"

    # 解析并验证时间
    try:
        run_time = datetime.fromisoformat(trigger_time)
        if run_time < datetime.now():
            return f"设置失败：时间 {trigger_time} 已过期，请选择未来的时间"
    except ValueError as e:
        return f"设置失败：时间格式无效（{e}），请使用 ISO 8601 格式"

    try:
        from transport.push_hub import publish_server_push
        await publish_server_push(
            "device_alarm_request",
            {
                "role_id": role_id,
                "title": title,
                "trigger_time": run_time.isoformat(),
                "kind": kind,
                "note": (note or "").strip(),
            },
        )
    except Exception as e:
        logger.error(f"set_alarm 推送失败 role={role_id}: {e}")
        return f"设置失败：{e}"

    kind_hint = "系统闹钟" if kind == "alarm" else "日历事件"
    logger.info(
        f"AI设置{kind_hint}: role={role_name}({role_id}), time={trigger_time}, title={title}"
    )
    return (
        f"已请求在设备上设置{kind_hint}：{title}（{trigger_time}）。"
        "若设备未授予权限，可能会降级为应用内提醒。"
    )


async def execute_continue_if_no_reply(
    role_data: Dict,
    delay_minutes: int,
    prompt: str,
) -> str:
    """登记「无回复续写」计时器，返回结果描述。"""
    role_id = role_data.get("id", "")
    role_name = role_data.get("name", role_id)

    # 校验时长
    try:
        delay = int(delay_minutes)
    except (TypeError, ValueError):
        return "设置失败：delay_minutes 必须是整数分钟数"
    if delay < 1:
        return "设置失败：delay_minutes 至少为 1 分钟"

    prompt = (prompt or "").strip()
    if not prompt:
        return "设置失败：prompt 不能为空，请说明续写时想继续说什么"

    # 读取角色续写配置
    profile_file = DATA_DIR / "roles" / role_id / "profile.json"
    followup_config = {}
    try:
        if profile_file.exists():
            with open(profile_file, "r", encoding="utf-8") as f:
                role_content = json.load(f)
            followup_config = role_content.get("followup_config") or {}
    except Exception as e:
        logger.warning(f"读取续写配置失败 role={role_id}: {e}")

    if not followup_config.get("enabled", True):
        return "该角色未启用「无回复续写」功能，无法设置"

    max_chain = max(1, int(followup_config.get("max_chain", 3)))

    from services import scheduler_service

    # 当前链计数：已排程状态中的 chain_count（无则 0）
    current_state = scheduler_service._load_followups().get(role_id) or {}
    current_chain = int(current_state.get("chain_count", 0))
    if current_chain >= max_chain:
        return (
            f"已达到最大续写次数（{max_chain} 次），无法继续安排跟进，"
            "请自然收尾，不要再等待用户回复。"
        )

    next_chain = current_chain + 1
    try:
        scheduler_service.schedule_followup(
            role_id,
            delay_minutes=delay,
            prompt=prompt,
            chain_count=next_chain,
            chat_id=role_id,
        )
    except Exception as e:
        logger.error(f"continue_if_no_reply 排程失败 role={role_id}: {e}")
        return f"设置失败：{e}"

    logger.info(
        f"AI设置无回复续写: role={role_name}({role_id}), delay={delay}min, "
        f"chain={next_chain}/{max_chain}"
    )
    remaining = max_chain - next_chain
    tail = "（这已是最后一次跟进）" if remaining <= 0 else ""
    return f"已设置：若 {delay} 分钟内用户未回复，将继续跟进{tail}"


async def execute_block_user(role_data: Dict, user_id: str, reason: str) -> str:
    """屏蔽用户，返回结果描述"""
    role_id = role_data.get("id", "")
    profile_file = DATA_DIR / "roles" / role_id / "profile.json"

    try:
        with open(profile_file, "r", encoding="utf-8") as f:
            role_content = json.load(f)
        onebot_config = role_content.get("onebot_config") or {}
        blocked = onebot_config.get("blocked_users") or {}

        if user_id not in blocked:
            blocked[user_id] = []
        onebot_config["blocked_users"] = blocked
        role_content["onebot_config"] = onebot_config

        with open(profile_file, "w", encoding="utf-8") as f:
            json.dump(role_content, f, ensure_ascii=False, indent=2)

        role_name = role_data.get("name", role_id)
        logger.warning(f"AI主动屏蔽用户: role={role_name}({role_id}), target={user_id}, reason={reason}")
        return f"已屏蔽用户 {user_id}，原因：{reason}"
    except Exception as e:
        return f"屏蔽失败：{e}"


# ========== 工具：语义记忆搜索 ==========

"""
向量记忆搜索工具：允许 AI 主动搜索历史记忆中的对话内容。
对所有场景开放。
"""
_SEARCH_MEMORY_TOOL = [{
    "type": "function",
    "function": {
        "name": "search_memory",
        "description": "搜索长期记忆来回忆过去的对话。这是你唯一能准确想起用户说过什么的方法。当对话涉及之前讨论过的话题、用户提到的任何名字/事件/偏好/约定、或你怀疑当前话题与过去有关联时，必须立即调用此工具搜索相关记忆。宁可多搜一次，不可假装记得或模糊猜测。",
        "strict": True,
        "parameters": {
            "type": "object",
            "properties": {
                "query": {
                    "type": "string",
                    "description": "搜索关键词或问题，用自然语言描述你想查找的记忆内容，如'用户喜欢什么食物''之前关于旅行的对话'"
                }
            },
            "required": ["query"],
            "additionalProperties": False,
        }
    }
}]


async def execute_search_memory(role_data: Dict, query: str) -> str:
    """语义搜索历史记忆，返回结果描述"""
    role_id = role_data.get("id", "")
    query = query.strip()
    if not query:
        return "搜索失败：查询内容为空"

    from services.vector_memory import VectorMemoryStore
    from services.ai_service import generate_embedding

    try:
        store = VectorMemoryStore(role_id)
        if store.count() == 0:
            return "记忆库为空，暂未存储可搜索的历史记忆"

        result = await generate_embedding(query)
        if not result["success"] or not result["embedding"]:
            return f"记忆搜索失败：{result.get('error', '嵌入向量生成失败')}"

        results = store.search(result["embedding"], top_k=3, min_score=0.35)
        if not results:
            return f"未找到与「{query}」相关的历史记忆"

        lines = []
        for r in results:
            text = r.get("text", "")
            score = r.get("score", 0)
            source = r.get("source", "chat")
            occurred_at = r.get("timestamp") or "未知"
            recorded_at = r.get("created_at") or "未知"
            lines.append(
                f"- {text[:200]}（发生时间:{occurred_at}, "
                f"记录时间:{recorded_at}, 来源:{source}, 相关度:{score:.2f}）"
            )
        return "找到以下相关记忆：\n" + "\n".join(lines)
    except Exception as e:
        logger.error(f"语义记忆搜索失败 role={role_id}: {e}")
        return f"记忆搜索失败：{e}"


# ========== 工具：联网搜索 ==========

"""
联网搜索工具：允许 AI 主动联网搜索获取最新信息。
对所有场景开放。
"""
_WEB_SEARCH_TOOL = [{
    "type": "function",
    "function": {
        "name": "web_search",
        "description": "联网搜索获取最新信息。当你需要查找实时新闻、天气、价格、最新事件、产品信息等无法从记忆中获取的外部信息时，调用此工具。",
        "strict": True,
        "parameters": {
            "type": "object",
            "properties": {
                "query": {
                    "type": "string",
                    "description": "搜索关键词，简洁明确，例如'2026年上海天气''iPhone最新价格'"
                },
                "max_results": {
                    "type": "integer",
                    "description": "返回结果数量，通常为 3"
                }
            },
            "required": ["query", "max_results"],
            "additionalProperties": False,
        }
    }
}]


async def execute_web_search(role_data: Dict, query: str, max_results: int = 3) -> str:
    """执行联网搜索，返回结果描述"""
    from services.search_service import web_search, format_search_results

    query = query.strip()
    if not query:
        return "搜索失败：查询内容为空"

    try:
        results = await web_search(query, max_results=max_results)
        if not results:
            return f"未找到与「{query}」相关的搜索结果"
        return format_search_results(results)
    except Exception as e:
        logger.error(f"联网搜索失败: {e}")
        return f"搜索失败：{e}"


# ========== 工具：向量记忆写入 ==========

"""
向量记忆写入工具：允许 AI 主动将重要信息写入长期记忆。
对所有场景开放。
"""
_WRITE_MEMORY_TOOL = [{
    "type": "function",
    "function": {
        "name": "write_memory",
        "description": "将重要信息写入长期记忆。必须先综合当前内容、人物、事件结果、上下文和时间，生成简洁客观的记忆摘要，禁止直接复制整段聊天。只保存未来确实会用到的信息。",
        "strict": True,
        "parameters": {
            "type": "object",
            "properties": {
                "summary": {
                    "type": "string",
                    "description": "综合提炼后的记忆摘要，用完整、客观的陈述句说明人物、事件和结果，不要粘贴聊天原文"
                },
                "occurred_at": {
                    "type": "string",
                    "description": "事件发生时间，ISO 8601 格式。事件发生时间不明确时传空字符串，服务端会使用当前消息时间"
                }
            },
            "required": ["summary", "occurred_at"],
            "additionalProperties": False,
        }
    }
}]


# ========== 工具：识图 ==========

"""
识图工具：允许 AI 在用户发送图片时，自主决定是否识别图片、并指定识别的重点细节。
仅在「工具模式」识图（vision_mode=tool）且本次消息附带图片时对聊天模型开放。
"""
_RECOGNIZE_IMAGE_TOOL = [{
    "type": "function",
    "function": {
        "name": "recognize_image",
        "description": "识别并理解用户本次发来的图片内容。本工具被提供时，说明本次消息附带图片；你必须在回复前调用一次。可以通过 focus 说明你想重点关注的细节（例如「图片里的文字」「人物的表情」「场景氛围」）。",
        "strict": True,
        "parameters": {
            "type": "object",
            "properties": {
                "focus": {
                    "type": "string",
                    "description": "你想重点识别的细节要求，用自然语言描述，例如「重点识别图中的文字内容」「描述人物的穿着和表情」。留空则做整体描述。"
                },
                "image_index": {
                    "type": "integer",
                    "description": "要识别第几张图片（从 0 开始）。通常只有一张图片时传 0。"
                }
            },
            "required": ["focus", "image_index"],
            "additionalProperties": False,
        }
    }
}]

_REVIEW_PREVIOUS_IMAGES_TOOL = [{
    "type": "function",
    "function": {
        "name": "review_previous_images",
        "description": "重新获取用户在同一会话上一批发送的原始图片，并使用本次提供的新提示词重新进行视觉识别。用户提及刚才、上一张、之前那几张图片，且需要重新确认或以不同问题识别图片时调用。不能用于查看其他会话或更早批次的图片。",
        "strict": True,
        "parameters": {
            "type": "object",
            "properties": {
                "prompt": {
                    "type": "string",
                    "description": "用于本次重新识图的完整提示词，明确说明需要从图片中识别什么；不使用之前的识图结果。"
                },
                "image_index": {
                    "type": "integer",
                    "description": "上一批图片中的索引，从 0 开始。"
                }
            },
            "required": ["prompt", "image_index"],
            "additionalProperties": False,
        }
    }
}]


async def execute_recognize_image(
    image_data_urls: List[str],
    focus: str = "",
    image_index: int = 0,
) -> str:
    """识别指定图片的内容，返回识别文本。失败/无配置时返回友好错误串（不抛异常）。

    image_data_urls: 本次消息携带的图片 data URL 列表（为将来多图预留，当前通常只有一张）。
    """
    from services import vision_service

    if not image_data_urls:
        return "识图失败：本次没有可识别的图片"

    # 越界回退到第 0 张
    idx = image_index if isinstance(image_index, int) else 0
    if idx < 0 or idx >= len(image_data_urls):
        idx = 0
    image_data_url = image_data_urls[idx]

    vision_cfg = vision_service.resolve_vision_config()
    api_url = vision_cfg.get("api_url", "")
    api_key = vision_cfg.get("api_key", "")
    model = vision_cfg.get("model", "gpt-4o")
    if not api_url or not api_key:
        return "识图失败：未配置识图模型（Vision API）"

    prompt = (focus or "").strip() or "请描述这张图片的关键内容"
    messages = vision_service.build_vision_messages(image_data_url, prompt)
    body = {
        "model": model,
        "messages": messages,
        "max_tokens": 1024,
    }
    try:
        result = await vision_service.call_vision_api(api_url, api_key, body)
        if not result:
            return "识图失败：识图模型未返回内容，请稍后重试"
        return result
    except Exception as e:
        logger.error(f"识图工具执行失败: {e}")
        return f"识图失败：{e}"


async def execute_write_memory(
    role_data: Dict,
    summary: str,
    occurred_at: Optional[str] = None,
) -> str:
    """将 AI 综合后的重要信息与发生时间写入向量记忆库。"""
    summary = summary.strip()
    if not summary:
        return "写入失败：记忆摘要为空"
    if len(summary) < 5:
        return "写入失败：记忆内容过短，请描述完整信息"

    raw_occurred_at = str(occurred_at or "").strip()
    if raw_occurred_at:
        try:
            parsed_time = datetime.fromisoformat(
                raw_occurred_at.replace("Z", "+00:00")
            )
            normalized_occurred_at = parsed_time.isoformat()
        except ValueError:
            return "写入失败：occurred_at 必须是 ISO 8601 时间"
    else:
        normalized_occurred_at = datetime.now().isoformat(timespec="seconds")

    role_id = role_data.get("id", "")
    from services.vector_memory import VectorMemoryStore
    from services.ai_service import generate_embedding

    try:
        result = await generate_embedding(summary)
        if not result["success"] or not result["embedding"]:
            err = result.get("error", "嵌入向量生成失败")
            logger.warning(
                "向量记忆写入失败：embedding 生成失败 role=%s source=ai_tool error=%s",
                role_id, err,
            )
            return f"记忆写入失败：{err}"

        store = VectorMemoryStore(role_id)
        store.store(
            text=summary,
            embedding=result["embedding"],
            role="assistant",
            timestamp=normalized_occurred_at,
            source="ai_tool",
        )
        logger.info(
            "AI主动写入记忆: role=%s, occurred_at=%s, summary=%s",
            role_id,
            normalized_occurred_at,
            summary[:80],
        )
        return f"已记住（发生时间：{normalized_occurred_at}）：{summary}"
    except Exception as e:
        logger.error(f"向量记忆写入失败 role={role_id}: {e}")
        return f"记忆写入失败：{e}"


# ========== 工具：情绪表情发送 ==========

"""
情绪表情工具：允许 AI 在对话中主动发送情绪表情贴图。
对所有场景开放。
"""
_SEND_EMOTION_EMOJI_TOOL = [{
    "type": "function",
    "function": {
        "name": "send_emotion_emoji",
        "description": "在回复中附加一个情绪表情贴图来表达你的感受。当你的回复带有明显情绪倾向时（开心、关心、难过、惊讶、困惑、疲惫、生气等），调用此工具发送对应的情绪表情。不需要每句话都用，选择有情绪表达的回复即可。",
        "strict": True,
        "parameters": {
            "type": "object",
            "properties": {
                "emotion": {
                    "type": "string",
                    "enum": ["happy", "sad", "angry", "surprised", "love", "confused", "excited", "tired"],
                    "description": "情绪标签，从以下中选择最匹配你当前回复情绪的标签：happy（开心）、sad（难过）、angry（生气）、surprised（惊讶）、love（爱意/撒娇）、confused（困惑）、excited（兴奋）、tired（疲惫）。例如回复搞笑的內容用 happy，表达关心用 love，听到好消息用 excited。"
                }
            },
            "required": ["emotion"],
            "additionalProperties": False,
        }
    }
}]


_IMAGE_EXTS = (".png", ".jpg", ".jpeg", ".gif", ".webp")

# 云端表情专用分类：不参与情绪随机抽取与情绪列举
CLOUD_EMOJI_CATEGORY = "__cloud__"


def _pick_emoji_file(role_id: str, emotion: str) -> Optional[Path]:
    """从角色的表情目录中随机选取一个表情文件，目录不存在或为空时返回 None"""
    if emotion == CLOUD_EMOJI_CATEGORY:
        return None
    emoji_dir = DATA_DIR / "roles" / role_id / "emojis" / emotion
    if not emoji_dir.exists() or not emoji_dir.is_dir():
        return None
    files = [f for f in emoji_dir.iterdir() if f.is_file() and f.suffix.lower() in _IMAGE_EXTS]
    return random.choice(files) if files else None


def _get_available_emotions(role_id: str) -> List[str]:
    """扫描角色可用的情绪类别（有图片文件的目录）"""
    emoji_root = DATA_DIR / "roles" / role_id / "emojis"
    if not emoji_root.exists():
        return []
    return [
        d.name for d in emoji_root.iterdir()
        if d.is_dir() and d.name != CLOUD_EMOJI_CATEGORY and any(
            f.is_file() and f.suffix.lower() in _IMAGE_EXTS for f in d.iterdir()
        )
    ]


async def execute_send_emotion_emoji(role_data: Dict, emotion: str) -> str:
    """发送情绪表情，返回结果描述"""
    role_id = role_data.get("id", "")
    emotion = emotion.strip().lower()
    if not emotion:
        return "发送失败：未指定情绪类型"

    if _pick_emoji_file(role_id, emotion) is not None:
        return f"[{emotion}]"

    # 目录不存在或为空时，提示可用情绪
    emoji_dir = DATA_DIR / "roles" / role_id / "emojis" / emotion
    available = _get_available_emotions(role_id)
    hint = f"，可用情绪: {', '.join(available)}" if available else ""
    if emoji_dir.exists() and emoji_dir.is_dir():
        return f"「{emotion}」表情目录为空，暂无可用表情图片{hint}"
    return f"没有找到「{emotion}」对应的表情包{hint}"
