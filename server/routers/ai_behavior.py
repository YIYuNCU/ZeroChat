"""
AI 行为统一入口
处理所有 AI 事件：聊天、主动消息、定时任务、朋友圈
"""
import asyncio
import functools
import json
import logging
import random
import re
import shutil
import uuid
from datetime import datetime
from enum import Enum
from pathlib import Path
from typing import Optional, List, Dict, Any
from pydantic import BaseModel
from fastapi import APIRouter, HTTPException

from core.utils import is_tool_role_id, atomic_write_json, load_moments_posts
from services.memory_service import trigger_memory_summary

logger = logging.getLogger(__name__)

router = APIRouter()

DATA_DIR = Path(__file__).parent.parent / "data"
ROLES_DIR = DATA_DIR / "roles"
MOMENTS_FILE = DATA_DIR / "moments" / "posts.json"
VISION_UPLOADS_DIR = DATA_DIR / "vision"

# ========== 数据模型 ==========

class AIEventType(str, Enum):
    CHAT = "chat"              # 用户聊天消息
    TASK = "task"              # 定时任务触发
    PROACTIVE = "proactive"    # 主动消息
    FOLLOWUP = "followup"      # 无回复续写
    MOMENT_POST = "moment"     # 发朋友圈
    MOMENT_COMMENT = "comment" # 朋友圈评论
    MEMORY_SUMMARIZATION = "memory_summarization"  # 记忆总结

class AIEvent(BaseModel):
    role_id: str
    event_type: AIEventType
    content: Optional[str] = ""
    context: Optional[Dict[str, Any]] = {}

class AIResponse(BaseModel):
    success: bool
    action: Optional[str] = None      # reply / ignore / post / comment
    content: Optional[str] = None
    error: Optional[str] = None
    metadata: Optional[Dict] = {}


class IntentDetectRequest(BaseModel):
    message: str
    api_url: Optional[str] = None
    api_key: Optional[str] = None
    model: Optional[str] = None


class IntentDetectResponse(BaseModel):
    success: bool
    intent: str = "normal_chat"
    extracted_content: Optional[str] = None
    duration_seconds: Optional[int] = None
    start_hour: Optional[int] = None
    end_hour: Optional[int] = None
    confidence: float = 0.8
    error: Optional[str] = None

# ========== 辅助函数 ==========

# ========== 角色缓存 ==========
_ROLE_CACHE: Dict[str, tuple] = {}  # role_id -> (data, timestamp)
_ROLE_CACHE_TTL = 2.0  # 缓存有效期（秒）


def invalidate_role_cache(role_id: Optional[str] = None):
    """使角色缓存失效"""
    if role_id:
        _ROLE_CACHE.pop(role_id, None)
    else:
        _ROLE_CACHE.clear()


def load_role(role_id: str) -> Optional[Dict]:
    cached = _ROLE_CACHE.get(role_id)
    if cached:
        from time import time
        data, ts = cached
        if (time() - ts) < _ROLE_CACHE_TTL:
            return data

    profile_file = ROLES_DIR / role_id / "profile.json"
    if profile_file.exists():
        with open(profile_file, "r", encoding="utf-8") as f:
            data = json.load(f)
            from time import time
            _ROLE_CACHE[role_id] = (data, time())
            return data
    return None


def _load_role_no_cache(role_id: str) -> Optional[Dict]:
    """强制从磁盘读取（绕过缓存）"""
    profile_file = ROLES_DIR / role_id / "profile.json"
    if profile_file.exists():
        with open(profile_file, "r", encoding="utf-8") as f:
            return json.load(f)
    return None


def _normalize_history_items(raw_history: Any) -> List[Dict[str, str]]:
    normalized: List[Dict[str, str]] = []
    if not isinstance(raw_history, list):
        return normalized

    for item in raw_history:
        if not isinstance(item, dict):
            continue
        role = str(item.get("role") or "user")
        content = str(item.get("content") or "")
        if not content:
            continue
        normalized.append({"role": role, "content": content})

    return normalized


def _normalize_core_memory_list(raw_core_memory: Any) -> List[str]:
    if not isinstance(raw_core_memory, list):
        return []
    result: List[str] = []
    for item in raw_core_memory:
        if item is None:
            continue
        text = str(item).strip()
        if text:
            result.append(text)
    return result


def _sanitize_reply_content(reply: Any) -> str:
    """Extract displayable AI content from provider-specific response wrappers."""
    text = str(reply or "").strip()
    if not text:
        return ""

    # 兼容层：AI 可能返回带 message/time/origin/sender 的 JSON 字符串
    from services.json_parse import extract_json_object

    parsed = extract_json_object(text)
    if parsed is not None:
        msg = parsed.get("message")
        if msg is not None:
            return _normalize_reply_tags(_normalize_reply_newlines(str(msg)).strip())

    normalized = _normalize_reply_newlines(text).replace("：", ":")
    lines = [line.rstrip() for line in normalized.splitlines()]
    message_idx = -1
    for idx, line in enumerate(lines):
        if line.strip().lower().startswith("message:"):
            message_idx = idx
            break

    if message_idx >= 0:
        first = re.sub(r"(?i)^\s*message\s*:\s*", "", lines[message_idx]).strip()
        parts = [first] if first else []
        for line in lines[message_idx + 1:]:
            low = line.strip().lower()
            if low.startswith("time:") or low.startswith("origin:") or low.startswith("sender:"):
                break
            local = line.strip()
            if local:
                parts.append(local)
        if parts:
            return _normalize_reply_tags("\n".join(parts).strip())

    return _normalize_reply_tags(normalized)


def _normalize_reply_newlines(text: str) -> str:
    """Convert the model's literal /n line-break typo to a real newline."""
    return re.sub(r"(?:\\\\n|/n)(?=\s*<)", "\n", text)


def _normalize_reply_tags(text: str) -> str:
    """把 AI 回复里的英文/别名结构标签归一化为中文规范标签。

    使别名标签（如 <message>/<action>）在入库和后续解析（数值块、无回复判断）
    时也能被正确识别，避免连同字面量泄漏到客户端。
    """
    from services.message_format import normalize_tags

    return normalize_tags(text)


def _load_moments_posts() -> List[Dict[str, Any]]:
    return load_moments_posts(MOMENTS_FILE)


def _load_moments_hint_state(role_id: str) -> Dict[str, Any]:
    """加载朋友圈已提示状态，避免重复注入相同内容。
    结构：{
        "hinted_no_reply_post_ids": [...],  # AI帖子已提示"用户未回复"的帖子ID
        "hinted_user_post_ids": [...]       # 用户帖子已注入过的帖子ID
    }
    """
    state_file = ROLES_DIR / role_id / "moments" / "moments_hint_state.json"
    if state_file.exists():
        try:
            logger.debug("加载朋友圈提示状态：角色 %s 的状态文件已找到，正在加载...", role_id)
            with open(state_file, "r", encoding="utf-8") as f:
                data = json.load(f)
            if isinstance(data, dict):
                return data
        except Exception as e:
            logger.warning("加载朋友圈提示状态失败: %s", e)
    return {"hinted_no_reply_post_ids": [], "hinted_user_post_ids": []}


def _save_moments_hint_state(role_id: str, state: Dict[str, Any]) -> None:
    state_file = ROLES_DIR / role_id / "moments" / "moments_hint_state.json"
    try:
        logger.debug(
            "保存朋友圈提示状态：角色 %s 的状态已更新，no_reply=%s user=%s",
            role_id,
            state.get("hinted_no_reply_post_ids"),
            state.get("hinted_user_post_ids"),
        )
        atomic_write_json(state_file, state)
    except Exception as e:
        logger.warning("保存朋友圈提示状态失败: %s", e)


