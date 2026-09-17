"""
AI 服务
统一处理所有 AI API 调用
"""
import atexit
import json
import logging
import httpx
import re
from urllib.parse import parse_qsl, urlencode, urlsplit, urlunsplit
from datetime import datetime
from typing import Optional, List, Dict, Any, Tuple

from services import prompt_config_service as prompt_config
from services import settings_service

logger = logging.getLogger(__name__)

NO_REPLY_DIRECTIVE = "<无回复/>"
_INLINE_EMOJI_TOOL_RE = re.compile(
    r'<\s*send_emotion_emoji\b(?P<attrs>[^>]*)/\s*>', re.IGNORECASE
)
_INLINE_EMOJI_EMOTION_RE = re.compile(
    r'\bemotion\s*=\s*["\'](?P<emotion>[^"\']*)["\']', re.IGNORECASE
)
_VALID_EMOJI_EMOTION_RE = re.compile(r'^[a-z0-9_-]{1,64}$')


def _prefer_precise_emoji_deliveries(deliveries: List[Any]) -> List[Any]:
    """Avoid rendering a local fallback beside a precise cloud emoji."""
    precise = [item for item in deliveries if isinstance(item, dict)]
    return precise or deliveries


def is_no_reply_directive(content: Any) -> bool:
    """仅接受独立的无回复指令，避免吞掉与正文混合的回复。"""
    return str(content or "").strip() == NO_REPLY_DIRECTIVE


async def _consume_inline_emoji_tool_markup(
    result: Dict[str, Any], role_data: Dict[str, Any]
) -> Dict[str, Any]:
    """Handle providers that emit an emoji tool call as XML in plain text."""
    content = str(result.get("content") or "")
    matches = list(_INLINE_EMOJI_TOOL_RE.finditer(content))
    if not matches:
        return result

    result["content"] = _INLINE_EMOJI_TOOL_RE.sub("", content).strip()
    emojis_called = list(result.get("_emojis_called") or [])
    for match in matches:
        emotion_match = _INLINE_EMOJI_EMOTION_RE.search(match.group("attrs"))
        emotion = (emotion_match.group("emotion") if emotion_match else "").strip().lower()
        if not _VALID_EMOJI_EMOTION_RE.fullmatch(emotion):
            logger.warning("Ignoring invalid inline emoji tool markup: %s", match.group(0))
            continue
        tool_result = await execute_send_emotion_emoji(role_data, emotion)
        if tool_result.startswith("["):
            emojis_called.append(emotion)
        else:
            logger.warning("Inline emoji tool call failed: %s", tool_result)

    result["_emojis_called"] = _prefer_precise_emoji_deliveries(emojis_called)
    return result

# 共享 httpx 客户端连接池
_SHARED_CLIENT: Optional[httpx.AsyncClient] = None
_SHARED_CLIENT_LOCK = None
try:
    import threading
    _SHARED_CLIENT_LOCK = threading.Lock()
except ImportError:
    pass


def _get_http_client() -> httpx.AsyncClient:
    """获取共享 httpx 客户端（带连接池）"""
    global _SHARED_CLIENT
    if _SHARED_CLIENT is not None and not _SHARED_CLIENT.is_closed:
        return _SHARED_CLIENT

    if _SHARED_CLIENT_LOCK:
        with _SHARED_CLIENT_LOCK:
            if _SHARED_CLIENT is not None and not _SHARED_CLIENT.is_closed:
                return _SHARED_CLIENT
            _SHARED_CLIENT = httpx.AsyncClient(
                timeout=httpx.Timeout(60.0, connect=10.0),
                limits=httpx.Limits(
                    max_connections=50,
                    max_keepalive_connections=20,
                    keepalive_expiry=30.0,
                ),
            )
    else:
        _SHARED_CLIENT = httpx.AsyncClient(
            timeout=httpx.Timeout(60.0, connect=10.0),
            limits=httpx.Limits(
                max_connections=50,
                max_keepalive_connections=20,
                keepalive_expiry=30.0,
            ),
        )
    return _SHARED_CLIENT


async def aclose_http_client():
    """异步关闭共享 httpx 客户端（生命周期 shutdown 时调用）"""
    global _SHARED_CLIENT
    if _SHARED_CLIENT is not None and not _SHARED_CLIENT.is_closed:
        await _SHARED_CLIENT.aclose()
    _SHARED_CLIENT = None


def close_http_client():
    """同步关闭共享 httpx 客户端（atexit 兜底）"""
    global _SHARED_CLIENT
    if _SHARED_CLIENT is not None and not _SHARED_CLIENT.is_closed:
        import asyncio
        try:
            asyncio.get_running_loop().create_task(aclose_http_client())
        except RuntimeError:
            pass
    _SHARED_CLIENT = None


atexit.register(close_http_client)


def _is_google_gemini_endpoint(api_url: Optional[str]) -> bool:
    try:
        return (urlsplit(str(api_url or "")).hostname or "").lower() == "generativelanguage.googleapis.com"
    except (TypeError, ValueError):
        return False


def _is_zhipu_endpoint(api_url: Optional[str]) -> bool:
    """智谱开放平台（BigModel/Z.ai）的 OpenAI 兼容端点。"""
    try:
        host = (urlsplit(str(api_url or "")).hostname or "").lower()
    except (TypeError, ValueError):
        return False
    return host in {"open.bigmodel.cn", "api.z.ai"} or host.endswith(".bigmodel.cn")


_API_FORMATS = {"auto", "gemini_native", "openai_compatible", "zhipu_compatible"}


def _normalize_api_format(value: Optional[str]) -> str:
    value = str(value or "auto").strip().lower()
    return value if value in _API_FORMATS else "auto"


def _uses_native_gemini(
    model: Optional[str], api_url: Optional[str], api_format: Optional[str] = None,
) -> bool:
    """Determine whether this request must use Gemini's native protocol."""
    api_format = _normalize_api_format(api_format)
    if api_format == "gemini_native":
        return True
    if api_format in {"openai_compatible", "zhipu_compatible"} or not _is_google_gemini_endpoint(api_url):
        return False
    return _is_gemini_model(model) and "/openai" not in urlsplit(str(api_url or "")).path.lower()


def _normalize_native_gemini_endpoint(api_url: str, model: str) -> str:
    parsed = urlsplit(str(api_url or "").strip())
    path = parsed.path.rstrip("/")
    # Settings may contain a base URL, an OpenAI compatibility URL, or a
    # complete Gemini resource URL. Always rebuild from the API version root.
    path = re.sub(r"/openai(?:/|$)", "/", path, count=1, flags=re.IGNORECASE)
    path = re.sub(r"/models(?:/.*)?$", "", path, flags=re.IGNORECASE)
    path = re.sub(r"/chat/completions$", "", path, flags=re.IGNORECASE).rstrip("/")
    if not path.lower().endswith(("/v1", "/v1beta")):
        path = f"{path}/v1beta"
    normalized_model = str(model or "gemini-2.5-flash").removeprefix("models/")
    return urlunsplit((
        parsed.scheme,
        parsed.netloc,
        f"{path}/models/{normalized_model}:generateContent",
        "",
        "",
    ))


def _with_gemini_api_key(api_url: str, api_key: str) -> str:
    """Use Gemini's query-string API key form required by some gateways."""
    parsed = urlsplit(api_url)
    query = [(key, value) for key, value in parse_qsl(parsed.query, keep_blank_values=True) if key != "key"]
    query.append(("key", api_key))
    return urlunsplit((parsed.scheme, parsed.netloc, parsed.path, urlencode(query), ""))


def _api_url_without_query(api_url: str) -> str:
    parsed = urlsplit(api_url)
    return urlunsplit((parsed.scheme, parsed.netloc, parsed.path, "", ""))


