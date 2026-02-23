"""
AI 服务
统一处理所有 AI API 调用
"""
import json
import httpx
from pathlib import Path
from typing import Optional, List, Dict, Any, Tuple

CONFIG_DIR = Path(__file__).parent.parent / "config"

def load_config() -> Dict:
    config_file = CONFIG_DIR / "settings.json"
    if config_file.exists():
        with open(config_file, "r", encoding="utf-8") as f:
            return json.load(f)
    return {}

def _normalize_api_url(api_url: str) -> str:
    if not api_url.endswith("/v1/chat/completions"):
        api_url = api_url.rstrip("/") + "/v1/chat/completions"
    return api_url

def _resolve_ai_config(
    model: Optional[str],
    api_url: Optional[str],
    api_key: Optional[str],
    temperature: Optional[float] = None
) -> Tuple[Optional[str], Optional[str], Optional[str],Optional[float]]:
    config = load_config()
    default_model = config.get("ai_model", "gpt-3.5-turbo")
    default_url = config.get("ai_api_url", "")
    default_key = config.get("ai_api_key", "")
    default_temperature = config.get("ai_temperature", 0.7)
    resolved_model = model or default_model
    resolved_url = _normalize_api_url(api_url or default_url)
    resolved_key = api_key or default_key
    resolved_temperature = temperature if temperature is not None else default_temperature

    return resolved_model, resolved_url, resolved_key, resolved_temperature

def _get_role_ai_config(role_data: Optional[Dict]) -> Tuple[Optional[str], Optional[str], Optional[str], Optional[float]]:
    if not role_data:
        return _resolve_ai_config(None, None, None, None)

    model = role_data.get("ai_model")
    api_url = role_data.get("ai_api_url")
    api_key = role_data.get("ai_api_key")
    temperature = role_data.get("ai_temperature")
    metadata = role_data.get("metadata")
    if isinstance(metadata, dict):
        model = model or metadata.get("ai_model")
        api_url = api_url or metadata.get("ai_api_url")
        api_key = api_key or metadata.get("ai_api_key")
        temperature = temperature if temperature is not None else metadata.get("ai_temperature")

    return _resolve_ai_config(model, api_url, api_key, temperature)

async def _post_chat(
    messages: List[Dict[str, str]],
    api_url: str,
    api_key: str,
    model: str,
    temperature: float,
    max_tokens: int
) -> Dict[str, Any]:
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
                    "temperature": temperature,
                    "max_tokens": max_tokens
                }
            )
            response.raise_for_status()
            data = response.json()
            content = data["choices"][0]["message"]["content"]
            if "usage" in data:
                print(
                    "hit chache:{},miss cache:{},total tokens:{}".format(
                        data["usage"].get("prompt_cache_hit_tokens"),
                        data["usage"].get("prompt_cache_miss_tokens"),
                        data["usage"].get("total_tokens")
                    )
                )
            return {"success": True, "content": content, "user_content": messages[-1], "error": None}
    except httpx.HTTPError as e:
        return {"success": False, "content": None, "error": f"HTTP Error: {str(e)}"}
    except Exception as e:
        return {"success": False, "content": None, "error": str(e)}

async def call_ai(
    messages: List[Dict[str, str]],
    model: Optional[str] = None,
    api_url: Optional[str] = None,
    api_key: Optional[str] = None,
    temperature: float = 0.7,
    max_tokens: int = 1000
) -> Dict[str, Any]:
    """
    统一 AI API 调用
    
    Args:
        messages: 消息列表 [{"role": "system/user/assistant", "content": "..."}]
        model: 模型名称，默认从配置读取
        temperature: 温度参数
        max_tokens: 最大 token 数
    
    Returns:
        {"success": bool, "content": str, "error": str}
    """
    config = load_config()
    default_model = config.get("ai_model", "gpt-3.5-turbo")
    default_temperature = config.get("ai_temperature", 0.7)
    resolved_model, resolved_url, resolved_key, resolved_temperature = _resolve_ai_config(
        model or default_model,
        api_url,
        api_key,
        temperature or default_temperature
    )
    
    if not resolved_url or not resolved_key:
        return {"success": False, "content": None, "error": "AI API 未配置"}

    return await _post_chat(
        messages=messages,
        api_url=resolved_url,
        api_key=resolved_key,
        model=resolved_model,
        temperature=resolved_temperature,
        max_tokens=max_tokens
    )

