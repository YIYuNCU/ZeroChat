"""
设置路由
管理全局配置的 API 端点
"""
from typing import Optional
import hashlib
from pydantic import BaseModel, ConfigDict
from fastapi import APIRouter, Query

router = APIRouter()

# 导入设置服务
from services import settings_service

class SettingsUpdate(BaseModel):
    model_config = ConfigDict(extra="forbid")

    ai_api_url: Optional[str] = None
    ai_api_key: Optional[str] = None
    ai_model: Optional[str] = None
    intent_enabled: Optional[bool] = None
    intent_api_url: Optional[str] = None
    intent_api_key: Optional[str] = None
    intent_model: Optional[str] = None
    vision_enabled: Optional[bool] = None
    vision_api_url: Optional[str] = None
    vision_api_key: Optional[str] = None
    vision_model: Optional[str] = None
    vision_mode: Optional[str] = None
    host: Optional[str] = None
    port: Optional[int] = None

@router.get("/settings")
async def get_settings(include_secrets: bool = Query(False)):
    """获取全局设置"""
    settings = settings_service.load_settings()

    # 默认隐藏敏感信息，避免泄露；用于新安装客户端全量同步时可显式请求明文
    if not include_secrets:
        if settings.get("ai_api_key"):
            key = settings["ai_api_key"]
            settings["ai_api_key_masked"] = f"{key[:8]}...{key[-4:]}" if len(key) > 12 else "***"
            del settings["ai_api_key"]
        if settings.get("intent_api_key"):
            key = settings["intent_api_key"]
            settings["intent_api_key_masked"] = f"{key[:8]}...{key[-4:]}" if len(key) > 12 else "***"
            del settings["intent_api_key"]
        if settings.get("vision_api_key"):
            key = settings["vision_api_key"]
            settings["vision_api_key_masked"] = f"{key[:8]}...{key[-4:]}" if len(key) > 12 else "***"
            del settings["vision_api_key"]
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
    if update.intent_enabled is not None:
        updates["intent_enabled"] = update.intent_enabled
    if update.intent_api_url is not None:
        updates["intent_api_url"] = update.intent_api_url
    if update.intent_api_key is not None:
        updates["intent_api_key"] = update.intent_api_key
    if update.intent_model is not None:
        updates["intent_model"] = update.intent_model
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
        updates["vision_mode"] = mode if mode in {"standalone", "pre_model"} else "standalone"
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
    if config.get("api_key"):
        key = config["api_key"]
        config["api_key_masked"] = f"{key[:8]}...{key[-4:]}" if len(key) > 12 else "***"
        del config["api_key"]
    return config


@router.get("/settings/vision")
async def get_vision_settings():
    """获取图像识别配置（不含敏感信息）"""
    config = settings_service.get_vision_config()
    if config.get("api_key"):
        key = config["api_key"]
        config["api_key_masked"] = f"{key[:8]}...{key[-4:]}" if len(key) > 12 else "***"
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
            models_url = api_url.rstrip("/")
            if not models_url.endswith("/models"):
                models_url = f"{models_url}/models"
            
            response = await client.get(
                models_url,
                headers={"Authorization": f"Bearer {api_key}"}
            )
            
            if response.status_code == 200:
                data = response.json()
                models = data.get("data", [])
                # 提取模型 ID 列表
                model_ids = [m.get("id") for m in models if m.get("id")]
                # 过滤常见的可用模型
                chat_models = [m for m in model_ids if any(x in m.lower() for x in ["gpt", "claude", "gemini", "llama", "qwen", "glm", "deepseek"])]
                return {"success": True, "models": chat_models or model_ids[:20]}
            else:
                return {"success": False, "error": f"HTTP {response.status_code}", "models": []}
    except Exception as e:
        return {"success": False, "error": str(e), "models": []}

# 头像上传
from fastapi import UploadFile, File
from pathlib import Path
import shutil
import uuid

DATA_DIR = Path(__file__).parent.parent / "data"
AVATARS_DIR = DATA_DIR / "avatars"

@router.post("/settings/avatar")
async def upload_avatar(file: UploadFile = File(...)):
    """上传用户头像"""
    AVATARS_DIR.mkdir(parents=True, exist_ok=True)
    
    # 生成唯一文件名
    ext = file.filename.split(".")[-1] if "." in file.filename else "jpg"
    filename = f"user_avatar_{uuid.uuid4().hex[:8]}.{ext}"
    filepath = AVATARS_DIR / filename
    
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
    filepath = AVATARS_DIR / filename
    if filepath.exists():
        return FileResponse(filepath)
    return {"error": "not found"}