def _normalize_api_url(
    api_url: str, model: Optional[str] = None, api_format: Optional[str] = None,
) -> str:
    """Normalize both OpenAI-compatible and official Gemini endpoints."""
    if _uses_native_gemini(model, api_url, api_format):
        return _normalize_native_gemini_endpoint(api_url, str(model or "gemini-2.5-flash"))
    value = str(api_url or "").strip().rstrip("/")
    if value.endswith("/chat/completions"):
        return value
    # 智谱 API uses /api/paas/v4 as its compatibility root (without /v1).
    if _is_zhipu_endpoint(value) or _normalize_api_format(api_format) == "zhipu_compatible":
        path = urlsplit(value).path.rstrip("/")
        if path.lower().endswith("/v4") or "/api/paas/" in path.lower():
            return f"{value}/chat/completions"
    # Gemini's compatibility endpoint is rooted at /v1beta/openai, not /v1.
    if _is_google_gemini_endpoint(value):
        if _normalize_api_format(api_format) == "openai_compatible" and "/openai" not in urlsplit(value).path.lower():
            value = f"{value}/openai"
        if value.endswith("/openai"):
            return f"{value}/chat/completions"
    return f"{value}/v1/chat/completions"

def _resolve_ai_config(
    model: Optional[str],
    api_url: Optional[str],
    api_key: Optional[str],
    temperature: Optional[float] = None,
    api_format: Optional[str] = None,
) -> Tuple[Optional[str], Optional[str], Optional[str], Optional[float], str, int, str, bool]:
    config = settings_service.load_settings()
    resolved_model = model or config.get("ai_model", "deepseek-chat")
    resolved_format = _normalize_api_format(api_format or config.get("ai_api_format"))
    resolved_url = _normalize_api_url(
        api_url or config.get("ai_api_url", ""), resolved_model, resolved_format,
    )
    resolved_key = api_key or config.get("ai_api_key", "")
    resolved_temperature = temperature if temperature is not None else config.get("ai_temperature", 0.7)
    timeout = config.get("ai_timeout_seconds", 60)
    try:
        timeout = max(1, min(3600, int(timeout)))
    except (TypeError, ValueError):
        timeout = 60
    effort = str(config.get("ai_reasoning_effort") or "").strip()
    return resolved_model, resolved_url, resolved_key, resolved_temperature, resolved_format, timeout, effort, bool(config.get("ai_stream", False))

def _get_role_ai_config(role_data: Optional[Dict]) -> Tuple[Optional[str], Optional[str], Optional[str], Optional[float], str, int, str, bool]:
    if not role_data:
        return _resolve_ai_config(None, None, None, None, None)

    model = role_data.get("ai_model")
    api_url = role_data.get("ai_api_url")
    api_key = role_data.get("ai_api_key")
    temperature = role_data.get("ai_temperature")
    api_format = role_data.get("ai_api_format")
    timeout = role_data.get("ai_timeout_seconds")
    effort = role_data.get("ai_reasoning_effort")
    stream = role_data.get("ai_stream")
    metadata = role_data.get("metadata")
    if isinstance(metadata, dict):
        model = model or metadata.get("ai_model")
        api_url = api_url or metadata.get("ai_api_url")
        api_key = api_key or metadata.get("ai_api_key")
        temperature = temperature if temperature is not None else metadata.get("ai_temperature")
        api_format = api_format or metadata.get("ai_api_format")
        timeout = timeout if timeout is not None else metadata.get("ai_timeout_seconds")
        effort = effort if effort is not None else metadata.get("ai_reasoning_effort")
        stream = stream if stream is not None else metadata.get("ai_stream")

    resolved = _resolve_ai_config(model, api_url, api_key, temperature, api_format)
    if timeout is None and effort is None and stream is None:
        return resolved
    try:
        normalized_timeout = max(1, min(3600, int(timeout))) if timeout is not None else resolved[5]
    except (TypeError, ValueError):
        normalized_timeout = resolved[5]
    return (*resolved[:5], normalized_timeout, str(effort or resolved[6]).strip(), bool(stream) if stream is not None else resolved[7])


def _is_grok_model(model: Optional[str]) -> bool:
    return "grok" in str(model or "").lower()


def _is_deepseek_model(model: Optional[str]) -> bool:
    return "deepseek" in str(model or "").lower()


def _is_mimo_provider(model: Optional[str], api_url: Optional[str] = None) -> bool:
    model_text = str(model or "").lower()
    if "mimo" in model_text:
        return True
    try:
        host = (urlsplit(str(api_url or "")).hostname or "").lower()
    except (TypeError, ValueError):
        host = ""
    return "api.xiaomimimo.com" in host


def _uses_conservative_tool_prompt_policy(model: Optional[str]) -> bool:
    """Apply the stricter tool-call prompt policy to all non-DeepSeek models."""
    return not _is_deepseek_model(model)


def _is_gemini_model(model: Optional[str]) -> bool:
    """Identify Gemini models served through the OpenAI-compatible endpoint."""
    return "gemini" in str(model or "").lower()


def _is_zhipu_model(model: Optional[str], api_url: Optional[str] = None) -> bool:
    text = str(model or "").lower()
    return "glm-" in text or _is_zhipu_endpoint(api_url)


def _is_thinking_quota_provider(api_url: Optional[str]) -> bool:
    host = (urlsplit(str(api_url or "")).hostname or "").lower()
    return "siliconflow" in host or "dashscope" in host or "aliyuncs" in host


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

    # Prefer structured JSON response when present.
    from services.json_parse import extract_json_object

    parsed = extract_json_object(text)
    if parsed is not None:
        message_value = parsed.get("message")
        if message_value is not None:
            message_text = str(message_value).strip()
            if message_text:
                return message_text

    # Strip markdown code fences before line-based fallback parsing
    if text.startswith("```") and text.endswith("```"):
        text = re.sub(r"^```[a-zA-Z0-9_-]*\n?", "", text).rstrip("`").strip()

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

def _build_base_chat_payload(
    messages: List[Dict[str, Any]],
    model: str,
    temperature: float,
    max_tokens: int,
    tools: Optional[List[Dict]],
) -> Dict[str, Any]:
    payload: Dict[str, Any] = {
        "model": model,
        "messages": messages,
        "temperature": temperature,
        "max_tokens": max_tokens,
    }
    if tools:
        payload["tools"] = tools
    return payload


def _gemini_inline_data(image_url: str) -> Optional[Dict[str, str]]:
    """Convert an OpenAI data URL into Gemini's native inlineData part."""
    if not image_url.startswith("data:") or ";base64," not in image_url:
        return None
    prefix, encoded = image_url.split(",", 1)
    mime_type = prefix[5:].split(";", 1)[0].strip()
    if not mime_type or not encoded:
        return None
    return {"mimeType": mime_type, "data": encoded}


def _gemini_parts_from_content(content: Any) -> List[Dict[str, Any]]:
    if isinstance(content, str):
        return [{"text": content}]
    if not isinstance(content, list):
        return [{"text": str(content or "")}]

    parts: List[Dict[str, Any]] = []
    for item in content:
        if not isinstance(item, dict):
            continue
        if item.get("type") == "text":
            parts.append({"text": str(item.get("text") or "")})
        elif item.get("type") == "image_url":
            image = item.get("image_url") or {}
            image_url = str(image.get("url") if isinstance(image, dict) else image)
            inline_data = _gemini_inline_data(image_url)
            if inline_data:
                parts.append({"inlineData": inline_data})
            elif image_url:
                # Gemini native supports externally hosted images through fileData.
                parts.append({"fileData": {"mimeType": "image/*", "fileUri": image_url}})
        elif item.get("type") == "file" and item.get("file_id"):
            # This form is not emitted by Gemini paths, but preserving it as text
            # avoids silently dropping context when a profile is changed mid-chat.
            parts.append({"text": f"Attached file: {item['file_id']}"})
    return parts or [{"text": ""}]


