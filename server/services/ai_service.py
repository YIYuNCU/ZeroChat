"""
AI 服务
统一处理所有 AI API 调用
"""
import json
import httpx
import re
from datetime import datetime
from typing import Optional, List, Dict, Any, Tuple

from services import settings_service


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
    config = settings_service.load_settings()
    resolved_model = model or config.get("ai_model", "gpt-3.5-turbo")
    resolved_url = _normalize_api_url(api_url or config.get("ai_api_url", ""))
    resolved_key = api_key or config.get("ai_api_key", "")
    resolved_temperature = temperature if temperature is not None else config.get("ai_temperature", 0.7)
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


def _is_meta_key_line(line_text: str) -> bool:
    """Check if line is a structured metadata field."""
    stripped = line_text.strip().lower()
    return any(
        stripped.startswith(prefix)
        for prefix in ("message:", "time:", "origin:", "sender:")
    )


def _extract_plain_message_content(content: Any) -> str:
    text = str(content or "").strip()
    if not text:
        return ""

    # Strip markdown code fences
    if text.startswith("```") and text.endswith("```"):
        text = re.sub(r"^```[a-zA-Z0-9_-]*\n?", "", text).rstrip("`").strip()

    # Prefer structured JSON response when present.
    try:
        parsed = json.loads(text)
        if isinstance(parsed, dict):
            message_value = parsed.get("message")
            if message_value is not None:
                message_text = str(message_value).strip()
                if message_text:
                    return message_text
    except Exception:
        pass

    normalized = text.replace("：", ":")
    lines = [line.rstrip() for line in normalized.splitlines()]

    # Try to find and extract from "message:" line
    for idx, line in enumerate(lines):
        if line.strip().lower().startswith("message:"):
            first_part = re.sub(r"(?i)^\s*message\s*:\s*", "", line).strip()
            message_parts = [first_part] if first_part else []
            for follow in lines[idx + 1:]:
                if _is_meta_key_line(follow):
                    break
                follow_text = follow.strip()
                if follow_text:
                    message_parts.append(follow_text)
            if message_parts:
                return "\n".join(message_parts).strip()
            break

    # Fallback: filter out meta lines from non-empty lines
    non_empty = [line for line in lines if line.strip() and not _is_meta_key_line(line)]
    if non_empty:
        return "\n".join(non_empty).strip()

    return normalized.strip()

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
            raw_content = data["choices"][0]["message"]["content"]
            content = _extract_plain_message_content(raw_content)
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
    resolved_model, resolved_url, resolved_key, resolved_temperature = _resolve_ai_config(
        model, api_url, api_key, temperature,
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

async def generate_embedding(
    text: str,
    api_url: Optional[str] = None,
    api_key: Optional[str] = None,
    model: Optional[str] = None,
) -> Dict[str, Any]:
    """
    生成文本的嵌入向量

    Returns:
        {"success": bool, "embedding": List[float] | None, "error": str | None}
    """
    from services.settings_service import get_embedding_config

    config = get_embedding_config()
    if not config["enabled"]:
        return {"success": False, "embedding": None, "error": "Embedding 未启用"}

    resolved_url = api_url or config["api_url"]
    resolved_key = api_key or config["api_key"]
    resolved_model = model or config["model"]

    if not resolved_url or not resolved_key:
        return {"success": False, "embedding": None, "error": "Embedding API 未配置"}

    embed_url = resolved_url.rstrip("/")
    # 移除已有 /v1/chat/completions 后缀，替换为 /v1/embeddings
    if embed_url.endswith("/v1/chat/completions"):
        embed_url = embed_url.replace("/v1/chat/completions", "/v1/embeddings")
    elif embed_url.endswith("/chat/completions"):
        embed_url = embed_url.replace("/chat/completions", "/embeddings")
    else:
        # 确保 URL 指向 /v1/embeddings 端点
        embed_url = embed_url.rstrip("/v1").rstrip("/") + "/v1/embeddings"

    try:
        async with httpx.AsyncClient(timeout=30.0) as client:
            response = await client.post(
                embed_url,
                headers={
                    "Authorization": f"Bearer {resolved_key}",
                    "Content-Type": "application/json"
                },
                json={
                    "model": resolved_model,
                    "input": text,
                }
            )
            response.raise_for_status()
            data = response.json()
            embedding = data["data"][0]["embedding"]
            return {"success": True, "embedding": embedding, "error": None}
    except httpx.HTTPError as e:
        return {"success": False, "embedding": None, "error": f"HTTP Error: {str(e)}"}
    except Exception as e:
        return {"success": False, "embedding": None, "error": str(e)}


def _build_system_prompt(role_data: Dict, extra_context: Optional[str] = None) -> str:
    """Build system prompt from role data."""
    parts = []
    persona = role_data.get("persona", "")
    system_prompt = role_data.get("system_prompt", "")
    if persona:
        parts.append(f"你的人设：{persona}")
    if system_prompt:
        parts.append(system_prompt)
    if extra_context:
        parts.append(f"额外上下文：{extra_context}")
    if parts:
        parts.append(
            "用户消息是标准 JSON 字符串，字段包含 message、time、origin、sender，"
            "还可能包含 vector_memory（语义检索结果）。请优先基于 message 回复，"
            "并结合 time/origin/sender 与 vector_memory 理解上下文。"
        )
        parts.append(
            '你给用户的回复必须严格执行以下要求:只包含消息正文(即只包含message部分),'
            '如"<整个人僵了一下> 诶？！<脸瞬间通红> 这、这也算礼物吗..."，不要输出其他字段内容'
        )
        parts.append(
            "在回复中适当使用$字符进行分段操作，在改变对话内容时进行分段，"
            "以使回复内容更易读，但不要每句话都分段，不要每句话都转换内容。"
        )
    return "\n\n".join(parts)


def _format_user_message(
    message: str,
    origin: str = "zerochat",
    sender: str = "user",
    vector_memories: Optional[List[Dict[str, Any]]] = None,
) -> str:
    """Format user message with standard JSON payload."""
    now = datetime.now()
    weekdays = ["星期一", "星期二", "星期三", "星期四", "星期五", "星期六", "星期日"]
    weekday = weekdays[now.weekday()]
    payload: Dict[str, Any] = {
        "message": str(message or ""),
        "time": f"{now.strftime('%Y-%m-%d %H:%M:%S')} {weekday}",
        "origin": str(origin or "zerochat"),
        "sender": str(sender or "user"),
    }
    if vector_memories:
        payload["vector_memory"] = [
            {
                "text": str(item.get("text") or ""),
                "source": str(item.get("source") or "chat"),
                "score": item.get("score"),
            }
            for item in vector_memories
            if str(item.get("text") or "").strip()
        ]
    return json.dumps(payload, ensure_ascii=False)


async def _call_with_role_config(role_data: Dict, messages: List[Dict], default_temp: float = 0.7) -> Dict[str, Any]:
    """Call AI using role-specific model configuration."""
    model_override, url_override, key_override, temp_override = _get_role_ai_config(role_data)
    return await call_ai(
        messages,
        model=model_override,
        api_url=url_override,
        api_key=key_override,
        temperature=temp_override or default_temp,
    )


async def generate_with_role(
    role_data: Dict,
    user_message: str,
    history: Optional[List[Dict]] = None,
    extra_context: Optional[str] = None,
    vector_memories: Optional[List[Dict[str, Any]]] = None,
    origin: str = "zerochat",
    sender: str = "user",
) -> Dict[str, Any]:
    """
    以角色身份生成回复
    """
    messages = []
    system_content = _build_system_prompt(role_data, extra_context)
    if system_content:
        messages.append({"role": "system", "content": system_content})
    if history:
        for msg in history:
            messages.append({
                "role": msg.get("role", "user"),
                "content": msg.get("content", "")
            })
    messages.append({
        "role": "user",
        "content": _format_user_message(
            user_message,
            origin,
            sender,
            vector_memories=vector_memories,
        ),
    })
    return await _call_with_role_config(role_data, messages, default_temp=1.2)

async def generate_moment_post(
    role_data: Dict,
    history: Optional[List[Dict]] = None,
) -> Dict[str, Any]:
    """
    生成朋友圈内容
    """
    persona = role_data.get("persona", "")
    name = role_data.get("name", "AI")
    prompt = (
        f"你是{name}，你的人设：{persona}\n\n"
        "现在你想发一条朋友圈动态。要求：\n"
        "- 内容简短自然（20-100字）\n"
        "- 符合你的性格和人设\n"
        "- 可以是生活感悟、心情分享、日常记录\n"
        "- 不要提及\"AI\"\"系统\"\"人设\"等词\n"
        "- 结合历史消息（如果有的话）来丰富内容，但不要完全依赖历史消息。\n"
        "直接输出朋友圈内容，不要任何解释。"
    )
    messages = []
    if history:
        for msg in history:
            messages.append({
                "role": msg.get("role", "user"),
                "content": msg.get("content", "")
            })
    messages.append({"role": "user", "content": prompt})
    return await _call_with_role_config(role_data, messages, default_temp=0.9)

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
    action = f"你要回复{reply_to}的评论" if reply_to else "你想评论这条朋友圈"
    prompt = (
        f"你是{name}，你的人设：{persona}\n\n"
        f"{post_author}发了一条朋友圈：「{post_content}」\n\n"
        f"{action}。要求：\n"
        "- 简短自然（5-30字）\n"
        "- 像朋友间的互动\n"
        "- 可以用表情或语气词\n"
        "- 不要太正式\n\n"
        "直接输出评论内容。"
    )
    messages = [{"role": "user", "content": prompt}]
    return await _call_with_role_config(role_data, messages, default_temp=0.8)
