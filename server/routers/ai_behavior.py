"""
AI 行为统一入口
处理所有 AI 事件：聊天、主动消息、定时任务、朋友圈
"""
import json
import random
from datetime import datetime
from enum import Enum
from pathlib import Path
from typing import Optional, List, Dict, Any
from pydantic import BaseModel
from fastapi import APIRouter, HTTPException

from services.memory_service import trigger_memory_summary

router = APIRouter()

DATA_DIR = Path(__file__).parent.parent / "data"
ROLES_DIR = DATA_DIR / "roles"

# ========== 数据模型 ==========

class AIEventType(str, Enum):
    CHAT = "chat"              # 用户聊天消息
    TASK = "task"              # 定时任务触发
    PROACTIVE = "proactive"    # 主动消息
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

# ========== 辅助函数 ==========

def load_role(role_id: str) -> Optional[Dict]:
    profile_file = ROLES_DIR / role_id / "profile.json"
    if profile_file.exists():
        with open(profile_file, "r", encoding="utf-8") as f:
            return json.load(f)
    return None

async def detect_emotion_and_get_emoji(role_id: str,worker_id:str, text: str) -> Optional[str]:
    """
    检测文本情绪并返回对应表情包路径
    
    表情包目录结构: roles/{role_id}/emojis/{emotion}/
    支持的情绪: happy, sad, angry, suprised, love, confused, excited, tired
    """
    rand = random.random()
    if rand >(1 - 0.75): # 75% 的概率不进行情绪检测，25% 的概率进行检测
        print(f"情绪检测随机跳过：{rand:.2f} > 0.25")
        return None
    from services.ai_service import call_ai_direct

    role_data = load_role(worker_id) or {}
    model = role_data.get("ai_model")
    api_url = role_data.get("ai_api_url")
    api_key = role_data.get("ai_api_key")
    temperature = role_data.get("ai_temperature", 0.1)
    if not model or not api_url or not api_key:
        return None

    system_prompt = role_data.get("system_prompt", "")
    emotion_prompt = (
        "你是情绪分类器。根据给定文本判断最主要的情绪。\n可选标签: happy, sad, angry, surprised, love, confused, excited, tired, none。\n要求: 只输出一个标签, 不要解释, 不要多余文本。\n如果没有明显情绪, 输出 none。"
    )
    messages = []
    if system_prompt:
        messages.append({"role": "system", "content": system_prompt})
    else:
        messages.append({"role": "system", "content": emotion_prompt})
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

    detected_emotion = (result.get("content") or "").strip().lower()
    allowed = {"happy", "sad", "angry", "surprised", "love", "confused", "excited", "tired", "none"}
    if detected_emotion not in allowed or detected_emotion == "none":
        return None
    
    # 检查对应表情包目录
    emoji_dir = ROLES_DIR / role_id / "emojis" / detected_emotion
    if not emoji_dir.exists():
        return None
    
    # 获取目录中的图片文件
    image_extensions = (".png", ".jpg", ".jpeg", ".gif", ".webp")
    emoji_files = [f for f in emoji_dir.iterdir() if f.suffix.lower() in image_extensions]
    
    if not emoji_files:
        return None
    
    # 随机选择一个
    selected = random.choice(emoji_files)
    return detected_emotion
    # return f"/api/emojis/{role_id}/{detected_emotion}/{selected.name}"

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
    # 根据事件类型分发
    if event.event_type == AIEventType.CHAT:
        return await handle_chat(role, event)
    elif event.event_type == AIEventType.PROACTIVE:
        return await handle_proactive(role, event)
    elif event.event_type == AIEventType.TASK:
        return await handle_task(role, event)
    elif event.event_type == AIEventType.MOMENT_POST:
        return await handle_moment_post(role, event)
    elif event.event_type == AIEventType.MOMENT_COMMENT:
        return await handle_moment_comment(role, event)
    elif event.event_type == AIEventType.MEMORY_SUMMARIZATION:
        return await handle_memory_summarization(role, event)
    else:
        return AIResponse(success=False, error="未知事件类型")

# ========== 聊天处理 ==========

