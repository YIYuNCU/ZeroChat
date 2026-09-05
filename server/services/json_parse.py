"""
集中式 AI 生成内容 JSON 解析工具

统一处理 AI 输出中常见的 JSON 提取场景：
1. 剥离 markdown 代码围栏（```json ... ```）
2. 直接 json.loads
3. 截取首个 { 到末个 } 再解析

并提供 call_ai_json：在需要结构化输出的调用点包一层
「解析失败自动重新请求」的逻辑（默认最多重试 2 次，共 3 次）。
"""
import json
import re
from typing import Any, Dict, List, Optional

# 剥离 ```json / ``` 等代码围栏
_FENCE_OPEN_RE = re.compile(r"^```[a-zA-Z0-9_-]*\n?")


def _strip_code_fence(text: str) -> str:
    """去除 markdown 代码围栏包裹。"""
    stripped = text.strip()
    if stripped.startswith("```") and stripped.endswith("```"):
        stripped = _FENCE_OPEN_RE.sub("", stripped).rstrip("`").strip()
    return stripped


def extract_json(text: Any) -> Optional[Any]:
    """从 AI 输出文本中提取并解析 JSON。

    依次尝试：直接解析 -> 去围栏后解析 -> 截取首末花括号后解析。
    解析失败返回 None。
    """
    raw = str(text or "").strip()
    if not raw:
        return None

    # 1) 直接解析
    try:
        return json.loads(raw)
    except Exception:
        pass

    # 2) 去除代码围栏后解析
    cleaned = _strip_code_fence(raw)
    if cleaned != raw:
        try:
            return json.loads(cleaned)
        except Exception:
            pass

    # 3) 截取首个 { 到末个 }（对象）或 [ 到 ]（数组）后解析
    for open_ch, close_ch in (("{", "}"), ("[", "]")):
        start = cleaned.find(open_ch)
        end = cleaned.rfind(close_ch)
        if start != -1 and end != -1 and end > start:
            try:
                return json.loads(cleaned[start : end + 1])
            except Exception:
                continue

    return None


def extract_json_object(text: Any) -> Optional[Dict[str, Any]]:
    """提取 JSON 且要求结果为 dict，否则返回 None。"""
    parsed = extract_json(text)
    return parsed if isinstance(parsed, dict) else None


# 追加到消息末尾用于纠正模型输出的提示
_RETRY_HINT = (
    "上一次的回复无法被解析为合法 JSON。请严格只输出一个合法的 JSON，"
    "不要包含任何解释文字、markdown 代码围栏或额外内容。"
)


async def call_ai_json(
    messages: List[Dict[str, str]],
    *,
    api_url: Optional[str] = None,
    api_key: Optional[str] = None,
    model: Optional[str] = None,
    temperature: float = 0.3,
    max_tokens: int = 1000,
    max_retries: int = 2,
    require_object: bool = True,
    direct: bool = False,
    api_format: Optional[str] = None,
    thinking_config: Optional[Dict[str, Any]] = None,
) -> Dict[str, Any]:
    """调用 AI 并解析其输出为 JSON，解析失败时自动重新请求。

    Args:
        messages: 消息列表，会在重试时被追加纠正提示（内部拷贝，不修改入参）。
        api_url/api_key/model: 传给底层调用；direct=True 时必填。
        max_retries: 最大重试次数（不含首次），默认 2，即最多请求 3 次。
        require_object: True 时要求解析结果为 dict。
        direct: True 使用 call_ai_direct（不依赖全局配置），否则使用 call_ai。

    Returns:
        {"success": bool, "data": Any | None, "content": str, "error": str | None}
    """
    # 延迟导入避免循环依赖
    from services.ai_service import call_ai, call_ai_direct

    convo = [dict(m) for m in messages]
    last_content = ""
    last_error: Optional[str] = None

    for attempt in range(max_retries + 1):
        if direct:
            if not api_url or not api_key or not model:
                return {"success": False, "data": None, "content": "", "error": "AI API 未配置"}
            result = await call_ai_direct(
                messages=convo,
                api_url=api_url,
                api_key=api_key,
                model=model,
                temperature=temperature,
                max_tokens=max_tokens,
                api_format=api_format,
                **(thinking_config or {}),
            )
        else:
            result = await call_ai(
                messages=convo,
                model=model,
                api_url=api_url,
                api_key=api_key,
                temperature=temperature,
                max_tokens=max_tokens,
                api_format=api_format,
                **(thinking_config or {}),
            )

        if not result.get("success"):
            last_error = result.get("error") or "ai request failed"
            # API 层失败（网络/鉴权等）通常重试无益，直接返回
            return {"success": False, "data": None, "content": "", "error": last_error}

        last_content = (result.get("content") or "").strip()
        parsed = extract_json(last_content)
        ok = parsed is not None and (not require_object or isinstance(parsed, dict))
        if ok:
            return {"success": True, "data": parsed, "content": last_content, "error": None}

        last_error = "invalid json response"
        # 追加纠正提示后重试（保留上一次的原始输出以便模型自我修正）
        if attempt < max_retries:
            convo.append({"role": "assistant", "content": last_content})
            convo.append({"role": "user", "content": _RETRY_HINT})

    return {"success": False, "data": None, "content": last_content, "error": last_error}