def _build_moments_chat_context(role_id: str, max_items: int = 4) -> str:
    posts = _load_moments_posts()
    if not posts:
        return ""

    today_str = datetime.now().strftime("%Y-%m-%d")
    hint_state = _load_moments_hint_state(role_id)
    hinted_no_reply: List[str] = hint_state.get("hinted_no_reply_post_ids") or []
    hinted_user: List[str] = hint_state.get("hinted_user_post_ids") or []
    state_dirty = False

    role_posts = [
        p for p in posts
        if str(p.get("author_id", "")) == role_id
        and str(p.get("created_at", "")).startswith(today_str)
    ]
    role_posts.sort(key=lambda x: x.get("created_at", ""), reverse=True)
    role_posts = role_posts[:1]  # 仅取当天最后一条

    role_post_lines: List[str] = []
    for post in role_posts:
        post_content = str(post.get("content", "")).strip()
        if not post_content:
            continue
        post_id = str(post.get("id", "")).strip() or post_content[:40]
        comments = post.get("comments") if isinstance(post.get("comments"), list) else []

        user_comments = [
            c for c in comments
            if isinstance(c, dict) and str(c.get("author_id", "")) == "me"
        ]

        if user_comments:
            # 有用户回复：总是注入，并从已提示列表中移除（允许再次提示"无回复"如果回复被删除）
            if post_id in hinted_no_reply:
                hinted_no_reply.remove(post_id)
                state_dirty = True
            for c in user_comments:
                user_comment = str(c.get("content", "")).strip()
                if user_comment:
                    role_post_lines.append(
                        f"- 你的朋友圈:「{post_content[:80]}」用户回复了:「{user_comment[:80]}」(请结合此内容进行回应)"
                    )
        else:
            # 无用户回复：仅提示一次
            if post_id not in hinted_no_reply:
                role_post_lines.append(
                    f"- 你今天发了朋友圈:「{post_content[:80]}」，用户还没有查看或回复，可以适当提及，询问对方是否看到了"
                )
                hinted_no_reply.append(post_id)
                state_dirty = True

    user_posts = [
        p for p in posts
        if str(p.get("author_id", "")) == "me"
        and str(p.get("created_at", "")).startswith(today_str)
    ]
    user_posts.sort(key=lambda x: x.get("created_at", ""), reverse=True)
    user_posts = user_posts[:1]  # 仅取当天最后一条

    user_moments_lines: List[str] = []
    for p in user_posts:
        content = str(p.get("content", "")).strip()
        if not content:
            continue
        post_id = str(p.get("id", "")).strip() or content[:40]
        if post_id not in hinted_user:
            user_moments_lines.append(f"- 用户朋友圈:「{content[:80]}」")
            hinted_user.append(post_id)
            state_dirty = True

    if state_dirty:
        _save_moments_hint_state(role_id, {
            "hinted_no_reply_post_ids": hinted_no_reply,
            "hinted_user_post_ids": hinted_user,
        })

    parts: List[str] = []
    if role_post_lines:
        parts.append("[朋友圈上下文]\n" + "\n".join(role_post_lines))
    if user_moments_lines:
        parts.append("[用户近期朋友圈]\n" + "\n".join(user_moments_lines))

    return "\n\n".join(parts).strip()


def _get_available_emoji_categories(role_id: str) -> List[str]:
    """Scan role emoji folders and return categories that contain at least one image."""
    emoji_root = ROLES_DIR / role_id / "emojis"
    if not emoji_root.exists() or not emoji_root.is_dir():
        return []

    image_extensions = {".png", ".jpg", ".jpeg", ".gif", ".webp"}
    categories: List[str] = []

    for category_dir in emoji_root.iterdir():
        if not category_dir.is_dir():
            continue
        has_image = any(
            f.is_file() and f.suffix.lower() in image_extensions
            for f in category_dir.iterdir()
        )
        if has_image:
            category_name = category_dir.name.strip()
            if category_name:
                categories.append(category_name)

    # Keep stable order and avoid duplicates caused by inconsistent folder naming.
    return sorted(set(categories))

async def detect_emotion_and_get_emoji(role_id: str,worker_id:str, text: str) -> Optional[str]:
    """
    检测文本情绪并返回对应表情包路径
    
    表情包目录结构: roles/{role_id}/emojis/{emotion}/
    支持的情绪: happy, sad, angry, suprised, love, confused, excited, tired
    """
    rand = random.random()
    if rand > 0.25:  # 75% 概率跳过情绪检测
        logger.debug("情绪检测随机跳过：%.2f > 0.25", rand)
        return None
    from services.ai_service import call_ai_direct

    role_data = load_role(worker_id) or {}
    model = role_data.get("ai_model")
    api_url = role_data.get("ai_api_url")
    api_key = role_data.get("ai_api_key")
    temperature = role_data.get("ai_temperature", 0.1)
    if not model or not api_url or not api_key:
        return None

    configured_categories = _get_available_emoji_categories(role_id)
    fallback_categories = ["happy", "sad", "angry", "surprised", "love", "confused", "excited", "tired"]
    candidate_categories = configured_categories if configured_categories else fallback_categories
    category_text = ", ".join(candidate_categories)

    system_prompt = role_data.get("system_prompt", "")
    emotion_prompt = (
        f"你是情绪分类器。根据给定文本判断最主要的情绪。\n可选标签: {category_text}, none。\n"
        "要求: 只输出一个标签, 不要解释, 不要多余文本。\n如果没有明显情绪, 输出 none。"
    )
    messages = [{"role": "system", "content": emotion_prompt}]
    messages.append({"role": "user", "content": text})

    result = await call_ai_direct(
        messages=messages,
        model=model,
        api_url=api_url,
        api_key=api_key,
        temperature=temperature
    )
    if not result.get("success"):
        return None

    raw_detected = (result.get("content") or "").strip().lower()
    detected_emotion = (raw_detected.split()[0] if raw_detected else "").strip("`'\"[](){}<>.,，。!！?？:：;；")

    category_map = {c.lower(): c for c in candidate_categories}
    if detected_emotion == "none" or detected_emotion not in category_map:
        return None

    selected_category = category_map[detected_emotion]

    # 检查对应表情包目录
    emoji_dir = ROLES_DIR / role_id / "emojis" / selected_category
    if not emoji_dir.exists():
        return None
    
    # 获取目录中的图片文件
    image_extensions = (".png", ".jpg", ".jpeg", ".gif", ".webp")
    emoji_files = [f for f in emoji_dir.iterdir() if f.suffix.lower() in image_extensions]
    
    if not emoji_files:
        return None
    
    # 随机选择一个
    selected = random.choice(emoji_files)
    return selected_category
    # return f"/api/emojis/{role_id}/{selected_category}/{selected.name}"

# ========== 统一入口 ==========