async def handle_chat(role: Dict, event: AIEvent) -> AIResponse:
    """处理用户聊天消息"""
    from services.ai_service import generate_with_role
    from services.memory_service import (
        get_context_messages, get_memory_context_string,
        append_short_term, trigger_memory_summary,
        _if_in_menstruation, _get_memory_length,
        sequential_memory_generation,_get_menstruation_cycle_info
    )
    
    role_id = event.role_id
    user_message = event.content or ""
    # 获取上下文
    history = await get_context_messages(role_id, limit=_get_memory_length())  # 获取更多历史消息，让 AI 有更完整的上下文
    memory_context = get_memory_context_string(role_id)
    
    # 联网搜索（如果角色开启了搜索功能）
    search_context = ""
    allow_search = role.get("allow_web_search", True)
    # if allow_search:
    #     from services.search_service import should_search, web_search, format_search_results
    #     if should_search(user_message):
    #         search_results = await web_search(user_message, max_results=5)
    #         search_context = format_search_results(search_results)
    result = await sequential_memory_generation(role_id, "1000000000003", user_message)
    if result != "noneed" and result is not None:
        print(f"衔接事件生成：角色 {role.get('name')} 生成了新的衔接事件记忆: {result}")
    elif result == "noneed":
        pass
    else:
        print(f"衔接事件生成：角色 {role.get('name')} 没有生成新的衔接事件记忆，AI 可能未能正确判断或发生错误")
    # 合并额外上下文
    extra_parts = []
    if memory_context:
        extra_parts.append(memory_context)
    if search_context:
        extra_parts.append(search_context)
    in_menstruation, menstruation_day = _if_in_menstruation(role_id)
    cycle_info = _get_menstruation_cycle_info(role_id)
    if in_menstruation is True and menstruation_day is not None:
        print(f"生理期检测：角色 {role.get('name')} 当前处于生理期第 {menstruation_day} 天，已将相关信息加入上下文")
        extra_parts.append(f"\n生理期数据：你当前处于生理期第{menstruation_day}天，预计持续时间{cycle_info['period_length']}天，请考虑这一点对你的情绪和状态的影响。\n")
    elif in_menstruation is False and menstruation_day is not None:
        if cycle_info:
            extra_parts.append(f"\n生理期数据：你当前不处于生理期，距离上次生理期结束已第{menstruation_day}天，平均月经周期天数为 {cycle_info['cycle_length']} 天\n")
        else:
            print(f"生理期检测：角色 {role.get('name')} 当前不处于生理期，距结束已第 {menstruation_day} 天")
            extra_parts.append(f"\n生理期数据：你当前不处于生理期，距离上次生理期结束已第{menstruation_day}天。\n")
    else:
        print(f"生理期检测：角色 {role.get('name')} 当前不需要进行生理期检测")
    # 外挂 JSON 记录
    attached_json = role.get("attached_json_content", "")
    if attached_json:
        extra_parts.append(f"[外挂记录]\n{attached_json}")
    
    extra_context = "\n\n".join(extra_parts) if extra_parts else None
    print(f"AI 事件触发：角色 {role.get('name')} 收到消息，历史消息数：{len(history)}, 额外上下文长度：{len(extra_context) if extra_context else 0}")
    # 生成回复
    result = await generate_with_role(
        role_data=role,
        user_message=user_message,
        history=history,
        extra_context=extra_context
    )

    if not result["success"]:
        return AIResponse(success=False, action="ignore", error=result["error"])
    
    ai_reply = result["content"]
    
    # 更新记忆
    append_short_term(role_id, "user", result.get("user_content", {"content": user_message}).get("content", user_message))
    append_short_term(role_id, "assistant", ai_reply)
    
    # 触发记忆总结
    new_core = await trigger_memory_summary("1000000000000", role)
    if new_core != "noneed" and new_core is not None:
        print(f"记忆总结触发：角色 {role.get('name')} 生成了新的核心记忆{new_core}")
    elif new_core is None:
        print(f"记忆总结触发：角色 {role.get('name')} 没有生成新的核心记忆")
    elif new_core == "noneed":
        print(f"无需记忆总结，已跳过总结过程")
    # 检测情绪并获取表情包
    emoji = await detect_emotion_and_get_emoji(role_id,"1000000000001", ai_reply)
    if emoji:
        print(f"情绪检测：角色 {role.get('name')} 的回复被检测出情绪，返回表情包: {emoji}")
        ai_reply += f" [{emoji}]"
    return AIResponse(
        success=True,
        action="reply",
        content=ai_reply,
        metadata={
            "role_name": role.get("name"),
            "emoji": emoji  # 如果有匹配的表情包，返回表情包名称
        }
    )

# ========== 主动消息处理 ==========

async def handle_proactive(role: Dict, event: AIEvent) -> AIResponse:
    """处理主动消息触发"""
    from services.ai_service import generate_with_role
    from services.memory_service import get_memory_context_string, append_short_term, get_context_messages,_get_memory_length
    
    role_id = event.role_id
    trigger_prompt = event.content or "请生成一条主动消息与用户互动，内容可以是问候、关心、建议等，要求符合角色设定，并符合上下文。"
    
    memory_context = get_memory_context_string(role_id)

    history = await get_context_messages(role_id, limit=_get_memory_length())
    
    result = await generate_with_role(
        role_data=role,
        user_message=trigger_prompt,
        history=history,
        extra_context=memory_context
    )
    
    if not result["success"]:
        return AIResponse(success=False, action="ignore", error=result["error"])
    
    ai_message = result["content"]
    
    # 记录到短期记忆
    append_short_term(role_id, "assistant", ai_message)
    
    return AIResponse(
        success=True,
        action="reply",
        content=ai_message,
        metadata={"type": "proactive", "role_name": role.get("name")}
    )

