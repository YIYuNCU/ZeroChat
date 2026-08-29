"""
设置路由
管理全局配置的 API 端点
"""
import hashlib
import re
from typing import List, Optional
from urllib.parse import parse_qsl, urlencode, urlsplit, urlunsplit
from pydantic import BaseModel, ConfigDict
from fastapi import APIRouter, HTTPException, Query

import logging
from core.utils import ensure_path_within_root, ensure_simple_path_segment, mask_api_key
from core.quiet_rules import ProviderQuietRule

logger = logging.getLogger(__name__)

router = APIRouter()

# 导入设置服务
from services import settings_service


def _is_google_gemini_url(api_url: str) -> bool:
    try:
        return (urlsplit(str(api_url or "")).hostname or "").lower() == "generativelanguage.googleapis.com"
    except (TypeError, ValueError):
        return False


def _with_gemini_api_key(api_url: str, api_key: str) -> str:
    parsed = urlsplit(api_url)
    query = [(key, value) for key, value in parse_qsl(parsed.query, keep_blank_values=True) if key != "key"]
    query.append(("key", api_key))
    return urlunsplit((parsed.scheme, parsed.netloc, parsed.path, urlencode(query), ""))


def _models_request(
    api_url: str, api_key: str, api_format: str = "auto",
) -> tuple[str, dict[str, str], bool]:
    """Build a model-list request for OpenAI-compatible or native Gemini APIs."""
    value = str(api_url or "").strip().rstrip("/")
    normalized_format = str(api_format or "auto").strip().lower()
    is_native_gemini = (
        normalized_format == "gemini_native"
        or (
            _is_google_gemini_url(value)
            and normalized_format != "openai_compatible"
            and "/openai" not in urlsplit(value).path.lower()
        )
    )
    if is_native_gemini:
        parsed = urlsplit(value)
        path = parsed.path.rstrip("/")
        # A saved endpoint can point at the native resource itself. Strip it
        # before requesting the collection resource to avoid duplicated paths.
        path = re.sub(r"/openai(?:/|$)", "/", path, count=1, flags=re.IGNORECASE)
        path = re.sub(r"/models(?:/.*)?$", "", path, flags=re.IGNORECASE)
        path = re.sub(r"/chat/completions$", "", path, flags=re.IGNORECASE).rstrip("/")
        if not path.lower().endswith(("/v1", "/v1beta")):
            path = f"{path}/v1beta"
        return (
            _with_gemini_api_key(
                urlunsplit((parsed.scheme, parsed.netloc, f"{path}/models", "", "")),
                api_key,
            ),
            {},
            True,
        )
    parsed = urlsplit(value)
    path = parsed.path.rstrip("/")
    if (
        _is_google_gemini_url(value)
        and normalized_format == "openai_compatible"
        and "/openai" not in path.lower()
    ):
        path = f"{path}/openai"
    if path.endswith("/chat/completions"):
        path = path[:-len("/chat/completions")]
    if not path.endswith("/models"):
        if _is_google_gemini_url(value) and path.endswith("/openai"):
            path = f"{path}/models"
        else:
            path = f"{path}/models" if path.endswith("/v1") else f"{path}/v1/models"
    return urlunsplit((parsed.scheme, parsed.netloc, path, "", "")), {"Authorization": f"Bearer {api_key}"}, False


def _model_ids(payload: dict, native_gemini: bool) -> list[str]:
    records = payload.get("models") if native_gemini else payload.get("data")
    if not isinstance(records, list):
        return []
    result = []
    for item in records:
        if not isinstance(item, dict):
            continue
        if native_gemini:
            methods = item.get("supportedGenerationMethods")
            if isinstance(methods, list) and "generateContent" not in methods:
                continue
            model_id = str(item.get("name") or "").removeprefix("models/")
        else:
            model_id = str(item.get("id") or "")
        if model_id:
            result.append(model_id)
    return sorted(set(result))