@router.post("/ai/event", response_model=AIResponse)
async def handle_ai_event(event: AIEvent):
    """
    AI 行为统一入口
    
    根据事件类型分发处理
    """
    role = load_role(event.role_id)
    if not role:
        raise HTTPException(status_code=404, detail="角色不存在")
    if is_tool_role_id(event.role_id):
        return AIResponse(success=False, action="ignore", error="工具角色不处理对话/朋友圈事件")
    # 根据事件类型分发
    if event.event_type == AIEventType.CHAT:
        return await handle_chat(role, event)
    elif event.event_type == AIEventType.PROACTIVE:
        return await handle_proactive(role, event)
    elif event.event_type == AIEventType.FOLLOWUP:
        return await handle_followup(role, event)
    elif event.event_type == AIEventType.TASK:
        return await handle_task(role, event)
    elif event.event_type == AIEventType.MOMENT_POST:
        return await handle_moment_post(role, event)
    elif event.event_type == AIEventType.MOMENT_COMMENT:
        return await handle_moment_comment(role, event)
    elif event.event_type == AIEventType.MEMORY_SUMMARIZATION:
        pass  # 记忆总结目前没有单独触发入口，由聊天处理流程内触发
    else:
        return AIResponse(success=False, error="未知事件类型")


@router.post("/ai/intent", response_model=IntentDetectResponse)
async def detect_intent(request: IntentDetectRequest):
    """通过后端代理进行意图识别"""
    from services import settings_service

    system_prompt = """
你是一个意图分类器。根据用户输入，返回一个 JSON 对象，格式如下：
{
  "intent": "normal_chat" | "set_memory" | "set_reminder" | "set_quiet_time",
  "extracted_content": "提取的关键内容",
  "duration_seconds": 数字（仅提醒类有效）, 
  "start_hour": 数字（仅安静时间有效）, 
  "end_hour": 数字（仅安静时间有效）, 
  "confidence": 0.0-1.0
}

意图说明：
- normal_chat: 普通聊天对话
- set_memory: 用户希望你记住某些信息，如"记住我喜欢猫"
- set_reminder: 用户希望设置提醒，如"10分钟后提醒我喝水"
- set_quiet_time: 用户希望设置免打扰时间，如"晚上11点到早上7点不要打扰我"
- clear_memory: 用户希望清除之前的记忆

只返回 JSON，不要其他内容。
""".strip()

    try:
      local_message = (request.message or "").strip()
      if not local_message:
          return IntentDetectResponse(success=False, error="message is empty")

      ai_config = settings_service.get_ai_config()
      api_url = request.api_url or ai_config.get("api_url")
      api_key = request.api_key or ai_config.get("api_key")
      model = request.model or ai_config.get("model") or "deepseek-chat"

      if not api_url or not api_key:
          return IntentDetectResponse(success=False, error="AI API 未配置")

      from services.json_parse import call_ai_json

      result = await call_ai_json(
          messages=[
              {"role": "system", "content": system_prompt},
              {"role": "user", "content": local_message},
          ],
          api_url=api_url,
          api_key=api_key,
          model=model,
          temperature=0.1,
          max_tokens=200,
          direct=True,
      )

      if not result.get("success"):
          return IntentDetectResponse(
              success=False,
              error=result.get("error") or "intent classify failed",
          )

      parsed = result.get("data") or {}
      return IntentDetectResponse(
          success=True,
          intent=str(parsed.get("intent") or "normal_chat"),
          extracted_content=parsed.get("extracted_content"),
          duration_seconds=parsed.get("duration_seconds"),
          start_hour=parsed.get("start_hour"),
          end_hour=parsed.get("end_hour"),
          confidence=float(parsed.get("confidence") or 0.8),
      )
    except Exception as exc:
      return IntentDetectResponse(success=False, error=str(exc))

# ========== 聊天处理 ==========

async def _run_memory_ai_pipeline(
    role: Dict,
    role_id: str,
    user_message: str,
    event_context: Optional[Dict[str, Any]] = None,
    extra_parts: Optional[List[str]] = None,
    task_id: Optional[str] = None,
    request_id: Optional[str] = None,
    attached_json: Optional[str] = None,
    origin: str = "zerochat",
    user_sender: str = "user",
    sender_id: str = "",
    group_id: str = "",
    include_user_memory: bool = True,
    include_assistant_memory: bool = True,
    trigger_summary_after_reply: bool = True,
    vision_context: Optional[Dict[str, Any]] = None,
) -> Dict[str, Any]:
    from services.ai_service import generate_with_role, is_no_reply_directive
    from services.memory_service import (
        get_context_messages,
        get_memory_context_string,
        append_short_term,
        trigger_memory_summary,
        _get_memory_length,
        _run_db,
    )
    local_context = event_context or {}
    is_main_user = (user_sender == "user")
    role_max_context_rounds = role.get("max_context_rounds") if isinstance(role, dict) else None
    role_allow_web_search = role.get("allow_web_search", True) if isinstance(role, dict) else True

    # 记忆隔离策略：
    # - 主用户: 全渠道记忆通用，onebot_private = zerochat
    # - 主用户在群聊: 10% 全渠道记忆 + 90% 群聊记忆（按时间排序）
    # - 其他用户: 每个渠道独立记忆上下文
    if is_main_user and origin.startswith("onebot"):
        if origin == "onebot_group" and group_id:
            conversation_key = f"group:{group_id}"
        else:
            conversation_key = "default_user"
    elif origin == "onebot_group" and group_id:
        conversation_key = f"group:{group_id}"
    elif origin == "onebot_private" and sender_id:
        conversation_key = f"private:{sender_id}"
    elif origin == "zerochat":
        conversation_key = "default_user"
    else:
        conversation_key = "all"

    backend_history = await get_context_messages(
        role_id, limit=_get_memory_length(role_max_context_rounds), user_message=user_message,
        conversation_key=conversation_key, max_context_rounds=role_max_context_rounds,
    )

    # 主用户群聊：混合 10% 全渠道记忆 + 90% 群聊记忆
    if is_main_user and conversation_key and conversation_key.startswith("group:"):
        try:
            main_history = await get_context_messages(
                role_id, limit=_get_memory_length(role_max_context_rounds), conversation_key="default_user",
                skip_summary=True, max_context_rounds=role_max_context_rounds,
            )
            memory_length = _get_memory_length(role_max_context_rounds)
            main_count = max(1, int(memory_length * 0.1))
            main_part = main_history[-main_count:] if main_history and len(main_history) >= main_count else (main_history or [])

            def _get_msg_time(item):
                try:
                    return json.loads(item["content"]).get("time", "")
                except Exception:
                    return ""

            # 去重合并后按时间排序
            all_items = list(backend_history)
            seen = {(item["role"], item["content"]) for item in backend_history}
            for item in main_part:
                key = (item["role"], item["content"])
                if key not in seen:
                    seen.add(key)
                    all_items.append(item)

            all_items.sort(key=_get_msg_time)
            history = all_items[-memory_length:]
        except Exception as e:
            logger.warning("混合记忆上下文构建失败：%s", e)
            history = backend_history if backend_history else _normalize_history_items(local_context.get("history"))
    else:
        client_history = _normalize_history_items(local_context.get("history"))
        history = backend_history if backend_history else client_history

    # 向量记忆已封装为 search_memory 工具，由 AI 主动调用
    vector_memories: List[Dict[str, Any]] = []

    backend_memory_context = (await _run_db(role_id, get_memory_context_string, role_id) or "").strip()
    client_core_memory = _normalize_core_memory_list(local_context.get("core_memory"))
    client_memory_context = "\n".join(client_core_memory).strip()
    memory_context = backend_memory_context if backend_memory_context else client_memory_context

    combined_parts: List[str] = []
    if extra_parts:
        combined_parts.extend([str(part).strip() for part in extra_parts if str(part or "").strip()])
    extra_context = "\n\n".join(combined_parts) if combined_parts else None

    normalized_request_id = str(request_id or local_context.get("request_id") or "").strip() or f"req_{uuid.uuid4().hex}"

    # 数值系统：当前值随本次用户消息发送（仅主 App 路径，onebot 不启用四部分/数值）
    stats_current = None
    if not origin.startswith("onebot"):
        try:
            from services import stats_service
            stats_current = stats_service.get_current_values(role_id, role)
        except Exception as e:
            logger.warning("数值状态读取失败：%s", e)

    result = await generate_with_role(
        role_data=role,
        user_message=user_message,
        history=history,
        extra_context=extra_context,
        core_memory_context=memory_context or None,
        vector_memories=vector_memories,
        origin=origin,
        sender=user_sender,
        stats_current=stats_current,
        vision_context=vision_context,
    )

    vector_memories_count = len(vector_memories)

    if not result.get("success"):
        return {
            "success": False,
            "error": result.get("error") or "AI 请求失败",
            "request_id": normalized_request_id,
            "reply": None,
            "history": history,
            "extra_context": extra_context,
            "new_core": None,
            "vector_memory_count": vector_memories_count,
        }

    ai_reply = _sanitize_reply_content(result.get("content") or "")
    no_reply = is_no_reply_directive(ai_reply)

    # 数值系统：从回复中解析数值块并按上下限裁剪后持久化
    if stats_current is not None and not no_reply:
        try:
            from services import stats_service
            stats_service.update_from_reply(role_id, role, ai_reply)
        except Exception as e:
            logger.warning("数值状态更新失败：%s", e)

    if include_user_memory:
        user_memory_content = str(user_message or "").strip()
        if not user_memory_content:
            user_memory_content = str(
                result.get("user_content", {"content": user_message}).get("content", user_message)
            )
        await _run_db(
            role_id, functools.partial(
                append_short_term,
                role_id,
                "user",
                user_memory_content,
                task_id=task_id,
                request_id=normalized_request_id,
                json_memory=attached_json,
                origin=origin,
                sender=user_sender,
                sender_id=sender_id,
                group_id=group_id,
            )
        )
    # 无回复指令是内部控制信号：保留用户输入，但不能污染助手短期记忆。
    if include_assistant_memory and not no_reply:
        await _run_db(
            role_id, functools.partial(
                append_short_term,
                role_id,
                "assistant",
                ai_reply,
                task_id=task_id,
                request_id=normalized_request_id,
                json_memory=attached_json,
                origin=origin,
                sender=role.get("name") or "assistant",
                sender_id=sender_id,
                group_id=group_id,
            )
        )

    new_core = None
    if trigger_summary_after_reply:
        new_core = await trigger_memory_summary("1000000000000", role)

    return {
        "success": True,
        "error": None,
        "request_id": normalized_request_id,
        "reply": ai_reply,
        "no_reply": no_reply,
        "history": history,
        "extra_context": extra_context,
        "new_core": new_core,
        "vector_memory_count": vector_memories_count,
        "emojis_called": result.get("_emojis_called", []),
    }