async def call_ai_direct(
    messages: List[Dict[str, str]],
    api_url: str,
    api_key: str,
    model: str,
    temperature: float = 0.7,
    max_tokens: int = 1000
) -> Dict[str, Any]:
    """
    独立调用 AI（不依赖全局配置）
    """
    if not api_url or not api_key or not model:
        return {"success": False, "content": None, "error": "AI API 未配置"}
    api_url = _normalize_api_url(api_url)
    return await _post_chat(
        messages=messages,
        api_url=api_url,
        api_key=api_key,
        model=model,
        temperature=temperature,
        max_tokens=max_tokens
    )

async def generate_with_role(
    role_data: Dict,
    user_message: str,
    history: Optional[List[Dict]] = None,
    extra_context: Optional[str] = None
) -> Dict[str, Any]:
    """
    以角色身份生成回复
    
    Args:
        role_data: 角色数据（含 persona, system_prompt 等）
        user_message: 用户消息
        history: 历史消息
        extra_context: 额外上下文（如记忆）
    """
    messages = []
    
    # 系统提示词
    system_prompt = role_data.get("system_prompt", "")
    persona = role_data.get("persona", "")
    
    if persona or system_prompt:
        system_content = ""
        if persona:
            system_content += f"你的人设：{persona}\n\n"
        if system_prompt:
            system_content += system_prompt
        if extra_context:
            system_content += f"\n\n额外上下文：{extra_context}"
        system_content += "用户消息格式为：message: <消息内容>\ntime: <消息时间> <星期几>，请严格按照这个格式理解用户消息，并在回复中体现对时间的理解和关联。"
        # 注入当前日期时间
        from datetime import datetime
        weekdays = ["星期一", "星期二", "星期三", "星期四", "星期五", "星期六", "星期日"]
        now = datetime.now()
        weekday = weekdays[now.weekday()]
        
        messages.append({"role": "system", "content": system_content})
    # 历史消息
    if history:
        for msg in history:
            messages.append({
                "role": msg.get("role", "user"),
                "content": msg.get("content", "")
            })
    user_message = f"message: {user_message}\ntime: {now.strftime('%Y-%m-%d %H:%M:%S')} {weekday}"
    # 当前消息
    messages.append({"role": "user", "content": user_message})

    model_override, url_override, key_override, temp_override = _get_role_ai_config(role_data)
    return await call_ai(
        messages,
        model=model_override,
        api_url=url_override,
        api_key=key_override,
        temperature=temp_override or 1.2
    )

async def generate_moment_post(
    role_data: Dict,
    mood: Optional[str] = None
) -> Dict[str, Any]:
    """
    生成朋友圈内容
    """
    persona = role_data.get("persona", "")
    name = role_data.get("name", "AI")
    
    prompt = f"""你是{name}，你的人设：{persona}

现在你想发一条朋友圈动态。要求：
- 内容简短自然（20-100字）
- 符合你的性格和人设
- 可以是生活感悟、心情分享、日常记录
- 不要提及"AI""系统""人设"等词
{f'- 当前心情偏向：{mood}' if mood else ''}

直接输出朋友圈内容，不要任何解释。"""

    messages = [{"role": "user", "content": prompt}]
    model_override, url_override, key_override, temp_override = _get_role_ai_config(role_data)
    return await call_ai(
        messages,
        model=model_override,
        api_url=url_override,
        api_key=key_override,
        temperature=temp_override or 0.9
    )

async def generate_moment_comment(
    role_data: Dict,
    post_content: str,
    post_author: str,
    reply_to: Optional[str] = None
) -> Dict[str, Any]:
    """
    生成朋友圈评论
    """
    persona = role_data.get("persona", "")
    name = role_data.get("name", "AI")
    
    prompt = f"""你是{name}，你的人设：{persona}

{post_author}发了一条朋友圈：「{post_content}」

{'你要回复'+reply_to+'的评论' if reply_to else '你想评论这条朋友圈'}。要求：
- 简短自然（5-30字）
- 像朋友间的互动
- 可以用表情或语气词
- 不要太正式

直接输出评论内容。"""

    messages = [{"role": "user", "content": prompt}]
    model_override, url_override, key_override, temp_override = _get_role_ai_config(role_data)
    return await call_ai(
        messages,
        model=model_override,
        api_url=url_override,
        api_key=key_override,
        temperature=temp_override or 0.8
    )
