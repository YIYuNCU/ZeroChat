"""
聊天路由
处理 AI 对话请求
"""
import json
from datetime import datetime
from pathlib import Path
from typing import Optional, List
from pydantic import BaseModel
from fastapi import APIRouter, HTTPException
import httpx

router = APIRouter()

# 数据目录
DATA_DIR = Path(__file__).parent.parent / "data"
CHATS_DIR = DATA_DIR / "chats"
CONFIG_DIR = Path(__file__).parent.parent / "config"

class ChatMessage(BaseModel):
    role: str  # user / assistant / system
    content: str

class ChatRequest(BaseModel):
    chat_id: str
    role_id: str
    message: str
    system_prompt: Optional[str] = None
    history: Optional[List[ChatMessage]] = None

class ChatResponse(BaseModel):
    success: bool
    content: Optional[str] = None
    error: Optional[str] = None

def load_config():
    config_file = CONFIG_DIR / "settings.json"
    if config_file.exists():
        with open(config_file, "r", encoding="utf-8") as f:
            return json.load(f)
    return {}

def save_chat_message(chat_id: str, role: str, content: str):
    """保存聊天消息"""
    chat_file = CHATS_DIR / f"{chat_id}.json"
    messages = []
    if chat_file.exists():
        with open(chat_file, "r", encoding="utf-8") as f:
            messages = json.load(f)
    
    messages.append({
        "id": f"{datetime.now().timestamp()}",
        "role": role,
        "content": content,
        "timestamp": datetime.now().isoformat()
    })
    
    with open(chat_file, "w", encoding="utf-8") as f:
        json.dump(messages, f, indent=2, ensure_ascii=False)

def get_chat_history(chat_id: str, limit: int = 20) -> List[dict]:
    """获取聊天历史"""
    chat_file = CHATS_DIR / f"{chat_id}.json"
    if not chat_file.exists():
        return []
    with open(chat_file, "r", encoding="utf-8") as f:
        messages = json.load(f)
    return messages[-limit:]

@router.post("/chat", response_model=ChatResponse)
async def chat(request: ChatRequest):
    """AI 对话接口"""
    config = load_config()
    
    api_url = config.get("ai_api_url", "")
    api_key = config.get("ai_api_key", "")
    model = config.get("ai_model", "gpt-3.5-turbo")
    
    if not api_url or not api_key:
        raise HTTPException(status_code=500, detail="AI API 未配置")
    
    # 构建消息列表
    messages = []
    if request.system_prompt:
        messages.append({"role": "system", "content": request.system_prompt})
    
    # 添加历史消息
    if request.history:
        for msg in request.history:
            messages.append({"role": msg.role, "content": msg.content})
    
    # 添加当前消息
    messages.append({"role": "user", "content": request.message})
    try:
        async with httpx.AsyncClient(timeout=60.0) as client:
            response = await client.post(
                api_url,
                headers={
                    "Authorization": f"Bearer {api_key}",
                    "Content-Type": "application/json"
                },
                json={
                    "model": model,
                    "messages": messages,
                    "temperature": 0.7
                }
            )
            response.raise_for_status()
            data = response.json()
            
            ai_content = data["choices"][0]["message"]["content"]
            
            # 保存消息
            save_chat_message(request.chat_id, "user", request.message)
            save_chat_message(request.chat_id, "assistant", ai_content)
            
            return ChatResponse(success=True, content=ai_content)
            
    except httpx.HTTPError as e:
        return ChatResponse(success=False, error=str(e))
    except Exception as e:
        return ChatResponse(success=False, error=str(e))

@router.get("/chats/{chat_id}/history")
async def get_history(chat_id: str, limit: int = 50):
    """获取聊天历史"""
    history = get_chat_history(chat_id, limit)
    return {"chat_id": chat_id, "messages": history}

@router.delete("/chats/{chat_id}")
async def clear_chat(chat_id: str):
    """清空聊天记录"""
    chat_file = CHATS_DIR / f"{chat_id}.json"
    if chat_file.exists():
        chat_file.unlink()
    return {"success": True}


@router.get("/search")
async def search_test(q: str):
    """测试联网搜索（GET /api/search?q=关键词）"""
    from services.search_service import should_search, web_search, format_search_results
    
    triggered = should_search(q)
    results = []
    formatted = ""
    
    if triggered:
        results = await web_search(q, max_results=3)
        formatted = format_search_results(results)
    
    return {
        "query": q,
        "triggered": triggered,
        "result_count": len(results),
        "results": results,
        "formatted": formatted,
    }