def _resolve_vision_uploads(upload_ids: List[str]) -> tuple[List[str], List[Path]]:
    """把分块上传的 upload_id 列表解析为 data URL 列表 + 待清理目录列表。

    读取 data/vision/<id>/merged.bin 与 meta.json（取 mime_type），
    组装 data:<mime>;base64,... 形式的 URL，供聚合流程（tool 模式）
    随 ai_event 一并交给聊天模型的 recognize_image 工具使用。
    无法读取的 upload_id 会被跳过。
    """
    import base64 as _base64

    data_urls: List[str] = []
    cleanup_dirs: List[Path] = []
    for raw_id in upload_ids:
        upload_id = str(raw_id or "").strip()
        if not upload_id:
            continue
        upload_dir = VISION_UPLOADS_DIR / upload_id
        merged_file = upload_dir / "merged.bin"
        if not merged_file.exists():
            continue
        cleanup_dirs.append(upload_dir)
        try:
            image_bytes = merged_file.read_bytes()
            if not image_bytes:
                continue
            mime_type = "image/jpeg"
            meta_file = upload_dir / "meta.json"
            if meta_file.exists():
                try:
                    with open(meta_file, "r", encoding="utf-8") as f:
                        meta = json.load(f)
                    mime_type = str(meta.get("mime_type") or mime_type)
                except Exception:
                    pass
            b64 = _base64.b64encode(image_bytes).decode("utf-8")
            data_urls.append(f"data:{mime_type};base64,{b64}")
        except Exception as e:
            logger.warning("解析识图上传失败 upload_id=%s: %s", upload_id, e)
    return data_urls, cleanup_dirs


def _vision_history_scope(event_context: Dict[str, Any]) -> str:
    """Build a stable scope so image history cannot cross chat boundaries."""
    origin = str(event_context.get("origin") or "zerochat").strip() or "zerochat"
    chat_id = str(
        event_context.get("chat_id")
        or event_context.get("onebot_group_id")
        or event_context.get("group_id")
        or event_context.get("sender_id")
        or "default"
    ).strip()
    return f"{origin}:{chat_id}"


