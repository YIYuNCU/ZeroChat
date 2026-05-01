"""
设置服务
管理全局配置（API URL、KEY、模型等）
"""
import json
from pathlib import Path
from typing import Optional, Dict, Any

CONFIG_DIR = Path(__file__).parent.parent / "config"

def get_settings_file() -> Path:
    CONFIG_DIR.mkdir(parents=True, exist_ok=True)
    return CONFIG_DIR / "settings.json"

def get_default_settings() -> Dict[str, Any]:
    """获取默认设置"""
    return {
        "host": "0.0.0.0",
        "port": 8000,
        "ai_api_url": "",
        "ai_api_key": "",
        "ai_model": "gpt-3.5-turbo",
        "intent_enabled": False,
        "intent_api_url": "",
        "intent_api_key": "",
        "intent_model": "gpt-3.5-turbo",
        "vision_enabled": False,
        "vision_api_url": "",
        "vision_api_key": "",
        "vision_model": "gpt-4o",
        "vision_mode": "standalone",
        "embedding_enabled": True,
        "embedding_api_url": "",
        "embedding_api_key": "",
        "embedding_model": "",
        "updated_at": None
    }

def load_settings() -> Dict[str, Any]:
    """加载设置"""
    settings_file = get_settings_file()
    default = get_default_settings()
    
    if settings_file.exists():
        try:
            with open(settings_file, "r", encoding="utf-8") as f:
                saved = json.load(f)
                return {**default, **saved}
        except Exception:
            pass
    
    return default

def save_settings(settings: Dict[str, Any]) -> bool:
    """保存设置"""
    try:
        settings_file = get_settings_file()
        
        # 合并现有设置
        current = load_settings()
        current.update(settings)
        
        # 添加更新时间
        from datetime import datetime
        current["updated_at"] = datetime.now().isoformat()
        
        with open(settings_file, "w", encoding="utf-8") as f:
            json.dump(current, f, indent=2, ensure_ascii=False)
        
        return True
    except Exception as e:
        print(f"Error saving settings: {e}")
        return False

def get_ai_config() -> Dict[str, str]:
    """获取 AI API 配置"""
    settings = load_settings()
    return {
        "api_url": settings.get("ai_api_url", ""),
        "api_key": settings.get("ai_api_key", ""),
        "model": settings.get("ai_model", "gpt-3.5-turbo")
    }


def get_intent_config() -> Dict[str, Any]:
    """获取意图识别配置"""
    settings = load_settings()
    return {
        "enabled": bool(settings.get("intent_enabled", False)),
        "api_url": settings.get("intent_api_url", ""),
        "api_key": settings.get("intent_api_key", ""),
        "model": settings.get("intent_model", "gpt-3.5-turbo"),
    }


def get_vision_config() -> Dict[str, Any]:
    """获取图像识别配置（全角色）"""
    settings = load_settings()
    mode = str(settings.get("vision_mode", "standalone") or "standalone").strip().lower()
    if mode not in {"standalone", "pre_model"}:
        mode = "standalone"
    return {
        "enabled": bool(settings.get("vision_enabled", False)),
        "api_url": settings.get("vision_api_url", ""),
        "api_key": settings.get("vision_api_key", ""),
        "model": settings.get("vision_model", "gpt-4o"),
        "mode": mode,
    }

def get_embedding_config() -> Dict[str, Any]:
    """获取嵌入向量配置"""
    settings = load_settings()
    enabled = bool(settings.get("embedding_enabled", True))
    api_url = settings.get("embedding_api_url", "") or settings.get("ai_api_url", "")
    api_key = settings.get("embedding_api_key", "") or settings.get("ai_api_key", "")
    model = settings.get("embedding_model", "") or _default_embedding_model(api_url)
    return {
        "enabled": enabled,
        "api_url": api_url,
        "api_key": api_key,
        "model": model,
    }


def _default_embedding_model(api_url: str) -> str:
    if "deepseek" in api_url.lower():
        return "deepseek-embedding"
    if "siliconflow" in api_url.lower():
        return "BAAI/bge-m3"
    return "text-embedding-ada-002"


def update_ai_config(api_url: Optional[str] = None, 
                     api_key: Optional[str] = None,
                     model: Optional[str] = None) -> bool:
    """更新 AI API 配置"""
    updates = {}
    if api_url is not None:
        updates["ai_api_url"] = api_url
    if api_key is not None:
        updates["ai_api_key"] = api_key
    if model is not None:
        updates["ai_model"] = model
    
    if updates:
        return save_settings(updates)
    return True
