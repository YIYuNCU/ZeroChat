"""
AI 工具定义与执行器
管理 AI 可调用的 function-calling 工具（定时任务、用户屏蔽等）
"""
import json
import logging
import uuid
from datetime import datetime
from pathlib import Path
from typing import Dict

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
        "description": "创建一个定时提醒任务。当你想在未来的某个时间提醒自己或用户做某件事时，调用此函数创建定时任务。时间到达后你会收到通知并执行该任务。",
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