async def handle_chat(role: Dict, event: AIEvent) -> AIResponse:
    """处理用户聊天消息"""
    from services.memory_service import (
        _get_memory_length, _get_menstruation_status,
        sequential_memory_generation,
    )
    
    role_id = event.role_id
    user_message = event.content or ""
    event_context = event.context or {}

    # 归档角色不可对话
    if role.get("archived", False):
        return AIResponse(
            success=False,
            action="ignore",
            error="角色已归档，无法聊天",
        )

    # 用户回复即取消上一轮「无回复续写」计时器并归零链计数。
    # 放在生成之前，避免误取消本轮 AI 可能新排的续写。
    if str(event_context.get("sender") or "user") == "user":
        from services import scheduler_service
        scheduler_service.cancel_followup(role_id)

    search_context = ""
    enable_connection = role.get("enable_connection", False)
    if enable_connection:
        seq_origin = str(event_context.get("origin") or "zerochat").strip() or "zerochat"
        seq_sender_id = str(event_context.get("sender_id") or "").strip()
        seq_group_id = str(event_context.get("onebot_group_id") or event_context.get("group_id") or "").strip()
        result = await sequential_memory_generation(
            role_id, "1000000000003", user_message,
            conv_origin=seq_origin,
            conv_group_id=seq_group_id,
            conv_sender_id=seq_sender_id,
        )
    else:
        result = "noneed"
    if result != "noneed" and result is not None:
        logger.info("衔接事件生成：角色 %s 生成了新的衔接事件记忆: %s", role.get("name"), result)
    elif result == "noneed":
        pass
    else:
        logger.info("衔接事件生成：角色 %s 没有生成新的衔接事件记忆", role.get("name"))
    # 合并额外上下文
    extra_parts: List[str] = []
    backend_moments_context = _build_moments_chat_context(role_id)
    if backend_moments_context:
        extra_parts.append(backend_moments_context)
    if search_context:
        extra_parts.append(search_context)
    menstruation_status = _get_menstruation_status(role_id)
    if menstruation_status is not None:
        if menstruation_status["in_period"]:
            extra_parts.append(
                "[生理期状态]\n"
                f"今天：{menstruation_status['today']}（周期第{menstruation_status['cycle_day']}天）\n"
                f"本次经期开始：{menstruation_status['period_start']}，今天是第{menstruation_status['period_day']}天。\n"
                f"预计下次经期开始：{menstruation_status['next_period_start']} 左右。\n"
                "请自然考虑这一状态对情绪和身体感受的影响，不要主动向用户解释系统数据。"
            )
            if menstruation_status["today"] == menstruation_status["expected_period_end"]:
                extra_parts.append(
                    "[生理期状态更新]\n"
                    "按当前周期估算，本次经期预计在今天结束。请自然考虑这一变化，"
                    "不要主动向用户解释系统数据。"
                )
        else:
            extra_parts.append(
                "[生理期状态]\n"
                f"今天：{menstruation_status['today']}（周期第{menstruation_status['cycle_day']}天），当前不在经期。\n"
                f"预计下次经期开始：{menstruation_status['next_period_start']} 左右，时间可能前后浮动。\n"
                "请自然考虑这一状态对情绪和身体感受的影响，不要主动向用户解释系统数据。"
            )
    # 外挂 JSON 记录
    attached_json = role.get("attached_json_content", "")
    if not attached_json:
        attached_json = str(event_context.get("attached_json") or "").strip()
    if attached_json:
        extra_parts.append(f"[外挂记录]\n{attached_json}")
    request_id = str(event_context.get("request_id") or "").strip() or f"req_{uuid.uuid4().hex}"

    # 图片聚合（tool 模式）：客户端把图片以 vision_upload_ids 随本次 ai_event 传来，
    # 这里解析为 data URL 组成 vision_context，交给管道 → generate_with_role
    # 会在存在图片时暴露 recognize_image 工具，并由提示词要求 AI 在回复前调用（不做前置识别）。
    vision_context: Optional[Dict[str, Any]] = None
    vision_cleanup_dirs: List[Path] = []
    from services import vision_service
    vision_history_scope = _vision_history_scope(event_context)
    previous_image_data_urls = vision_service.load_previous_images(
        role_id, vision_history_scope
    )
    upload_ids = event_context.get("vision_upload_ids") or []
    if isinstance(upload_ids, list) and upload_ids:
        data_urls, vision_cleanup_dirs = _resolve_vision_uploads(upload_ids)
        if data_urls:
            vision_context = {
                "image_data_urls": data_urls,
                "previous_image_data_urls": previous_image_data_urls,
            }
            vision_service.save_previous_images(role_id, vision_history_scope, data_urls)
            extra_parts.append(
                f"[图片附件 - 必须执行] 用户本次发送了 {len(data_urls)} 张图片。"
                "回复前必须调用 recognize_image 工具；可在 focus 中说明想重点关注的细节。"
            )
            if previous_image_data_urls:
                extra_parts.append(
                    f"[上一批图片] 本会话上一批共有 {len(previous_image_data_urls)} 张图片。"
                    "如需用新问题重新识别，请调用 review_previous_images 并提供 prompt。"
                )
            if not user_message.strip():
                user_message = "用户发送了图片"
    elif previous_image_data_urls:
        vision_context = {"previous_image_data_urls": previous_image_data_urls}
        extra_parts.append(
            f"[上一批图片] 用户在本会话上一批发送了 {len(previous_image_data_urls)} 张图片。"
            "若用户要求回看，请调用 review_previous_images 并提供新的 prompt。"
        )

    try:
        pipeline_result = await _run_memory_ai_pipeline(
            role=role,
            role_id=role_id,
            user_message=user_message,
            event_context=event_context,
            extra_parts=extra_parts,
            request_id=request_id,
            attached_json=attached_json or None,
            origin=str(event_context.get("origin") or "zerochat").strip() or "zerochat",
            user_sender=str(event_context.get("sender") or "user").strip() or "user",
            sender_id=str(event_context.get("sender_id") or "").strip(),
            group_id=str(event_context.get("onebot_group_id") or event_context.get("group_id") or "").strip(),
            include_user_memory=True,
            include_assistant_memory=True,
            trigger_summary_after_reply=True,
            vision_context=vision_context,
        )
    finally:
        # 识图工具在管道内执行，必须等管道返回后再清理图片目录
        for upload_dir in vision_cleanup_dirs:
            shutil.rmtree(upload_dir, ignore_errors=True)
    if not pipeline_result.get("success"):
        return AIResponse(success=False, action="ignore", error=pipeline_result.get("error"))

    ai_reply = pipeline_result.get("reply") or ""
    extra_context = pipeline_result.get("extra_context")
    history = pipeline_result.get("history") or []
    new_core = pipeline_result.get("new_core")

    vector_memory_count = pipeline_result.get("vector_memory_count", 0)
    logger.info(
        "AI 事件触发：角色 %s 收到消息，历史消息数：%d, 额外上下文长度：%d, 向量记忆数：%s",
        role.get("name"), len(history), len(extra_context) if extra_context else 0, vector_memory_count,
    )
    if new_core != "noneed" and new_core is not None:
        logger.info("记忆总结触发：角色 %s 生成了新的核心记忆%s", role.get("name"), new_core)
    elif new_core is None:
        logger.info("记忆总结触发：角色 %s 没有生成新的核心记忆", role.get("name"))
    elif new_core == "noneed":
        pass
    # 用户发消息后重置主动消息冷却计时
    if str(event_context.get("sender") or "user") == "user":
        from services import scheduler_service
        scheduler_service.schedule_proactive_for_role(role_id, reset=True)
    no_reply = pipeline_result.get("no_reply") is True
    # 情绪表情已封装为 send_emotion_emoji 工具，由 AI 主动调用
    return AIResponse(
        success=True,
        action="ignore" if no_reply else "reply",
        content=ai_reply,
        metadata={
            "role_name": role.get("name"),
            "request_id": pipeline_result.get("request_id") or request_id,
            "emojis_called": [] if no_reply else pipeline_result.get("emojis_called", []),
            "no_reply": no_reply,
        }
    )

# ========== 主动消息处理 ==========

async def handle_proactive(role: Dict, event: AIEvent) -> AIResponse:
    """处理主动消息触发"""
    if not role.get("proactive_config", {}).get("enabled", False):
        return AIResponse(success=False, action="ignore", content=None)

    role_id = event.role_id
    trigger_prompt = event.content or "请生成一条主动消息与用户互动，内容可以是问候、关心、建议等，要求符合角色设定，并符合上下文。"

    pipeline_result = await _run_memory_ai_pipeline(
        role=role,
        role_id=role_id,
        user_message=trigger_prompt,
        event_context=event.context or {},
        origin="zerochat",
        user_sender="system",
        include_user_memory=False,
        include_assistant_memory=True,
        trigger_summary_after_reply=False,
    )
    if not pipeline_result.get("success"):
        return AIResponse(success=False, action="ignore", error=pipeline_result.get("error"))
    if pipeline_result.get("no_reply") is True:
        return AIResponse(success=True, action="ignore", content=None)

    ai_message = pipeline_result.get("reply") or ""
    
    return AIResponse(
        success=True,
        action="reply",
        content=ai_message,
        metadata={"type": "proactive", "role_name": role.get("name")}
    )


# ========== 无回复续写处理 ==========

