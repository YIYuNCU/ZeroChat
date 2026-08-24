"""
Vision / 图片识别共享工具模块
提供 OneBot 与 WebSocket 前端共用的图片识别处理逻辑
"""
import base64
import hashlib
import json
import logging
from pathlib import Path
from typing import Any, Dict, List, Optional
from urllib.parse import urlsplit, urlunsplit

import httpx

from services.memory_service import append_short_term
from core.utils import is_tool_role_id

logger = logging.getLogger(__name__)

_VISION_HISTORY_DIR = Path(__file__).parent.parent / "data" / "vision_history"
DEEPSEEK_FILE_TTL_SECONDS = 24 * 60 * 60


class VisionApiError(RuntimeError):
    """A provider-facing vision failure that can be shown to API callers."""


def _history_file(role_id: str, conversation_scope: str) -> Path:
    scope = f"{role_id}\0{conversation_scope}".encode("utf-8")
    return _VISION_HISTORY_DIR / f"{hashlib.sha256(scope).hexdigest()}.json"


def load_previous_images(role_id: str, conversation_scope: str) -> List[str]:
    """Return the prior image batch for this role and conversation only."""
    if not role_id or not conversation_scope:
        return []
    try:
        with open(_history_file(role_id, conversation_scope), "r", encoding="utf-8") as f:
            data = json.load(f)
        images = data.get("images") if isinstance(data, dict) else None
        if not isinstance(images, list):
            return []
        return [str(image) for image in images if str(image).startswith("data:image/")]
    except (FileNotFoundError, OSError, json.JSONDecodeError):
        return []


def save_previous_images(role_id: str, conversation_scope: str, image_data_urls: List[str]) -> None:
    """Replace the prior image batch for one role and one conversation."""
    if not role_id or not conversation_scope:
        return
    images = [str(image) for image in image_data_urls if str(image).startswith("data:image/")]
    if not images:
        return
    target = _history_file(role_id, conversation_scope)
    try:
        target.parent.mkdir(parents=True, exist_ok=True)
        temp = target.with_suffix(".tmp")
        with open(temp, "w", encoding="utf-8") as f:
            json.dump({"images": images}, f, ensure_ascii=False)
        temp.replace(target)
    except OSError as error:
        logger.warning("Unable to save previous image batch: %s", error)


def guess_image_mime(data: bytes) -> Optional[str]:
    """从文件头推测图片 MIME 类型"""
    if data[:3] == b'\xff\xd8\xff':
        return "image/jpeg"
    if data[:4] == b'\x89PNG':
        return "image/png"
    if data[:6] in (b'GIF87a', b'GIF89a'):
        return "image/gif"
    if data[:4] == b'RIFF' and data[8:12] == b'WEBP':
        return "image/webp"
    return None


def normalize_chat_completions_endpoint(api_url: str) -> str:
    """规范化 API URL 到 /chat/completions 路径"""
    value = str(api_url or "").strip().rstrip("/")
    if not value:
        return ""
    if value.endswith("/chat/completions"):
        return value
    if value.endswith("/v1"):
        return f"{value}/chat/completions"
    if "/v1/" in value:
        return f"{value.rstrip('/')}/chat/completions"
    return f"{value}/v1/chat/completions"


def _is_deepseek_vision(model: str, api_url: str) -> bool:
    try:
        host = (urlsplit(api_url).hostname or "").lower()
    except (TypeError, ValueError):
        host = ""
    return model.strip().lower() == "deepseek-v4-flash-vision-exp" and host.endswith("deepseek.com")


def _deepseek_files_endpoint(api_url: str) -> str:
    parsed = urlsplit(str(api_url or "").strip())
    path = parsed.path.rstrip("/")
    for suffix in ("/v1/chat/completions", "/chat/completions", "/v1"):
        if path.endswith(suffix):
            path = path[:-len(suffix)]
            break
    return urlunsplit((parsed.scheme, parsed.netloc, f"{path}/files", "", ""))


def _decode_image_data_url(image_url: str) -> tuple[str, bytes]:
    if not image_url.startswith("data:") or ";base64," not in image_url:
        raise VisionApiError("DeepSeek vision requires an image data URL from the local upload")
    header, encoded = image_url.split(",", 1)
    mime_type = header[5:].split(";", 1)[0].strip()
    if mime_type not in {"image/jpeg", "image/png", "image/gif", "image/webp"}:
        raise VisionApiError(f"DeepSeek vision does not support image MIME type: {mime_type or 'unknown'}")
    try:
        return mime_type, base64.b64decode(encoded, validate=True)
    except ValueError as error:
        raise VisionApiError("Invalid image data for DeepSeek vision") from error