def _build_native_gemini_request(
    messages: List[Dict[str, Any]], api_key: str, model: str,
    temperature: float, max_tokens: int, tools: Optional[List[Dict]],
) -> Tuple[Dict[str, Any], Dict[str, str]]:
    """Translate the internal OpenAI-shaped conversation to generateContent."""
    contents: List[Dict[str, Any]] = []
    system_parts: List[Dict[str, Any]] = []
    tool_names: Dict[str, str] = {}

    for message in messages:
        role = str(message.get("role") or "user")
        if role == "system":
            system_parts.extend(_gemini_parts_from_content(message.get("content", "")))
            continue
        if role == "assistant":
            parts = _gemini_parts_from_content(message.get("content", ""))
            for call in message.get("tool_calls") or []:
                if not isinstance(call, dict):
                    continue
                function = call.get("function") or {}
                name = str(function.get("name") or "")
                if not name:
                    continue
                arguments = function.get("arguments", {})
                if isinstance(arguments, str):
                    try:
                        arguments = json.loads(arguments or "{}")
                    except json.JSONDecodeError:
                        arguments = {}
                part: Dict[str, Any] = {"functionCall": {"name": name, "args": arguments or {}}}
                signature = ((call.get("extra_content") or {}).get("google") or {}).get("thought_signature")
                if signature:
                    part["thoughtSignature"] = signature
                parts.append(part)
                tool_names[str(call.get("id") or name)] = name
            contents.append({"role": "model", "parts": parts})
            continue
        if role == "tool":
            name = tool_names.get(str(message.get("tool_call_id") or ""))
            if name:
                contents.append({
                    "role": "user",
                    "parts": [{"functionResponse": {"name": name, "response": {"result": str(message.get("content") or "")}}}],
                })
            continue
        contents.append({"role": "user", "parts": _gemini_parts_from_content(message.get("content", ""))})

    payload: Dict[str, Any] = {
        "contents": contents,
        "generationConfig": {"temperature": temperature, "maxOutputTokens": max_tokens},
    }
    if system_parts:
        payload["systemInstruction"] = {"parts": system_parts}
    declarations = []
    for tool in tools or []:
        function = tool.get("function") if isinstance(tool, dict) else None
        if isinstance(function, dict) and function.get("name"):
            declarations.append({
                "name": function["name"],
                "description": function.get("description", ""),
                "parameters": function.get("parameters", {"type": "object", "properties": {}}),
            })
    if declarations:
        payload["tools"] = [{"functionDeclarations": declarations}]
    return payload, {"Content-Type": "application/json"}


def _parse_native_gemini_response(data: Dict[str, Any]) -> Tuple[str, List[Dict[str, Any]], Optional[Dict[str, Any]]]:
    candidate = (data.get("candidates") or [{}])[0]
    content = candidate.get("content") or {}
    text_parts: List[str] = []
    tool_calls: List[Dict[str, Any]] = []
    for index, part in enumerate(content.get("parts") or []):
        if not isinstance(part, dict):
            continue
        if part.get("text"):
            text_parts.append(str(part["text"]))
        function_call = part.get("functionCall")
        if isinstance(function_call, dict) and function_call.get("name"):
            call_id = f"gemini-{index}-{function_call['name']}"
            call: Dict[str, Any] = {
                "id": call_id,
                "type": "function",
                "function": {
                    "name": str(function_call["name"]),
                    "arguments": function_call.get("args") or {},
                },
            }
            if part.get("thoughtSignature"):
                call["extra_content"] = {"google": {"thought_signature": part["thoughtSignature"]}}
            tool_calls.append(call)
    return "\n".join(text_parts).strip(), tool_calls, data.get("usageMetadata")


def _build_deepseek_chat_request(
    messages: List[Dict[str, Any]], api_key: str, model: str,
    temperature: float, max_tokens: int, tools: Optional[List[Dict]],
) -> Tuple[Dict[str, Any], Dict[str, str]]:
    """Build a DeepSeek-compatible request, including its thinking extension."""
    payload = _build_base_chat_payload(messages, model, temperature, max_tokens, tools)
    payload["thinking"] = {"type": "enabled" if settings_service.load_settings().get("thinking_enabled", True) else "disabled"}
    return payload, {"Authorization": f"Bearer {api_key}", "Content-Type": "application/json"}


def _build_gemini_chat_request(
    messages: List[Dict[str, Any]], api_key: str, model: str,
    temperature: float, max_tokens: int, tools: Optional[List[Dict]],
) -> Tuple[Dict[str, Any], Dict[str, str]]:
    """Build a Gemini OpenAI-compatibility request with standard fields only."""
    return _build_base_chat_payload(messages, model, temperature, max_tokens, tools), {
        "Authorization": f"Bearer {api_key}", "Content-Type": "application/json",
    }


def _build_mimo_chat_request(
    messages: List[Dict[str, Any]], api_key: str, model: str,
    temperature: float, max_tokens: int, tools: Optional[List[Dict]],
) -> Tuple[Dict[str, Any], Dict[str, str]]:
    """Build a MiMo request with thinking explicitly disabled."""
    payload = _build_base_chat_payload(messages, model, temperature, max_tokens, tools)
    payload["thinking"] = {"type": "disabled"}
    return payload, {
        "Authorization": f"Bearer {api_key}", "Content-Type": "application/json",
    }


def _build_zhipu_chat_request(
    messages: List[Dict[str, Any]], api_key: str, model: str,
    temperature: float, max_tokens: int, tools: Optional[List[Dict]],
) -> Tuple[Dict[str, Any], Dict[str, str]]:
    """Build 智谱's OpenAI-compatible request."""
    return _build_base_chat_payload(messages, model, temperature, max_tokens, tools), {
        "Authorization": f"Bearer {api_key}", "Content-Type": "application/json",
    }


def _build_generic_chat_request(
    messages: List[Dict[str, Any]], api_key: str, model: str,
    temperature: float, max_tokens: int, tools: Optional[List[Dict]],
) -> Tuple[Dict[str, Any], Dict[str, str]]:
    """Build a portable OpenAI-compatible request without provider extensions."""
    return _build_base_chat_payload(messages, model, temperature, max_tokens, tools), {
        "Authorization": f"Bearer {api_key}", "Content-Type": "application/json",
    }


def _build_chat_request(
    messages: List[Dict[str, Any]], api_key: str, model: str, api_url: str,
    temperature: float, max_tokens: int, tools: Optional[List[Dict]],
    api_format: Optional[str] = None,
) -> Tuple[Dict[str, Any], Dict[str, str]]:
    if _uses_native_gemini(model, api_url, api_format):
        return _build_native_gemini_request(messages, api_key, model, temperature, max_tokens, tools)
    if _normalize_api_format(api_format) in {"openai_compatible", "zhipu_compatible"}:
        return _build_generic_chat_request(messages, api_key, model, temperature, max_tokens, tools)
    if _is_deepseek_model(model):
        return _build_deepseek_chat_request(messages, api_key, model, temperature, max_tokens, tools)
    if _is_mimo_provider(model, api_url):
        return _build_mimo_chat_request(messages, api_key, model, temperature, max_tokens, tools)
    if _is_zhipu_model(model, api_url):
        return _build_zhipu_chat_request(messages, api_key, model, temperature, max_tokens, tools)
    if _is_gemini_model(model):
        return _build_gemini_chat_request(messages, api_key, model, temperature, max_tokens, tools)
    return _build_generic_chat_request(messages, api_key, model, temperature, max_tokens, tools)


def _usage_platform(api_url: str) -> str:
    """Return the provider host used for a usage-statistics bucket."""
    try:
        return (urlsplit(str(api_url or "")).hostname or "").lower() or "未知平台"
    except (TypeError, ValueError):
        return "未知平台"


async def _post_chat_stream(client, endpoint, headers, payload, timeout_seconds, messages, model, stats_role_id):
    text_parts, reasoning_parts, tool_calls = [], [], {}
    usage = None
    timeout = httpx.Timeout(float(timeout_seconds), connect=min(20.0, float(timeout_seconds)))
    async with client.stream("POST", endpoint, headers=headers, json=payload, timeout=timeout) as response:
        response.raise_for_status()
        async for line in response.aiter_lines():
            line = line.strip()
            if not line or not line.startswith("data:"):
                continue
            raw = line[5:].strip()
            if raw == "[DONE]":
                break
            item = json.loads(raw)
            usage = item.get("usage") or usage
            for choice in item.get("choices") or []:
                delta = choice.get("delta") or {}
                if delta.get("content"):
                    text_parts.append(str(delta["content"]))
                if delta.get("reasoning_content"):
                    reasoning_parts.append(str(delta["reasoning_content"]))
                for tc in delta.get("tool_calls") or []:
                    index = tc.get("index", 0)
                    current = tool_calls.setdefault(index, {"id": "", "type": "function", "function": {"name": "", "arguments": ""}})
                    current["id"] += str(tc.get("id") or "")
                    function = tc.get("function") or {}
                    current["function"]["name"] += str(function.get("name") or "")
                    current["function"]["arguments"] += str(function.get("arguments") or "")
    content = _extract_plain_message_content("".join(text_parts))
    if not content and not tool_calls:
        raise ValueError("empty streaming response")
    result = {"success": True, "content": content, "user_content": messages[-1], "error": None}
    if usage:
        result["usage"] = usage
    if tool_calls:
        result["tool_calls"] = list(tool_calls.values())
        result["assistant_content"] = "".join(text_parts) or None
    if reasoning_parts:
        result["reasoning_content"] = "".join(reasoning_parts)
    if usage and stats_role_id:
        try:
            from services.memory_service import record_usage, _run_db
            await _run_db(
                stats_role_id,
                record_usage,
                stats_role_id,
                usage,
                model,
                _usage_platform(endpoint),
            )
        except Exception as exc:
            logger.warning("record_usage failed: %s", exc)
    return result