async def handle_followup(role: Dict, event: AIEvent) -> AIResponse:
    """处理无回复续写触发：用户在设定时长内未回复，AI 主动继续。"""
    if not role.get("followup_config", {}).get("enabled", True):
        return AIResponse(success=False, action="ignore", content=None)

    role_id = event.role_id
    ctx = event.context or {}
    chain_count = int(ctx.get("chain_count", 1))
    max_chain = max(1, int(role.get("followup_config", {}).get("max_chain", 3)))

    base_prompt = event.content or "用户还没有回复，请自然地继续刚才的话题、追问或补充一句。"

    # 告知 AI 当前续写进度，便于其自主决定是否再次调用 continue_if_no_reply
    if chain_count >= max_chain:
        chain_hint = (
            f"\n[续写状态] 这是第 {chain_count} 次跟进，已达到上限（{max_chain} 次）。"
            "请自然收尾，不要再设置继续等待用户回复。"
        )
    else:
        chain_hint = (
            f"\n[续写状态] 这是第 {chain_count} 次跟进（上限 {max_chain} 次）。"
            "如果你觉得还有必要，可以再次设置无回复续写；否则自然收尾即可。"
        )

    pipeline_result = await _run_memory_ai_pipeline(
        role=role,
        role_id=role_id,
        user_message=base_prompt,
        event_context=ctx,
        extra_parts=[chain_hint],
        origin="zerochat",
        user_sender="system",
        include_user_memory=False,
        include_assistant_memory=True,
        trigger_summary_after_reply=False,
    )
    if not pipeline_result.get("success"):
        return AIResponse(success=False, action="ignore", error=pipeline_result.get("error"))
    if pipeline_result.get("no_reply") is True:
        return AIResponse(success=True, action="ignore", content=None)

    ai_message = pipeline_result.get("reply") or ""

    return AIResponse(
        success=True,
        action="reply",
        content=ai_message,
        metadata={"type": "followup", "role_name": role.get("name")}
    )


# ========== 定时任务处理 ==========

async def handle_task(role: Dict, event: AIEvent) -> AIResponse:
    """处理定时任务触发"""
    from services.memory_service import (
        _if_in_menstruation, _get_menstruation_cycle_info
    )

    role_id = event.role_id
    task_prompt = event.content or ""
    task_context = event.context or {}
    task_id = str(task_context.get("task_id") or "").strip() or None
    request_id = str(task_context.get("request_id") or "").strip() or f"req_{uuid.uuid4().hex}"
    attached_json = str(task_context.get("attached_json") or "").strip() or None

    extra_parts: List[str] = []
    backend_moments_context = _build_moments_chat_context(role_id)
    if backend_moments_context:
        extra_parts.append(backend_moments_context)
    in_menstruation, menstruation_day = _if_in_menstruation(role_id)
    cycle_info = _get_menstruation_cycle_info(role_id)
    if in_menstruation is True and menstruation_day is not None:
        extra_parts.append(f"\n生理期数据：你当前处于生理期第{menstruation_day}天，预计持续时间{cycle_info['period_length']}天，请考虑这一点对你的情绪和状态的影响。\n")
    elif in_menstruation is False and menstruation_day is not None:
        extra_parts.append(f"\n生理期数据：你当前不处于生理期，预计还有{menstruation_day}天来生理期。\n")
    attached_json = role.get("attached_json_content", "")
    if not attached_json:
        attached_json = str(task_context.get("attached_json") or "").strip()
    if attached_json:
        extra_parts.append(f"[外挂记录]\n{attached_json}")

    pipeline_result = await _run_memory_ai_pipeline(
        role=role,
        role_id=role_id,
        user_message=task_prompt,
        event_context=task_context,
        extra_parts=extra_parts if extra_parts else None,
        task_id=task_id,
        request_id=request_id,
        attached_json=attached_json or None,
        origin=str(task_context.get("origin") or "zerochat").strip() or "zerochat",
        user_sender=str(task_context.get("sender") or "system").strip() or "system",
        include_user_memory=True,
        include_assistant_memory=True,
        trigger_summary_after_reply=True,
    )
    if not pipeline_result.get("success"):
        return AIResponse(success=False, action="ignore", error=pipeline_result.get("error"))
    if pipeline_result.get("no_reply") is True:
        return AIResponse(success=True, action="ignore", content=None)

    ai_message = pipeline_result.get("reply") or ""
    
    return AIResponse(
        success=True,
        action="reply",
        content=ai_message,
        metadata={
            "type": "task",
            "task_id": task_context.get("task_id"),
            "request_id": pipeline_result.get("request_id") or request_id,
        }
    )

# ========== 朋友圈发布 ==========

async def handle_moment_post(role: Dict, event: AIEvent) -> AIResponse:
    """AI 发布朋友圈"""
    if is_tool_role_id(str(event.role_id or role.get("id", ""))):
        return AIResponse(success=True, action="ignore", content=None)

    from services.ai_service import generate_moment_post
    from services.memory_service import (
        _get_memory_length,
        _run_db,
        get_context_messages,
        get_memory_context_string,
    )
    role_max_ctx = role.get("max_context_rounds") if isinstance(role, dict) else None
    history = await get_context_messages(
        event.role_id,
        limit=_get_memory_length(role_max_ctx),
        skip_summary=True,
        latest=True,
        max_context_rounds=role_max_ctx,
    )

    # 剥离历史消息中的对话标签，避免模型把聊天格式示范到朋友圈正文里。
    from services.message_format import strip_to_plain
    if history:
        for msg in history:
            if isinstance(msg, dict) and msg.get("content"):
                stripped = strip_to_plain(str(msg["content"]))
                if stripped:
                    msg["content"] = stripped

    core_memory_context = (
        await _run_db(event.role_id, get_memory_context_string, event.role_id) or ""
    ).strip()
    result = await generate_moment_post(
        role_data=role,
        history=history,
        core_memory_context=core_memory_context or None,
    )

    if not result["success"]:
        return AIResponse(success=False, action="ignore", error=result["error"])

    from services.message_format import strip_to_plain

    # 兜底：即使模型无视 prompt 输出了对话/动作标签，也在此剥离为纯文本，
    # 避免 <动作> 等标签泄漏到朋友圈正文。
    content = strip_to_plain(result.get("content") or "")

    return AIResponse(
        success=True,
        action="post",
        content=content,
        metadata={"role_name": role.get("name")}
    )

# ========== 朋友圈评论 ==========

async def handle_moment_comment(role: Dict, event: AIEvent) -> AIResponse:
    """AI 评论朋友圈"""
    from routers.moments import load_moments
    from services.ai_service import generate_moment_comment
    from services.memory_service import (
        _get_memory_length,
        _run_db,
        get_context_messages,
        get_memory_context_string,
    )

    context = event.context or {}
    post_content = context.get("post_content", "")
    post_author = context.get("post_author", "用户")
    reply_to = context.get("reply_to")
    reply_to_name = context.get("reply_to_name")
    post_id = str(context.get("post_id") or "").strip()
    comment_thread: List[Dict[str, Any]] = []

    if post_id:
        for post in load_moments():
            if str(post.get("id") or "").strip() != post_id:
                continue
            post_content = str(post.get("content") or post_content)
            post_author = str(post.get("author_name") or post_author)
            raw_comments = post.get("comments")
            if isinstance(raw_comments, list):
                comment_thread = [item for item in raw_comments if isinstance(item, dict)]
            break

    role_max_ctx = role.get("max_context_rounds") if isinstance(role, dict) else None
    history = await get_context_messages(
        event.role_id,
        limit=_get_memory_length(role_max_ctx),
        skip_summary=True,
        latest=True,
        max_context_rounds=role_max_ctx,
    )
    core_memory_context = (
        await _run_db(event.role_id, get_memory_context_string, event.role_id) or ""
    ).strip()

    # 是否互动的概率已由调度器（scheduler_service）统一决定，
    # 此处不再二次随机跳过，避免双重概率相乘导致评论过于稀少、不可控。
    result = await generate_moment_comment(
        role_data=role,
        post_content=post_content,
        post_author=post_author,
        reply_to=reply_to,
        reply_to_name=reply_to_name,
        comment_thread=comment_thread,
        history=history,
        core_memory_context=core_memory_context or None,
    )
    
    if not result["success"]:
        return AIResponse(success=False, action="ignore", error=result["error"])

    from services.message_format import strip_to_plain

    content = strip_to_plain(result.get("content") or "")

    return AIResponse(
        success=True,
        action="comment",
        content=content,
        metadata={"role_name": role.get("name")}
    )