async def _upload_deepseek_vision_file(api_url: str, api_key: str, image_url: str) -> str:
    mime_type, image_bytes = _decode_image_data_url(image_url)
    if not image_bytes:
        raise VisionApiError("DeepSeek vision image is empty")
    extension = {"image/jpeg": "jpg", "image/png": "png", "image/gif": "gif", "image/webp": "webp"}[mime_type]
    try:
        async with httpx.AsyncClient(timeout=httpx.Timeout(600.0, connect=20.0)) as client:
            response = await client.post(
                _deepseek_files_endpoint(api_url),
                headers={"Authorization": f"Bearer {api_key}"},
                data={
                    "purpose": "user_data",
                    "expires_after[anchor]": "created_at",
                    "expires_after[seconds]": str(DEEPSEEK_FILE_TTL_SECONDS),
                },
                files={"file": (f"vision.{extension}", image_bytes, mime_type)},
            )
            response.raise_for_status()
            file_id = str(response.json().get("id") or "").strip()
    except httpx.HTTPError as error:
        raise VisionApiError("DeepSeek vision file upload failed") from error
    except (TypeError, ValueError, json.JSONDecodeError) as error:
        raise VisionApiError("DeepSeek vision file upload returned an invalid response") from error
    if not file_id:
        raise VisionApiError("DeepSeek vision file upload did not return file_id")
    return file_id


async def _prepare_deepseek_file_messages(
    messages: List[Dict[str, Any]], api_url: str, api_key: str, model: str,
) -> List[Dict[str, Any]]:
    if not _is_deepseek_vision(model, api_url):
        return messages
    prepared: List[Dict[str, Any]] = []
    for message in messages:
        copied = dict(message)
        content = message.get("content")
        if not isinstance(content, list):
            prepared.append(copied)
            continue
        parts: List[Dict[str, Any]] = []
        for part in content:
            if isinstance(part, dict) and part.get("type") == "image_url":
                image = part.get("image_url") or {}
                image_url = str(image.get("url") if isinstance(image, dict) else image)
                file_id = await _upload_deepseek_vision_file(api_url, api_key, image_url)
                parts.append({"type": "file", "file_id": file_id})
            else:
                parts.append(part)
        copied["content"] = parts
        prepared.append(copied)
    return prepared


def resolve_vision_config() -> Dict[str, str]:
    """统一解析 Vision 配置，回退到全局 AI 配置"""
    from services import settings_service

    vision_cfg = settings_service.get_vision_config()
    global_ai = settings_service.get_ai_config()
    uses_vision_endpoint = bool(
        str(vision_cfg.get("api_url") or "").strip()
        or str(vision_cfg.get("api_key") or "").strip()
    )

    return {
        "api_url": str(vision_cfg.get("api_url") or "").strip() or str(global_ai.get("api_url") or "").strip(),
        "api_key": str(vision_cfg.get("api_key") or "").strip() or str(global_ai.get("api_key") or "").strip(),
        "model": str(vision_cfg.get("model") or "").strip() or str(global_ai.get("model") or "gpt-4o").strip(),
        "mode": str(vision_cfg.get("mode") or "standalone").strip().lower(),
        "api_format": str(
            (vision_cfg.get("api_format") if uses_vision_endpoint else global_ai.get("api_format"))
            or "auto"
        ).strip().lower(),
    }


def build_vision_messages(
    image_data_url: str,
    prompt: str,
    system_prompt: str = "",
) -> List[Dict[str, Any]]:
    """构造多模态 Vision API 请求消息数组"""
    messages: List[Dict[str, Any]] = []
    if system_prompt:
        messages.append({"role": "system", "content": system_prompt})
    messages.append({
        "role": "user",
        "content": [
            {"type": "image_url", "image_url": {"url": image_data_url}},
            {"type": "text", "text": prompt},
        ],
    })
    return messages


async def call_vision_api(
    api_url: str,
    api_key: str,
    body: Dict[str, Any],
    api_format: str = "auto",
) -> Optional[str]:
    """调用 OpenAI 兼容的 Vision API，返回图片描述文本。失败返回 None"""
    if not api_url or not api_key:
        return None
    try:
        from services.ai_service import _post_chat, _uses_native_gemini

        model = str(body.get("model") or "")
        messages = await _prepare_deepseek_file_messages(
            list(body.get("messages") or []), api_url, api_key, model,
        )
        request_url = api_url if _uses_native_gemini(model, api_url, api_format) else normalize_chat_completions_endpoint(api_url)
        result = await _post_chat(
            messages=messages,
            api_url=request_url,
            api_key=api_key,
            model=model,
            temperature=float(body.get("temperature", 0.7)),
            max_tokens=int(body.get("max_tokens", 1024)),
            tools=None,
            api_format=api_format,
        )
        if result.get("success"):
            return str(result.get("content") or "").strip() or None
        logger.warning("Vision API request failed: %s", result.get("error"))
        return None
    except VisionApiError:
        raise
    except Exception as e:
        logger.warning(f"Vision API 调用失败: {e}")
        return None


def append_vision_memory(
    role_id: Optional[str],
    user_prompt: str,
    final_reply: str,
    mode: str,
    image_understanding: Optional[str] = None,
) -> None:
    """将识图过程关键信息写入短期记忆"""
    rid = str(role_id or "").strip()
    if not rid or is_tool_role_id(rid):
        return

    prompt_text = (user_prompt or "").strip() or "请描述这张图片的内容"

    understanding = str(image_understanding or "").strip()
    if understanding:
        append_short_term(rid, "user", f"[图片识别结果/{mode}] {understanding}")
    else:
        append_short_term(rid, "user", f"[图片识别请求] {prompt_text}")
        append_short_term(rid, "assistant", f"[图片识别结果/{mode}] {(final_reply or '').strip()}")

    reply_text = (final_reply or "").strip()
    if reply_text and (not understanding or reply_text != understanding):
        append_short_term(rid, "assistant", f"[图片识别回复] {reply_text}")