class SettingsUpdate(BaseModel):
    model_config = ConfigDict(extra="forbid")

    ai_api_url: Optional[str] = None
    ai_api_key: Optional[str] = None
    ai_model: Optional[str] = None
    ai_api_format: Optional[str] = None
    ai_timeout_seconds: Optional[int] = None
    ai_reasoning_effort: Optional[str] = None
    ai_stream: Optional[bool] = None
    intent_enabled: Optional[bool] = None
    intent_api_url: Optional[str] = None
    intent_api_key: Optional[str] = None
    intent_model: Optional[str] = None
    intent_api_format: Optional[str] = None
    vision_enabled: Optional[bool] = None
    vision_api_url: Optional[str] = None
    vision_api_key: Optional[str] = None
    vision_model: Optional[str] = None
    vision_mode: Optional[str] = None
    vision_api_format: Optional[str] = None
    embedding_enabled: Optional[bool] = None
    embedding_api_url: Optional[str] = None
    embedding_api_key: Optional[str] = None
    embedding_model: Optional[str] = None
    quiet_rules: Optional[List[ProviderQuietRule]] = None
    host: Optional[str] = None
    port: Optional[int] = None

@router.get("/settings")
async def get_settings(include_secrets: bool = Query(False)):
    """获取全局设置"""
    settings = dict(settings_service.load_settings())

    # 默认隐藏敏感信息，避免泄露；用于新安装客户端全量同步时可显式请求明文
    if not include_secrets:
        for key_name in ("ai_api_key", "intent_api_key", "vision_api_key", "embedding_api_key"):
            masked = mask_api_key(settings.get(key_name))
            if masked is not None:
                settings[f"{key_name}_masked"] = masked
                del settings[key_name]
    return {"settings": settings}

@router.put("/settings")
async def update_settings(update: SettingsUpdate):
    """更新全局设置"""
    updates = {}
    
    if update.ai_api_url is not None:
        updates["ai_api_url"] = update.ai_api_url
    if update.ai_api_key is not None:
        updates["ai_api_key"] = update.ai_api_key
    if update.ai_model is not None:
        updates["ai_model"] = update.ai_model
    if update.ai_api_format is not None:
        value = update.ai_api_format.strip().lower()
        updates["ai_api_format"] = value if value in {"auto", "gemini_native", "openai_compatible"} else "auto"
    if update.ai_timeout_seconds is not None:
        updates["ai_timeout_seconds"] = max(1, min(3600, update.ai_timeout_seconds))
    if update.ai_reasoning_effort is not None:
        updates["ai_reasoning_effort"] = update.ai_reasoning_effort.strip()
    if update.ai_stream is not None:
        updates["ai_stream"] = update.ai_stream
    if update.intent_enabled is not None:
        updates["intent_enabled"] = update.intent_enabled
    if update.intent_api_url is not None:
        updates["intent_api_url"] = update.intent_api_url
    if update.intent_api_key is not None:
        updates["intent_api_key"] = update.intent_api_key
    if update.intent_model is not None:
        updates["intent_model"] = update.intent_model
    if update.intent_api_format is not None:
        value = update.intent_api_format.strip().lower()
        updates["intent_api_format"] = value if value in {"auto", "gemini_native", "openai_compatible"} else "auto"
    if update.vision_enabled is not None:
        updates["vision_enabled"] = update.vision_enabled
    if update.vision_api_url is not None:
        updates["vision_api_url"] = update.vision_api_url
    if update.vision_api_key is not None:
        updates["vision_api_key"] = update.vision_api_key
    if update.vision_model is not None:
        updates["vision_model"] = update.vision_model
    if update.vision_mode is not None:
        mode = update.vision_mode.strip().lower()
        updates["vision_mode"] = mode if mode in {"standalone", "pre_model", "tool"} else "standalone"
    if update.vision_api_format is not None:
        value = update.vision_api_format.strip().lower()
        updates["vision_api_format"] = value if value in {"auto", "gemini_native", "openai_compatible"} else "auto"
    if update.embedding_enabled is not None:
        updates["embedding_enabled"] = update.embedding_enabled
    if update.embedding_api_url is not None:
        updates["embedding_api_url"] = update.embedding_api_url
    if update.embedding_api_key is not None:
        updates["embedding_api_key"] = update.embedding_api_key
    if update.embedding_model is not None:
        updates["embedding_model"] = update.embedding_model
    if update.quiet_rules is not None:
        updates["quiet_rules"] = [
            rule.model_dump(exclude_none=True) for rule in update.quiet_rules
        ]
    if update.host is not None:
        updates["host"] = update.host
    if update.port is not None:
        updates["port"] = update.port
    
    if updates:
        success = settings_service.save_settings(updates)
        if success:
            return {"success": True, "message": "Settings updated"}
        else:
            return {"success": False, "error": "Failed to save settings"}
    
    return {"success": True, "message": "No changes"}