def _apply_thinking_config(
    payload: Dict[str, Any], model: str, api_url: str, native_gemini: bool,
    enabled: Optional[bool], effort: str, budget: Optional[int],
) -> None:
    explicit_enabled = enabled
    if enabled is None:
        enabled = bool(settings_service.load_settings().get("thinking_enabled", True))
    try:
        budget = int(budget) if budget is not None else None
    except (TypeError, ValueError):
        budget = None
    if budget is not None and budget <= 0:
        budget = None
    if native_gemini:
        config = {}
        if not enabled:
            config["thinkingBudget"] = 0
        elif budget is not None:
            config["thinkingBudget"] = budget
        elif effort and "gemini-3" in model.lower():
            config["thinkingLevel"] = effort
        if config:
            payload["generationConfig"]["thinkingConfig"] = config
    elif _is_thinking_quota_provider(api_url):
        # Hosted DeepSeek models use the hosting provider's request schema.
        payload.pop("thinking", None)
        payload["enable_thinking"] = enabled
        if enabled:
            if budget is None:
                try:
                    budget = max(1, int(effort))
                except (TypeError, ValueError):
                    pass
            if budget is not None:
                payload["thinking_budget"] = budget
    elif _is_deepseek_model(model) or _is_mimo_provider(model, api_url):
        if _is_mimo_provider(model, api_url) and explicit_enabled is None:
            enabled = False
        payload["thinking"] = {"type": "enabled" if enabled else "disabled"}
        if enabled and effort:
            payload["reasoning_effort"] = effort
    elif _is_zhipu_model(model, api_url) and ("glm-4.5" in model.lower() or "glm-4.6" in model.lower()):
        payload["thinking"] = {"type": "enabled" if enabled else "disabled"}
    elif enabled and effort:
        payload["reasoning_effort"] = effort
    elif not enabled and explicit_enabled is not None and re.fullmatch(
        r"gpt-5\.(?:1|2|3|4)(?:-\d{4}-\d{2}-\d{2})?", model.lower(),
    ):
        payload["reasoning_effort"] = "none"


async def _post_chat(
    messages: List[Dict[str, str]],
    api_url: str,
    api_key: str,
    model: str,
    temperature: float,
    max_tokens: int,
    tools: Optional[List[Dict]] = None,
    stats_role_id: Optional[str] = None,
    api_format: Optional[str] = None,
    timeout_seconds: int = 60,
    reasoning_effort: str = "",
    stream: bool = False,
    thinking_enabled: Optional[bool] = None,
    thinking_budget: Optional[int] = None,
) -> Dict[str, Any]:
    try:
        api_format = _normalize_api_format(api_format)
        native_gemini = _uses_native_gemini(model, api_url, api_format)
        endpoint = _normalize_api_url(api_url, model, api_format) if native_gemini else api_url
        if native_gemini:
            endpoint = _with_gemini_api_key(endpoint, api_key)
        payload, headers = _build_chat_request(
            messages,
            api_key,
            model,
            api_url,
            temperature,
            max_tokens,
            tools,
            api_format,
        )
        _apply_thinking_config(payload, model, api_url, native_gemini,
                               thinking_enabled, reasoning_effort, thinking_budget)
        if stream and not native_gemini:
            payload["stream"] = True
        client = _get_http_client()
        if stream and not native_gemini:
            try:
                return await _post_chat_stream(client, endpoint, headers, payload, timeout_seconds, messages, model, stats_role_id)
            except Exception as exc:
                logger.warning("Streaming chat failed, retrying non-stream: %s", exc)
                payload.pop("stream", None)
        response = await client.post(
            endpoint,
            headers=headers,
            json=payload,
            timeout=httpx.Timeout(float(timeout_seconds), connect=min(20.0, float(timeout_seconds))),
        )
        response.raise_for_status()
        data = response.json()
        if native_gemini:
            assistant_content, tool_calls, usage = _parse_native_gemini_response(data)
            content = _extract_plain_message_content(assistant_content)
            message: Dict[str, Any] = {}
        else:
            message = data["choices"][0]["message"]
            assistant_content = message.get("content")
            content = _extract_plain_message_content(assistant_content or "")
            tool_calls = message.get("tool_calls")
            usage = data.get("usage")
        # DeepSeek 等 API 可能在限速时返回 200 OK 但 content 为空
        if not content and not tool_calls:
            return {"success": False, "content": None, "error": "AI 返回了空内容，可能是 API 限速或服务不稳定，请重试"}
        if usage:
            # 按角色累计 token 用量与缓存量（无角色的辅助调用不计入）
            if stats_role_id:
                try:
                    from services.memory_service import record_usage, _run_db
                    await _run_db(
                        stats_role_id,
                        record_usage,
                        stats_role_id,
                        usage,
                        model,
                        _usage_platform(endpoint),
                    )
                except Exception as exc:
                    logger.warning("record_usage failed: %s", exc)
        result = {"success": True, "content": content, "user_content": messages[-1], "error": None}
        if usage:
            result["usage"] = usage
        if tool_calls:
            result["tool_calls"] = tool_calls
            # DeepSeek requires the assistant's original tool-call message to
            # be replayed before each role=tool result. Do not substitute the
            # display-normalized content here; it may be null or empty.
            result["assistant_content"] = assistant_content
        # DeepSeek 等 API 的 thinking 模式会返回 reasoning_content，重调时需原样传回
        if message.get("reasoning_content"):
            result["reasoning_content"] = message["reasoning_content"]
        return result
    except httpx.HTTPStatusError as e:
        resp_body = e.response.text if e.response else ""
        logger.error(
            "AI API HTTP %s 错误: url=%s, model=%s, tool_count=%d, response=%s",
            e.response.status_code if e.response else "?",
            _api_url_without_query(endpoint) if 'endpoint' in locals() else _api_url_without_query(api_url),
            model,
            len(tools) if tools else 0,
            resp_body[:1000],
        )
        return {"success": False, "content": None, "error": "AI 接口请求失败"}
    except Exception as e:
        logger.error("AI API 调用异常: url=%s, model=%s: %s", api_url, model, e, exc_info=True)
        return {"success": False, "content": None, "error": "AI 接口请求失败"}

async def call_ai(
    messages: List[Dict[str, str]],
    model: Optional[str] = None,
    api_url: Optional[str] = None,
    api_key: Optional[str] = None,
    temperature: float = 0.7,
    max_tokens: int = 1000,
    tools: Optional[List[Dict]] = None,
    stats_role_id: Optional[str] = None,
    api_format: Optional[str] = None,
    timeout_seconds: Optional[int] = None,
    reasoning_effort: Optional[str] = None,
    stream: Optional[bool] = None,
    thinking_enabled: Optional[bool] = None,
    thinking_budget: Optional[int] = None,
) -> Dict[str, Any]:
    """
    统一 AI API 调用

    Args:
        messages: 消息列表 [{"role": "system/user/assistant", "content": "..."}]
        model: 模型名称，默认从配置读取
        temperature: 温度参数
        max_tokens: 最大 token 数
        stats_role_id: 若提供，则按该角色累计记录本次 token/缓存用量

    Returns:
        {"success": bool, "content": str, "error": str}
    """
    resolved_model, resolved_url, resolved_key, resolved_temperature, resolved_format, config_timeout, config_effort, config_stream = _resolve_ai_config(
        model, api_url, api_key, temperature, api_format,
    )
    timeout_seconds = config_timeout if timeout_seconds is None else max(1, min(3600, int(timeout_seconds)))
    reasoning_effort = config_effort if reasoning_effort is None else reasoning_effort.strip()
    stream = config_stream if stream is None else bool(stream)
    thinking = settings_service.get_thinking_config()
    if not resolved_url or not resolved_key:
        return {"success": False, "content": None, "error": "AI API 未配置"}

    return await _post_chat(
        messages=messages,
        api_url=resolved_url,
        api_key=resolved_key,
        model=resolved_model,
        temperature=resolved_temperature,
        max_tokens=max_tokens,
        tools=tools,
        stats_role_id=stats_role_id,
        api_format=resolved_format,
        timeout_seconds=timeout_seconds,
        reasoning_effort=reasoning_effort,
        stream=stream,
        thinking_enabled=thinking["thinking_enabled"] if thinking_enabled is None else thinking_enabled,
        thinking_budget=thinking["thinking_budget"] if thinking_budget is None else thinking_budget,
    )