# ========== 状态查询 ==========

@router.get("/ai/status/{role_id}")
async def get_ai_status(role_id: str):
    """获取角色 AI 状态"""
    from services.memory_service import load_memory
    
    role = load_role(role_id)
    if not role:
        raise HTTPException(status_code=404, detail="角色不存在")
    
    memory = load_memory(role_id)
    proactive_config = role.get("proactive_config", {})
    
    return {
        "role_id": role_id,
        "role_name": role.get("name"),
        "proactive_enabled": proactive_config.get("enabled", False),
        "memory_summary_count": memory.get("message_count_since_summary", 0),
        "has_core_memory": bool(memory.get("core_memory")),
        "short_term_count": len(memory.get("short_term", []))
    }


# ========== 图片识别 ==========

import httpx
import base64

class VisionRequest(BaseModel):
    """图片识别请求"""
    image_base64: Optional[str] = ""
    upload_id: Optional[str] = None
    mime_type: str = "image/jpeg"
    user_prompt: str = "请描述这张图片的内容"
    system_prompt: str = ""
    role_id: Optional[str] = None
    run_mode: Optional[str] = None


def _normalize_chat_completions_endpoint(api_url: str) -> str:
    # 统一委托给 vision_service 的规范化实现，避免两份逻辑漂移（D3）。
    from services.vision_service import normalize_chat_completions_endpoint
    return normalize_chat_completions_endpoint(api_url)


def _resolve_role_or_global_chat_config(role_id: Optional[str]) -> Dict[str, str]:
    from services import settings_service

    global_ai = settings_service.get_ai_config()
    resolved = {
        "api_url": global_ai.get("api_url", ""),
        "api_key": global_ai.get("api_key", ""),
        "model": global_ai.get("model", "deepseek-chat"),
    }

    role_key = str(role_id or "").strip()
    if not role_key:
        return resolved

    role_data = load_role(role_key) or {}
    if not isinstance(role_data, dict):
        return resolved

    metadata = role_data.get("metadata") if isinstance(role_data.get("metadata"), dict) else {}
    role_model = str(role_data.get("ai_model") or metadata.get("ai_model") or "").strip()
    role_api_url = str(role_data.get("ai_api_url") or metadata.get("ai_api_url") or "").strip()
    role_api_key = str(role_data.get("ai_api_key") or metadata.get("ai_api_key") or "").strip()

    if role_model:
        resolved["model"] = role_model
    if role_api_url:
        resolved["api_url"] = role_api_url
    if role_api_key:
        resolved["api_key"] = role_api_key

    return resolved


async def _post_chat_completion(api_url: str, api_key: str, body: Dict[str, Any]) -> Dict[str, Any]:
    endpoint = _normalize_chat_completions_endpoint(api_url)
    if not endpoint or not api_key:
        raise HTTPException(status_code=400, detail="AI API 未配置")

    from services.ai_service import _get_http_client
    client = _get_http_client()
    response = await client.post(
        endpoint,
        headers={
            "Authorization": f"Bearer {api_key}",
            "Content-Type": "application/json"
        },
        json=body,
    )

    if response.status_code != 200:
        raise HTTPException(
            status_code=response.status_code,
            detail=f"AI API 错误: {response.text}",
        )
    return response.json()


# _append_vision_memory 已迁移至 services.vision_service