@router.get("/settings/ai")
async def get_ai_settings():
    """获取 AI API 配置（不含敏感信息）"""
    config = settings_service.get_ai_config()
    # 隐藏 API KEY
    masked = mask_api_key(config.get("api_key"))
    if masked is not None:
        config["api_key_masked"] = masked
        del config["api_key"]
    return config


@router.get("/settings/vision")
async def get_vision_settings():
    """获取图像识别配置（不含敏感信息）"""
    config = settings_service.get_vision_config()
    masked = mask_api_key(config.get("api_key"))
    if masked is not None:
        config["api_key_masked"] = masked
        del config["api_key"]
    return config

@router.get("/settings/models")
async def get_available_models():
    """获取 API 可用模型列表"""
    import httpx
    
    config = settings_service.get_ai_config()
    api_url = config.get("api_url", "")
    api_key = config.get("api_key", "")
    
    if not api_url or not api_key:
        return {"success": False, "error": "API 未配置", "models": []}
    
    # 尝试获取模型列表
    try:
        async with httpx.AsyncClient(timeout=10.0) as client:
            # 构建 models 端点 URL
            models_url, headers, native_gemini = _models_request(
                api_url, api_key, config.get("api_format", "auto"),
            )
            response = await client.get(
                models_url,
                headers=headers,
            )
            
            if response.status_code == 200:
                data = response.json()
                models = _model_ids(data, native_gemini)
                # 提取模型 ID 列表
                model_ids = models
                # 过滤常见的可用模型
                chat_models = [m for m in model_ids if any(x in m.lower() for x in ["gpt", "claude", "gemini", "llama", "qwen", "glm", "deepseek"])]
                return {"success": True, "models": chat_models or model_ids[:20]}
            else:
                return {"success": False, "error": f"HTTP {response.status_code}", "models": []}
    except Exception as e:
        logger.warning("获取模型列表失败 url=%s: %s", api_url, e)
        return {"success": False, "error": "无法连接到 API 或请求失败", "models": []}

# 头像上传
from fastapi import UploadFile, File
from pathlib import Path
import shutil
import uuid

DATA_DIR = Path(__file__).parent.parent / "data"
AVATARS_DIR = DATA_DIR / "avatars"
ALLOWED_AVATAR_EXTENSIONS = {".png", ".jpg", ".jpeg", ".gif", ".webp"}


def _normalize_avatar_filename(filename: str) -> str:
    try:
        return ensure_simple_path_segment(filename, "filename")
    except ValueError as exc:
        raise HTTPException(status_code=400, detail=str(exc)) from exc

@router.post("/settings/avatar")
async def upload_avatar(file: UploadFile = File(...)):
    """上传用户头像"""
    AVATARS_DIR.mkdir(parents=True, exist_ok=True)
    
    # 生成唯一文件名
    ext = f".{file.filename.split('.')[-1].lower()}" if "." in (file.filename or "") else ".jpg"
    if ext not in ALLOWED_AVATAR_EXTENSIONS:
        raise HTTPException(status_code=400, detail=f"Unsupported file type: {ext}")
    filename = f"user_avatar_{uuid.uuid4().hex[:8]}{ext}"
    filepath = ensure_path_within_root(AVATARS_DIR / filename, AVATARS_DIR)
    
    # 保存文件
    with open(filepath, "wb") as f:
        shutil.copyfileobj(file.file, f)

    with open(filepath, "rb") as f:
        avatar_hash = hashlib.md5(f.read()).hexdigest()
    
    # 返回相对路径
    return {
        "success": True,
        "filename": filename,
        "path": f"/api/avatars/{filename}",
        "hash": avatar_hash,
    }

@router.get("/avatars/{filename}")
async def get_avatar(filename: str):
    """获取头像文件"""
    from fastapi.responses import FileResponse
    safe_name = _normalize_avatar_filename(filename)
    filepath = ensure_path_within_root(AVATARS_DIR / safe_name, AVATARS_DIR)
    if filepath.exists():
        return FileResponse(filepath)
    return {"error": "not found"}
