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

def detect_emotion_and_get_emoji(role_id: str, text: str) -> Optional[str]:
    """
    检测文本情绪并返回对应表情包路径
    
    表情包目录结构: roles/{role_id}/emojis/{emotion}/
    支持的情绪: happy, sad, angry, surprised, love, confused, excited, tired
    """
    # 简单情绪关键词匹配
    emotion_keywords = {
        "happy": ["开心", "高兴", "哈哈", "😊", "😄", "太好了", "棒", "喜欢", "快乐", "nice", "great"],
        "sad": ["难过", "伤心", "哭", "😢", "😭", "抱歉", "遗憾", "可惜", "唉"],
        "angry": ["生气", "愤怒", "😠", "😡", "讨厌", "烦", "气死"],
        "surprised": ["惊讶", "天哪", "😲", "😮", "竟然", "居然", "什么", "wow", "不敢相信"],
        "love": ["爱你", "喜欢你", "❤️", "💕", "😍", "亲爱", "宝贝", "想你"],
        "confused": ["困惑", "不懂", "🤔", "奇怪", "为什么", "怎么回事", "不明白"],
        "excited": ["兴奋", "激动", "🎉", "太棒了", "期待", "迫不及待", "耶"],
        "tired": ["累", "困", "😴", "休息", "睡觉", "疲惫"]
    }
    
    text_lower = text.lower()
    detected_emotion = None
    
    for emotion, keywords in emotion_keywords.items():
        for keyword in keywords:
            if keyword.lower() in text_lower:
                detected_emotion = emotion
                break
        if detected_emotion:
            break
    
    if not detected_emotion:
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
    return f"/api/emojis/{role_id}/{detected_emotion}/{selected.name}"

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
    else:
        return AIResponse(success=False, error="未知事件类型")

# ========== 聊天处理 ==========

async def handle_chat(role: Dict, event: AIEvent) -> AIResponse:
    """处理用户聊天消息"""
    from services.ai_service import generate_with_role
    from services.memory_service import (
        get_context_messages, get_memory_context_string,
        append_short_term, trigger_memory_summary
    )
    
    role_id = event.role_id
    user_message = event.content or ""
    # 获取上下文
    history = get_context_messages(role_id)
    memory_context = get_memory_context_string(role_id)
    
    # 联网搜索（如果角色开启了搜索功能）
    search_context = ""
    allow_search = role.get("allow_web_search", True)
    if allow_search:
        from services.search_service import should_search, web_search, format_search_results
        if should_search(user_message):
            search_results = await web_search(user_message, max_results=5)
            search_context = format_search_results(search_results)
    
    # 合并额外上下文
    extra_parts = []
    if memory_context:
        extra_parts.append(memory_context)
    if search_context:
        extra_parts.append(search_context)
    
    # 外挂 JSON 记录
    attached_json = role.get("attached_json_content", "")
    if attached_json:
        extra_parts.append(f"[外挂记录]\n{attached_json}")
    
    extra_context = "\n\n".join(extra_parts) if extra_parts else None

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
    
    # 触发记忆总结（静默执行，不影响回复）
    await trigger_memory_summary(role_id, role)
    
    # 检测情绪并获取表情包
    emoji_url = detect_emotion_and_get_emoji(role_id, ai_reply)
    
    return AIResponse(
        success=True,
        action="reply",
        content=ai_reply,
        metadata={
            "role_name": role.get("name"),
            "emoji_url": emoji_url  # 如果有匹配的表情包，返回URL
        }
    )

# ========== 主动消息处理 ==========

async def handle_proactive(role: Dict, event: AIEvent) -> AIResponse:
    """处理主动消息触发"""
    from services.ai_service import generate_proactive_message
    from services.memory_service import get_memory_context_string, append_short_term
    
    role_id = event.role_id
    proactive_config = role.get("proactive_config", {})
    trigger_prompt = proactive_config.get("trigger_prompt", "")
    
    memory_context = get_memory_context_string(role_id)
    
    result = await generate_proactive_message(
        role_data=role,
        trigger_prompt=trigger_prompt,
        memory_context=memory_context
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