async def call_ai_direct(
    messages: List[Dict[str, str]],
    api_url: str,
    api_key: str,
    model: str,
    temperature: float = 0.7,
    max_tokens: int = 1000,
    api_format: Optional[str] = None,
    thinking_enabled: Optional[bool] = None,
    thinking_budget: Optional[int] = None,
    reasoning_effort: str = "",
    timeout_seconds: int = 60,
) -> Dict[str, Any]:
    """
    独立调用 AI（不依赖全局配置）
    """
    if not api_url or not api_key or not model:
        return {"success": False, "content": None, "error": "AI API 未配置"}
    api_url = _normalize_api_url(api_url, model, api_format)
    return await _post_chat(
        messages=messages,
        api_url=api_url,
        api_key=api_key,
        model=model,
        temperature=temperature,
        max_tokens=max_tokens,
        api_format=api_format,
        timeout_seconds=timeout_seconds,
        thinking_enabled=thinking_enabled,
        thinking_budget=thinking_budget,
        reasoning_effort=reasoning_effort,
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

    embed_url = _normalize_embedding_url(resolved_url)

    try:
        client = _get_http_client()
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
    except httpx.HTTPStatusError as e:
        if e.response.status_code == 401:
            return {
                "success": False,
                "embedding": None,
                "error": "Embedding API authentication failed (HTTP 401). Update the embedding API key.",
            }
        return {"success": False, "embedding": None, "error": f"Embedding API HTTP {e.response.status_code}"}
    except httpx.HTTPError as e:
        return {"success": False, "embedding": None, "error": f"Embedding API request failed: {e}"}
    except Exception as e:
        return {"success": False, "embedding": None, "error": str(e)}


def _normalize_embedding_url(api_url: str) -> str:
    """Convert an OpenAI-compatible base or chat URL to its embeddings endpoint."""
    parsed = urlsplit(api_url.strip())
    path = parsed.path.rstrip("/")
    if path.endswith("/chat/completions"):
        path = f"{path[:-len('/chat/completions')]}/embeddings"
    elif not path.endswith("/embeddings"):
        path = f"{path}/embeddings" if path.endswith("/v1") else f"{path}/v1/embeddings"
    return urlunsplit((parsed.scheme, parsed.netloc, path, "", ""))


def _build_stats_instruction(
    role_data: Dict,
    stats_current: Optional[Dict[str, Any]] = None,
    include_current_values: bool = True,
    settings: Optional[Dict[str, Any]] = None,
) -> str:
    """根据角色的 stats_config 构建数值系统指令。未启用则返回空串。"""
    stats_config = role_data.get("stats_config") or {}
    if not stats_config.get("enabled"):
        return ""
    stats = stats_config.get("stats") or []
    if not stats:
        return ""
    stats_current = stats_current or {}
    resolved_model, resolved_url = _get_prompt_target(role_data)
    is_grok = _is_grok_model(resolved_model)
    layout_rule = prompt_config.resolve(
        prompt_config.CHAT_STATS_BULLET_GROK_ID if is_grok
        else prompt_config.CHAT_STATS_BULLET_DEFAULT_ID,
        settings=settings,
        api_url=resolved_url,
        model=resolved_model,
        role_data=role_data,
    )
    lines = [
        "【数值系统】\n"
        "你需要维护以下数值，并在每次回复中输出一个数值块，格式为："
        "<数值>键1:值1;键2:值2;...</数值>（每个数值用 键:值 表示，多个用 ; 分隔）。\n"
        "规则：\n"
        "  - 当前用户消息是顶层 JSON 对象，stats_current 是独立字段（不在 message 文本内）；"
        "每次生成前都必须读取它，并检查上下文中最近一条 <数值> 块；"
        "stats_current 是最新状态的优先来源，字段缺失时才使用最近数值块，不能重新按 initial 值开始或只维护发生变化的数值\n"
        "  - 即使本轮没有变化，也必须完整回写全部数值；不得省略、删除、改名或只输出变化项；"
        "本轮输出的完整数值块将作为下一轮上下文的最新状态\n"
        "  - 必须覆盖下方列出的全部数值，取值为数字且必须落在各自的上下限区间内\n"
        "  - 依据数值的作用与当前对话情境合理演化（可增可减，变化幅度要自然）\n",
        layout_rule,
        "当前各数值及其定义：",
    ]
    for item in stats:
        if not isinstance(item, dict):
            continue
        key = str(item.get("key") or "").strip()
        if not key:
            continue
        name = str(item.get("name") or key).strip()
        vmin = item.get("min", 0)
        vmax = item.get("max", 100)
        initial = item.get("initial")
        desc = str(item.get("description") or "").strip()
        desc_part = f"，作用：{desc}" if desc else ""
        if include_current_values:
            cur = stats_current.get(key)
            if cur is None:
                cur = initial if initial is not None else vmin
            state_part = f"当前 {cur}"
        else:
            state_part = "当前值见用户消息的 stats_current 字段"
        lines.append(
            f"  - {name}（键 {key}）：{state_part}，范围 [{vmin}, {vmax}]{desc_part}"
        )
    return "\n".join(lines)



def _get_prompt_target(role_data: Dict) -> Tuple[str, str]:
    """Use the configured URL, matching client profile keys, before HTTP expansion."""
    model, _, _, _, _, _, _, _ = _get_role_ai_config(role_data)
    metadata = role_data.get("metadata") or {}
    if not isinstance(metadata, dict):
        metadata = {}
    api_url = (role_data.get("ai_api_url") or metadata.get("ai_api_url")
               or settings_service.load_settings().get("ai_api_url") or "")
    return str(model or ""), str(api_url)


def _prompt_variant(model: Optional[str]) -> str:
    """Pick the prompt variant for a model (only emoji tool rules vary today)."""
    return "cloud_emoji" if _emoji_plugin is not None and bool(
        getattr(_emoji_plugin, "TOOLS", [])
    ) else "default"


def _onebot_main_qq_hint(role_data: Dict) -> str:
    onebot_cfg = role_data.get("onebot_config") or {}
    main_qq = str(onebot_cfg.get("main_user_id") or "").strip()
    return f"（QQ号：{main_qq}）" if main_qq else ""


def _build_system_prompt(
    role_data: Dict,
    extra_context: Optional[str] = None,
    is_onebot: bool = False,
    include_runtime_context: bool = True,
    settings: Optional[Dict[str, Any]] = None,
) -> str:
    """Build system prompt from role data and the configurable prompt registry."""
    parts: List[str] = []
    stats_config = role_data.get("stats_config") or {}
    stats_enabled = bool(stats_config.get("enabled") and stats_config.get("stats"))
    sound_enabled = role_data.get("show_sound", True) is not False
    resolved_model, resolved_url = _get_prompt_target(role_data)
    is_grok = _is_grok_model(resolved_model)
    use_conservative_tool_prompt_policy = _uses_conservative_tool_prompt_policy(
        resolved_model
    )
    variant = _prompt_variant(resolved_model)

    def resolve(prompt_id: str, render: Optional[Dict[str, str]] = None) -> str:
        return prompt_config.resolve(
            prompt_id,
            settings=settings,
            api_url=resolved_url,
            model=resolved_model,
            role_data=role_data,
            variant=variant,
            render=render,
        )

    # Protocol tokens stay code-owned; user-editable templates reference them by name.
    # NOTE: do not blank EMOJI_TOOL_RULE here — resolve() already substitutes the branch
    # selected by `variant`, and overriding it with "" would silently drop rule 2.
    render_vars = {
        "NO_REPLY_DIRECTIVE": NO_REPLY_DIRECTIVE,
        "STATS_LAYOUT_RULE": resolve(
            prompt_config.CHAT_STATS_LAYOUT_GROK_ID if is_grok
            else prompt_config.CHAT_STATS_LAYOUT_DEFAULT_ID
        ),
        "MAIN_QQ_HINT": _onebot_main_qq_hint(role_data),
        "TOOL_POLICY_CONSERVATIVE": (
            resolve(prompt_config.CHAT_TOOL_POLICY_CONSERVATIVE_ID)
            if use_conservative_tool_prompt_policy else ""
        ),
    }

    def prompt(prompt_id: str) -> str:
        return resolve(prompt_id, render_vars)

    if not is_onebot:
        parts.append(prompt(prompt_config.CHAT_FORMAT_PROTOCOL_ID))
        if stats_enabled:
            parts.append(prompt(prompt_config.CHAT_STATS_BLOCK_ID))
        if sound_enabled:
            parts.append(prompt(prompt_config.CHAT_SOUND_DEDUP_ID))

    # 安全规则放在最前面，确保最高优先级
    if is_onebot:
        parts.append(prompt(prompt_config.ONEBOT_SYSTEM_DIRECTIVE_ID))

    # 通用工具能力（所有场景可用）；表情工具分支由 variant 决定，
    # 可选表情包插件的指引在其声明了 PROMPT 时并入。
    parts.append(prompt(prompt_config.CHAT_TOOL_RULES_ID))
    if _emoji_plugin is not None and getattr(_emoji_plugin, "PROMPT", ""):
        parts.append(_emoji_plugin.PROMPT)
    # 角色人设（优先级低于系统级指令）
    persona = role_data.get("persona", "")
    system_prompt = role_data.get("system_prompt", "")
    if persona:
        parts.append(f"你的人设：{persona}")
    if system_prompt:
        parts.append(system_prompt)
    if include_runtime_context and extra_context:
        parts.append(f"额外上下文：{extra_context}")
    if parts:
        parts.append(prompt(prompt_config.CHAT_USER_MESSAGE_JSON_HINT_ID))
        if not is_onebot:
            parts.append(prompt(prompt_config.CHAT_REPLY_FORMAT_HINT_ID))
            parts.append(prompt(prompt_config.CHAT_NO_REPLY_ID))
            stats_instruction = _build_stats_instruction(
                role_data,
                include_current_values=False,
                settings=settings,
            )
            if stats_instruction:
                parts.append(stats_instruction)
    return "\n\n".join(parts)


def _format_user_message(
    message: str,
    origin: str = "zerochat",
    sender: str = "user",
    vector_memories: Optional[List[Dict[str, Any]]] = None,
    core_memory_context: Optional[str] = None,
    stats_current: Optional[Dict[str, Any]] = None,
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
    if core_memory_context:
        payload["core_memory"] = str(core_memory_context)
    if stats_current:
        payload["stats_current"] = stats_current
    # 向量记忆已封装为 search_memory 工具，不再被动注入
    return json.dumps(payload, ensure_ascii=False)


async def _call_with_role_config(
    role_data: Dict,
    messages: List[Dict],
    default_temp: float = 0.7,
    tools: Optional[List[Dict]] = None,
) -> Dict[str, Any]:
    """Call AI using role-specific model configuration."""
    model_override, url_override, key_override, temp_override, format_override, timeout_seconds, reasoning_effort, stream = _get_role_ai_config(role_data)
    stats_role_id = str(role_data.get("id") or "").strip() if isinstance(role_data, dict) else ""
    thinking = settings_service.get_thinking_config(role_data=role_data)
    return await call_ai(
        messages,
        model=model_override,
        api_url=url_override,
        api_key=key_override,
        temperature=temp_override or default_temp,
        tools=tools,
        stats_role_id=stats_role_id or None,
        api_format=format_override,
        timeout_seconds=timeout_seconds,
        reasoning_effort=reasoning_effort,
        stream=stream,
        thinking_enabled=thinking["thinking_enabled"],
        thinking_budget=thinking["thinking_budget"],
    )


def _append_grok_reasoning_followup_context(
    messages: List[Dict[str, Any]],
    result: Dict[str, Any],
    resolved_model: Optional[str],
) -> None:
    """Preserve Grok reasoning context when a turn needs a second pass."""
    if not _is_grok_model(resolved_model):
        return
    assistant_content = result.get("assistant_content", result.get("content"))
    if assistant_content is None and not result.get("reasoning_content"):
        return
    assistant_msg: Dict[str, Any] = {
        "role": "assistant",
        "content": assistant_content,
    }
    if result.get("reasoning_content"):
        assistant_msg["reasoning_content"] = result["reasoning_content"]
    messages.append(assistant_msg)


from services.ai_tools import (
    _SCHEDULE_TASK_TOOL,
    _SET_ALARM_TOOL,
    _CONTINUE_IF_NO_REPLY_TOOL,
    _BLOCK_USER_TOOL,
    _SEARCH_MEMORY_TOOL,
    _SEND_EMOTION_EMOJI_TOOL,
    _WEB_SEARCH_TOOL,
    _WRITE_MEMORY_TOOL,
    _RECOGNIZE_IMAGE_TOOL,
    _REVIEW_PREVIOUS_IMAGES_TOOL,
    execute_schedule_task,
    execute_set_alarm,
    execute_continue_if_no_reply,
    execute_block_user,
    execute_search_memory,
    execute_send_emotion_emoji,
    execute_web_search,
    execute_write_memory,
    execute_recognize_image,
)

# 可选表情包插件：存在则并入工具集/提示词/分发，缺失则完全回退到内置行为。
try:
    from services import emoji_ivs_plugin as _emoji_plugin
except Exception as _emoji_plugin_err:  # noqa: BLE001
    _emoji_plugin = None
    logger.debug("可选表情包插件未加载: %s", _emoji_plugin_err)


async def generate_with_role(
    role_data: Dict,
    user_message: str,
    history: Optional[List[Dict]] = None,
    extra_context: Optional[str] = None,
    core_memory_context: Optional[str] = None,
    vector_memories: Optional[List[Dict[str, Any]]] = None,
    origin: str = "zerochat",
    sender: str = "user",
    stats_current: Optional[Dict[str, Any]] = None,
    vision_context: Optional[Dict[str, Any]] = None,
) -> Dict[str, Any]:
    """
    以角色身份生成回复

    vision_context: 工具模式识图上下文，包含本次和同一会话上一批图片。
    """
    messages = []
    is_onebot = origin.startswith("onebot")
    is_third_party = is_onebot and sender != "user"
    resolved_model, _, _, _, _, _, _, _ = _get_role_ai_config(role_data)
    system_content = _build_system_prompt(
        role_data,
        None,
        is_onebot=is_onebot,
        include_runtime_context=False,
    )
    system_parts = [system_content] if system_content else []
    if extra_context:
        system_parts.append(f"额外上下文：{extra_context}")
    if system_parts:
        messages.append({"role": "system", "content": "\n\n".join(system_parts)})
    if history:
        for msg in history:
            history_role = msg.get("role", "user")
            if history_role == "system":
                history_role = "user"
            messages.append({
                "role": history_role,
                "content": msg.get("content", "")
            })
    messages.append({
        "role": "user",
        "content": _format_user_message(
            user_message,
            origin,
            sender,
            vector_memories=vector_memories,
            core_memory_context=core_memory_context,
            stats_current=stats_current,
        ),
    })

    # 工具配置：schedule_task、search_memory、send_emotion_emoji、
    # web_search、write_memory 对所有场景开放；block_user 仅对第三方用户开放
    active_tools = list(_SCHEDULE_TASK_TOOL)
    active_tools.extend(_SEARCH_MEMORY_TOOL)
    if _emoji_plugin is not None:
        active_tools.extend(getattr(_emoji_plugin, "TOOLS", []))
    else:
        active_tools.extend(_SEND_EMOTION_EMOJI_TOOL)
    active_tools.extend(_WEB_SEARCH_TOOL)
    active_tools.extend(_WRITE_MEMORY_TOOL)
    # set_alarm 作用于用户设备的系统闹钟/日历，仅对有设备的场景开放
    # continue_if_no_reply（无回复续写）同样仅对有设备的场景开放
    if not is_onebot:
        active_tools.extend(_SET_ALARM_TOOL)
        active_tools.extend(_CONTINUE_IF_NO_REPLY_TOOL)
    if is_third_party:
        active_tools.extend(_BLOCK_USER_TOOL)
    # 工具模式识图：本次消息附带图片时，开放 recognize_image 供模型调用。
    image_data_urls = list((vision_context or {}).get("image_data_urls") or [])
    previous_image_data_urls = list((vision_context or {}).get("previous_image_data_urls") or [])
    if image_data_urls:
        active_tools.extend(_RECOGNIZE_IMAGE_TOOL)
    if previous_image_data_urls:
        active_tools.extend(_REVIEW_PREVIOUS_IMAGES_TOOL)
    tools = active_tools if active_tools else None
    result = await _call_with_role_config(
        role_data,
        messages,
        default_temp=1.2,
        tools=tools,
    )

    # 处理 tool_calls
    if result.get("tool_calls"):
        result = await _handle_tool_calls(
            result,
            messages,
            role_data,
            tools,
            vision_context=vision_context,
        )

    # Some models prioritize another tool (for example memory or web search)
    # despite the image-tool instruction. Never let that turn into a reply
    # which silently ignores an image attached to the current message.
    if image_data_urls and not result.get("_recognized_current_image"):
        image_understanding = await execute_recognize_image(
            image_data_urls,
            user_message,
            0,
        )
        image_context = (
            "[Image recognition result - must use]\n"
            f"{image_understanding}\n"
            "Answer the user's current message using this image information."
        )
        _append_grok_reasoning_followup_context(messages, result, resolved_model)
        # The vision response is external data. Keep it at user priority and
        # preserve the original system prompt for every provider.
        messages.append({"role": "user", "content": image_context})
        result = await _call_with_role_config(
            role_data,
            messages,
            default_temp=1.2,
            tools=tools,
        )
        if result.get("tool_calls"):
            result = await _handle_tool_calls(
                result,
                messages,
                role_data,
                tools,
                vision_context=vision_context,
            )

    return await _consume_inline_emoji_tool_markup(result, role_data)


async def _handle_tool_calls(
    result: Dict[str, Any],
    messages: List[Dict[str, Any]],
    role_data: Dict,
    tools: Optional[List[Dict]],
    vision_context: Optional[Dict[str, Any]] = None,
) -> Dict[str, Any]:
    """
    处理 AI 返回的 tool_calls，支持多轮工具调用循环（最多 5 轮）。
    每轮执行所有工具调用，将结果注入消息历史后重新调用 AI，
    若 AI 继续返回 tool_calls 则继续循环，直到获得纯文本回复。
    """
    # 元素可为 str（情绪名，走随机）或 dict（精确云端文件 {category, filename}）
    emojis_called: List[Any] = []
    recognized_current_image = False
    max_rounds = 5

    for round_idx in range(max_rounds):
        # DeepSeek requires its original assistant tool-call message, followed
        # by one role=tool message per tool_call_id.
        assistant_msg: Dict[str, Any] = {
            "role": "assistant",
            "content": result.get("assistant_content", result.get("content")),
            "tool_calls": result["tool_calls"],
        }
        if "reasoning_content" in result:
            assistant_msg["reasoning_content"] = result["reasoning_content"]
        messages.append(assistant_msg)

        for tc in result["tool_calls"]:
            if not isinstance(tc, dict):
                logger.warning("Ignoring malformed tool call: %r", tc)
                continue
            tool_call_id = str(tc.get("id") or "").strip()
            if not tool_call_id:
                logger.warning("Ignoring tool call without id: %r", tc)
                continue
            func = tc.get("function", {})
            if not isinstance(func, dict):
                logger.warning("Ignoring tool call without function: %r", tc)
                continue
            func_name = func.get("name", "")
            try:
                from services.json_parse import extract_json_object
                raw_args = func.get("arguments", "{}")
                args = raw_args if isinstance(raw_args, dict) else extract_json_object(raw_args)
                if args is None:
                    args = {}

                if func_name == "schedule_task":
                    msg = str(args.get("message", "")).strip()
                    trigger_time = str(args.get("trigger_time", "")).strip()
                    repeat = str(args.get("repeat", "none")).strip()
                    logger.info(f"Tool call: schedule_task [message={msg}, trigger_time={trigger_time}, repeat={repeat}]")
                    if msg and trigger_time:
                        tool_result = await execute_schedule_task(role_data, msg, trigger_time, repeat)
                        messages.append({"role": "tool", "tool_call_id": tool_call_id, "content": tool_result})
                        logger.info(f"Tool result: schedule_task -> {tool_result[:100]}")
                    else:
                        err = "参数不完整：message 和 trigger_time 为必填"
                        messages.append({"role": "tool", "tool_call_id": tool_call_id, "content": err})
                        logger.warning(f"Tool error: schedule_task -> {err}")

                elif func_name == "set_alarm":
                    title = str(args.get("title", "")).strip()
                    trigger_time = str(args.get("trigger_time", "")).strip()
                    kind = str(args.get("kind", "alarm")).strip()
                    note = str(args.get("note", "")).strip()
                    logger.info(f"Tool call: set_alarm [title={title}, trigger_time={trigger_time}, kind={kind}]")
                    if title and trigger_time:
                        tool_result = await execute_set_alarm(role_data, title, trigger_time, kind, note)
                        messages.append({"role": "tool", "tool_call_id": tool_call_id, "content": tool_result})
                        logger.info(f"Tool result: set_alarm -> {tool_result[:100]}")
                    else:
                        err = "参数不完整：title 和 trigger_time 为必填"
                        messages.append({"role": "tool", "tool_call_id": tool_call_id, "content": err})
                        logger.warning(f"Tool error: set_alarm -> {err}")

                elif func_name == "continue_if_no_reply":
                    delay_minutes = args.get("delay_minutes")
                    prompt = str(args.get("prompt", "")).strip()
                    logger.info(f"Tool call: continue_if_no_reply [delay_minutes={delay_minutes}, prompt={prompt[:60]}]")
                    if delay_minutes is not None and prompt:
                        tool_result = await execute_continue_if_no_reply(role_data, delay_minutes, prompt)
                        messages.append({"role": "tool", "tool_call_id": tool_call_id, "content": tool_result})
                        logger.info(f"Tool result: continue_if_no_reply -> {tool_result[:100]}")
                    else:
                        err = "参数不完整：delay_minutes 和 prompt 为必填"
                        messages.append({"role": "tool", "tool_call_id": tool_call_id, "content": err})
                        logger.warning(f"Tool error: continue_if_no_reply -> {err}")

                elif func_name == "block_user":
                    uid = str(args.get("user_id", "")).strip()
                    reason = str(args.get("reason", "")).strip() or "未说明原因"
                    logger.info(f"Tool call: block_user [user_id={uid}, reason={reason}]")
                    if uid:
                        tool_result = await execute_block_user(role_data, uid, reason)
                        messages.append({"role": "tool", "tool_call_id": tool_call_id, "content": tool_result})
                        logger.info(f"Tool result: block_user -> {tool_result[:100]}")
                    else:
                        err = "参数不完整：user_id 为必填"
                        messages.append({"role": "tool", "tool_call_id": tool_call_id, "content": err})
                        logger.warning(f"Tool error: block_user -> {err}")

                elif func_name == "search_memory":
                    query = str(args.get("query", "")).strip()
                    logger.info(f"Tool call: search_memory [query={query[:80]}]")
                    if query:
                        tool_result = await execute_search_memory(role_data, query)
                        messages.append({"role": "tool", "tool_call_id": tool_call_id, "content": tool_result})
                        logger.info(f"Tool result: search_memory -> {tool_result[:100]}")
                    else:
                        err = "参数不完整：query 为必填"
                        messages.append({"role": "tool", "tool_call_id": tool_call_id, "content": err})
                        logger.warning(f"Tool error: search_memory -> {err}")

                elif func_name == "send_emotion_emoji":
                    emotion = str(args.get("emotion", "")).strip()
                    logger.info(f"Tool call: send_emotion_emoji [emotion={emotion}]")
                    if emotion:
                        tool_result = await execute_send_emotion_emoji(role_data, emotion)
                        if not tool_result.startswith("没有找到"):
                            emojis_called.append(emotion)
                        messages.append({"role": "tool", "tool_call_id": tool_call_id, "content": tool_result})
                        logger.info(f"Tool result: send_emotion_emoji -> {tool_result[:100]}")
                    else:
                        err = "参数不完整：emotion 为必填"
                        messages.append({"role": "tool", "tool_call_id": tool_call_id, "content": err})
                        logger.warning(f"Tool error: send_emotion_emoji -> {err}")

                elif _emoji_plugin is not None and func_name in getattr(_emoji_plugin, "TOOL_NAMES", set()):
                    logger.info(f"Tool call: {func_name} [args={str(args)[:120]}]")
                    delivered = await _emoji_plugin.execute(role_data, args)
                    if delivered:
                        emojis_called.extend(delivered)
                        tool_result = f"已发送表情（{len(delivered)} 个）"
                    else:
                        tool_result = "没有找到匹配的表情包"
                    messages.append({"role": "tool", "tool_call_id": tool_call_id, "content": tool_result})
                    logger.info(f"Tool result: {func_name} -> {tool_result}")

                elif func_name == "web_search":
                    query = str(args.get("query", "")).strip()
                    max_results = int(args.get("max_results", 3))
                    allow_search = role_data.get("allow_web_search", True) if isinstance(role_data, dict) else True
                    logger.info(f"Tool call: web_search [query={query[:80]}, max_results={max_results}]")
                    if not allow_search:
                        tool_result = "该角色未启用联网搜索功能"
                    elif query:
                        tool_result = await execute_web_search(role_data, query, max_results)
                    else:
                        tool_result = "参数不完整：query 为必填"
                    messages.append({"role": "tool", "tool_call_id": tool_call_id, "content": tool_result})
                    logger.info(f"Tool result: web_search -> {tool_result[:100]}")

                elif func_name == "write_memory":
                    summary = str(
                        args.get("summary") or args.get("content") or ""
                    ).strip()
                    occurred_at = str(args.get("occurred_at") or "").strip() or None
                    logger.info(
                        "Tool call: write_memory [summary=%s, occurred_at=%s]",
                        summary[:80],
                        occurred_at,
                    )
                    if summary:
                        tool_result = await execute_write_memory(
                            role_data, summary, occurred_at
                        )
                    else:
                        tool_result = "参数不完整：summary 为必填"
                    messages.append({"role": "tool", "tool_call_id": tool_call_id, "content": tool_result})
                    logger.info(f"Tool result: write_memory -> {tool_result[:100]}")

                elif func_name == "recognize_image":
                    focus = str(args.get("focus", "")).strip()
                    try:
                        image_index = int(args.get("image_index", 0))
                    except (TypeError, ValueError):
                        image_index = 0
                    urls = list((vision_context or {}).get("image_data_urls") or [])
                    logger.info(f"Tool call: recognize_image [focus={focus}, image_index={image_index}]")
                    tool_result = await execute_recognize_image(urls, focus, image_index)
                    messages.append({"role": "tool", "tool_call_id": tool_call_id, "content": tool_result})
                    recognized_current_image = True
                    logger.info(f"Tool result: recognize_image -> {tool_result[:100]}")

                elif func_name == "review_previous_images":
                    prompt = str(args.get("prompt", "")).strip()
                    try:
                        image_index = int(args.get("image_index", 0))
                    except (TypeError, ValueError):
                        image_index = 0
                    urls = list((vision_context or {}).get("previous_image_data_urls") or [])
                    logger.info(
                        "Tool call: review_previous_images [prompt=%s, image_index=%s]",
                        prompt,
                        image_index,
                    )
                    tool_result = await execute_recognize_image(urls, prompt, image_index)
                    messages.append({"role": "tool", "tool_call_id": tool_call_id, "content": tool_result})
                    logger.info(f"Tool result: review_previous_images -> {tool_result[:100]}")
            except Exception as e:
                logger.error(f"Tool execution error: {func_name} -> {e}")
                messages.append({"role": "tool", "tool_call_id": tool_call_id, "content": f"操作失败：{e}"})

        tool_count = len(result["tool_calls"])
        logger.info(f"Re-calling AI with {tool_count} tool result(s) (round {round_idx+1}/{max_rounds})")
        result = await _call_with_role_config(
            role_data,
            messages,
            default_temp=1.2,
            tools=tools,
        )

        if not result.get("tool_calls"):
            if recognized_current_image:
                result["_recognized_current_image"] = True
            result["_emojis_called"] = _prefer_precise_emoji_deliveries(emojis_called)
            return result

    logger.warning(f"Tool call loop reached max {max_rounds} rounds, returning last result")
    if recognized_current_image:
        result["_recognized_current_image"] = True
    result["_emojis_called"] = _prefer_precise_emoji_deliveries(emojis_called)
    return result

async def generate_moment_post(
    role_data: Dict,
    history: Optional[List[Dict]] = None,
    core_memory_context: Optional[str] = None,
) -> Dict[str, Any]:
    """
    生成朋友圈内容
    """
    prompt = (
        "现在请发布一条朋友圈动态。要求：\n"
        "- 内容简短自然（20-100字）\n"
        "- 严格符合你的角色人设、系统提示词和与用户的既有关系\n"
        "- 可以是生活感悟、心情分享、日常记录\n"
        "- 不要提及\"AI\"\"系统\"\"人设\"等词\n"
        "- 结合历史消息（如果有的话）来丰富内容，但不要完全依赖历史消息。\n"
        "- 将最终朋友圈正文放在一个<对话>标签中；不要输出动作、声音、心理、数值或解释。"
    )
    return await generate_with_role(
        role_data=role_data,
        user_message=prompt,
        history=history,
        core_memory_context=core_memory_context,
        origin="moments",
        sender="system",
    )

async def generate_moment_comment(
    role_data: Dict,
    post_content: str,
    post_author: str,
    reply_to: Optional[str] = None,
    reply_to_name: Optional[str] = None,
    comment_thread: Optional[List[Dict[str, Any]]] = None,
    history: Optional[List[Dict]] = None,
    core_memory_context: Optional[str] = None,
) -> Dict[str, Any]:
    """
    生成朋友圈评论
    """
    if reply_to:
        target_name = str(reply_to_name or "对方").strip() or "对方"
        action = f"请回复{target_name}的这条评论：{reply_to}"
    else:
        action = "请评论这条朋友圈"

    thread_lines: List[str] = []
    for comment in (comment_thread or [])[-20:]:
        if not isinstance(comment, dict):
            continue
        author = str(comment.get("author_name") or "用户").strip() or "用户"
        reply_name = str(comment.get("reply_to_name") or "").strip()
        content = str(comment.get("content") or "").strip()
        if not content:
            continue
        recipient = f" 回复 {reply_name}" if reply_name else ""
        thread_lines.append(f"{author}{recipient}：{content}")
    thread_context = "\n".join(thread_lines) or "暂无其他评论"

    prompt = (
        f"{post_author}发了一条朋友圈：「{post_content}」\n\n"
        f"当前评论串：\n{thread_context}\n\n"
        f"{action}。要求：\n"
        "- 简短自然（5-30字）\n"
        "- 严格符合你的角色人设、系统提示词和与用户的既有关系\n"
        "- 像朋友间的互动，并结合评论串避免重复或答非所问\n"
        "- 可以用表情或语气词\n"
        "- 不要太正式\n"
        "- 将最终评论正文放在一个<对话>标签中；不要输出动作、声音、心理、数值或解释。"
    )
    return await generate_with_role(
        role_data=role_data,
        user_message=prompt,
        history=history,
        core_memory_context=core_memory_context,
        origin="moments",
        sender="system",
    )