async def handle_memory_summarization(role, event):
    return await trigger_memory_summary("1000000000000", role)


# ========== 定时任务处理 ==========

async def handle_task(role: Dict, event: AIEvent) -> AIResponse:
    """处理定时任务触发"""
    from services.ai_service import generate_with_role
    from services.memory_service import get_memory_context_string, append_short_term
    
    role_id = event.role_id
    task_prompt = event.content or ""
    task_context = event.context or {}
    
    memory_context = get_memory_context_string(role_id)
    
    result = await generate_with_role(
        role_data=role,
        user_message=task_prompt,
        extra_context=memory_context
    )
    
    if not result["success"]:
        return AIResponse(success=False, action="ignore", error=result["error"])
    
    ai_message = result["content"]
    append_short_term(role_id, "assistant", ai_message)
    
    return AIResponse(
        success=True,
        action="reply",
        content=ai_message,
        metadata={"type": "task", "task_id": task_context.get("task_id")}
    )

# ========== 朋友圈发布 ==========

async def handle_moment_post(role: Dict, event: AIEvent) -> AIResponse:
    """AI 发布朋友圈"""
    from services.ai_service import generate_moment_post
    
    mood = event.context.get("mood") if event.context else None
    
    result = await generate_moment_post(role_data=role, mood=mood)
    
    if not result["success"]:
        return AIResponse(success=False, action="ignore", error=result["error"])
    
    return AIResponse(
        success=True,
        action="post",
        content=result["content"],
        metadata={"role_name": role.get("name")}
    )

# ========== 朋友圈评论 ==========

async def handle_moment_comment(role: Dict, event: AIEvent) -> AIResponse:
    """AI 评论朋友圈"""
    from services.ai_service import generate_moment_comment
    
    context = event.context or {}
    post_content = context.get("post_content", "")
    post_author = context.get("post_author", "用户")
    reply_to = context.get("reply_to")
    
    # 概率决定是否互动
    if random.random() > 0.5:
        return AIResponse(success=True, action="ignore", content=None)
    
    result = await generate_moment_comment(
        role_data=role,
        post_content=post_content,
        post_author=post_author,
        reply_to=reply_to
    )
    
    if not result["success"]:
        return AIResponse(success=False, action="ignore", error=result["error"])
    
    return AIResponse(
        success=True,
        action="comment",
        content=result["content"],
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
    image_base64: str
    mime_type: str = "image/jpeg"
    user_prompt: str = "请描述这张图片的内容"
    system_prompt: str = ""

@router.post("/chat/vision")
async def chat_with_vision(request: VisionRequest):
    """
    图片识别聊天
    
    使用 OpenAI Vision API 或兼容的 API 进行图片识别
    """
    from services import settings_service
    
    try:
        # 获取 AI 配置
        ai_settings = settings_service.get_ai_config()
        api_url = ai_settings.get("api_url", "")
        api_key = ai_settings.get("api_key", "")
        model = ai_settings.get("model", "gpt-4o")
        
        if not api_url or not api_key:
            raise HTTPException(status_code=400, detail="AI API 未配置")
        
        # 构建 vision 请求
        messages = []
        
        # 添加 system prompt
        if request.system_prompt:
            messages.append({"role": "system", "content": request.system_prompt})
        
        # 添加用户消息（包含图片）
        messages.append({
            "role": "user",
            "content": [
                {
                    "type": "image_url",
                    "image_url": {
                        "url": f"data:{request.mime_type};base64,{request.image_base64}"
                    }
                },
                {
                    "type": "text",
                    "text": request.user_prompt
                }
            ]
        })
        
        # 确保 URL 格式正确
        if not api_url.endswith("/"):
            api_url += "/"
        if not api_url.endswith("v1/"):
            api_url += "v1/"
        
        endpoint = f"{api_url}chat/completions"
        
        # 调用 API
        async with httpx.AsyncClient(timeout=60.0) as client:
            response = await client.post(
                endpoint,
                headers={
                    "Authorization": f"Bearer {api_key}",
                    "Content-Type": "application/json"
                },
                json={
                    "model": model,
                    "messages": messages,
                    "max_tokens": 1024
                }
            )
        
        if response.status_code != 200:
            raise HTTPException(
                status_code=response.status_code,
                detail=f"AI API 错误: {response.text}"
            )
        
        result = response.json()
        reply = result.get("choices", [{}])[0].get("message", {}).get("content", "")
        
        return {"reply": reply, "success": True}
        
    except httpx.TimeoutException:
        raise HTTPException(status_code=504, detail="AI 请求超时")
    except Exception as e:
        raise HTTPException(status_code=500, detail=str(e))
