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
            "required": ["message", "trigger_time"]
        }
    }
}]

"""
主动回复开关工具：允许 AI 自主开启或关闭主动回复功能。
对所有场景开放。
"""
_SET_PROACTIVE_TOOL = [{
    "type": "function",
    "function": {
        "name": "set_proactive",
        "description": "开启或关闭主动回复功能。当你需要休息、不想被消息打扰时可以关闭它；当你想重新开始主动联系用户时可以开启它。只有在你确实想改变主动回复状态时才调用此工具。",
        "parameters": {
            "type": "object",
            "properties": {
                "enabled": {
                    "type": "boolean",
                    "description": "true 开启主动回复，false 关闭主动回复"
                },
                "reason": {
                    "type": "string",
                    "description": "开启或关闭的原因说明"
                }
            },
            "required": ["enabled"]
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
            "required": ["user_id", "reason"]
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

        repeat_hint = "" if repeat == "none" else f"（重复：{repeat}）"
        logger.info(f"AI创建定时任务: role={role_name}({role_id}), time={trigger_time}, msg={message}{repeat_hint}")
        return f"定时任务已创建：在 {trigger_time} 提醒「{message}」{repeat_hint}"
    except Exception as e:
        return f"创建失败：{e}"


async def execute_set_proactive(role_data: Dict, enabled: bool, reason: str = "") -> str:
    """开启/关闭主动回复，返回结果描述"""
    role_id = role_data.get("id", "")
    profile_file = DATA_DIR / "roles" / role_id / "profile.json"

    try:
        with open(profile_file, "r", encoding="utf-8") as f:
            role_content = json.load(f)

        # 服务端调度器 proactive_config
        proactive_config = role_content.setdefault("proactive_config", {})
        proactive_config["enabled"] = enabled

        # OneBot 主动回复配置（全部会话）
        onebot_config = role_content.get("onebot_config") or {}
        scenes = onebot_config.setdefault("proactive_config", {})
        for conv_key in scenes:
            scenes[conv_key]["enabled"] = enabled

        with open(profile_file, "w", encoding="utf-8") as f:
            json.dump(role_content, f, ensure_ascii=False, indent=2)

        from services import scheduler_service
        if enabled:
            scheduler_service.schedule_proactive_for_role(role_id, reset=True)
        else:
            scheduler_service.unschedule_proactive_for_role(role_id)

        action = "开启" if enabled else "关闭"
        reason_txt = f"，原因：{reason}" if reason else ""
        logger.info(f"AI主动{action}主动回复: role={role_id}{reason_txt}")
        return f"已{action}主动回复功能{reason_txt}"
    except Exception as e:
        logger.error(f"主动回复设置失败 role={role_id}: {e}")
        return f"操作失败：{e}"


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
        "parameters": {
            "type": "object",
            "properties": {
                "query": {
                    "type": "string",
                    "description": "搜索关键词或问题，用自然语言描述你想查找的记忆内容，如'用户喜欢什么食物''之前关于旅行的对话'"
                }
            },
            "required": ["query"]
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
        "parameters": {
            "type": "object",
            "properties": {
                "query": {
                    "type": "string",
                    "description": "搜索关键词，简洁明确，例如'2026年上海天气''iPhone最新价格'"
                },
                "max_results": {
                    "type": "integer",
                    "description": "返回结果数量，默认3",
                    "default": 3
                }
            },
            "required": ["query"]
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
        "parameters": {
            "type": "object",
            "properties": {
                "summary": {
                    "type": "string",
                    "description": "综合提炼后的记忆摘要，用完整、客观的陈述句说明人物、事件和结果，不要粘贴聊天原文"
                },
                "occurred_at": {
                    "type": "string",
                    "description": "事件发生时间，ISO 8601 格式。事件发生时间不明确时省略，服务端会使用当前消息时间"
                }
            },
            "required": ["summary"]
        }
    }
}]


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
            return f"记忆写入失败：{result.get('error', '嵌入向量生成失败')}"

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
        "parameters": {
            "type": "object",
            "properties": {
                "emotion": {
                    "type": "string",
                    "description": "情绪标签，从以下中选择最匹配你当前回复情绪的标签：happy（开心）、sad（难过）、angry（生气）、surprised（惊讶）、love（爱意/撒娇）、confused（困惑）、excited（兴奋）、tired（疲惫）。例如回复搞笑的內容用 happy，表达关心用 love，听到好消息用 excited。"
                }
            },
            "required": ["emotion"]
        }
    }
}]


_IMAGE_EXTS = (".png", ".jpg", ".jpeg", ".gif", ".webp")


def _pick_emoji_file(role_id: str, emotion: str) -> Optional[Path]:
    """从角色的表情目录中随机选取一个表情文件，目录不存在或为空时返回 None"""
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
        if d.is_dir() and any(
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