@router.post("/chat/vision")
async def chat_with_vision(request: VisionRequest):
    """
    图片识别聊天
    
    使用 OpenAI Vision API 或兼容的 API 进行图片识别
    """
    from services import vision_service
    from services.ai_service import generate_with_role

    try:
        upload_dir_for_cleanup: Optional[Path] = None

        vision_cfg = vision_service.resolve_vision_config()
        mode = str(request.run_mode or vision_cfg.get("mode") or "standalone").strip().lower()
        if mode not in {"standalone", "pre_model", "tool"}:
            mode = "standalone"

        vision_api_url = vision_cfg.get("api_url", "")
        vision_api_key = vision_cfg.get("api_key", "")
        vision_model = vision_cfg.get("model", "gpt-4o")

        upload_id = str(request.upload_id or "").strip()
        image_base64_value = str(request.image_base64 or "").strip()

        if upload_id:
            upload_dir = VISION_UPLOADS_DIR / upload_id
            merged_file = upload_dir / "merged.bin"
            if not merged_file.exists():
                raise HTTPException(status_code=400, detail="上传文件不存在或未完成")
            upload_dir_for_cleanup = upload_dir
            image_bytes = merged_file.read_bytes()
            if not image_bytes:
                raise HTTPException(status_code=400, detail="上传图片为空")
            image_base64_value = base64.b64encode(image_bytes).decode("utf-8")

            meta_file = upload_dir / "meta.json"
            if meta_file.exists():
                try:
                    with open(meta_file, "r", encoding="utf-8") as f:
                        meta = json.load(f)
                    request.mime_type = str(meta.get("mime_type") or request.mime_type or "image/jpeg")
                except Exception:
                    pass

        if not image_base64_value:
            raise HTTPException(status_code=400, detail="image_base64 或 upload_id 必须提供")

        image_data_url = f"data:{request.mime_type};base64,{image_base64_value}"
        multimodal_messages = vision_service.build_vision_messages(
            image_data_url, request.user_prompt, request.system_prompt
        )

        # 独立模型模式：全角色统一识图模型直接返回结果
        if mode == "standalone":
            result = await _post_chat_completion(
                api_url=vision_api_url,
                api_key=vision_api_key,
                body={
                    "model": vision_model,
                    "messages": multimodal_messages,
                    "max_tokens": 1024,
                },
            )
            reply = result.get("choices", [{}])[0].get("message", {}).get("content", "")
            vision_service.append_vision_memory(
                role_id=request.role_id,
                user_prompt=request.user_prompt,
                final_reply=reply,
                mode=mode,
                image_understanding=reply,
            )
            if upload_dir_for_cleanup is not None:
                shutil.rmtree(upload_dir_for_cleanup, ignore_errors=True)
            return {"reply": reply, "success": True, "mode": mode, "vision_model": vision_model}

        # 工具模式：不做前置识图，把 recognize_image 作为工具交给聊天模型，
        # 并由提示词要求 AI 在回复前调用，可指定识图重点（focus）。
        if mode == "tool":
            chat_cfg = _resolve_role_or_global_chat_config(request.role_id)
            role_id_text = str(request.role_id or "").strip()
            chat_model = str(chat_cfg.get("model") or "deepseek-chat")
            guide_parts = [
                "[图片附件 - 必须执行] 用户本次发送了一张图片。"
                "回复前必须调用 recognize_image 工具；可在 focus 中说明想重点关注的细节。"
            ]
            vision_context = {"image_data_urls": [image_data_url]}
            reply = ""
            try:
                if role_id_text and not is_tool_role_id(role_id_text):
                    role_for_pipeline = load_role(role_id_text) or {"id": role_id_text, "name": "vision_chat"}
                    role_for_pipeline["ai_model"] = role_for_pipeline.get("ai_model") or str(chat_cfg.get("model") or "deepseek-chat")
                    role_for_pipeline["ai_api_url"] = role_for_pipeline.get("ai_api_url") or str(chat_cfg.get("api_url") or "")
                    role_for_pipeline["ai_api_key"] = role_for_pipeline.get("ai_api_key") or str(chat_cfg.get("api_key") or "")
                    chat_model = str(role_for_pipeline.get("ai_model") or chat_model)

                    if request.system_prompt:
                        existing_system_prompt = str(role_for_pipeline.get("system_prompt") or "").strip()
                        request_system_prompt = str(request.system_prompt or "").strip()
                        if existing_system_prompt and request_system_prompt:
                            role_for_pipeline["system_prompt"] = f"{existing_system_prompt}\n\n{request_system_prompt}"
                        elif request_system_prompt:
                            role_for_pipeline["system_prompt"] = request_system_prompt

                    pipeline_result = await _run_memory_ai_pipeline(
                        role=role_for_pipeline,
                        role_id=role_id_text,
                        user_message=str(request.user_prompt or "").strip() or "请看看我发的图片",
                        event_context={
                            "origin": "vision_tool",
                            "sender": "user_vision",
                        },
                        extra_parts=guide_parts,
                        origin="vision_tool",
                        user_sender="user_vision",
                        include_user_memory=False,
                        include_assistant_memory=False,
                        trigger_summary_after_reply=False,
                        vision_context=vision_context,
                    )
                    if not pipeline_result.get("success"):
                        raise HTTPException(status_code=502, detail=pipeline_result.get("error") or "识图工具模式聊天模型生成失败")
                    reply = pipeline_result.get("reply") or ""
                else:
                    # 无角色/工具角色兜底：直接以全局配置调用 generate_with_role，仍暴露识图工具
                    fallback_role = {
                        "id": role_id_text or "vision_tool",
                        "name": "vision_chat",
                        "ai_model": str(chat_cfg.get("model") or "deepseek-chat"),
                        "ai_api_url": str(chat_cfg.get("api_url") or ""),
                        "ai_api_key": str(chat_cfg.get("api_key") or ""),
                    }
                    if request.system_prompt:
                        fallback_role["system_prompt"] = str(request.system_prompt or "").strip()
                    gen_result = await generate_with_role(
                        role_data=fallback_role,
                        user_message=str(request.user_prompt or "").strip() or "请看看我发的图片",
                        extra_context="\n\n".join(guide_parts),
                        origin="vision_tool",
                        sender="user_vision",
                        vision_context=vision_context,
                    )
                    if not gen_result.get("success"):
                        raise HTTPException(status_code=502, detail=gen_result.get("error") or "识图工具模式聊天模型生成失败")
                    reply = _sanitize_reply_content(gen_result.get("content") or "")

                vision_service.append_vision_memory(
                    role_id=request.role_id,
                    user_prompt=request.user_prompt,
                    final_reply=reply,
                    mode=mode,
                    image_understanding=None,
                )
            finally:
                # 生成完成后再清理图片，确保识图工具执行期间图片仍可读取
                if upload_dir_for_cleanup is not None:
                    shutil.rmtree(upload_dir_for_cleanup, ignore_errors=True)
            return {
                "reply": reply,
                "success": True,
                "mode": mode,
                "vision_model": vision_model,
                "chat_model": chat_model,
            }

        # 前置模型模式：先识图，再把识图结果交给聊天模型生成最终回复
        pre_messages = vision_service.build_vision_messages(
            image_data_url,
            f"用户的问题是：{request.user_prompt}\n请提取图片中和用户问题相关的关键内容，长度不超过100个字符。",
            "你是图片理解助手。请准确提取图像中的关键视觉信息，输出简洁文本，不要编造不可见细节。",
        )
        pre_result = await _post_chat_completion(
            api_url=vision_api_url,
            api_key=vision_api_key,
            body={
                "model": vision_model,
                "messages": pre_messages,
                "max_tokens": 700,
            },
        )
        image_understanding = pre_result.get("choices", [{}])[0].get("message", {}).get("content", "")

        chat_cfg = _resolve_role_or_global_chat_config(request.role_id)
        role_id_text = str(request.role_id or "").strip()
        reply = ""
        chat_model = str(chat_cfg.get("model") or "deepseek-chat")

        if role_id_text and not is_tool_role_id(role_id_text):
            role_for_pipeline = load_role(role_id_text) or {"id": role_id_text, "name": "vision_chat"}
            role_for_pipeline["ai_model"] = role_for_pipeline.get("ai_model") or str(chat_cfg.get("model") or "deepseek-chat")
            role_for_pipeline["ai_api_url"] = role_for_pipeline.get("ai_api_url") or str(chat_cfg.get("api_url") or "")
            role_for_pipeline["ai_api_key"] = role_for_pipeline.get("ai_api_key") or str(chat_cfg.get("api_key") or "")
            chat_model = str(role_for_pipeline.get("ai_model") or chat_model)

            if request.system_prompt:
                existing_system_prompt = str(role_for_pipeline.get("system_prompt") or "").strip()
                request_system_prompt = str(request.system_prompt or "").strip()
                if existing_system_prompt and request_system_prompt:
                    role_for_pipeline["system_prompt"] = f"{existing_system_prompt}\n\n{request_system_prompt}"
                elif request_system_prompt:
                    role_for_pipeline["system_prompt"] = request_system_prompt

            vision_extra_parts = [
                f"[图片识别结果]\n{image_understanding}",
                "请仅基于图片识别结果与用户要求生成最终回复。",
            ]
            pipeline_result = await _run_memory_ai_pipeline(
                role=role_for_pipeline,
                role_id=role_id_text,
                user_message=str(request.user_prompt or "").strip() or "请描述这张图片的内容",
                event_context={
                    "origin": "vision_pre_model",
                    "sender": "user_vision",
                },
                extra_parts=vision_extra_parts,
                origin="vision_pre_model",
                user_sender="user_vision",
                include_user_memory=False,
                include_assistant_memory=False,
                trigger_summary_after_reply=False,
            )
            if not pipeline_result.get("success"):
                raise HTTPException(status_code=502, detail=pipeline_result.get("error") or "识图前置聊天模型生成失败")
            reply = pipeline_result.get("reply") or ""
        else:
            final_messages: List[Dict[str, Any]] = []
            if request.system_prompt:
                final_messages.append({"role": "system", "content": request.system_prompt})
            final_messages.append(
                {
                    "role": "user",
                    "content": (
                        "[图片识别结果]:"
                        f"{image_understanding}\n"
                        "[用户要求]:"
                        f"{request.user_prompt}\n"
                        "请仅基于图片识别结果与用户要求生成最终回复。"
                    ),
                }
            )

            final_result = await _post_chat_completion(
                api_url=str(chat_cfg.get("api_url") or ""),
                api_key=str(chat_cfg.get("api_key") or ""),
                body={
                    "model": str(chat_cfg.get("model") or "deepseek-chat"),
                    "messages": final_messages,
                    "max_tokens": 1024,
                },
            )
            reply = _sanitize_reply_content(final_result.get("choices", [{}])[0].get("message", {}).get("content", ""))
        vision_service.append_vision_memory(
            role_id=request.role_id,
            user_prompt=request.user_prompt,
            final_reply=reply,
            mode=mode,
            image_understanding=image_understanding,
        )
        if upload_dir_for_cleanup is not None:
            shutil.rmtree(upload_dir_for_cleanup, ignore_errors=True)
        return {
            "reply": reply,
            "success": True,
            "mode": mode,
            "vision_model": vision_model,
            "chat_model": chat_model,
        }
        
    except httpx.TimeoutException:
        raise HTTPException(status_code=504, detail="AI 请求超时")
    except Exception as e:
        raise HTTPException(status_code=500, detail=str(e))
